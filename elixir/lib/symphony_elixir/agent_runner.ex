defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.DynamicTool

  alias SymphonyElixir.{
    AgentBackend,
    AgentFailure,
    AgentRouter,
    Config,
    Linear.Client,
    Linear.Comment,
    Linear.Issue,
    Orchestrator,
    PromptBuilder,
    RepoConfig,
    ReviewGate,
    ReviewOutcome,
    Router,
    SessionStartHook,
    TaskContextPrompt,
    Telemetry,
    Tracker,
    Workspace
  }

  @type worker_host :: String.t() | nil
  @prompt_built_telemetry_event [:symphony_elixir, :agent, :prompt_built]
  @handoff_gate_prompt_key {__MODULE__, :handoff_gate_prompt}
  @deferred_review_handoff_key {__MODULE__, :deferred_review_handoff}

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

    run_end_attrs =
      case result do
        :ok ->
          %{duration_ms: duration_ms, outcome: "ok", failure_class: nil}

        {:error, reason} ->
          failure = classify_run_failure(reason, issue)

          failure_attrs = %{
            failure_class: Atom.to_string(failure.class),
            failure_scope: Atom.to_string(failure.scope),
            trusted_failure: failure.trusted,
            backend: failure.backend,
            reset_at: failure.reset_at && DateTime.to_iso8601(failure.reset_at),
            retry_after_ms: failure.retry_after_ms
          }

          Telemetry.emit(:failure, Map.merge(telemetry_issue_attrs(issue, worker_host), failure_attrs))

          %{
            duration_ms: duration_ms,
            outcome: "error",
            failure_class: failure_attrs.failure_class,
            failure_scope: failure_attrs.failure_scope,
            trusted_failure: failure_attrs.trusted_failure,
            reset_at: failure_attrs.reset_at,
            retry_after_ms: failure_attrs.retry_after_ms
          }
      end

    Telemetry.emit(:run_end, Map.merge(telemetry_issue_attrs(issue, worker_host), run_end_attrs))

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        failure = classify_run_failure(reason, issue)
        Logger.error("Agent run failed for #{issue_context(issue)} class=#{failure.class}: #{failure.message}")
        send_worker_run_failure(codex_update_recipient, issue, failure)
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp classify_run_failure(%AgentFailure{} = failure, _issue), do: failure

  defp classify_run_failure(reason, issue) do
    {backend, _overrides} = AgentBackend.resolve_for_issue(issue)
    AgentFailure.classify(reason, backend: AgentBackend.backend_name(backend))
  end

  defp send_worker_run_failure(recipient, %Issue{id: issue_id}, %AgentFailure{} = failure)
       when is_pid(recipient) and is_binary(issue_id) do
    send(recipient, {:worker_run_failure, issue_id, self(), failure})
    :ok
  end

  defp send_worker_run_failure(_recipient, _issue, _failure), do: :ok

  defp telemetry_issue_attrs(%Issue{} = issue, worker_host) do
    %{
      issue_id: issue.id,
      identifier: issue.identifier,
      issue_identifier: issue.identifier,
      parent_issue_id: issue.parent_id,
      repository: repository_from_labels(issue.labels),
      worker_host: worker_host || "local",
      labels: issue.labels || []
    }
  end

  defp telemetry_issue_attrs(_issue, worker_host) do
    %{worker_host: worker_host || "local"}
  end

  defp repository_from_labels(labels) when is_list(labels) do
    Enum.find_value(labels, fn
      "repo:" <> name -> name
      _label -> nil
    end) || "default"
  end

  defp repository_from_labels(_labels), do: "default"

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
        # Optional reviewer agent: when the consumer repo ships a
        # WORKFLOW_REVIEW.md, ReviewGate runs it at the In Progress ->
        # In Review handoff. Absent file == feature off (legacy behavior).
        review_workflow = load_repo_review_workflow(workspace, routed_repo)

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

        try do
          with {:ok, issue_with_comments} <- attach_issue_comments(issue, opts),
               {:ok, _context_file} <-
                 Workspace.prepare_issue_context(workspace, issue_with_comments, worker_host) do
            run_prepared_agent(%{
              workspace: workspace,
              issue: issue_with_comments,
              codex_update_recipient: codex_update_recipient,
              opts: opts,
              worker_host: worker_host,
              repo_workflow: repo_workflow,
              review_workflow: review_workflow,
              repo_hook_opts: repo_hook_opts
            })
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

  defp run_prepared_agent(%{
         workspace: workspace,
         issue: issue,
         codex_update_recipient: codex_update_recipient,
         opts: opts,
         worker_host: worker_host,
         repo_workflow: repo_workflow,
         review_workflow: review_workflow,
         repo_hook_opts: repo_hook_opts
       }) do
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
      |> Keyword.put(:session_start_result, session_start)
      |> Keyword.put(:issue_context_file, Workspace.issue_context_path(workspace))
      |> maybe_put(:per_repo_before_handoff, Map.get(repo_hook_opts, :before_handoff))
      |> maybe_put(:per_repo_workflow, repo_workflow)
      |> maybe_put(:per_repo_review_workflow, review_workflow)

    with :ok <-
           Workspace.run_before_run_hook(
             workspace,
             issue,
             worker_host,
             hook_command: Map.get(repo_hook_opts, :before_run)
           ) do
      run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
    end
  end

  defp attach_issue_comments(%Issue{id: issue_id} = issue, opts) when is_binary(issue_id) do
    comments_fetcher = Keyword.get(opts, :issue_comments_fetcher, &Tracker.fetch_issue_comments/1)

    case comments_fetcher.(issue_id) do
      {:ok, %{comments: comments, truncated: truncated?}}
      when is_list(comments) and is_boolean(truncated?) ->
        if Enum.all?(comments, &match?(%Comment{}, &1)) do
          {:ok, %{issue | comments: comments, comments_truncated: truncated?}}
        else
          {:error, {:issue_comments_fetch_failed, :invalid_comments}}
        end

      {:ok, unexpected} ->
        {:error, {:issue_comments_fetch_failed, {:invalid_result, unexpected}}}

      {:error, reason} ->
        {:error, {:issue_comments_fetch_failed, reason}}
    end
  end

  defp attach_issue_comments(issue, _opts), do: {:ok, issue}

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
        Logger.warning("Falling back to host-level hooks; could not load per-repo workflow at #{path}: #{inspect(reason)}")

        nil
    end
  end

  defp load_repo_workflow(_workspace, _routed_repo), do: nil

  # Load `<workspace>/<review_workflow_path>` (default WORKFLOW_REVIEW.md).
  # Works in both multi-repo dispatch (path from the routed repo entry) and
  # the legacy single-repo path (routed_repo nil -> default filename in the
  # cloned worktree). A missing file means the reviewer feature is off, so we
  # stay quiet; only a present-but-unreadable/empty file warns.
  defp load_repo_review_workflow(workspace, routed_repo) do
    path = Path.join(workspace, review_workflow_path(routed_repo))

    # Missing file == reviewer feature off; stay quiet.
    if File.regular?(path), do: load_review_workflow_file(path)
  end

  defp load_review_workflow_file(path) do
    case SymphonyElixir.Workflow.load(path) do
      {:ok, %{prompt_template: prompt} = workflow} when is_binary(prompt) ->
        use_review_workflow_if_nonempty(path, workflow, prompt)

      {:error, reason} ->
        Logger.warning("Ignoring per-repo review workflow at #{path}: #{inspect(reason)}")
        nil
    end
  end

  defp use_review_workflow_if_nonempty(path, workflow, prompt) do
    if String.trim(prompt) == "" do
      Logger.warning("Ignoring per-repo review workflow at #{path}: empty review prompt")
      nil
    else
      Logger.info("Loaded per-repo review workflow from #{path}")
      workflow
    end
  end

  defp review_workflow_path(%{review_workflow_path: path}) when is_binary(path) and path != "", do: path
  defp review_workflow_path(_routed_repo), do: "WORKFLOW_REVIEW.md"

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

  # Report the *actual* backend (the resolved module the session runs on) and
  # model/effort, so the dashboard shows what is really running rather than re-deriving
  # it from the issue's labels. The session holds Codex's resolved model or the
  # config/override value handed to ACP/Claude Code; backends that report their
  # real model later on the wire refine it via the `:session_started` event.
  defp send_agent_backend_info(recipient, %Issue{id: issue_id}, route, session)
       when is_binary(issue_id) and is_pid(recipient) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         backend: AgentBackend.backend_name(route.backend),
         model: agent_session_model(session) || Map.get(route.overrides, :model),
         reasoning_effort:
           agent_session_reasoning_effort(session) ||
             Map.get(route.overrides, :reasoning_effort),
         profile: route.profile
       }}
    )

    :ok
  end

  defp send_agent_backend_info(_recipient, _issue, _route, _session), do: :ok

  defp agent_session_model(session) when is_map(session) do
    model =
      Map.get(session, :model) ||
        get_in(session, [:claude_code, :model]) ||
        get_in(session, [:acp, :model])

    if is_binary(model) and String.trim(model) != "", do: model
  end

  defp agent_session_model(_session), do: nil

  defp agent_session_reasoning_effort(session) when is_map(session) do
    case Map.get(session, :reasoning_effort) do
      effort when is_binary(effort) ->
        case String.trim(effort) do
          "" -> nil
          trimmed -> trimmed
        end

      _effort ->
        nil
    end
  end

  defp agent_session_reasoning_effort(_session), do: nil

  @doc false
  # Test seam: drive the per-turn loop directly with an injected backend
  # (`opts[:agent_backend]` = `{module, overrides}`), bypassing the
  # workspace/clone/hook setup `run/3` performs.
  @spec run_codex_turns_for_test(Path.t(), Issue.t(), pid() | nil, keyword(), worker_host()) ::
          :ok | {:error, term()}
  def run_codex_turns_for_test(workspace, issue, recipient, opts, worker_host) do
    run_codex_turns(workspace, issue, recipient, opts, worker_host)
  end

  @doc false
  @spec prompt_built_telemetry_event() :: [atom()]
  def prompt_built_telemetry_event, do: @prompt_built_telemetry_event

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, route} <- resolve_agent_route(workspace, issue, opts, worker_host) do
      result =
        with {:ok, session} <-
               route.backend.start_session(workspace,
                 worker_host: worker_host,
                 overrides: route.overrides,
                 issue_context_file: Keyword.get(opts, :issue_context_file)
               ) do
          send_agent_backend_info(codex_update_recipient, issue, route, session)

          try do
            do_run_codex_turns(
              route.backend,
              session,
              workspace,
              issue,
              codex_update_recipient,
              opts,
              issue_state_fetcher,
              1,
              max_turns
            )
          after
            route.backend.stop_session(session)
          end
        end

      case {result, Keyword.has_key?(opts, :agent_backend)} do
        {{:error, reason}, false} ->
          {:error,
           AgentFailure.classify(reason,
             backend: AgentBackend.backend_name(route.backend)
           )}

        _ ->
          result
      end
    end
  end

  defp resolve_agent_route(workspace, issue, opts, worker_host) do
    case Keyword.get(opts, :agent_backend) do
      {backend, overrides} when is_atom(backend) and is_map(overrides) ->
        {:ok,
         %{
           backend: backend,
           overrides: overrides,
           profile: nil,
           source: :injected
         }}

      nil ->
        router_opts =
          []
          |> maybe_put(:classifier, Keyword.get(opts, :agent_classifier))
          |> maybe_put(:issue_context_file, Keyword.get(opts, :issue_context_file))

        AgentRouter.resolve(
          workspace,
          issue,
          Keyword.get(opts, :per_repo_workflow),
          worker_host,
          router_opts
        )
    end
  end

  defp do_run_codex_turns(backend, app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    {prompt, included_sections, section_hashes} = build_turn_prompt(issue, opts, turn_number, max_turns)

    emit_prompt_built(
      prompt,
      %{included_sections: included_sections, section_hashes: section_hashes},
      issue,
      workspace,
      app_session.worker_host,
      opts,
      turn_number,
      max_turns
    )

    tool_executor = dynamic_tool_executor(issue, workspace, app_session.worker_host, opts)

    case backend.run_turn(
           app_session,
           prompt,
           issue,
           on_message: codex_message_handler(codex_update_recipient, issue),
           tool_executor: tool_executor
         ) do
      {:ok, turn_session} ->
        Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")
        handoff_gate_prompt = pop_handoff_gate_prompt()

        handoff_gate_prompt =
          maybe_run_deferred_review_handoff(
            pop_deferred_review_handoff(),
            handoff_gate_prompt,
            codex_update_recipient,
            backend
          )

        case continue_with_issue?(issue, issue_state_fetcher) do
          {:continue, refreshed_issue} when turn_number < max_turns ->
            Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

            do_run_codex_turns(
              backend,
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

      {:error, reason} = error ->
        # Abnormal turn completion (an interruption surfaces as
        # `{:error, {:turn_completed_abnormally, _}}`) short-circuits before the
        # normal deferred-review step above. The handoff mutation the agent
        # captured during this turn lives in this task's process dictionary and
        # would be silently dropped when the task exits, leaving the issue stuck
        # In Progress. Run the deferred review here too so the In Review handoff
        # isn't lost; the gate's own interim-verdict / abnormal-completion
        # detection still guards against a false-success handoff. The returned
        # findings prompt can't be consumed (the turn is over), so discard it —
        # the orchestrator re-dispatches the still-active issue for a fresh turn.
        maybe_run_deferred_review_handoff(
          pop_deferred_review_handoff(),
          nil,
          codex_update_recipient,
          backend
        )

        Logger.warning("Agent turn ended abnormally for #{issue_context(issue)} turn=#{turn_number}/#{max_turns} reason=#{inspect(reason)}")
        error
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns) do
    [
      {"task_context", TaskContextPrompt.render(issue, Keyword.get(opts, :session_start_result))},
      {"repository_workflow", PromptBuilder.build_prompt(issue, opts)},
      {"handoff_tool_guidance", handoff_tool_guidance(opts)}
    ]
    |> compose_prompt_sections()
  end

  defp build_turn_prompt(_issue, opts, turn_number, max_turns) do
    handoff_gate_prompt = Keyword.get(opts, :handoff_gate_prompt)
    handoff_guidance = handoff_tool_guidance(opts)

    prompt =
      """
      #{handoff_gate_prompt_section(handoff_gate_prompt)}
      Continuation guidance:

      - The previous Codex turn completed normally, but the Linear issue is still in an active state.
      - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
      - Resume from the current workspace and workpad state instead of restarting from scratch.
      - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
      - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.

      #{handoff_guidance}
      """

    {included_sections, section_hashes} =
      prompt_section_metadata([
        {"handoff_gate_remediation", handoff_gate_prompt},
        {"continuation_guidance", "included"},
        {"handoff_tool_guidance", handoff_guidance}
      ])

    {prompt, included_sections, section_hashes}
  end

  defp compose_prompt_sections(sections) do
    included_sections =
      Enum.reject(sections, fn {_name, content} ->
        is_nil(content) or String.trim(content) == ""
      end)

    prompt = Enum.map_join(included_sections, "\n\n", fn {_name, content} -> content end)
    {names, hashes} = prompt_section_metadata(included_sections)
    {prompt, names, hashes}
  end

  defp prompt_section_metadata(sections) do
    sections = Enum.reject(sections, fn {_name, content} -> is_nil(content) or String.trim(content) == "" end)

    {
      Enum.map(sections, fn {name, _content} -> name end),
      Map.new(sections, fn {name, content} ->
        {name, :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)}
      end)
    }
  end

  defp emit_prompt_built(
         prompt,
         prompt_metadata,
         issue,
         workspace,
         worker_host,
         opts,
         turn_number,
         max_turns
       ) do
    included_sections = prompt_metadata.included_sections
    prompt_kind = if turn_number == 1, do: "initial", else: "continuation"
    prompt_chars = String.length(prompt)
    prompt_bytes = byte_size(prompt)

    measurements = %{
      count: 1,
      prompt_bytes: prompt_bytes,
      prompt_chars: prompt_chars
    }

    metadata = %{
      event: "agent.prompt_built",
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      workspace: workspace,
      worker_host: worker_host,
      attempt: Keyword.get(opts, :attempt),
      turn_number: turn_number,
      max_turns: max_turns,
      prompt_kind: prompt_kind,
      included_sections: included_sections,
      injected_section_hashes: prompt_metadata.section_hashes,
      prompt_sha256: :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower)
    }

    :telemetry.execute(@prompt_built_telemetry_event, measurements, metadata)
    Telemetry.emit(:prompt_built, Map.merge(metadata, measurements))

    Logger.info(
      "agent.prompt_built #{issue_context(issue)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)} " <>
        "attempt=#{inspect(metadata.attempt)} turn=#{turn_number}/#{max_turns} prompt_kind=#{prompt_kind} " <>
        "prompt_chars=#{prompt_chars} prompt_bytes=#{prompt_bytes} included_sections=#{Enum.join(included_sections, ",")}"
    )
  end

  defp dynamic_tool_executor(issue, workspace, worker_host, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)
    per_repo_before_handoff = Keyword.get(opts, :per_repo_before_handoff)
    per_repo_review_workflow = Keyword.get(opts, :per_repo_review_workflow)

    handoff_context =
      %{issue: issue, workspace: workspace, worker_host: worker_host}
      |> maybe_put_map(:before_handoff_command, per_repo_before_handoff)
      |> maybe_put_map(:review_workflow, per_repo_review_workflow)
      |> maybe_put_map(:deferred_review_callback, deferred_review_callback(per_repo_review_workflow))

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

  defp deferred_review_callback(nil), do: nil
  defp deferred_review_callback(_review_workflow), do: &store_deferred_review_handoff/1

  defp store_deferred_review_handoff(request) when is_map(request) do
    case Process.get(@deferred_review_handoff_key) do
      nil ->
        Process.put(@deferred_review_handoff_key, request)
        :ok

      existing_request ->
        issue = Map.get(existing_request, :issue) || Map.get(request, :issue)

        Logger.info("review.gate deferred already pending #{issue_context(issue)}; coalescing repeated handoff request")

        :already_pending
    end
  end

  defp pop_deferred_review_handoff do
    Process.delete(@deferred_review_handoff_key)
  end

  @doc false
  # Test seam: seed the deferred-review handoff a backend would normally capture
  # mid-turn via the dynamic tool executor, so the abnormal-completion path can
  # be exercised without simulating the full handoff tool call.
  @spec store_deferred_review_handoff_for_test(map()) :: :ok | :already_pending
  def store_deferred_review_handoff_for_test(request) when is_map(request) do
    store_deferred_review_handoff(request)
  end

  defp maybe_run_deferred_review_handoff(nil, handoff_gate_prompt, _recipient, _backend),
    do: handoff_gate_prompt

  defp maybe_run_deferred_review_handoff(%{} = request, _handoff_gate_prompt, recipient, backend) do
    issue = Map.fetch!(request, :issue)
    workspace = Map.fetch!(request, :workspace)
    worker_host = Map.get(request, :worker_host)
    review_workflow = Map.fetch!(request, :review_workflow)
    review_job_id = System.unique_integer([:positive, :monotonic])
    review_opts = review_opts_with_progress(request, recipient, issue, review_job_id)
    review_timeout_ms = handoff_review_timeout_ms(AgentBackend.backend_name(backend))

    Logger.info("review.gate deferred starting #{issue_context(issue)} workspace=#{workspace}")

    :ok =
      transition_agent_lifecycle(recipient, issue, :handoff_pending_review, %{
        timeout_ms: review_timeout_ms,
        review_job_id: review_job_id,
        review_key: {:resolving_review_target, issue.id}
      })

    {review_key, review_opts} = ReviewGate.prepare_review(workspace, issue, review_opts)

    :ok =
      transition_agent_lifecycle(recipient, issue, :handoff_pending_review, %{
        timeout_ms: review_timeout_ms,
        review_job_id: review_job_id,
        review_key: review_key
      })

    {outcome, handoff_gate_prompt, review_outcome} =
      case ReviewGate.run(workspace, issue, worker_host, review_workflow, review_opts) do
        {:approved, review_outcome} ->
          apply_reviewed_handoff(request, review_key, review_opts, review_outcome)

        {:request_changes, prompt, review_outcome} ->
          Logger.info("review.gate deferred blocked #{issue_context(issue)} findings=#{length(review_outcome.findings)}")
          {:request_changes, prompt, review_outcome}

        {terminal_outcome, %ReviewOutcome{} = review_outcome}
        when terminal_outcome in [
               :automation_inconclusive,
               :infrastructure_unavailable,
               :budget_exhausted_with_findings
             ] ->
          Logger.warning("review.gate deferred withheld #{issue_context(issue)} outcome=#{terminal_outcome} reason=#{inspect(review_outcome.failure_reason)}")

          {terminal_outcome, review_nonapproval_prompt(issue, review_outcome), review_outcome}
      end

    :ok =
      transition_agent_lifecycle(recipient, issue, :implementing, %{
        review_job_id: review_job_id,
        review_outcome: outcome,
        review_state: ReviewOutcome.to_map(review_outcome)
      })

    handoff_gate_prompt
  end

  defp apply_reviewed_handoff(request, review_key, review_opts, %ReviewOutcome{} = review_outcome) do
    workspace = Map.fetch!(request, :workspace)
    issue = Map.fetch!(request, :issue)

    if ReviewGate.authoritative_for_current_head?(
         workspace,
         issue,
         review_key,
         review_opts,
         review_outcome
       ) do
      case apply_deferred_review_handoff(request) do
        nil ->
          {:approved, nil, review_outcome}

        failure_prompt ->
          unavailable = unavailable_review_outcome(review_outcome, :deferred_linear_mutation_failed)
          {:infrastructure_unavailable, failure_prompt, unavailable}
      end
    else
      Logger.warning("review.gate deferred head changed or unpinned #{issue_context(issue)} reviewed_key=#{inspect(review_key)}; withholding Linear handoff")

      inconclusive =
        inconclusive_review_outcome(
          review_outcome,
          {:review_head_unpinned_or_changed, review_key}
        )

      {:automation_inconclusive, deferred_review_head_changed_prompt(issue), inconclusive}
    end
  end

  defp inconclusive_review_outcome(%ReviewOutcome{} = review_outcome, reason) do
    %{
      review_outcome
      | outcome: :automation_inconclusive,
        authoritative: false,
        failure_reason: reason,
        resume_condition: "Re-run automated review for the exact current candidate head before applying the handoff."
    }
  end

  defp unavailable_review_outcome(%ReviewOutcome{} = review_outcome, reason) do
    %{
      review_outcome
      | outcome: :infrastructure_unavailable,
        authoritative: false,
        failure_reason: reason,
        resume_condition: "Restore Linear mutation availability, then re-attempt the gated handoff; approval is not carried forward."
    }
  end

  # UDPE-6952: resolve the deferred-review timeout from the RUNNING backend's
  # own config namespace (stall timeout when positive, else turn timeout),
  # falling back to codex where the backend has no value.
  defp handoff_review_timeout_ms(backend_name),
    do: Config.backend_review_timeout_ms(backend_name)

  defp review_opts_with_progress(request, recipient, issue, review_job_id) do
    review_opts = Map.get(request, :review_opts, [])
    existing_on_message = Keyword.get(review_opts, :on_message)
    worker_pid = self()

    on_message = fn message ->
      if is_function(existing_on_message, 1), do: existing_on_message.(message)

      send_handoff_review_heartbeat(
        recipient,
        issue,
        worker_pid,
        review_job_id,
        message
      )
    end

    Keyword.put(review_opts, :on_message, on_message)
  end

  defp send_handoff_review_heartbeat(
         recipient,
         %Issue{id: issue_id},
         worker_pid,
         review_job_id,
         message
       )
       when is_pid(recipient) and is_binary(issue_id) and is_pid(worker_pid) and
              is_integer(review_job_id) and is_map(message) do
    timestamp =
      case Map.get(message, :timestamp) do
        %DateTime{} = timestamp -> timestamp
        _ -> DateTime.utc_now()
      end

    send(recipient, {:handoff_review_heartbeat, issue_id, worker_pid, review_job_id, timestamp})
    :ok
  end

  defp send_handoff_review_heartbeat(
         _recipient,
         _issue,
         _worker_pid,
         _review_job_id,
         _message
       ),
       do: :ok

  defp transition_agent_lifecycle(recipient, %Issue{id: issue_id}, lifecycle_state, metadata)
       when is_pid(recipient) and is_binary(issue_id) and is_atom(lifecycle_state) and
              is_map(metadata) do
    if recipient == self() do
      send(recipient, {:agent_lifecycle, issue_id, lifecycle_state, metadata})
      :ok
    else
      case GenServer.call(
             recipient,
             {:agent_lifecycle, issue_id, lifecycle_state, metadata},
             15_000
           ) do
        :ok ->
          :ok

        other ->
          raise "orchestrator rejected #{lifecycle_state} lifecycle transition for issue_id=#{issue_id}: #{inspect(other)}"
      end
    end
  end

  defp transition_agent_lifecycle(_recipient, _issue, _lifecycle_state, _metadata), do: :ok

  defp apply_deferred_review_handoff(%{} = request) do
    issue = Map.fetch!(request, :issue)
    query = Map.fetch!(request, :query)
    variables = Map.get(request, :variables, %{})
    linear_client = Map.fetch!(request, :linear_client)

    Logger.info("review.gate deferred approved #{issue_context(issue)}; applying Linear handoff mutation")

    case linear_client.(query, variables, []) do
      {:ok, response} ->
        if graphql_success?(response) do
          Logger.info("review.gate deferred handoff applied #{issue_context(issue)}")
          nil
        else
          Logger.warning("review.gate deferred handoff mutation returned GraphQL errors #{issue_context(issue)}")
          deferred_handoff_failure_prompt(issue, {:linear_graphql_errors, graphql_errors(response)})
        end

      {:error, reason} ->
        Logger.warning("review.gate deferred handoff mutation failed #{issue_context(issue)} reason=#{inspect(reason)}")
        deferred_handoff_failure_prompt(issue, reason)
    end
  end

  defp graphql_success?(response) do
    graphql_errors(response) == []
  end

  defp graphql_errors(%{"errors" => errors}) when is_list(errors), do: errors
  defp graphql_errors(%{errors: errors}) when is_list(errors), do: errors
  defp graphql_errors(_response), do: []

  defp deferred_handoff_failure_prompt(%Issue{} = issue, reason) do
    """
    System message:

    The automated reviewer approved the In Progress -> In Review handoff for #{issue.identifier}, but Symphony could not apply the original Linear status mutation after the review completed.

    Reason: `#{inspect(reason)}`

    Keep the issue in In Progress, inspect the Linear status transition, and re-attempt the handoff with Symphony's `linear_graphql` tool.
    """
    |> String.trim()
  end

  defp deferred_review_head_changed_prompt(%Issue{} = issue) do
    """
    System message:

    The pull request head for #{issue.identifier} changed while the automated reviewer was running, so Symphony did not apply the reviewed Linear handoff.

    Keep the issue in In Progress and re-attempt the handoff. The next reviewer will inspect the new pull request head.
    """
    |> String.trim()
  end

  defp review_nonapproval_prompt(%Issue{} = issue, %ReviewOutcome{} = outcome) do
    findings = format_review_findings(outcome.findings)

    """
    System message:

    Automated review did not approve the In Progress -> In Review handoff for #{issue.identifier}.

    Outcome: `#{outcome.outcome}`
    Reviewed candidate SHA: `#{outcome.reviewed_sha || "unavailable"}`
    Review iteration: #{outcome.iteration} of #{outcome.max_iterations}
    Severity counts: `#{inspect(outcome.severity_counts)}`
    Failure reason: `#{inspect(outcome.failure_reason)}`

    Preserved findings:
    #{findings}

    The original Linear mutation was not applied. #{outcome.resume_condition}
    Do not represent this outcome as automated approval in the workpad or pull request.
    """
    |> String.trim()
  end

  defp format_review_findings([]),
    do: "- (no structured findings were recovered; inspect the review failure evidence)"

  defp format_review_findings(findings) when is_list(findings),
    do: Enum.map_join(findings, "\n", &format_review_finding/1)

  defp format_review_finding(finding) do
    severity = Map.get(finding, :severity, "comment")
    location = review_finding_location(Map.get(finding, :file), Map.get(finding, :line))
    "- #{location}[#{severity}] #{Map.get(finding, :body, "(no detail)")}"
  end

  defp review_finding_location(file, line) when is_binary(file) and is_integer(line),
    do: "#{file}:#{line} "

  defp review_finding_location(file, _line) when is_binary(file), do: "#{file} "
  defp review_finding_location(_file, _line), do: ""

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

  defp handoff_tool_guidance(opts) do
    if Keyword.has_key?(opts, :per_repo_before_handoff) or Keyword.has_key?(opts, :per_repo_review_workflow) do
      """
      Symphony handoff requirement:

      - To move this issue from In Progress to In Review or Human Review, use Symphony's `linear_graphql` tool for the Linear `issueUpdate` mutation.
      - If that tool returns gate remediation, keep the issue In Progress and address the reported gate failures.
      - Do not use the native Linear MCP `save_issue` tool for that handoff; it cannot run Symphony's before_handoff and automated review gates.
      """
      |> String.trim()
    else
      ""
    end
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        refreshed_issue = preserve_issue_comments(issue, refreshed_issue)

        cond do
          repo_label_drifted?(issue, refreshed_issue) ->
            Logger.info("Label drift detected mid-flight for #{issue_context(refreshed_issue)}; finishing current turn cleanly and halting (no reroute)")

            {:done, refreshed_issue}

          Orchestrator.review_state?(refreshed_issue.state) ->
            # The issue moved into a review/merge state mid-run (Human
            # Review, In Review, Merging, Ready to Merge). The repo prompt
            # forbids the agent from touching the PR there — humans merge —
            # so continuing would only burn no-op turns until agent.max_turns
            # trips mark_blocked_on_giveup(:max_turns_exhausted) and demotes a
            # merge-ready issue to a false Blocked. Finish the current turn
            # cleanly and halt. Mirrors the dispatch-side guard in
            # Orchestrator.candidate_issue?/3 and is authoritative even if a
            # host misconfigures such a state as active (UDPE-6950).
            Logger.info("Issue #{issue_context(refreshed_issue)} entered review/merge state (now #{inspect(refreshed_issue.state)}); ending run without further continuation")

            {:done, refreshed_issue}

          active_issue_state?(refreshed_issue.state) ->
            {:continue, refreshed_issue}

          true ->
            # The issue left the active states mid-run. This is the sanctioned
            # "blocked" channel: an agent that knows it is stuck transitions the
            # issue to Blocked (via the gated linear_graphql tool), and that
            # transition ends the run here — the current turn finishes and we do
            # NOT dispatch another. Any non-active terminal (Done/Cancelled/…)
            # ends it the same way.
            Logger.info("Issue #{issue_context(refreshed_issue)} left active states (now #{inspect(refreshed_issue.state)}); ending run without further continuation")

            {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp preserve_issue_comments(%Issue{} = previous_issue, %Issue{} = refreshed_issue) do
    %{
      refreshed_issue
      | comments: previous_issue.comments,
        comments_truncated: previous_issue.comments_truncated
    }
  end

  # Audit §9.4 (Symphony multi-repo, sub-step 6): if the routed issue's
  # `repo:<name>` label disappears or changes during a run, finish the
  # current Codex turn cleanly and halt; do not reroute mid-flight.
  defp repo_label_drifted?(%Issue{labels: original}, %Issue{labels: refreshed})
       when is_list(original) and is_list(refreshed) do
    repo_label_set(original) != repo_label_set(refreshed)
  end

  defp repo_label_drifted?(_original, _refreshed), do: false

  # `MapSet.member?/2` on a MapSet built and consumed in the same module trips
  # a Dialyzer opacity false-positive (the set's success typing is seen as the
  # bare struct, not the opaque MapSet.t()). The usage is correct, so suppress
  # opacity warnings for this function only.
  @dialyzer {:no_opaque, repo_label_set: 1}
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
      Logger.info("Skipping Blocked transition for #{issue_context(issue)}; idempotency label '#{@idempotency_label}' already present")

      :ok
    else
      body = blocked_comment_body(issue, context)

      case Tracker.create_comment(issue_id, body) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to post Blocked comment for #{issue_context(issue)}: #{inspect(reason)}")
      end

      add_label_best_effort(issue, @needs_human_input_label)
      add_label_best_effort(issue, @idempotency_label)

      case Tracker.update_issue_state(issue_id, @blocked_state) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to transition #{issue_context(issue)} to '#{@blocked_state}': #{inspect(reason)}")
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
        Logger.info("Skipping label '#{label_name}' on #{issue_context(issue)}; label not configured in workspace")

      {:error, reason} ->
        Logger.warning("Failed to add label '#{label_name}' on #{issue_context(issue)}: #{inspect(reason)}")
    end
  end

  defp blocked_comment_body(%Issue{} = issue, context) do
    reason = Map.get(context, :reason, :unknown)
    turn_number = Map.get(context, :turn_number)
    max_turns = Map.get(context, :max_turns)
    retries = Map.get(context, :retries)
    max_retries = Map.get(context, :max_retries)
    workspace = Map.get(context, :workspace)
    error = Map.get(context, :error)

    summary =
      case reason do
        :max_turns_exhausted ->
          "Symphony reached agent.max_turns (#{turn_number}/#{max_turns}) without resolving the issue."

        :retries_exhausted when is_integer(retries) and is_integer(max_retries) ->
          "Symphony exhausted all agent-run retries on this issue after #{retries} consecutive failed runs (agent.max_retries=#{max_retries})."

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
