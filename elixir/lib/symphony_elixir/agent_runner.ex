defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.{AppServer, DynamicTool}

  alias SymphonyElixir.{
    Config,
    Linear.Client,
    Linear.Issue,
    PromptBuilder,
    RepoConfig,
    Router,
    SessionStartHook,
    Telemetry,
    Tracker,
    Workspace
  }

  @type worker_host :: String.t() | nil
  @handoff_gate_prompt_key {__MODULE__, :handoff_gate_prompt}

  # See T04 in /data/projects/coding-harness/implementation-plan.md and audit §5.1 O9.
  # Symphony silently giving up on terminal failure is a trust-killer; we mark the
  # issue Blocked, apply needs-human-input, and post one Linear comment when we
  # give up. The same Linear label is reused across routing/cardinality/give-up
  # warnings — its presence is the cross-condition idempotency marker.
  @blocked_state "Blocked"
  @needs_human_input_label "needs-human-input"
  @idempotency_label "symphony:routing-warned"
  @blocked_marker "<!-- symphony:blocked-on-giveup -->"

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")
    started_at_ms = System.monotonic_time(:millisecond)
    Telemetry.emit(:run_start, telemetry_issue_attrs(issue, worker_host))

    result = run_on_worker_host(issue, codex_update_recipient, opts, worker_host)
    duration_ms = System.monotonic_time(:millisecond) - started_at_ms

    Telemetry.emit(
      :run_end,
      telemetry_issue_attrs(issue, worker_host)
      |> Map.merge(%{
        duration_ms: duration_ms,
        outcome:
          case result do
            :ok -> "ok"
            {:error, reason} -> "error:#{inspect(reason)}"
          end
      })
    )

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp telemetry_issue_attrs(%Issue{} = issue, worker_host) do
    %{
      issue_id: issue.id,
      identifier: issue.identifier,
      worker_host: worker_host || "local",
      labels: issue.labels || []
    }
  end

  defp telemetry_issue_attrs(_issue, worker_host) do
    %{worker_host: worker_host || "local"}
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    routed_repo = resolve_routed_repo(issue)

    workspace_opts =
      []
      |> maybe_put(:routed_repo, routed_repo)

    case Workspace.create_for_issue(issue, worker_host, workspace_opts) do
      {:ok, workspace} ->
        # Once the worktree is populated we load the consumer repo's own
        # WORKFLOW.md from <workspace>/<workflow_path> and use ITS hook
        # commands for the rest of the lifecycle. This is what makes
        # multi-repo dispatch actually multi-repo — each consumer owns
        # its session_start / before_run / before_handoff / after_run.
        repo_workflow = load_repo_workflow(workspace, routed_repo)
        repo_hook_opts = repo_workflow_hook_opts(repo_workflow)

        # When Symphony did the worktree clone (routed_repo present),
        # we now run the per-repo after_create here. The legacy single-
        # repo path already ran the host-level after_create inside
        # Workspace.create_for_issue.
        if routed_repo do
          _ =
            Workspace.run_after_create_hook(
              workspace,
              issue,
              worker_host,
              hook_command: Map.get(repo_hook_opts, :after_create)
            )
        end

        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)
        session_start =
          SessionStartHook.run(
            workspace,
            issue,
            worker_host,
            hook_command: Map.get(repo_hook_opts, :session_start)
          )

        opts =
          opts
          |> Keyword.put(:session_start_prompt, session_start.prompt)
          |> maybe_put(:per_repo_before_handoff, Map.get(repo_hook_opts, :before_handoff))
          |> maybe_put(:per_repo_workflow, repo_workflow)

        try do
          with :ok <-
                 Workspace.run_before_run_hook(
                   workspace,
                   issue,
                   worker_host,
                   hook_command: Map.get(repo_hook_opts, :before_run)
                 ) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(
            workspace,
            issue,
            worker_host,
            hook_command: Map.get(repo_hook_opts, :after_run)
          )
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp resolve_routed_repo(%Issue{} = issue) do
    case RepoConfig.load() do
      {:ok, config} ->
        case Router.route(issue, config) do
          {:ok, repo} -> repo
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp resolve_routed_repo(_issue), do: nil

  # Load `<workspace>/<workflow_path>` after Symphony has populated the
  # worktree. Returns nil when there's no routed_repo (legacy single-repo
  # path) or when the consumer's WORKFLOW.md isn't readable — callers
  # fall back to host-level hooks in those cases.
  defp load_repo_workflow(workspace, %{workflow_path: workflow_path}) when is_binary(workflow_path) do
    path = Path.join(workspace, workflow_path)

    case SymphonyElixir.Workflow.load(path) do
      {:ok, workflow} ->
        Logger.info("Loaded per-repo workflow from #{path}")
        workflow

      {:error, reason} ->
        Logger.warning(
          "Falling back to host-level hooks; could not load per-repo workflow at #{path}: #{inspect(reason)}"
        )

        nil
    end
  end

  defp load_repo_workflow(_workspace, _routed_repo), do: nil

  defp repo_workflow_hook_opts(nil), do: %{}

  defp repo_workflow_hook_opts(%{config: config}) when is_map(config) do
    hooks = Map.get(config, "hooks", %{})

    %{
      before_run: Map.get(hooks, "before_run"),
      after_run: Map.get(hooks, "after_run"),
      session_start: Map.get(hooks, "session_start"),
      before_handoff: Map.get(hooks, "before_handoff"),
      after_create: Map.get(hooks, "after_create"),
      before_remove: Map.get(hooks, "before_remove")
    }
  end

  defp repo_workflow_hook_opts(_workflow), do: %{}

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)
    tool_executor = dynamic_tool_executor(issue, workspace, app_session.worker_host, opts)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue),
             tool_executor: tool_executor
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")
      handoff_gate_prompt = pop_handoff_gate_prompt()

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            Keyword.put(opts, :handoff_gate_prompt, handoff_gate_prompt),
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; marking Blocked and returning control to orchestrator")

          mark_blocked_on_giveup(refreshed_issue, %{
            reason: :max_turns_exhausted,
            turn_number: turn_number,
            max_turns: max_turns,
            workspace: workspace
          })

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns) do
    session_start_prompt = Keyword.get(opts, :session_start_prompt)

    [session_start_prompt, PromptBuilder.build_prompt(issue, opts)]
    |> Enum.reject(&(is_nil(&1) or String.trim(&1) == ""))
    |> Enum.join("\n\n")
  end

  defp build_turn_prompt(_issue, opts, turn_number, max_turns) do
    handoff_gate_prompt = Keyword.get(opts, :handoff_gate_prompt)

    """
    #{handoff_gate_prompt_section(handoff_gate_prompt)}
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp dynamic_tool_executor(issue, workspace, worker_host, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)
    per_repo_before_handoff = Keyword.get(opts, :per_repo_before_handoff)

    handoff_context =
      %{issue: issue, workspace: workspace, worker_host: worker_host}
      |> maybe_put_map(:before_handoff_command, per_repo_before_handoff)

    fn tool, arguments ->
      result =
        DynamicTool.execute(tool, arguments,
          linear_client: linear_client,
          handoff_gate_context: handoff_context
        )

      maybe_store_handoff_gate_prompt(result)
      result
    end
  end

  defp maybe_put_map(map, _key, nil), do: map
  defp maybe_put_map(map, key, value), do: Map.put(map, key, value)

  defp maybe_store_handoff_gate_prompt(%{"success" => false, "output" => output}) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, %{"error" => %{"remediation" => remediation}}} when is_binary(remediation) ->
        Process.put(@handoff_gate_prompt_key, remediation)

      _ ->
        :ok
    end
  end

  defp maybe_store_handoff_gate_prompt(_result), do: :ok

  defp pop_handoff_gate_prompt do
    Process.delete(@handoff_gate_prompt_key)
  end

  defp handoff_gate_prompt_section(prompt) when is_binary(prompt) do
    case String.trim(prompt) do
      "" -> ""
      trimmed -> trimmed <> "\n\n"
    end
  end

  defp handoff_gate_prompt_section(_prompt), do: ""

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        cond do
          repo_label_drifted?(issue, refreshed_issue) ->
            Logger.info(
              "Label drift detected mid-flight for #{issue_context(refreshed_issue)}; finishing current turn cleanly and halting (no reroute)"
            )

            {:done, refreshed_issue}

          active_issue_state?(refreshed_issue.state) ->
            {:continue, refreshed_issue}

          true ->
            {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  # Audit §9.4 (Symphony multi-repo, sub-step 6): if the routed issue's
  # `repo:<name>` label disappears or changes during a run, finish the
  # current Codex turn cleanly and halt; do not reroute mid-flight.
  defp repo_label_drifted?(%Issue{labels: original}, %Issue{labels: refreshed})
       when is_list(original) and is_list(refreshed) do
    repo_label_set(original) != repo_label_set(refreshed)
  end

  defp repo_label_drifted?(_original, _refreshed), do: false

  defp repo_label_set(labels) when is_list(labels) do
    configured = configured_repo_label_set()

    labels
    |> Enum.map(&Router.normalize/1)
    |> Enum.filter(&MapSet.member?(configured, &1))
    |> MapSet.new()
  end

  defp configured_repo_label_set do
    case RepoConfig.load() do
      {:ok, %{repos: repos}} ->
        repos
        |> Enum.map(fn %{label: label} -> Router.normalize(label) end)
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  @doc """
  Mark an issue Blocked when the agent run terminally gives up (max_turns
  exhausted or, in the future, all retries exhausted). Idempotent: skips work
  if the issue already carries the routing-warned label. Best-effort on each
  Linear write — logs and continues rather than raising, since this runs in
  the failure path.
  """
  @spec mark_blocked_on_giveup(map(), map()) :: :ok
  def mark_blocked_on_giveup(%Issue{id: issue_id} = issue, context)
      when is_binary(issue_id) and is_map(context) do
    if already_blocked?(issue) do
      Logger.info(
        "Skipping Blocked transition for #{issue_context(issue)}; idempotency label '#{@idempotency_label}' already present"
      )

      :ok
    else
      body = blocked_comment_body(issue, context)

      case Tracker.create_comment(issue_id, body) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Failed to post Blocked comment for #{issue_context(issue)}: #{inspect(reason)}"
          )
      end

      add_label_best_effort(issue, @needs_human_input_label)
      add_label_best_effort(issue, @idempotency_label)

      case Tracker.update_issue_state(issue_id, @blocked_state) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Failed to transition #{issue_context(issue)} to '#{@blocked_state}': #{inspect(reason)}"
          )
      end

      :ok
    end
  end

  def mark_blocked_on_giveup(_issue, _context), do: :ok

  defp already_blocked?(%Issue{labels: labels}) when is_list(labels) do
    @idempotency_label in labels
  end

  defp already_blocked?(_issue), do: false

  defp add_label_best_effort(%Issue{id: issue_id} = issue, label_name) do
    case Tracker.add_label(issue_id, label_name) do
      :ok ->
        :ok

      {:error, :label_missing} ->
        Logger.info(
          "Skipping label '#{label_name}' on #{issue_context(issue)}; label not configured in workspace"
        )

      {:error, reason} ->
        Logger.warning(
          "Failed to add label '#{label_name}' on #{issue_context(issue)}: #{inspect(reason)}"
        )
    end
  end

  defp blocked_comment_body(%Issue{} = issue, context) do
    reason = Map.get(context, :reason, :unknown)
    turn_number = Map.get(context, :turn_number)
    max_turns = Map.get(context, :max_turns)
    workspace = Map.get(context, :workspace)
    error = Map.get(context, :error)

    summary =
      case reason do
        :max_turns_exhausted ->
          "Symphony reached agent.max_turns (#{turn_number}/#{max_turns}) without resolving the issue."

        :retries_exhausted ->
          "Symphony exhausted all agent-run retries on this issue."

        other ->
          "Symphony stopped working on this issue (reason: #{inspect(other)})."
      end

    details =
      [
        workspace && "Workspace: `#{workspace}`",
        error && "Last error: `#{inspect_error(error)}`",
        "Transcript: see Symphony logs for `#{issue.identifier}`",
        "This issue has been moved to `#{@blocked_state}` and tagged `#{@needs_human_input_label}` for a human."
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    """
    #{@blocked_marker}
    #{summary}

    #{details}
    """
  end

  defp inspect_error(error) when is_binary(error), do: error
  defp inspect_error(error), do: inspect(error)
end
