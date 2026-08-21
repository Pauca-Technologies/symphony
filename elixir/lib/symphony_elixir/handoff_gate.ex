defmodule SymphonyElixir.HandoffGate do
  @moduledoc """
  Runs the configured before_handoff hook and formats gate remediation.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue, Telemetry, Workspace}

  @telemetry_event [:symphony_elixir, :gate, :before_handoff]
  @handoff_target_states MapSet.new(["in review", "human review"])
  @source_state "in progress"

  @type gate_breakdown :: [
          %{
            name: String.t(),
            status: String.t(),
            passed: boolean(),
            detail: String.t() | nil
          }
        ]

  @type protocol_status :: :pending | :running | :passed | :failed | :invalidated | :infrastructure_error
  @type protocol_gate :: %{
          protocol_version: 1,
          job_id: String.t(),
          status: protocol_status(),
          identity: map(),
          candidate_hash: String.t(),
          exact_hash: String.t(),
          heartbeat_at: String.t() | nil,
          heartbeat_age_ms: non_neg_integer() | nil,
          next_poll_ms: pos_integer() | nil,
          progress: map(),
          started_at: String.t() | nil,
          completed_at: String.t() | nil,
          result_artifact: String.t() | nil,
          checks: list(),
          remediation: String.t() | nil,
          summary: String.t() | nil,
          single_flight: boolean() | nil
        }

  @type result ::
          :ok
          | {:passed, protocol_gate()}
          | {:pending, protocol_gate()}
          | {:blocked, String.t(), gate_breakdown()}
          | {:failed, String.t(), protocol_gate()}
          | {:invalidated, String.t(), protocol_gate()}
          | {:infrastructure_error, String.t(), protocol_gate() | map()}

  @spec handoff_transition?(String.t() | nil, String.t() | nil) :: boolean()
  def handoff_transition?(current_state, target_state) when is_binary(current_state) and is_binary(target_state) do
    normalize_state(current_state) == @source_state and
      MapSet.member?(@handoff_target_states, normalize_state(target_state))
  end

  def handoff_transition?(_current_state, _target_state), do: false

  @spec run_before_handoff(Path.t(), Issue.t(), term(), String.t(), keyword()) :: result()
  def run_before_handoff(workspace, %Issue{} = issue, worker_host, target_state, opts \\ [])
      when is_binary(workspace) and is_binary(target_state) do
    # Per-repo workflow overrides (T27 multi-repo dispatch): when AgentRunner
    # threads the consumer's WORKFLOW.md before_handoff command through, we
    # use it; otherwise fall back to the host-level Config (legacy single-
    # repo path).
    override = Keyword.get(opts, :hook_command)
    command = override || Config.settings!().hooks.before_handoff

    case command do
      nil ->
        :ok

      _command ->
        run_hook(workspace, issue, worker_host, target_state, opts)
    end
  end

  @doc "Poll an existing asynchronous before-handoff job without starting a new gate."
  @spec poll_before_handoff(Path.t(), Issue.t(), term(), String.t(), String.t(), keyword()) :: result()
  def poll_before_handoff(workspace, %Issue{} = issue, worker_host, target_state, job_id, opts \\ [])
      when is_binary(workspace) and is_binary(target_state) and is_binary(job_id) do
    run_hook(
      workspace,
      issue,
      worker_host,
      target_state,
      opts
      |> Keyword.put(:github_auth, false)
      |> Keyword.put(:prepare_issue_context, false)
      |> Keyword.put(:quiet, true)
      |> Keyword.put(:async, true)
      |> Keyword.put(:gate_job_id, job_id)
    )
  end

  @doc false
  @spec parse_protocol_result(String.t(), non_neg_integer(), String.t() | nil, pos_integer()) ::
          :legacy
          | {:ok, protocol_gate()}
          | {:candidate_changed, protocol_gate()}
          | {:error, String.t(), map()}
  def parse_protocol_result(output, exit_status, expected_candidate_hash, stale_ms)
      when is_binary(output) and is_integer(exit_status) and is_integer(stale_ms) and stale_ms > 0 do
    case decode_hook_report(output) do
      %{"protocolVersion" => 1} = report ->
        parse_protocol_report(report, exit_status, expected_candidate_hash, stale_ms)

      _report ->
        :legacy
    end
  end

  defp parse_protocol_report(report, exit_status, expected_candidate_hash, stale_ms) do
    with {:ok, gate} <- normalize_protocol_gate(report),
         :ok <- validate_protocol_exit(gate.status, exit_status),
         :ok <- validate_protocol_heartbeat(gate, stale_ms) do
      apply_expected_candidate(gate, expected_candidate_hash)
    else
      {:error, reason} -> {:error, reason, report}
    end
  end

  defp apply_expected_candidate(gate, expected_candidate_hash) do
    case validate_expected_candidate(gate, expected_candidate_hash) do
      :ok -> {:ok, gate}
      :candidate_changed -> {:candidate_changed, %{gate | status: :invalidated}}
    end
  end

  defp run_hook(workspace, issue, worker_host, target_state, opts) do
    settings = Config.settings!().hooks

    timeout_ms =
      Keyword.get(opts, :timeout_ms) || settings.before_handoff_timeout_ms || settings.timeout_ms

    stale_ms = Keyword.get(opts, :stale_ms) || settings.before_handoff_stale_ms
    async? = Keyword.get(opts, :async, false)

    hook_opts =
      opts
      |> Keyword.put(:timeout_ms, timeout_ms)
      |> maybe_put_protocol(async?)

    case Workspace.run_before_handoff_hook(workspace, issue, worker_host, hook_opts) do
      {:ok, output} ->
        handle_hook_result(output, 0, issue, target_state, opts, stale_ms)

      {:error, {:workspace_hook_failed, "before_handoff", status, output}} ->
        handle_hook_result(output, status, issue, target_state, opts, stale_ms)

      {:error, reason} ->
        generic_hook_failure(issue, target_state, reason, async?)
    end
  end

  defp maybe_put_protocol(opts, true), do: Keyword.put(opts, :gate_protocol, 1)
  defp maybe_put_protocol(opts, false), do: opts

  defp handle_hook_result(output, status, issue, target_state, opts, stale_ms) do
    expected_candidate_hash = Keyword.get(opts, :expected_candidate_hash)

    case parse_protocol_result(output, status, expected_candidate_hash, stale_ms) do
      :legacy -> handle_legacy_result(output, status, issue, target_state)
      {:ok, gate} -> handle_protocol_gate(gate, output, issue, target_state)
      {:candidate_changed, gate} -> handle_protocol_gate(gate, output, issue, target_state)
      {:error, reason, report} -> protocol_error(issue, target_state, reason, report)
    end
  end

  defp handle_legacy_result(output, 0, issue, target_state) do
    breakdown = gate_breakdown(output, true)
    emit_telemetry(issue, target_state, :passed, breakdown)
    :ok
  end

  defp handle_legacy_result(output, _status, issue, target_state) do
    breakdown = gate_breakdown(output, false)
    prompt = remediation_prompt(breakdown, output)
    emit_telemetry(issue, target_state, :failed, breakdown)
    {:blocked, prompt, breakdown}
  end

  defp handle_protocol_gate(%{status: :passed} = gate, _output, issue, target_state) do
    emit_protocol_telemetry(issue, target_state, gate)
    {:passed, gate}
  end

  defp handle_protocol_gate(%{status: status} = gate, _output, issue, target_state)
       when status in [:pending, :running] do
    emit_protocol_telemetry(issue, target_state, gate)
    {:pending, gate}
  end

  defp handle_protocol_gate(%{status: :failed} = gate, output, issue, target_state) do
    emit_protocol_telemetry(issue, target_state, gate)
    {:failed, protocol_remediation_prompt(gate, output), gate}
  end

  defp handle_protocol_gate(%{status: :invalidated} = gate, output, issue, target_state) do
    emit_protocol_telemetry(issue, target_state, gate)
    {:invalidated, protocol_remediation_prompt(gate, output), gate}
  end

  defp handle_protocol_gate(%{status: :infrastructure_error} = gate, output, issue, target_state) do
    emit_protocol_telemetry(issue, target_state, gate)
    {:infrastructure_error, protocol_remediation_prompt(gate, output), gate}
  end

  defp generic_hook_failure(issue, target_state, reason, true) do
    report = %{status: :infrastructure_error, reason: inspect(reason)}
    prompt = protocol_error_prompt(inspect(reason))
    emit_telemetry(issue, target_state, :infrastructure_error, [])
    {:infrastructure_error, prompt, report}
  end

  defp generic_hook_failure(issue, target_state, reason, false) do
    breakdown = [%{name: "before_handoff", status: "failed", passed: false, detail: inspect(reason)}]
    prompt = remediation_prompt(breakdown, inspect(reason))
    emit_telemetry(issue, target_state, :failed, breakdown)
    {:blocked, prompt, breakdown}
  end

  defp protocol_error(issue, target_state, reason, report) do
    emit_telemetry(issue, target_state, :infrastructure_error, [])
    {:infrastructure_error, protocol_error_prompt(reason), report}
  end

  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  @spec remediation_prompt(gate_breakdown(), String.t()) :: String.t()
  def remediation_prompt(breakdown, raw_output) when is_list(breakdown) and is_binary(raw_output) do
    failed_gates =
      breakdown
      |> Enum.reject(& &1.passed)
      |> case do
        [] ->
          [%{name: "before_handoff", detail: String.trim(raw_output), status: "failed", passed: false}]

        gates ->
          gates
      end

    details =
      Enum.map_join(failed_gates, "\n", fn gate ->
        detail =
          gate.detail
          |> to_string()
          |> String.trim()

        if detail == "" do
          "- #{gate.name}: #{gate.status}"
        else
          "- #{gate.name}: #{detail}"
        end
      end)

    """
    System message:

    The before_handoff lifecycle hook blocked the Linear status transition.

    the following gates failed:
    #{details}

    Keep the issue in In Progress, fix the failed gates, rerun validation, and attempt handoff again only after the gate passes.
    """
    |> String.trim()
  end

  @spec gate_breakdown(String.t(), boolean()) :: gate_breakdown()
  def gate_breakdown(output, hook_passed?) when is_binary(output) and is_boolean(hook_passed?) do
    output
    |> decode_hook_report()
    |> breakdown_from_report(hook_passed?)
  end

  defp decode_hook_report(output) do
    trimmed = String.trim(output)

    with {:error, _reason} <- Jason.decode(trimmed),
         {:ok, candidate} <- json_object_candidate(trimmed),
         {:error, _reason} <- Jason.decode(candidate) do
      %{"raw" => trimmed}
    else
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{"raw" => trimmed}
    end
  end

  defp json_object_candidate(output) do
    start_index = :binary.match(output, "{")
    end_index = last_binary_match(output, "}")

    case {start_index, end_index} do
      {{start, _}, {last, _}} when last >= start ->
        {:ok, binary_part(output, start, last - start + 1)}

      _ ->
        {:error, :no_json_object}
    end
  end

  defp last_binary_match(output, pattern) do
    output
    |> :binary.matches(pattern)
    |> List.last()
  end

  defp breakdown_from_report(%{"checks" => checks}, hook_passed?) when is_list(checks) do
    Enum.map(checks, &gate_from_map(&1, hook_passed?))
  end

  defp breakdown_from_report(%{"gates" => gates}, hook_passed?) when is_list(gates) do
    Enum.map(gates, &gate_from_map(&1, hook_passed?))
  end

  defp breakdown_from_report(%{"failures" => failures}, _hook_passed?) when is_list(failures) do
    Enum.map(failures, fn failure ->
      gate_from_failure(failure)
    end)
  end

  defp breakdown_from_report(%{"raw" => raw}, hook_passed?) do
    [
      %{
        name: "before_handoff",
        status: if(hook_passed?, do: "passed", else: "failed"),
        passed: hook_passed?,
        detail: raw
      }
    ]
  end

  defp breakdown_from_report(_report, hook_passed?) do
    [
      %{
        name: "before_handoff",
        status: if(hook_passed?, do: "passed", else: "failed"),
        passed: hook_passed?,
        detail: nil
      }
    ]
  end

  defp gate_from_failure(failure) when is_map(failure) do
    %{
      name: map_string(failure, ["name", "gate", "check"], "before_handoff"),
      status: "failed",
      passed: false,
      detail: failure_detail(failure)
    }
  end

  defp gate_from_failure(failure) do
    %{
      name: "before_handoff",
      status: "failed",
      passed: false,
      detail: failure_detail(failure)
    }
  end

  defp gate_from_map(gate, hook_passed?) when is_map(gate) do
    status = map_string(gate, ["status", "result"], if(hook_passed?, do: "passed", else: "failed"))

    %{
      name: map_string(gate, ["name", "gate", "check"], "before_handoff"),
      status: status,
      passed: gate_passed?(status, hook_passed?),
      detail: failure_detail(gate)
    }
  end

  defp gate_from_map(gate, hook_passed?) do
    %{
      name: "before_handoff",
      status: if(hook_passed?, do: "passed", else: "failed"),
      passed: hook_passed?,
      detail: inspect(gate)
    }
  end

  defp gate_passed?(status, hook_passed?) do
    normalized = normalize_state(status)

    cond do
      normalized in ["passed", "pass", "success", "ok"] -> true
      normalized in ["failed", "fail", "error", "blocked"] -> false
      true -> hook_passed?
    end
  end

  defp failure_detail(value) when is_map(value) do
    map_string(value, ["detail", "summary", "message", "remediation", "reason"], nil)
  end

  defp failure_detail(value) when is_binary(value), do: value
  defp failure_detail(value), do: inspect(value)

  defp map_string(map, keys, default) when is_map(map) do
    Enum.find_value(keys, default, fn key ->
      case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
        value when is_binary(value) -> value
        value when is_integer(value) or is_boolean(value) -> to_string(value)
        _ -> nil
      end
    end)
  end

  defp normalize_protocol_gate(report) do
    with {:ok, job_id} <- required_string(report, "jobId"),
         {:ok, status_text} <- required_string(report, "status"),
         {:ok, status} <- protocol_status(status_text),
         {:ok, identity} <- required_map(report, "identity"),
         :ok <- validate_protocol_identity(identity),
         {:ok, candidate_hash} <- required_string(identity, "candidateHash"),
         {:ok, exact_hash} <- required_string(identity, "exactHash"),
         {:ok, progress} <- normalize_progress(Map.get(report, "progress"), status),
         {:ok, heartbeat_at, heartbeat_age_ms, next_poll_ms} <-
           normalize_poll_fields(report, status) do
      {:ok,
       %{
         protocol_version: 1,
         job_id: job_id,
         status: status,
         identity: identity,
         candidate_hash: candidate_hash,
         exact_hash: exact_hash,
         heartbeat_at: heartbeat_at,
         heartbeat_age_ms: heartbeat_age_ms,
         next_poll_ms: next_poll_ms,
         progress: progress,
         started_at: optional_string(report, "startedAt"),
         completed_at: optional_string(report, "completedAt"),
         result_artifact: optional_string(report, "resultArtifact"),
         checks: list_value(report, "checks"),
         remediation: optional_string(report, "remediation"),
         summary: optional_string(report, "summary"),
         single_flight: boolean_value(report, "singleFlight")
       }}
    end
  end

  defp protocol_status("pending"), do: {:ok, :pending}
  defp protocol_status("running"), do: {:ok, :running}
  defp protocol_status("passed"), do: {:ok, :passed}
  defp protocol_status("failed"), do: {:ok, :failed}
  defp protocol_status("invalidated"), do: {:ok, :invalidated}
  defp protocol_status("infrastructure_error"), do: {:ok, :infrastructure_error}
  defp protocol_status(status), do: {:error, "unsupported protocol status #{inspect(status)}"}

  defp validate_protocol_identity(identity) do
    required_strings = [
      "repositoryIdentity",
      "worktreeIdentity",
      "baseRef",
      "baseSha",
      "headSha",
      "candidateFingerprint",
      "gateConfigHash",
      "mutablePrStateHash",
      "candidateHash",
      "exactHash"
    ]

    with :ok <- require_identity_strings(identity, required_strings),
         :ok <- validate_protocol_pr_number(Map.get(identity, "prNumber")) do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  defp validate_protocol_pr_number(pr_number) when is_integer(pr_number) and pr_number > 0,
    do: :ok

  defp validate_protocol_pr_number(pr_number) when is_binary(pr_number) do
    if Regex.match?(~r/^[1-9][0-9]*$/, pr_number) do
      :ok
    else
      {:error, "missing or invalid identity.prNumber"}
    end
  end

  defp validate_protocol_pr_number(_pr_number),
    do: {:error, "missing or invalid identity.prNumber"}

  defp require_identity_strings(identity, keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case required_string(identity, key) do
        {:ok, _value} -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, "missing or invalid identity.#{key}"}}
      end
    end)
  end

  defp required_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "missing or invalid #{key}"}
    end
  end

  defp required_map(map, key) do
    case Map.get(map, key) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, "missing or invalid #{key}"}
    end
  end

  defp normalize_progress(progress, status) when status in [:pending, :running] and is_map(progress) do
    case Map.get(progress, "stage") do
      stage when is_binary(stage) and stage != "" -> {:ok, progress}
      _ -> {:error, "pending gate progress.stage is required"}
    end
  end

  defp normalize_progress(progress, _status) when is_map(progress), do: {:ok, progress}
  defp normalize_progress(_progress, status) when status in [:pending, :running], do: {:error, "pending gate progress is required"}
  defp normalize_progress(_progress, _status), do: {:ok, %{}}

  defp normalize_poll_fields(report, status) when status in [:pending, :running] do
    with heartbeat_at when is_binary(heartbeat_at) and heartbeat_at != "" <- Map.get(report, "heartbeatAt"),
         heartbeat_age_ms when is_integer(heartbeat_age_ms) and heartbeat_age_ms >= 0 <-
           Map.get(report, "heartbeatAgeMs"),
         next_poll_ms when is_integer(next_poll_ms) and next_poll_ms > 0 <- Map.get(report, "nextPollMs") do
      {:ok, heartbeat_at, heartbeat_age_ms, next_poll_ms}
    else
      _ -> {:error, "pending gate heartbeatAt, heartbeatAgeMs, and nextPollMs are required"}
    end
  end

  defp normalize_poll_fields(report, _status) do
    {:ok, optional_string(report, "heartbeatAt"), non_negative_integer(report, "heartbeatAgeMs"), positive_integer(report, "nextPollMs")}
  end

  defp validate_protocol_exit(status, exit_status) do
    expected =
      case status do
        :passed -> 0
        status when status in [:pending, :running] -> 3
        status when status in [:failed, :invalidated] -> 2
        :infrastructure_error -> 1
      end

    if exit_status == expected,
      do: :ok,
      else: {:error, "protocol status #{status} requires exit #{expected}, received #{exit_status}"}
  end

  defp validate_expected_candidate(_gate, nil), do: :ok

  defp validate_expected_candidate(%{candidate_hash: expected}, expected), do: :ok

  defp validate_expected_candidate(%{candidate_hash: actual}, expected) do
    Logger.warning("gate.before_handoff candidate changed expected_candidate_hash=#{expected} actual_candidate_hash=#{actual}; withholding handoff")

    :candidate_changed
  end

  defp validate_protocol_heartbeat(%{status: status, heartbeat_age_ms: age}, stale_ms)
       when status in [:pending, :running] and is_integer(age) and age > stale_ms do
    {:error, "gate heartbeat is stale (#{age}ms > #{stale_ms}ms)"}
  end

  defp validate_protocol_heartbeat(_gate, _stale_ms), do: :ok

  defp optional_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp list_value(map, key) do
    case Map.get(map, key) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp boolean_value(map, key) do
    case Map.get(map, key) do
      value when is_boolean(value) -> value
      _ -> nil
    end
  end

  defp non_negative_integer(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) and value >= 0 -> value
      _ -> nil
    end
  end

  defp positive_integer(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) and value > 0 -> value
      _ -> nil
    end
  end

  defp protocol_remediation_prompt(gate, raw_output) do
    detail = gate.remediation || gate.summary || String.trim(raw_output)

    """
    System message:

    The asynchronous before_handoff gate ended with `#{gate.status}` for candidate `#{gate.candidate_hash}`.

    #{detail}

    The original Linear mutation was not applied. Keep the issue In Progress, address this result once, and attempt handoff again only for the current candidate.
    """
    |> String.trim()
  end

  defp protocol_error_prompt(reason) do
    """
    System message:

    Symphony could not verify the asynchronous before_handoff gate result.

    Reason: #{reason}

    The original Linear mutation was not applied. Keep the issue In Progress and restore a valid, live gate result before retrying handoff.
    """
    |> String.trim()
  end

  defp emit_protocol_telemetry(issue, target_state, gate) do
    hook_passed? = gate.status == :passed
    output = Jason.encode!(%{"checks" => gate.checks})
    breakdown = gate_breakdown(output, hook_passed?)
    emit_telemetry(issue, target_state, gate.status, breakdown)
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp emit_telemetry(%Issue{} = issue, target_state, outcome, breakdown) do
    metadata = %{
      subtype: "before_handoff",
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      parent_issue_id: issue.parent_id,
      from_state: issue.state,
      target_state: target_state,
      outcome: outcome,
      gates: breakdown,
      checks: Enum.map(breakdown, &Map.take(&1, [:name, :status, :passed]))
    }

    :telemetry.execute(
      @telemetry_event,
      %{count: 1},
      Map.put(metadata, :event, "gate.before_handoff")
    )

    Telemetry.emit(:gate, metadata)

    if outcome == :passed do
      Telemetry.emit(:quality_outcome, %{
        outcome: "handoff",
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        parent_issue_id: issue.parent_id,
        target_state: target_state
      })
    end

    Logger.info("gate.before_handoff issue_id=#{issue.id || "n/a"} issue_identifier=#{issue.identifier || "n/a"} from_state=#{issue.state || "n/a"} target_state=#{target_state} outcome=#{outcome}")
  end
end
