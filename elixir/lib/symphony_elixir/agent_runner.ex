defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.DynamicTool

  alias SymphonyElixir.{
    AgentBackend,
    AgentBudgetCollector,
    AgentEfficiency,
    AgentFailure,
    AgentRouter,
    BaseDrift,
    Config,
    GitHubAuth,
    HandoffGate,
    Linear.Client,
    Linear.Comment,
    Linear.Issue,
    Orchestrator,
    PromptBuilder,
    PromptComposer,
    PromptSection,
    RepoConfig,
    ReviewGate,
    ReviewOutcome,
    ReviewPacket,
    Router,
    SessionStartHook,
    TaskContextPrompt,
    Telemetry,
    TestWorkerBudget,
    Tracker,
    Workspace
  }

  @type worker_host :: String.t() | nil
  @prompt_built_telemetry_event [:symphony_elixir, :agent, :prompt_built]
  @handoff_gate_prompt_key {__MODULE__, :handoff_gate_prompt}
  @handoff_gate_infrastructure_failure_key {__MODULE__, :handoff_gate_infrastructure_failure}
  @deferred_handoff_gate_key {__MODULE__, :deferred_handoff_gate}
  @deferred_review_handoff_key {__MODULE__, :deferred_review_handoff}
  @agent_wait_request_key {__MODULE__, :agent_wait_request}

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
    {routed_repo, automation_opt_in_label} = resolve_routing_context(issue)

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

        opts =
          opts
          |> Keyword.put_new(:issue_comments_fetcher, &Tracker.fetch_issue_comments/1)
          |> maybe_put(:repository_id, routed_repo && routed_repo.id)
          |> maybe_put(:automation_opt_in_label, automation_opt_in_label)
          |> maybe_put(:base_drift_ref, routed_repo && routed_repo.base_branch)

        try do
          with :ok <-
                 maybe_run_routed_after_create(
                   routed_repo,
                   workspace,
                   issue,
                   worker_host,
                   Map.get(repo_hook_opts, :after_create)
                 ),
               {:ok, issue_with_comments} <- attach_issue_comments(issue, opts),
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

  defp maybe_run_routed_after_create(nil, _workspace, _issue, _worker_host, _command), do: :ok

  defp maybe_run_routed_after_create(_routed_repo, workspace, issue, worker_host, command) do
    Workspace.run_after_create_hook(
      workspace,
      issue,
      worker_host,
      hook_command: command
    )
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

    send_scheduling_runtime_info(
      codex_update_recipient,
      issue,
      worker_host,
      workspace,
      opts
    )

    case prepare_github_auth(workspace, issue, worker_host) do
      {:ok, _github_auth} ->
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
          |> maybe_put(
            :per_repo_before_handoff_timeout_ms,
            Map.get(repo_hook_opts, :before_handoff_timeout_ms)
          )
          |> maybe_put(
            :per_repo_before_handoff_stale_ms,
            Map.get(repo_hook_opts, :before_handoff_stale_ms)
          )
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

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prepare_github_auth(workspace, issue, worker_host) do
    case GitHubAuth.prepare(workspace, worker_host: worker_host) do
      {:ok, session} ->
        Logger.info(
          "GitHub App authentication ready #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)} repository=#{session.repo} github_host=#{session.host} expires_at=#{DateTime.to_iso8601(session.expires_at)}"
        )

        {:ok, session}

      {:error, reason} ->
        Logger.error("GitHub App authentication failed #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)} reason=#{inspect(reason)}")

        {:error, reason}
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

  defp resolve_routing_context(%Issue{} = issue) do
    case RepoConfig.load() do
      {:ok, config} ->
        routed_repo =
          case Router.route(issue, config) do
            {:ok, repo} -> repo
            _ -> nil
          end

        {routed_repo, config.linear.filter_label}

      _ ->
        {nil, nil}
    end
  end

  defp resolve_routing_context(_issue), do: {nil, nil}

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
      before_handoff_timeout_ms: Map.get(hooks, "before_handoff_timeout_ms"),
      before_handoff_stale_ms: Map.get(hooks, "before_handoff_stale_ms"),
      after_create: Map.get(hooks, "after_create"),
      before_remove: Map.get(hooks, "before_remove")
    }
  end

  defp codex_message_handler(recipient, issue, budget_ref) do
    fn message ->
      AgentBudgetCollector.observe(budget_ref, message)
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

  defp send_scheduling_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace, opts)
       when is_pid(recipient) and is_binary(issue_id) and is_binary(workspace) do
    manifest =
      BaseDrift.manifest(workspace, Keyword.get(opts, :base_drift_ref), worker_host: worker_host)

    scheduling_info =
      %{
        repository_id: Keyword.get(opts, :repository_id),
        base_sha: manifest.base_sha,
        base_age_seconds: manifest.base_age_seconds,
        candidate_base_sha: manifest.candidate_base_sha,
        workspace_dirty: manifest.dirty
      }
      |> maybe_put_actual_manifest(manifest.actual_paths)

    send(
      recipient,
      {:worker_runtime_info, issue_id, scheduling_info}
    )

    :ok
  end

  defp send_scheduling_runtime_info(_recipient, _issue, _worker_host, _workspace, _opts), do: :ok

  defp maybe_put_actual_manifest(info, []), do: info

  defp maybe_put_actual_manifest(info, paths) when is_list(paths) do
    info
    |> Map.put(:scheduling_paths, paths)
    |> Map.put(:scheduling_path_source, "actual")
  end

  # Report the *actual* backend (the resolved module the session runs on) and
  # model/effort, so the dashboard shows what is really running rather than re-deriving
  # it from the issue's labels. The session holds Codex's resolved model or the
  # config/override value handed to ACP/Claude Code; backends that report their
  # real model later on the wire refine it via the `:session_started` event.
  defp send_agent_backend_info(recipient, %Issue{id: issue_id}, route, session, efficiency)
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
         profile: route.profile,
         task_type: efficiency.task_type,
         routing_confidence: efficiency.confidence,
         budget_profile: efficiency.budget_profile,
         budget_mode: efficiency.mode,
         budget_transitions: []
       }}
    )

    :ok
  end

  defp send_agent_backend_info(_recipient, _issue, _route, _session, _efficiency), do: :ok

  defp send_budget_runtime_info(recipient, %Issue{id: issue_id}, budget_runtime)
       when is_binary(issue_id) and is_pid(recipient) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         budget_metrics: budget_runtime.metrics,
         budget_transitions: budget_runtime.transitions
       }}
    )

    :ok
  end

  defp send_budget_runtime_info(_recipient, _issue, _budget_runtime), do: :ok

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

    with {:ok, route} <- resolve_agent_route(workspace, issue, opts, worker_host),
         {:ok, efficiency} <-
           AgentEfficiency.decide(issue, route, Keyword.get(opts, :per_repo_workflow)) do
      recovery =
        recover_pending_handoff_gate(
          workspace,
          issue,
          worker_host,
          codex_update_recipient,
          route.backend,
          opts,
          issue_state_fetcher
        )
        |> reject_recovered_handoff_infrastructure()

      result =
        case recovery do
          :none ->
            run_agent_session(
              route,
              efficiency,
              %{
                workspace: workspace,
                issue: issue,
                recipient: codex_update_recipient,
                opts: opts,
                issue_state_fetcher: issue_state_fetcher,
                max_turns: max_turns,
                worker_host: worker_host
              }
            )

          {:completed, _issue} ->
            :ok

          {:resume, prompt, refreshed_issue} ->
            run_agent_session(
              route,
              efficiency,
              %{
                workspace: workspace,
                issue: refreshed_issue,
                recipient: codex_update_recipient,
                opts: Keyword.put(opts, :handoff_gate_prompt, prompt),
                issue_state_fetcher: issue_state_fetcher,
                max_turns: max_turns,
                worker_host: worker_host
              }
            )

          {:error, reason} ->
            {:error, reason}
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

  defp reject_recovered_handoff_infrastructure({:resume, _prompt, _issue} = recovery) do
    case pop_handoff_infrastructure_failure() do
      nil -> recovery
      failure -> {:error, failure}
    end
  end

  defp reject_recovered_handoff_infrastructure(recovery), do: recovery

  defp run_agent_session(route, efficiency, context) do
    workspace = context.workspace
    issue = context.issue
    codex_update_recipient = context.recipient
    opts = context.opts

    with {:ok, budget_collector} <- AgentBudgetCollector.start_link(efficiency, issue) do
      opts =
        opts
        |> Keyword.put(:efficiency_decision, efficiency)
        |> Keyword.put(:budget_collector, budget_collector)

      try do
        with {:ok, session} <-
               route.backend.start_session(workspace,
                 worker_host: context.worker_host,
                 overrides: route.overrides,
                 issue_context_file: Keyword.get(opts, :issue_context_file)
               ) do
          send_agent_backend_info(codex_update_recipient, issue, route, session, efficiency)

          try do
            do_run_codex_turns(
              route.backend,
              session,
              workspace,
              issue,
              codex_update_recipient,
              opts,
              context.issue_state_fetcher,
              {1, context.max_turns}
            )
          after
            route.backend.stop_session(session)
          end
        end
      after
        AgentBudgetCollector.stop(budget_collector)
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

  defp do_run_codex_turns(
         backend,
         app_session,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         issue_state_fetcher,
         {turn_number, max_turns}
       ) do
    budget_collector = Keyword.fetch!(opts, :budget_collector)
    strategy_prompt = AgentBudgetCollector.take_strategy_prompt(budget_collector)
    opts = maybe_put(opts, :efficiency_strategy_prompt, strategy_prompt)
    prompt_composition = build_turn_prompt(issue, opts, turn_number, max_turns)
    prompt = prompt_composition.prompt

    emit_prompt_built(
      prompt,
      prompt_composition,
      issue,
      workspace,
      app_session.worker_host,
      opts,
      turn_number,
      max_turns
    )

    tool_executor =
      dynamic_tool_executor(
        issue,
        workspace,
        app_session.worker_host,
        codex_update_recipient,
        opts
      )

    budget_ref = AgentBudgetCollector.ref(budget_collector)
    started_ms = System.monotonic_time(:millisecond)
    :ok = AgentBudgetCollector.start_turn(budget_collector, prompt, started_ms)

    turn_result =
      backend.run_turn(
        app_session,
        prompt,
        issue,
        on_message: codex_message_handler(codex_update_recipient, issue, budget_ref),
        tool_executor: tool_executor
      )

    budget_runtime =
      AgentBudgetCollector.finish_turn(
        budget_collector,
        System.monotonic_time(:millisecond)
      )

    send_budget_runtime_info(codex_update_recipient, issue, budget_runtime)

    send_scheduling_runtime_info(
      codex_update_recipient,
      issue,
      app_session.worker_host,
      workspace,
      opts
    )

    case turn_result do
      {:ok, turn_session} ->
        Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")
        handoff_gate_prompt = pop_handoff_gate_prompt()

        handoff_gate_prompt =
          maybe_run_deferred_handoff_gate(
            pop_deferred_handoff_gate(),
            handoff_gate_prompt,
            codex_update_recipient,
            backend,
            issue_state_fetcher,
            opts
          )

        handoff_gate_prompt =
          maybe_run_deferred_review_handoff(
            pop_deferred_review_handoff(),
            handoff_gate_prompt,
            codex_update_recipient,
            backend
          )

        infrastructure_failure = pop_handoff_infrastructure_failure()
        wait_request = pop_agent_wait_request()
        continuation = continue_with_issue?(issue, issue_state_fetcher, opts)

        finish_successful_turn(
          %{
            backend: backend,
            app_session: app_session,
            workspace: workspace,
            recipient: codex_update_recipient,
            opts: opts,
            handoff_gate_prompt: handoff_gate_prompt,
            prompt_state: prompt_composition.state,
            issue_state_fetcher: issue_state_fetcher,
            turn_number: turn_number,
            max_turns: max_turns
          },
          continuation,
          infrastructure_failure,
          wait_request
        )

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
        handoff_gate_prompt =
          maybe_run_deferred_handoff_gate(
            pop_deferred_handoff_gate(),
            nil,
            codex_update_recipient,
            backend,
            issue_state_fetcher,
            opts
          )

        maybe_run_deferred_review_handoff(
          pop_deferred_review_handoff(),
          handoff_gate_prompt,
          codex_update_recipient,
          backend
        )

        Logger.warning("Agent turn ended abnormally for #{issue_context(issue)} turn=#{turn_number}/#{max_turns} reason=#{inspect(reason)}")
        error
    end
  end

  defp finish_successful_turn(context, {:continue, refreshed_issue}, nil, %{} = request) do
    :ok =
      transition_agent_lifecycle(context.recipient, refreshed_issue, :waiting, %{
        request: request
      })

    Logger.info("Parking agent work for #{issue_context(refreshed_issue)} condition_key=#{request.condition_key} reason=#{inspect(request.reason)}")
    :ok
  end

  defp finish_successful_turn(context, continuation, infrastructure_failure, _wait_request) do
    continue_successful_turn(context, continuation, infrastructure_failure)
  end

  defp continue_successful_turn(_context, {:continue, _refreshed_issue}, failure)
       when not is_nil(failure),
       do: {:error, failure}

  defp continue_successful_turn(
         %{turn_number: turn_number, max_turns: max_turns} = context,
         {:continue, refreshed_issue},
         nil
       )
       when turn_number < max_turns do
    Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

    do_run_codex_turns(
      context.backend,
      context.app_session,
      context.workspace,
      refreshed_issue,
      context.recipient,
      context.opts
      |> Keyword.put(:handoff_gate_prompt, context.handoff_gate_prompt)
      |> Keyword.put(:prompt_composition_state, context.prompt_state),
      context.issue_state_fetcher,
      {turn_number + 1, max_turns}
    )
  end

  defp continue_successful_turn(
         %{handoff_gate_prompt: prompt} = context,
         {:continue, refreshed_issue},
         nil
       )
       when is_binary(prompt) do
    continue_terminal_gate_remediation(%{
      backend: context.backend,
      app_session: context.app_session,
      workspace: context.workspace,
      issue: refreshed_issue,
      recipient: context.recipient,
      opts: context.opts,
      prompt: prompt,
      prompt_state: context.prompt_state,
      issue_state_fetcher: context.issue_state_fetcher,
      turn_number: context.turn_number,
      max_turns: context.max_turns
    })
  end

  defp continue_successful_turn(context, {:continue, refreshed_issue}, nil) do
    finish_max_turns(refreshed_issue, context.turn_number, context.max_turns)
  end

  defp continue_successful_turn(_context, {:done, _refreshed_issue}, _failure), do: :ok
  defp continue_successful_turn(_context, {:error, reason}, _failure), do: {:error, reason}

  defp finish_max_turns(issue, turn_number, max_turns) do
    Logger.info(
      "Reached agent.max_turns for #{issue_context(issue)} with issue still active; ending this worker session for orchestrator continuation without changing tracker state turn=#{turn_number}/#{max_turns}"
    )

    :ok
  end

  defp continue_terminal_gate_remediation(context) do
    if Keyword.get(context.opts, :handoff_gate_grace_turn_used, false) do
      finish_max_turns(context.issue, context.turn_number, context.max_turns)
    else
      Logger.info("Continuing agent run for one terminal-gate remediation turn #{issue_context(context.issue)} after reaching agent.max_turns=#{context.max_turns}")

      do_run_codex_turns(
        context.backend,
        context.app_session,
        context.workspace,
        context.issue,
        context.recipient,
        context.opts
        |> Keyword.put(:handoff_gate_prompt, context.prompt)
        |> Keyword.put(:handoff_gate_grace_turn_used, true)
        |> Keyword.put(:prompt_composition_state, context.prompt_state),
        context.issue_state_fetcher,
        {context.turn_number + 1, context.max_turns}
      )
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns) do
    handoff_guidance = handoff_tool_guidance(issue, opts)
    handoff_gate_prompt = Keyword.get(opts, :handoff_gate_prompt)

    sections =
      TaskContextPrompt.sections(issue, Keyword.get(opts, :session_start_result)) ++
        [
          PromptBuilder.build_section(issue, opts),
          TestWorkerBudget.prompt_section(),
          prompt_section(
            "waiting.resume_event",
            :wait_resume,
            "symphony:wait_watcher",
            "wait-resume/v1",
            Keyword.get(opts, :wait_resume_prompt),
            false
          ),
          prompt_section(
            "review.open_findings",
            :open_findings,
            "symphony:latest_handoff_gate",
            "review-findings/v1",
            handoff_gate_prompt,
            false
          ),
          prompt_section(
            "symphony.handoff_constraints",
            :handoff_constraints,
            "symphony:agent_runner",
            "handoff/v1",
            handoff_guidance,
            true
          )
        ]

    canonical_fragments =
      TaskContextPrompt.canonical_fragments(issue) ++
        canonical_handoff_fragments(handoff_guidance)

    composition = PromptComposer.compose(sections, canonical_fragments: canonical_fragments)
    %{composition | state: TaskContextPrompt.put_activity_cursor(composition.state, issue)}
  end

  defp build_turn_prompt(issue, opts, turn_number, max_turns) do
    handoff_gate_prompt = Keyword.get(opts, :handoff_gate_prompt)
    efficiency_strategy = Keyword.get(opts, :efficiency_strategy_prompt)
    prior_state = Keyword.get(opts, :prompt_composition_state, %{})

    current_sections =
      issue
      |> TaskContextPrompt.sections(nil)
      |> Enum.filter(&(&1.id in ["task.current_metadata", "task.activity"]))

    {reused, changed_current} = PromptComposer.reused_sections(prior_state, current_sections)

    changed_for_prompt =
      Enum.map(changed_current, fn
        %{id: "task.activity"} = full_activity ->
          TaskContextPrompt.activity_delta_section(issue, prior_state) || full_activity

        section ->
          section
      end)

    static_reused = reusable_static_sections(prior_state)

    sections = [
      prompt_section(
        "review.open_findings",
        :open_findings,
        "symphony:latest_handoff_gate",
        "review-findings/v1",
        handoff_gate_prompt,
        false
      ),
      prompt_section(
        "efficiency.current_strategy",
        :efficiency_strategy,
        "symphony:agent_budget",
        "efficiency-strategy/v1",
        efficiency_strategy,
        false
      ),
      prompt_section(
        "continuation.resume_capsule",
        :continuation_capsule,
        "symphony:agent_runner",
        "resume-capsule/v1",
        continuation_capsule(static_reused, reused, changed_for_prompt, turn_number, max_turns),
        false
      )
      | changed_for_prompt
    ]

    composition = PromptComposer.compose(sections)
    current_state = PromptComposer.compose(current_sections).state

    reuse_decisions =
      Enum.map(static_reused ++ reused, fn identity ->
        %{
          section_id: identity.id,
          decision: "reused",
          reason: "unchanged_section_already_in_live_thread",
          hash: identity.hash,
          suppressed_bytes: identity.bytes
        }
      end)

    %{
      composition
      | decisions: composition.decisions ++ reuse_decisions,
        suppressed_bytes: composition.suppressed_bytes + Enum.sum(Enum.map(static_reused ++ reused, & &1.bytes)),
        state:
          prior_state
          |> Map.merge(composition.state)
          |> Map.merge(current_state)
          |> TaskContextPrompt.put_activity_cursor(issue)
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
    prompt_kind = if turn_number == 1, do: "initial", else: "continuation"
    included_sections = legacy_included_sections(prompt_metadata.included_sections, prompt_kind)
    prompt_chars = String.length(prompt)
    prompt_bytes = byte_size(prompt)

    measurements = %{
      count: 1,
      prompt_bytes: prompt_bytes,
      prompt_chars: prompt_chars,
      prompt_tokens_estimate: PromptSection.estimated_tokens(prompt_bytes),
      suppressed_prompt_bytes: prompt_metadata.suppressed_bytes
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
      prompt_sections: prompt_metadata.sections,
      prompt_section_decisions: prompt_metadata.decisions,
      prompt_section_diagnostics: prompt_metadata.diagnostics,
      prompt_sha256: :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower)
    }

    :telemetry.execute(@prompt_built_telemetry_event, measurements, metadata)
    Telemetry.emit(:prompt_built, Map.merge(metadata, measurements))

    maybe_log_prompt_debug(prompt_metadata, opts)

    Logger.info(
      "agent.prompt_built #{issue_context(issue)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)} " <>
        "attempt=#{inspect(metadata.attempt)} turn=#{turn_number}/#{max_turns} prompt_kind=#{prompt_kind} " <>
        "prompt_chars=#{prompt_chars} prompt_bytes=#{prompt_bytes} included_sections=#{Enum.join(included_sections, ",")}"
    )
  end

  defp dynamic_tool_executor(issue, workspace, worker_host, lifecycle_recipient, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)
    per_repo_before_handoff = Keyword.get(opts, :per_repo_before_handoff)
    per_repo_before_handoff_timeout_ms = Keyword.get(opts, :per_repo_before_handoff_timeout_ms)
    per_repo_before_handoff_stale_ms = Keyword.get(opts, :per_repo_before_handoff_stale_ms)
    per_repo_review_workflow = Keyword.get(opts, :per_repo_review_workflow)
    efficiency_decision = Keyword.get(opts, :efficiency_decision)

    review_opts =
      []
      |> maybe_put(:efficiency_decision, efficiency_decision)
      |> maybe_put(:requested_lenses, AgentEfficiency.review_lenses(efficiency_decision))
      |> maybe_put(:base_drift_ref, Keyword.get(opts, :base_drift_ref))

    handoff_context =
      %{issue: issue, workspace: workspace, worker_host: worker_host}
      |> maybe_put_map(:before_handoff_command, per_repo_before_handoff)
      |> maybe_put_map(:before_handoff_timeout_ms, per_repo_before_handoff_timeout_ms)
      |> maybe_put_map(:before_handoff_stale_ms, per_repo_before_handoff_stale_ms)
      |> Map.put(:deferred_handoff_gate_callback, &store_deferred_handoff_gate/1)
      |> Map.put(:handoff_infrastructure_failure_callback, &store_handoff_infrastructure_failure/2)
      |> Map.put(
        :handoff_gate_lifecycle_callback,
        handoff_gate_lifecycle_callback(lifecycle_recipient, issue)
      )
      |> maybe_put_map(:review_workflow, per_repo_review_workflow)
      |> maybe_put_map(:deferred_review_callback, deferred_review_callback(per_repo_review_workflow))
      |> maybe_put_map(:review_opts, review_opts)

    wait_context = %{
      issue: issue,
      workspace: workspace,
      worker_host: worker_host,
      repository_scope: Keyword.get(opts, :repository_id)
    }

    fn tool, arguments ->
      dynamic_tool_opts =
        [
          linear_client: linear_client,
          handoff_gate_context: handoff_context,
          wait_context: wait_context,
          wait_callback: &store_agent_wait_request/1
        ]
        |> maybe_put(:wait_observer, Keyword.get(opts, :wait_observer))

      result =
        DynamicTool.execute(tool, arguments, dynamic_tool_opts)

      maybe_store_handoff_gate_prompt(result)
      result
    end
  end

  defp maybe_put_map(map, _key, nil), do: map
  defp maybe_put_map(map, key, value), do: Map.put(map, key, value)

  defp handoff_gate_lifecycle_callback(recipient, issue) do
    fn
      :started, %{gate_job_id: gate_job_id, gate: gate} ->
        transition_agent_lifecycle(recipient, issue, :handoff_pending_gate, %{
          gate_job_id: gate_job_id,
          gate: gate
        })

      :finished, %{gate_job_id: gate_job_id, outcome: outcome} ->
        transition_agent_lifecycle(recipient, issue, :implementing, %{
          gate_job_id: gate_job_id,
          gate_outcome: outcome
        })
    end
  end

  defp deferred_review_callback(nil), do: nil
  defp deferred_review_callback(_review_workflow), do: &store_deferred_review_handoff/1

  defp store_deferred_handoff_gate(request) when is_map(request) do
    existing = Process.get(@deferred_handoff_gate_key)

    if same_pending_candidate?(existing, request) do
      :already_pending
    else
      with :ok <- persist_deferred_handoff_gate(request) do
        Process.put(@deferred_handoff_gate_key, request)
        :ok
      end
    end
  end

  defp same_pending_candidate?(%{gate: %{candidate_hash: candidate_hash, job_id: job_id}}, %{
         gate: %{candidate_hash: candidate_hash, job_id: job_id}
       }),
       do: true

  defp same_pending_candidate?(_existing, _request), do: false

  defp store_handoff_infrastructure_failure(prompt, gate) when is_binary(prompt) do
    Process.put(
      @handoff_gate_infrastructure_failure_key,
      {:handoff_gate_infrastructure, %{message: prompt, gate: gate}}
    )

    :ok
  end

  defp store_review_infrastructure_failure(%ReviewOutcome{} = outcome) do
    Process.put(
      @handoff_gate_infrastructure_failure_key,
      {:review_gate_infrastructure, %{review: ReviewOutcome.to_map(outcome)}}
    )

    :ok
  end

  defp pop_handoff_infrastructure_failure do
    Process.delete(@handoff_gate_infrastructure_failure_key)
  end

  defp store_agent_wait_request(request) when is_map(request) do
    Process.put(@agent_wait_request_key, request)
    :ok
  end

  defp pop_agent_wait_request do
    Process.delete(@agent_wait_request_key)
  end

  defp persist_deferred_handoff_gate(request) do
    Workspace.persist_handoff_gate_state(
      Map.fetch!(request, :workspace),
      durable_handoff_request(request),
      Map.get(request, :worker_host)
    )
  end

  defp durable_handoff_request(request) do
    gate = Map.fetch!(request, :gate)

    %{
      "query" => Map.fetch!(request, :query),
      "variables" => Map.get(request, :variables, %{}),
      "targetState" => Map.fetch!(request, :target_state),
      "gate" => %{
        "jobId" => gate.job_id,
        "status" => to_string(gate.status),
        "candidateHash" => gate.candidate_hash,
        "exactHash" => gate.exact_hash,
        "identity" => gate.identity,
        "heartbeatAt" => gate.heartbeat_at,
        "heartbeatAgeMs" => gate.heartbeat_age_ms,
        "nextPollMs" => gate.next_poll_ms,
        "progress" => gate.progress,
        "startedAt" => gate.started_at
      }
    }
  end

  defp pop_deferred_handoff_gate do
    Process.delete(@deferred_handoff_gate_key)
  end

  @doc false
  @spec store_deferred_handoff_gate_for_test(map()) ::
          :ok | :already_pending | {:error, term()}
  def store_deferred_handoff_gate_for_test(request) when is_map(request) do
    store_deferred_handoff_gate(request)
  end

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

  defp recover_pending_handoff_gate(
         workspace,
         issue,
         worker_host,
         recipient,
         backend,
         opts,
         issue_state_fetcher
       ) do
    if Keyword.get(opts, :issue_context_file) do
      do_recover_pending_handoff_gate(
        workspace,
        issue,
        worker_host,
        recipient,
        backend,
        opts,
        issue_state_fetcher
      )
    else
      :none
    end
  end

  defp do_recover_pending_handoff_gate(
         workspace,
         issue,
         worker_host,
         recipient,
         backend,
         opts,
         issue_state_fetcher
       ) do
    case Workspace.load_handoff_gate_state(workspace, worker_host) do
      {:ok, nil} ->
        :none

      {:ok, durable_request} ->
        case restore_handoff_request(durable_request, workspace, issue, worker_host, opts) do
          {:ok, request} ->
            Logger.info("handoff.gate recovering durable job #{issue_context(issue)} job_id=#{request.gate.job_id}")

            poll_pending_handoff_gate(
              request,
              recipient,
              backend,
              issue_state_fetcher,
              opts,
              false
            )

          {:error, reason} ->
            Workspace.clear_handoff_gate_state(workspace, worker_host)
            {:error, {:invalid_persisted_handoff_gate, reason}}
        end

      {:error, reason} ->
        {:error, {:handoff_gate_recovery_failed, reason}}
    end
  end

  defp restore_handoff_request(
         %{"query" => query, "targetState" => target_state, "gate" => durable_gate} = durable,
         workspace,
         issue,
         worker_host,
         opts
       )
       when is_binary(query) and is_binary(target_state) and is_map(durable_gate) do
    with {:ok, gate} <- restore_durable_gate(durable_gate) do
      linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

      review_opts =
        []
        |> maybe_put(:base_drift_ref, Keyword.get(opts, :base_drift_ref))

      {:ok,
       %{
         query: query,
         variables: Map.get(durable, "variables", %{}),
         workspace: workspace,
         issue: issue,
         worker_host: worker_host,
         target_state: target_state,
         gate: gate,
         before_handoff_command: Keyword.get(opts, :per_repo_before_handoff),
         before_handoff_timeout_ms: Keyword.get(opts, :per_repo_before_handoff_timeout_ms),
         before_handoff_stale_ms: Keyword.get(opts, :per_repo_before_handoff_stale_ms),
         review_workflow: Keyword.get(opts, :per_repo_review_workflow),
         review_opts: review_opts,
         linear_client: linear_client
       }}
    end
  end

  defp restore_handoff_request(_durable, _workspace, _issue, _worker_host, _opts),
    do: {:error, :invalid_request}

  defp restore_durable_gate(
         %{
           "jobId" => job_id,
           "candidateHash" => candidate_hash,
           "exactHash" => exact_hash,
           "identity" => identity
         } = gate
       )
       when is_binary(job_id) and is_binary(candidate_hash) and is_binary(exact_hash) and
              is_map(identity) do
    {:ok,
     %{
       protocol_version: 1,
       job_id: job_id,
       status: restore_gate_status(Map.get(gate, "status")),
       candidate_hash: candidate_hash,
       exact_hash: exact_hash,
       identity: identity,
       heartbeat_at: Map.get(gate, "heartbeatAt"),
       heartbeat_age_ms: Map.get(gate, "heartbeatAgeMs"),
       next_poll_ms: Map.get(gate, "nextPollMs") || 1_000,
       progress: Map.get(gate, "progress", %{}),
       started_at: Map.get(gate, "startedAt"),
       completed_at: nil,
       result_artifact: nil,
       checks: [],
       remediation: nil,
       summary: nil,
       single_flight: nil
     }}
  end

  defp restore_durable_gate(_gate), do: {:error, :invalid_gate}

  defp restore_gate_status("running"), do: :running
  defp restore_gate_status(_status), do: :pending

  defp maybe_run_deferred_handoff_gate(
         nil,
         handoff_gate_prompt,
         _recipient,
         _backend,
         _issue_state_fetcher,
         _opts
       ),
       do: handoff_gate_prompt

  defp maybe_run_deferred_handoff_gate(
         %{} = request,
         handoff_gate_prompt,
         recipient,
         backend,
         issue_state_fetcher,
         opts
       ) do
    case poll_pending_handoff_gate(request, recipient, backend, issue_state_fetcher, opts, true) do
      {:completed, _issue} ->
        handoff_gate_prompt

      {:resume, prompt, _issue} ->
        prompt

      {:error, reason} ->
        prompt = pending_gate_error_prompt(Map.fetch!(request, :issue), reason)
        store_handoff_infrastructure_failure(prompt, %{reason: reason})
        prompt
    end
  end

  defp poll_pending_handoff_gate(
         request,
         recipient,
         backend,
         issue_state_fetcher,
         opts,
         sleep_first?
       ) do
    issue = Map.fetch!(request, :issue)
    gate = Map.fetch!(request, :gate)
    transition_pending_gate(recipient, issue, gate)

    if sleep_first?, do: handoff_gate_sleep(gate.next_poll_ms, opts)

    case continue_with_issue?(issue, issue_state_fetcher, opts) do
      {:continue, refreshed_issue} ->
        request = Map.put(request, :issue, refreshed_issue)
        poll_current_handoff_gate(request, recipient, backend, issue_state_fetcher, opts)

      {:done, refreshed_issue} ->
        case finish_pending_gate(request, recipient, :issue_no_longer_active) do
          :ok -> {:completed, refreshed_issue}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        case finish_pending_gate(request, recipient, :issue_refresh_failed) do
          :ok -> {:error, reason}
          {:error, clear_reason} -> {:error, {reason, clear_reason}}
        end
    end
  end

  defp poll_current_handoff_gate(request, recipient, backend, issue_state_fetcher, opts) do
    issue = Map.fetch!(request, :issue)
    gate = Map.fetch!(request, :gate)
    poller = Keyword.get(opts, :handoff_gate_poller, &HandoffGate.poll_before_handoff/6)

    poll_opts =
      [expected_candidate_hash: gate.candidate_hash]
      |> maybe_put(:hook_command, Map.get(request, :before_handoff_command))
      |> maybe_put(:timeout_ms, Map.get(request, :before_handoff_timeout_ms))
      |> maybe_put(:stale_ms, Map.get(request, :before_handoff_stale_ms))

    result =
      poller.(
        request.workspace,
        issue,
        request.worker_host,
        request.target_state,
        gate.job_id,
        poll_opts
      )

    handle_pending_gate_poll(result, request, recipient, backend, issue_state_fetcher, opts)
  end

  defp handle_pending_gate_poll(
         {:pending, next_gate},
         request,
         recipient,
         backend,
         issue_state_fetcher,
         opts
       ) do
    request = Map.put(request, :gate, next_gate)

    case persist_deferred_handoff_gate(request) do
      :ok ->
        poll_pending_handoff_gate(request, recipient, backend, issue_state_fetcher, opts, true)

      {:error, reason} ->
        prompt = pending_gate_error_prompt(request.issue, reason)
        store_handoff_infrastructure_failure(prompt, %{reason: reason})

        case finish_pending_gate(request, recipient, :persistence_failed) do
          :ok -> {:resume, prompt, request.issue}
          {:error, clear_reason} -> {:error, {reason, clear_reason}}
        end
    end
  end

  defp handle_pending_gate_poll({:passed, gate}, request, recipient, backend, _fetcher, _opts) do
    request = Map.put(request, :gate, gate)

    case finish_pending_gate(request, recipient, :passed) do
      :ok -> apply_passed_handoff_gate(request, recipient, backend)
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_pending_gate_poll({:failed, prompt, gate}, request, recipient, _backend, _fetcher, _opts) do
    resume_after_terminal_gate(request, gate, prompt, recipient, :failed)
  end

  defp handle_pending_gate_poll(
         {:invalidated, prompt, gate},
         request,
         recipient,
         _backend,
         _fetcher,
         _opts
       ) do
    resume_after_terminal_gate(request, gate, prompt, recipient, :invalidated)
  end

  defp handle_pending_gate_poll(
         {:infrastructure_error, prompt, gate},
         request,
         recipient,
         _backend,
         _fetcher,
         _opts
       ) do
    terminal_gate = if is_map(gate) and Map.has_key?(gate, :job_id), do: gate, else: request.gate
    store_handoff_infrastructure_failure(prompt, gate)
    resume_after_terminal_gate(request, terminal_gate, prompt, recipient, :infrastructure_error)
  end

  defp handle_pending_gate_poll({:blocked, prompt, _gates}, request, recipient, _backend, _fetcher, _opts) do
    case finish_pending_gate(request, recipient, :legacy_failure) do
      :ok -> {:resume, prompt, request.issue}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_pending_gate_poll(:ok, request, recipient, backend, _fetcher, _opts) do
    case finish_pending_gate(request, recipient, :legacy_passed) do
      :ok -> apply_passed_handoff_gate(request, recipient, backend)
      {:error, reason} -> {:error, reason}
    end
  end

  defp resume_after_terminal_gate(request, gate, prompt, recipient, outcome) do
    request = Map.put(request, :gate, gate)

    case finish_pending_gate(request, recipient, outcome) do
      :ok -> {:resume, prompt, request.issue}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_passed_handoff_gate(request, recipient, backend) do
    case Map.get(request, :review_workflow) do
      review_workflow when is_map(review_workflow) ->
        review_request = Map.put(request, :review_workflow, review_workflow)

        case maybe_run_deferred_review_handoff(review_request, nil, recipient, backend) do
          nil -> {:completed, request.issue}
          prompt -> {:resume, prompt, request.issue}
        end

      _ ->
        case apply_deferred_review_handoff(request) do
          nil -> {:completed, request.issue}
          prompt -> {:resume, prompt, request.issue}
        end
    end
  end

  defp transition_pending_gate(recipient, issue, gate) do
    :ok =
      transition_agent_lifecycle(recipient, issue, :handoff_pending_gate, %{
        gate_job_id: gate.job_id,
        gate: handoff_gate_lifecycle_payload(gate)
      })
  end

  defp finish_pending_gate(request, recipient, outcome) do
    gate = request.gate

    with :ok <- Workspace.clear_handoff_gate_state(request.workspace, request.worker_host) do
      transition_agent_lifecycle(recipient, request.issue, :implementing, %{
        gate_job_id: gate.job_id,
        gate_outcome: outcome
      })
    end
  end

  defp handoff_gate_lifecycle_payload(gate) do
    %{
      job_id: gate.job_id,
      status: gate.status,
      candidate_hash: gate.candidate_hash,
      exact_hash: gate.exact_hash,
      identity: gate.identity,
      heartbeat_at: gate.heartbeat_at,
      heartbeat_age_ms: gate.heartbeat_age_ms,
      next_poll_ms: gate.next_poll_ms,
      progress: gate.progress,
      started_at: gate.started_at
    }
  end

  defp handoff_gate_sleep(next_poll_ms, opts) do
    sleep = Keyword.get(opts, :handoff_gate_sleep, &Process.sleep/1)
    sleep.(max(next_poll_ms || 1_000, 1))
  end

  defp pending_gate_error_prompt(issue, reason) do
    """
    System message:

    Symphony stopped polling the asynchronous before_handoff gate for #{issue.identifier} because its state could not be verified.

    Reason: `#{inspect(reason)}`

    The Linear handoff was not applied. Restore gate availability and retry once for the current candidate.
    """
    |> String.trim()
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

        {:infrastructure_unavailable, %ReviewOutcome{} = review_outcome} ->
          Logger.warning("review.gate deferred withheld #{issue_context(issue)} outcome=infrastructure_unavailable reason=#{inspect(review_outcome.failure_reason)}")
          store_review_infrastructure_failure(review_outcome)

          {:infrastructure_unavailable, review_nonapproval_prompt(issue, review_outcome), review_outcome}

        {terminal_outcome, %ReviewOutcome{} = review_outcome}
        when terminal_outcome in [:automation_inconclusive, :budget_exhausted_with_findings] ->
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
    review_opts =
      request
      |> Map.get(:review_opts, [])
      |> put_handoff_gate_attestations(Map.get(request, :gate), Map.get(request, :worker_host))

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

  defp put_handoff_gate_attestations(review_opts, gate, worker_host) do
    case ReviewPacket.handoff_gate_attestations(gate, worker_host) do
      [] -> review_opts
      attestations -> Keyword.update(review_opts, :handoff_gate_attestations, attestations, &(&1 ++ attestations))
    end
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

  defp prompt_section(id, type, source, version, content, reusable) do
    PromptSection.new(
      id: id,
      type: type,
      source: source,
      version: version,
      content: if(is_binary(content), do: content, else: ""),
      reusable: reusable,
      ownership: :symphony
    )
  end

  defp canonical_handoff_fragments(handoff_guidance) when is_binary(handoff_guidance) do
    case String.trim(handoff_guidance) do
      "" ->
        []

      content ->
        [
          %{
            id: "symphony.handoff_constraints",
            content: content,
            authoritative_section_id: "symphony.handoff_constraints",
            source_section_ids: ["repository.workflow"],
            allow_format_equivalent: true
          }
        ]
    end
  end

  defp continuation_capsule(static_reused, current_reused, changed_current, turn_number, max_turns) do
    static_references =
      static_reused
      |> Enum.map_join("\n", fn identity ->
        "- `#{identity.id}` `#{identity.version}` `#{identity.hash}`"
      end)

    current_status = [
      current_section_status(
        "Current candidate metadata",
        "task.current_metadata",
        current_reused,
        changed_current
      ),
      current_section_status("Current Linear activity", "task.activity", current_reused, changed_current)
    ]

    """
    Continuation guidance:

    This bounded resume capsule is for continuation turn ##{turn_number} of #{max_turns}. Resume from the current workspace and workpad instead of restarting. Focus on remaining ticket work and current unresolved findings.

    #{Enum.join(current_status, "\n")}

    Unchanged static context already present in this live thread (section, version, hash):
    #{if(static_references == "", do: "- No reusable section manifest was available; preserve the existing thread context.", else: static_references)}
    """
    |> String.trim()
  end

  defp current_section_status(label, id, reused, changed) do
    cond do
      Enum.any?(changed, &(&1.id == id)) ->
        "- #{label} changed and is included as section `#{id}` below."

      Enum.any?(reused, &(&1.id == id)) ->
        "- #{label} is unchanged and is reused by version/hash."

      true ->
        "- #{label} was unavailable; preserve the existing live-thread context."
    end
  end

  defp reusable_static_sections(prior_state) do
    prior_state
    |> Map.values()
    |> Enum.filter(fn
      %{reusable: true, id: id} ->
        id in [
          "task.issue",
          "task.startup_artifacts",
          "repository.workflow",
          "symphony.test_worker_budget",
          "symphony.handoff_constraints"
        ]

      _non_section_state ->
        false
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp legacy_included_sections(section_ids, prompt_kind) do
    section_ids
    |> Enum.map(fn
      "task.current_metadata" when prompt_kind == "continuation" -> nil
      "task." <> _rest -> "task_context"
      "repository.workflow" -> "repository_workflow"
      "symphony.test_worker_budget" -> "test_worker_budget"
      "symphony.handoff_constraints" -> "handoff_tool_guidance"
      "review.open_findings" -> "handoff_gate_remediation"
      "efficiency.current_strategy" -> "efficiency_strategy"
      "continuation.resume_capsule" -> "continuation_guidance"
      "waiting.resume_event" -> "wait_resume_event"
      id -> id
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp maybe_log_prompt_debug(composition, opts) do
    observability = Telemetry.observability()
    enabled? = Keyword.get(opts, :prompt_debug, Map.get(observability, :prompt_debug, false))

    if enabled? do
      Logger.debug(fn ->
        "agent.prompt_debug\n" <>
          PromptComposer.debug_render(composition,
            redact_fields: observability.redact_fields,
            max_bytes:
              Keyword.get(
                opts,
                :prompt_debug_max_bytes,
                Map.get(observability, :prompt_debug_max_bytes, 32_000)
              )
          )
      end)
    end

    :ok
  end

  defp handoff_tool_guidance(issue, opts) do
    identity_guidance = automation_identity_guidance(issue, opts)

    waiting_guidance = """
    Symphony waiting requirement:

    - If useful work cannot continue until an external GitHub, git, or Linear condition changes, call Symphony's `wait_for` tool once and end the turn.
    - Do not spend agent turns repeatedly polling an unchanged external condition. Symphony will persist the wait, free the agent slot, and resume this issue after the condition changes.
    - Never call `wait_for` because of local CPU or memory pressure, another validation running, local process or port contention, or a desired time delay. Continue useful work and run repository validations with the configured per-run worker limit; Symphony intentionally permits validations from multiple agents to overlap.
    """

    handoff_guidance =
      if Keyword.has_key?(opts, :per_repo_before_handoff) or Keyword.has_key?(opts, :per_repo_review_workflow) do
        """
        Symphony handoff requirement:

        - To move this issue from In Progress to In Review or Human Review, use Symphony's `linear_graphql` tool for the Linear `issueUpdate` mutation.
        - If that tool returns gate remediation, keep the issue In Progress and address the reported gate failures.
        - Do not use the native Linear MCP `save_issue` tool for that handoff; it cannot run Symphony's before_handoff and automated review gates.
        """
      else
        ""
      end

    [identity_guidance, waiting_guidance, handoff_guidance]
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp automation_identity_guidance(%Issue{labels: labels}, opts) when is_list(labels) do
    opt_in_label = Keyword.get(opts, :automation_opt_in_label)

    if issue_has_label?(labels, opt_in_label) do
      """
      Symphony automation identity authorization:

      - This issue carries Symphony's configured opt-in label `#{opt_in_label}`. That label is explicit authorization for this unattended run to use the bot or GitHub App identity installed by trusted host and repository startup hooks for git and GitHub work.
      - Verify the injected identity before publishing. If hook-provided bot mode is active (for example `UDP_BOT_MODE=1`) and `gh auth status` identifies the expected bot, that is both authentication and authorization. Do not require a second human comment, restore a personal `gh` login, or block solely because work will be attributed to the bot.
      - If an older workpad or `needs-human-input` label says the verified bot identity still needs separate attribution authorization, treat that claim as stale: correct the workpad, remove `needs-human-input` when it represented only that claim, and continue.
      - Authentication remains a valid blocker only when the injected identity is absent, invalid, or lacks a required permission after available in-session recovery has been attempted.
      """
      |> String.trim()
    else
      ""
    end
  end

  defp automation_identity_guidance(_issue, _opts), do: ""

  defp issue_has_label?(_labels, label) when not is_binary(label), do: false

  defp issue_has_label?(labels, label) do
    normalized_label = String.downcase(String.trim(label))

    normalized_label != "" and
      Enum.any?(labels, &(is_binary(&1) and String.downcase(String.trim(&1)) == normalized_label))
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher, opts)
       when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        case refresh_issue_activity(issue, refreshed_issue, opts) do
          {:ok, refreshed_issue} ->
            classify_refreshed_issue(issue, refreshed_issue)

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher, _opts), do: {:done, issue}

  defp refresh_issue_activity(previous_issue, refreshed_issue, opts) do
    cond do
      not active_issue_state?(refreshed_issue.state) ->
        {:ok, preserve_issue_comments(previous_issue, refreshed_issue)}

      Keyword.has_key?(opts, :issue_comments_fetcher) ->
        attach_issue_comments(refreshed_issue, opts)

      true ->
        {:ok, preserve_issue_comments(previous_issue, refreshed_issue)}
    end
  end

  defp classify_refreshed_issue(issue, refreshed_issue) do
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
  end

  defp preserve_issue_comments(%Issue{} = previous_issue, %Issue{} = refreshed_issue) do
    {comments, truncated?} =
      if refreshed_issue.comments != [] or refreshed_issue.comments_truncated do
        {refreshed_issue.comments, refreshed_issue.comments_truncated}
      else
        {previous_issue.comments, previous_issue.comments_truncated}
      end

    %{
      refreshed_issue
      | comments: comments,
        comments_truncated: truncated?
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
  Mark an issue Blocked when retry policy identifies a terminal failure that
  requires human action. Idempotent: skips work
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
