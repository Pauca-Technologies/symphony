defmodule SymphonyElixir.WaitCondition do
  @moduledoc """
  Validates agent-requested wait conditions and probes them without an LLM.

  Conditions deliberately carry the observation the agent just saw. A probe
  resumes work only after that observation changes (or, for GitHub Actions,
  after the component becomes operational), preventing an immediate wake-up
  loop on the same external state.
  """

  alias SymphonyElixir.{AgentTransport, Tracker}

  @github_status_url "https://www.githubstatus.com/api/v2/components.json"
  @command_timeout_ms 30_000
  @max_command_output_bytes 2_000_000
  @condition_types ~w(github_actions_recovered github_pr_checks_changed git_ref_changed linear_issue_changed time)

  @type request :: %{
          condition: map(),
          condition_key: String.t(),
          reason: String.t(),
          min_poll_ms: pos_integer(),
          max_poll_ms: pos_integer()
        }

  @doc "Validate and enrich a `wait_for` tool request."
  @spec normalize(term(), map()) :: {:ok, request()} | {:error, term()}
  def normalize(arguments, context) when is_map(arguments) and is_map(context) do
    condition = value(arguments, "condition")
    reason = value(arguments, "reason")

    with {:ok, reason} <- non_blank(reason, :missing_reason),
         {:ok, condition} <- normalize_condition(condition, context),
         {:ok, min_poll_ms} <- poll_ms(arguments, "min_poll_seconds", 60, 15, 1_800),
         {:ok, max_poll_ms} <- poll_ms(arguments, "max_poll_seconds", 1_800, 60, 21_600),
         true <- min_poll_ms <= max_poll_ms or {:error, :invalid_poll_range} do
      {:ok,
       %{
         condition: condition,
         condition_key: condition_key(condition),
         reason: reason,
         min_poll_ms: min_poll_ms,
         max_poll_ms: max_poll_ms
       }}
    end
  end

  def normalize(_arguments, _context), do: {:error, :invalid_arguments}

  @doc "Probe one normalized condition."
  @spec probe(request()) :: {:changed | :unchanged, map()} | {:error, term()}
  def probe(%{condition: %{"type" => "github_actions_recovered"} = condition}) do
    component = condition["component"]

    with {:ok, response} <- Req.get(@github_status_url, receive_timeout: 15_000),
         200 <- response.status,
         %{"components" => components} when is_list(components) <- response.body,
         %{} = match <- Enum.find(components, &(Map.get(&1, "name") == component)) do
      observation = %{"component" => component, "status" => Map.get(match, "status")}
      if observation["status"] == "operational", do: {:changed, observation}, else: {:unchanged, observation}
    else
      status when is_integer(status) -> {:error, {:github_status_http, status}}
      nil -> {:error, {:github_status_component_missing, component}}
      other -> {:error, {:github_status_invalid_response, other}}
    end
  rescue
    error -> {:error, {:github_status_request, Exception.message(error)}}
  end

  def probe(%{condition: %{"type" => "git_ref_changed"} = condition}) do
    command =
      "git ls-remote origin " <>
        shell_escape(condition["ref"])

    with {:ok, output, 0} <- run_command(condition, command),
         [sha | _] <- String.split(String.trim(output), ~r/\s+/, trim: true) do
      compare_observation(sha, condition["observed"])
    else
      {:ok, output, status} -> {:error, {:git_ls_remote_failed, status, String.trim(output)}}
      [] -> {:error, {:git_ref_not_found, condition["ref"]}}
      {:error, reason} -> {:error, reason}
    end
  end

  def probe(%{condition: %{"type" => "github_pr_checks_changed"} = condition}) do
    repo_arg = if condition["repository"], do: " --repo " <> shell_escape(condition["repository"]), else: ""

    command =
      "gh pr checks #{condition["pr_number"]} --json name,state,bucket,workflow" <>
        repo_arg

    with {:ok, output, _status} <- run_command(condition, command),
         {:ok, checks} when is_list(checks) <- Jason.decode(output) do
      observation = checks_observation(checks)
      compare_observation(observation, condition["observed"])
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def probe(%{condition: %{"type" => "linear_issue_changed"} = condition}) do
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

      compare_observation(observation, condition["observed"])
    else
      {:ok, []} -> {:error, {:linear_issue_missing, issue_id}}
      {:error, reason} -> {:error, {:linear_issue_probe, reason}}
    end
  end

  def probe(%{condition: %{"type" => "time", "resume_at" => resume_at}}) do
    case DateTime.from_iso8601(resume_at) do
      {:ok, datetime, _offset} ->
        observation = %{"now" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}
        if DateTime.compare(DateTime.utc_now(), datetime) in [:eq, :gt], do: {:changed, observation}, else: {:unchanged, observation}

      _ ->
        {:error, :invalid_resume_at}
    end
  end

  def probe(_request), do: {:error, :invalid_wait_condition}

  @doc "Return a compact prompt describing why a parked issue was resumed."
  @spec resume_prompt(request(), map(), :condition_changed | :manual) :: String.t()
  def resume_prompt(request, observation, trigger) do
    trigger_text = if trigger == :manual, do: "A human requested an immediate resume", else: "The watched condition changed"

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

    if type in @condition_types do
      do_normalize_condition(type, condition, context)
    else
      {:error, {:unsupported_condition_type, type}}
    end
  end

  defp normalize_condition(_condition, _context), do: {:error, :missing_condition}

  defp do_normalize_condition("github_actions_recovered", condition, _context) do
    component = value(condition, "component") || "Actions"
    with {:ok, component} <- non_blank(component, :invalid_component), do: {:ok, %{"type" => "github_actions_recovered", "component" => component}}
  end

  defp do_normalize_condition("git_ref_changed", condition, context) do
    with {:ok, ref} <- non_blank(value(condition, "ref"), :missing_ref),
         {:ok, observed} <- non_blank(value(condition, "observed"), :missing_observed),
         {:ok, workspace} <- context_path(context, :workspace) do
      repository_scope =
        blank_to_nil(value(condition, "repository")) || context[:repository_scope] || workspace

      {:ok,
       %{
         "type" => "git_ref_changed",
         "ref" => ref,
         "observed" => observed,
         "repository_scope" => repository_scope,
         "workspace" => workspace,
         "worker_host" => context[:worker_host]
       }}
    end
  end

  defp do_normalize_condition("github_pr_checks_changed", condition, context) do
    with pr_number when is_integer(pr_number) and pr_number > 0 <- value(condition, "pr_number"),
         {:ok, observed} <- normalize_observed(value(condition, "observed")),
         {:ok, workspace} <- context_path(context, :workspace) do
      repository = blank_to_nil(value(condition, "repository"))

      {:ok,
       %{
         "type" => "github_pr_checks_changed",
         "pr_number" => pr_number,
         "repository" => repository,
         "repository_scope" => repository || context[:repository_scope] || workspace,
         "observed" => observed,
         "workspace" => workspace,
         "worker_host" => context[:worker_host]
       }}
    else
      _ -> {:error, :invalid_pr_check_condition}
    end
  end

  defp do_normalize_condition("linear_issue_changed", condition, context) do
    issue_id = value(condition, "issue_id") || get_in(context, [:issue, :id])

    with {:ok, issue_id} <- non_blank(issue_id, :missing_issue_id),
         {:ok, observed} <- normalize_observed(value(condition, "observed")) do
      {:ok, %{"type" => "linear_issue_changed", "issue_id" => issue_id, "observed" => observed}}
    end
  end

  defp do_normalize_condition("time", condition, _context) do
    with {:ok, resume_at} <- non_blank(value(condition, "resume_at"), :missing_resume_at),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(resume_at),
         :gt <- DateTime.compare(datetime, DateTime.utc_now()) do
      {:ok, %{"type" => "time", "resume_at" => DateTime.to_iso8601(datetime)}}
    else
      _ -> {:error, :invalid_resume_at}
    end
  end

  defp condition_key(condition) do
    condition
    |> Map.drop(["workspace", "worker_host"])
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp checks_observation(checks) do
    normalized =
      checks
      |> Enum.map(fn check -> Map.take(check, ["name", "state", "bucket", "workflow"]) end)
      |> Enum.sort_by(&{&1["workflow"] || "", &1["name"] || ""})

    aggregate =
      cond do
        Enum.any?(normalized, &(&1["bucket"] in ["fail", "cancel"])) -> "fail"
        Enum.any?(normalized, &(&1["bucket"] in ["pending", "skipping"])) -> "pending"
        normalized == [] -> "none"
        true -> "pass"
      end

    %{"aggregate" => aggregate, "fingerprint" => digest(normalized), "checks" => normalized}
  end

  defp compare_observation(%{"aggregate" => aggregate} = observation, observed)
       when is_binary(observed) and observed in ["pending", "pass", "fail", "none"] do
    if aggregate == observed, do: {:unchanged, observation}, else: {:changed, observation}
  end

  defp compare_observation(%{"updated_at" => updated_at} = observation, observed)
       when is_binary(observed) do
    if updated_at == observed, do: {:unchanged, observation}, else: {:changed, observation}
  end

  defp compare_observation(observation, observed) when is_map(observation) and is_map(observed) do
    current = Map.take(observation, Map.keys(observed))
    if canonical(current) == canonical(observed), do: {:unchanged, observation}, else: {:changed, observation}
  end

  defp compare_observation(observation, observed) do
    if canonical(observation) == canonical(observed), do: {:unchanged, observation}, else: {:changed, observation}
  end

  defp canonical(value) when is_map(value) or is_list(value), do: Jason.encode!(value)
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

  defp normalize_observed(value) when is_binary(value) and value != "", do: {:ok, value}
  defp normalize_observed(value) when is_map(value) or is_list(value), do: {:ok, value}
  defp normalize_observed(_value), do: {:error, :missing_observed}

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
  defp key_atom("observed"), do: :observed
  defp key_atom("resume_at"), do: :resume_at
  defp datetime_string(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp datetime_string(value) when is_binary(value), do: value
  defp datetime_string(_value), do: nil

  defp shell_escape(value), do: "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
end
