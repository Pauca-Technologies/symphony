defmodule SymphonyElixir.WaitCondition do
  @moduledoc """
  Validates agent-requested wait conditions and probes them without an LLM.

  Symphony captures the baseline itself before parking work. Agents identify
  only the external target and desired event, so differently-shaped guesses
  cannot create unique conditions or trigger immediate wake-up loops.
  """

  alias SymphonyElixir.{AgentTransport, Tracker}

  @github_status_url "https://www.githubstatus.com/api/v2/summary.json"
  @command_timeout_ms 30_000
  @max_command_output_bytes 2_000_000
  @condition_types ~w(github_actions_recovered github_pr_checks_changed github_pr_check_changed github_pr_gate_settled git_ref_changed linear_issue_changed)

  @type request :: %{
          condition: map(),
          condition_key: String.t(),
          baseline: map() | nil,
          reason: String.t(),
          min_poll_ms: pos_integer(),
          max_poll_ms: pos_integer()
        }

  @doc "Validate and enrich a `wait_for` tool request."
  @spec normalize(term(), map()) :: {:ok, request()} | {:error, term()}
  def normalize(arguments, context) when is_map(arguments) and is_map(context) do
    condition = value(arguments, "condition")
    reason = value(arguments, "reason")

    with :ok <- reject_agent_observation(arguments),
         {:ok, reason} <- non_blank(reason, :missing_reason),
         {:ok, condition} <- normalize_condition(condition, context),
         {:ok, min_poll_ms} <- poll_ms(arguments, "min_poll_seconds", 60, 15, 1_800),
         {:ok, max_poll_ms} <- poll_ms(arguments, "max_poll_seconds", 1_800, 60, 21_600),
         true <- min_poll_ms <= max_poll_ms or {:error, :invalid_poll_range} do
      {:ok,
       %{
         condition: condition,
         condition_key: condition_key(condition),
         baseline: nil,
         reason: reason,
         min_poll_ms: min_poll_ms,
         max_poll_ms: max_poll_ms
       }}
    end
  end

  def normalize(_arguments, _context), do: {:error, :invalid_arguments}

  @doc "Capture the normalized condition's baseline from the external system."
  @spec capture_baseline(request(), keyword()) ::
          {:ok, request()} | {:error, term()}
  def capture_baseline(request, opts \\ []) when is_map(request) and is_list(opts) do
    observer = Keyword.get(opts, :observer, &observe/1)

    with {:ok, observation} when is_map(observation) <- observer.(request),
         :ok <- ensure_not_already_satisfied(request, observation) do
      {:ok, Map.put(request, :baseline, observation)}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_baseline_observation, other}}
    end
  end

  @doc "Probe one normalized condition."
  @spec probe(request()) :: {:changed | :unchanged, map()} | {:error, term()}
  def probe(request) when is_map(request) do
    with {:ok, observation} <- observe(request) do
      if changed?(request, observation),
        do: {:changed, observation},
        else: {:unchanged, observation}
    end
  end

  @doc "Read the current typed observation without comparing agent input."
  @spec observe(request()) :: {:ok, map()} | {:error, term()}
  def observe(%{condition: %{"type" => "github_actions_recovered"} = condition}) do
    component = condition["component"]

    with {:ok, response} <- Req.get(@github_status_url, receive_timeout: 15_000),
         200 <- response.status,
         %{"components" => components, "incidents" => incidents}
         when is_list(components) and is_list(incidents) <- response.body,
         %{} = match <- Enum.find(components, &github_component_match?(&1, component)) do
      signal = github_recovery_signal(match, incidents)

      observation = %{
        "component" => Map.get(match, "name"),
        "status" => Map.get(match, "status"),
        "incident_statuses" => github_incident_statuses(incidents, component),
        "recovery_signal" => to_string(signal)
      }

      {:ok, observation}
    else
      status when is_integer(status) -> {:error, {:github_status_http, status}}
      nil -> {:error, {:github_status_component_missing, component}}
      other -> {:error, {:github_status_invalid_response, other}}
    end
  rescue
    error -> {:error, {:github_status_request, Exception.message(error)}}
  end

  def observe(%{condition: %{"type" => "git_ref_changed"} = condition}) do
    command =
      "git ls-remote origin " <>
        shell_escape(condition["ref"])

    with {:ok, output, 0} <- run_command(condition, command),
         [sha | _] <- String.split(String.trim(output), ~r/\s+/, trim: true) do
      {:ok, %{"sha" => sha}}
    else
      {:ok, output, status} -> {:error, {:git_ls_remote_failed, status, String.trim(output)}}
      [] -> {:error, {:git_ref_not_found, condition["ref"]}}
      {:error, reason} -> {:error, reason}
    end
  end

  def observe(%{condition: %{"type" => type} = condition})
      when type in [
             "github_pr_checks_changed",
             "github_pr_check_changed",
             "github_pr_gate_settled"
           ] do
    repo_arg = if condition["repository"], do: " --repo " <> shell_escape(condition["repository"]), else: ""

    checks_command =
      "gh pr checks #{condition["pr_number"]} --json name,state,bucket,workflow" <>
        repo_arg

    pr_command =
      "gh pr view #{condition["pr_number"]} " <>
        "--json state,isDraft,headRefOid,baseRefOid,mergeable,mergeStateStatus,reviewDecision" <>
        repo_arg

    with {:ok, checks_output, _status} <- run_command(condition, checks_command),
         {:ok, checks} when is_list(checks) <- Jason.decode(checks_output),
         {:ok, pr_output, 0} <- run_command(condition, pr_command),
         {:ok, pull_request} when is_map(pull_request) <- Jason.decode(pr_output) do
      {:ok, github_pr_observation(type, checks, condition, pull_request)}
    else
      {:ok, output, status} when is_integer(status) ->
        {:error, {:github_pr_view_failed, status, String.trim(output)}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:github_pr_invalid_response, other}}
    end
  end

  def observe(%{condition: %{"type" => "linear_issue_changed"} = condition}) do
    issue_id = condition["issue_id"]

    with {:ok, [issue | _]} <- Tracker.fetch_issue_states_by_ids([issue_id]),
         {:ok, %{comments: comments}} when is_list(comments) <- Tracker.fetch_issue_comments(issue_id) do
      observation = %{
        "state" => issue.state,
        "updated_at" => datetime_string(issue.updated_at),
        "comments" => comment_observations(comments),
        "comment_count" => length(comments),
        "latest_comment_at" => latest_comment_at(comments),
        "comment_fingerprint" => digest(comment_observations(comments))
      }

      {:ok, observation}
    else
      {:ok, []} -> {:error, {:linear_issue_missing, issue_id}}
      {:error, reason} -> {:error, {:linear_issue_probe, reason}}
    end
  end

  # Compatibility for timer waits persisted by releases that accepted them. New
  # requests no longer normalize this condition type, but existing entries must
  # still wake instead of becoming stranded during an upgrade.
  def observe(%{condition: %{"type" => "time", "resume_at" => resume_at}}) do
    case DateTime.from_iso8601(resume_at) do
      {:ok, datetime, _offset} ->
        observation = %{"now" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}
        {:ok, Map.put(observation, "resume_at", DateTime.to_iso8601(datetime))}

      _ ->
        {:error, :invalid_resume_at}
    end
  end

  def observe(_request), do: {:error, :invalid_wait_condition}

  @doc "Return whether an observation satisfies or changes a normalized wait."
  @spec changed?(request(), map()) :: boolean()
  def changed?(%{condition: %{"type" => "github_actions_recovered"}}, observation),
    do: observation["recovery_signal"] != "waiting"

  def changed?(%{condition: %{"type" => "github_pr_gate_settled"}} = request, observation) do
    observation["aggregate"] in ["pass", "fail"] or
      pull_request_changed?(request, observation)
  end

  def changed?(%{condition: %{"type" => "time", "resume_at" => resume_at}}, _observation) do
    case DateTime.from_iso8601(resume_at) do
      {:ok, datetime, _offset} -> DateTime.compare(DateTime.utc_now(), datetime) in [:eq, :gt]
      _ -> false
    end
  end

  def changed?(request, observation) when is_map(request) and is_map(observation) do
    baseline = Map.get(request, :baseline) || get_in(request, [:condition, "observed"])
    canonical(observation) != canonical(baseline)
  end

  @doc false
  @spec github_component_match_for_test?(map(), String.t()) :: boolean()
  def github_component_match_for_test?(component, expected_name),
    do: github_component_match?(component, expected_name)

  @doc false
  @spec github_recovery_signal_for_test(map(), [map()]) ::
          :component_operational | :incident_monitoring | :waiting
  def github_recovery_signal_for_test(component, incidents),
    do: github_recovery_signal(component, incidents)

  @doc false
  @spec checks_observation_for_test([map()]) :: map()
  def checks_observation_for_test(checks),
    do: checks_observation("github_pr_checks_changed", checks, %{})

  @doc "Return a compact prompt describing why a parked issue was resumed."
  @spec resume_prompt(request(), map(), :condition_changed | :manual | :policy_changed) :: String.t()
  def resume_prompt(request, observation, trigger) do
    trigger_text =
      case trigger do
        :manual -> "A human requested an immediate resume"
        :policy_changed -> "Symphony retired an unsafe cross-issue wait"
        :condition_changed -> "The watched condition changed"
      end

    """
    Symphony resumed this issue from a parked wait. #{trigger_text}.
    Previous wait reason: #{request.reason}
    Condition: #{Jason.encode!(request.condition)}
    Latest observation: #{Jason.encode!(observation)}
    Re-check the external state once, then continue from the existing workspace. Do not repeat the old polling loop.
    """
    |> String.trim()
  end

  defp normalize_condition(condition, context) when is_map(condition) do
    type = value(condition, "type")

    with :ok <- reject_agent_observation(condition) do
      if type in @condition_types do
        do_normalize_condition(type, condition, context)
      else
        {:error, {:unsupported_condition_type, type}}
      end
    end
  end

  defp normalize_condition(_condition, _context), do: {:error, :missing_condition}

  defp do_normalize_condition("github_actions_recovered", condition, _context) do
    component = value(condition, "component") || "Actions"
    with {:ok, component} <- non_blank(component, :invalid_component), do: {:ok, %{"type" => "github_actions_recovered", "component" => component}}
  end

  defp do_normalize_condition("git_ref_changed", condition, context) do
    with {:ok, ref} <- non_blank(value(condition, "ref"), :missing_ref),
         {:ok, workspace} <- context_path(context, :workspace) do
      repository_scope =
        blank_to_nil(value(condition, "repository")) || context[:repository_scope] || workspace

      {:ok,
       %{
         "type" => "git_ref_changed",
         "ref" => ref,
         "repository_scope" => repository_scope,
         "workspace" => workspace,
         "worker_host" => context[:worker_host]
       }}
    end
  end

  defp do_normalize_condition("github_pr_checks_changed", condition, context) do
    with pr_number when is_integer(pr_number) and pr_number > 0 <- value(condition, "pr_number"),
         {:ok, workspace} <- context_path(context, :workspace) do
      repository = blank_to_nil(value(condition, "repository"))

      {:ok,
       %{
         "type" => "github_pr_checks_changed",
         "pr_number" => pr_number,
         "repository" => repository,
         "repository_scope" => repository || context[:repository_scope] || workspace,
         "workspace" => workspace,
         "worker_host" => context[:worker_host]
       }}
    else
      _ -> {:error, :invalid_pr_check_condition}
    end
  end

  defp do_normalize_condition("github_pr_check_changed", condition, context) do
    with pr_number when is_integer(pr_number) and pr_number > 0 <- value(condition, "pr_number"),
         {:ok, check_name} <- non_blank(value(condition, "check_name"), :missing_check_name),
         {:ok, workspace} <- context_path(context, :workspace) do
      repository = blank_to_nil(value(condition, "repository"))

      {:ok,
       %{
         "type" => "github_pr_check_changed",
         "pr_number" => pr_number,
         "check_name" => check_name,
         "repository" => repository,
         "repository_scope" => repository || context[:repository_scope] || workspace,
         "workspace" => workspace,
         "worker_host" => context[:worker_host]
       }}
    else
      _ -> {:error, :invalid_named_pr_check_condition}
    end
  end

  defp do_normalize_condition("github_pr_gate_settled", condition, context) do
    do_normalize_condition("github_pr_checks_changed", condition, context)
    |> case do
      {:ok, normalized} -> {:ok, Map.put(normalized, "type", "github_pr_gate_settled")}
      error -> error
    end
  end

  defp do_normalize_condition("linear_issue_changed", condition, context) do
    current_issue_id = get_in(context, [:issue, :id])
    issue_id = value(condition, "issue_id") || current_issue_id

    with {:ok, current_issue_id} <- non_blank(current_issue_id, :missing_current_issue_id),
         {:ok, issue_id} <- non_blank(issue_id, :missing_issue_id),
         true <- issue_id == current_issue_id or {:error, :cross_issue_linear_wait_not_allowed} do
      {:ok, %{"type" => "linear_issue_changed", "issue_id" => issue_id}}
    end
  end

  defp condition_key(condition) do
    condition
    |> Map.drop(["workspace", "worker_host", "observed", "baseline"])
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp github_component_match?(component, expected_name) when is_binary(expected_name) do
    case Map.get(component, "name") do
      name when is_binary(name) -> String.downcase(name) == String.downcase(expected_name)
      _ -> false
    end
  end

  defp github_component_match?(_component, _expected_name), do: false

  defp github_recovery_signal(%{"status" => "operational"}, _incidents),
    do: :component_operational

  defp github_recovery_signal(component, incidents) do
    component_name = Map.get(component, "name")
    relevant_incidents = Enum.filter(incidents, &github_incident_affects_component?(&1, component_name))

    if relevant_incidents != [] and
         Enum.all?(relevant_incidents, &(Map.get(&1, "status") in ["monitoring", "resolved"])) do
      :incident_monitoring
    else
      :waiting
    end
  end

  defp github_incident_statuses(incidents, component_name) do
    incidents
    |> Enum.filter(&github_incident_affects_component?(&1, component_name))
    |> Enum.map(&Map.get(&1, "status"))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp github_incident_affects_component?(incident, component_name) when is_binary(component_name) do
    incident
    |> Map.get("components", [])
    |> Enum.any?(&github_component_match?(&1, component_name))
  end

  defp github_incident_affects_component?(_incident, _component_name), do: false

  defp checks_observation("github_pr_check_changed", checks, condition) do
    check_name = String.downcase(condition["check_name"])

    case Enum.find(checks, fn check ->
           name = Map.get(check, "name")
           is_binary(name) and String.downcase(name) == check_name
         end) do
      nil -> %{"present" => false, "name" => condition["check_name"]}
      check -> check |> Map.take(["name", "state", "bucket", "workflow"]) |> Map.put("present", true)
    end
  end

  defp checks_observation(_type, checks, _condition) do
    normalized =
      checks
      |> Enum.map(fn check -> Map.take(check, ["name", "state", "bucket", "workflow"]) end)
      |> Enum.sort_by(&{&1["workflow"] || "", &1["name"] || ""})

    aggregate =
      cond do
        Enum.any?(normalized, &(&1["bucket"] in ["fail", "cancel"])) -> "fail"
        Enum.any?(normalized, &(&1["bucket"] == "pending")) -> "pending"
        normalized == [] -> "none"
        true -> "pass"
      end

    %{"aggregate" => aggregate, "fingerprint" => digest(normalized), "checks" => normalized}
  end

  defp github_pr_observation(type, checks, condition, pull_request) do
    pull_request_state =
      Map.take(pull_request, [
        "state",
        "isDraft",
        "headRefOid",
        "baseRefOid",
        "mergeable",
        "mergeStateStatus",
        "reviewDecision"
      ])

    type
    |> checks_observation(checks, condition)
    |> Map.put("pull_request", pull_request_state)
  end

  defp pull_request_changed?(request, observation) do
    baseline = Map.get(request, :baseline) || get_in(request, [:condition, "observed"])

    is_map(baseline) and
      canonical(observation["pull_request"]) != canonical(baseline["pull_request"])
  end

  defp canonical(value) when is_map(value) or is_list(value), do: Jason.encode!(value)
  defp canonical(nil), do: ""
  defp canonical(value), do: to_string(value)
  defp digest(value), do: :crypto.hash(:sha256, Jason.encode!(value)) |> Base.encode16(case: :lower)

  defp comment_observations(comments) do
    comments
    |> Enum.map(&%{"id" => &1.id, "updated_at" => datetime_string(&1.updated_at || &1.created_at)})
    |> Enum.sort_by(&{&1["updated_at"] || "", &1["id"] || ""})
  end

  defp latest_comment_at(comments) do
    comments
    |> comment_observations()
    |> Enum.map(& &1["updated_at"])
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  defp run_command(condition, command) do
    workspace = condition["workspace"]
    worker_host = condition["worker_host"]

    with {:ok, port} <- AgentTransport.start_port(workspace, worker_host, command, []) do
      collect_port(port, System.monotonic_time(:millisecond) + @command_timeout_ms, "")
    end
  end

  defp collect_port(port, deadline, output) when byte_size(output) <= @max_command_output_bytes do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, {:eol, chunk}}} -> collect_port(port, deadline, output <> to_string(chunk) <> "\n")
      {^port, {:data, {:noeol, chunk}}} -> collect_port(port, deadline, output <> to_string(chunk))
      {^port, {:exit_status, status}} -> {:ok, output, status}
    after
      remaining ->
        AgentTransport.stop_port(port)
        {:error, :wait_probe_timeout}
    end
  end

  defp collect_port(port, _deadline, _output) do
    AgentTransport.stop_port(port)
    {:error, :wait_probe_output_too_large}
  end

  defp context_path(context, key) do
    case Map.get(context, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_context, key}}
    end
  end

  defp ensure_not_already_satisfied(
         %{condition: %{"type" => type}} = request,
         observation
       )
       when type in ["github_actions_recovered", "github_pr_gate_settled"] do
    if changed?(request, observation),
      do: {:error, {:condition_already_satisfied, observation}},
      else: :ok
  end

  defp ensure_not_already_satisfied(_request, _observation), do: :ok

  defp reject_agent_observation(condition) do
    if Enum.any?(["observed", :observed, "baseline", :baseline], &Map.has_key?(condition, &1)),
      do: {:error, :agent_observation_not_allowed},
      else: :ok
  end

  defp poll_ms(arguments, key, default, minimum, maximum) do
    case value(arguments, key) || default do
      seconds when is_integer(seconds) and seconds >= minimum and seconds <= maximum -> {:ok, seconds * 1_000}
      _ -> {:error, {:invalid_poll_seconds, key}}
    end
  end

  defp non_blank(value, error) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, error}
      trimmed -> {:ok, trimmed}
    end
  end

  defp non_blank(_value, error), do: {:error, error}
  defp blank_to_nil(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))
  defp blank_to_nil(_value), do: nil
  defp value(map, key), do: Map.get(map, key) || Map.get(map, key_atom(key))
  defp key_atom("condition"), do: :condition
  defp key_atom("reason"), do: :reason
  defp key_atom("min_poll_seconds"), do: :min_poll_seconds
  defp key_atom("max_poll_seconds"), do: :max_poll_seconds
  defp key_atom("type"), do: :type
  defp key_atom("component"), do: :component
  defp key_atom("repository"), do: :repository
  defp key_atom("pr_number"), do: :pr_number
  defp key_atom("ref"), do: :ref
  defp key_atom("issue_id"), do: :issue_id
  defp key_atom("check_name"), do: :check_name
  defp key_atom("observed"), do: :observed
  defp datetime_string(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp datetime_string(value) when is_binary(value), do: value
  defp datetime_string(_value), do: nil

  defp shell_escape(value), do: "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
end
