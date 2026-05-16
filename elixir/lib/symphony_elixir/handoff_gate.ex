defmodule SymphonyElixir.HandoffGate do
  @moduledoc """
  Runs the configured before_handoff hook and formats gate remediation.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue, Workspace}

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

  @type result :: :ok | {:blocked, String.t(), gate_breakdown()}

  @spec handoff_transition?(String.t() | nil, String.t() | nil) :: boolean()
  def handoff_transition?(current_state, target_state) when is_binary(current_state) and is_binary(target_state) do
    normalize_state(current_state) == @source_state and
      MapSet.member?(@handoff_target_states, normalize_state(target_state))
  end

  def handoff_transition?(_current_state, _target_state), do: false

  @spec run_before_handoff(Path.t(), Issue.t(), term(), String.t()) :: result()
  def run_before_handoff(workspace, %Issue{} = issue, worker_host, target_state)
      when is_binary(workspace) and is_binary(target_state) do
    case Config.settings!().hooks.before_handoff do
      nil ->
        :ok

      _command ->
        case Workspace.run_before_handoff_hook(workspace, issue, worker_host) do
          {:ok, output} ->
            breakdown = gate_breakdown(output, true)
            emit_telemetry(issue, target_state, :passed, breakdown)
            :ok

          {:error, {:workspace_hook_failed, "before_handoff", _status, output}} ->
            breakdown = gate_breakdown(output, false)
            prompt = remediation_prompt(breakdown, output)
            emit_telemetry(issue, target_state, :failed, breakdown)
            {:blocked, prompt, breakdown}

          {:error, reason} ->
            breakdown = [
              %{
                name: "before_handoff",
                status: "failed",
                passed: false,
                detail: inspect(reason)
              }
            ]

            prompt = remediation_prompt(breakdown, inspect(reason))
            emit_telemetry(issue, target_state, :failed, breakdown)
            {:blocked, prompt, breakdown}
        end
    end
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

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp emit_telemetry(%Issue{} = issue, target_state, outcome, breakdown) do
    :telemetry.execute(
      @telemetry_event,
      %{count: 1},
      %{
        event: "gate.before_handoff",
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        from_state: issue.state,
        target_state: target_state,
        outcome: outcome,
        gates: breakdown
      }
    )

    Logger.info("gate.before_handoff issue_id=#{issue.id || "n/a"} issue_identifier=#{issue.identifier || "n/a"} from_state=#{issue.state || "n/a"} target_state=#{target_state} outcome=#{outcome}")
  end
end
