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
    Cardinality,
    Config,
    Experiment,
    Github.PrReviewSection,
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
    ResumePacket,
    ReviewGate,
    ReviewOutcome,
    ReviewPacket,
    Router,
    RunManifest,
    SessionStartHook,
    TaskContextPrompt,
    TaskOutcome,
    Telemetry,
    TestWorkerBudget,
    Tracker,
    Workspace
  }

  @type worker_host :: String.t() | nil
  @prompt_built_telemetry_event [:symphony_elixir, :agent, :prompt_built]
  @handoff_gate_prompt_key {__MODULE__, :handoff_gate_prompt}
  @handoff_gate_infrastructure_failure_key {__MODULE__, :handoff_gate_infrastructure_failure}
  @handoff_gate_lifecycle_key {__MODULE__, :handoff_gate_lifecycle}
  @deferred_handoff_gate_key {__MODULE__, :deferred_handoff_gate}
  @deferred_review_handoff_key {__MODULE__, :deferred_review_handoff}
  @agent_wait_request_key {__MODULE__, :agent_wait_request}
  @resume_packet_verification_key {__MODULE__, :resume_packet_verification}
  @handoff_issue_refresh_retry_base_ms 1_000
  @handoff_issue_refresh_retry_max_ms 30_000
  @no_progress_omission_codes ~w(
    assessment_failed invalid_signal normalization_failed pending_evicted signal_evicted
    start_missing_correlation start_missing_operation start_without_terminal
    terminal_missing_operation terminal_unmatched
  )

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
    identity = RunManifest.execution_identity(Keyword.get(opts, :attempt), opts)
    opts = Keyword.merge(opts, Map.to_list(Map.delete(identity, :attempt)))

    Telemetry.with_context(identity, fn ->
      do_run(issue, codex_update_recipient, opts)
    end)
  end

  defp do_run(issue, codex_update_recipient, opts) do
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
          |> Keyword.put(:workflow_source, workflow_source(routed_repo))
          |> maybe_put(:review_workflow_source, review_workflow_source(routed_repo, review_workflow))
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
          repository_manifest = collect_repository_manifest(workspace, issue, worker_host, opts)

          send_scheduling_runtime_info(
            codex_update_recipient,
            issue,
            repository_manifest,
            opts
          )

          run_agent_with_progress_tracking(%{
            workspace: workspace,
            issue: issue,
            recipient: codex_update_recipient,
            opts: Keyword.put(opts, :repository_manifest, repository_manifest),
            worker_host: worker_host
          })
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

  defp workflow_source(%{workflow_path: path}) when is_binary(path), do: "repository:#{path}"
  defp workflow_source(_routed_repo), do: "repository:#{SymphonyElixir.Workflow.workflow_file_path()}"

  defp review_workflow_source(_routed_repo, nil), do: nil

  defp review_workflow_source(routed_repo, _workflow),
    do: "repository:#{review_workflow_path(routed_repo)}"

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

  defp send_scheduling_runtime_info(recipient, %Issue{id: issue_id}, manifest, opts)
       when is_pid(recipient) and is_binary(issue_id) and is_map(manifest) do
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

  defp send_scheduling_runtime_info(_recipient, _issue, _manifest, _opts), do: :ok

  defp collect_repository_manifest(workspace, issue, worker_host, opts) do
    manifest_opts =
      [worker_host: worker_host]
      |> maybe_put(:git_runner, Keyword.get(opts, :repository_git_runner))

    collector = Keyword.get(opts, :repository_manifest_collector, &BaseDrift.manifest/3)

    manifest =
      case collector.(workspace, Keyword.get(opts, :base_drift_ref), manifest_opts) do
        manifest when is_map(manifest) -> manifest
        _invalid -> repository_collection_failure_manifest()
      end

    Enum.each(repository_manifest_errors(manifest), fn code ->
      resume_packet_failure(issue, workspace, worker_host, code, :repository_probe_unavailable)
    end)

    manifest
  rescue
    error ->
      resume_packet_failure(issue, workspace, worker_host, "repository.collection_failed", error.__struct__)
      repository_collection_failure_manifest()
  catch
    kind, _reason ->
      resume_packet_failure(issue, workspace, worker_host, "repository.collection_failed", kind)
      repository_collection_failure_manifest()
  end

  defp run_agent_with_progress_tracking(context) do
    run_codex_turns(
      context.workspace,
      context.issue,
      context.recipient,
      context.opts,
      context.worker_host
    )
  end

  defp maybe_emit_material_progress(issue, opts, before, after_run) do
    if repository_progress?(before, after_run) do
      TaskOutcome.emit(:material_progress, :recorded, %{
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        parent_issue_id: issue.parent_id,
        repository: Keyword.get(opts, :repository_id) || repository_from_labels(issue.labels),
        before_sha: Map.get(before, :head_sha),
        after_sha: Map.get(after_run, :head_sha),
        before_worktree_fingerprint: Map.get(before, :worktree_fingerprint),
        after_worktree_fingerprint: Map.get(after_run, :worktree_fingerprint),
        before_worktree_status_fingerprint: Map.get(before, :worktree_status_fingerprint),
        after_worktree_status_fingerprint: Map.get(after_run, :worktree_status_fingerprint),
        before_worktree_content_fingerprint: Map.get(before, :worktree_content_fingerprint),
        after_worktree_content_fingerprint: Map.get(after_run, :worktree_content_fingerprint),
        workspace_dirty: Map.get(after_run, :dirty)
      })
    end
  end

  defp repository_progress?(before, after_run) do
    before_head = Map.get(before, :head_sha)
    after_head = Map.get(after_run, :head_sha)
    before_status = Map.get(before, :worktree_status_fingerprint)
    after_status = Map.get(after_run, :worktree_status_fingerprint)
    before_content = Map.get(before, :worktree_content_fingerprint)
    after_content = Map.get(after_run, :worktree_content_fingerprint)

    (is_binary(before_head) and is_binary(after_head) and before_head != after_head) or
      (is_binary(before_status) and is_binary(after_status) and before_status != after_status) or
      (is_binary(before_content) and is_binary(after_content) and before_content != after_content)
  end

  defp refresh_scheduling_runtime_info(recipient, issue, worker_host, workspace, opts) do
    manifest = collect_repository_manifest(workspace, issue, worker_host, opts)
    send_scheduling_runtime_info(recipient, issue, manifest, opts)
    manifest
  end

  defp prepare_experiment_turn(opts, issue, workspace, worker_host) do
    case Keyword.get(opts, :experiment_assignment) do
      assignment when is_map(assignment) ->
        decision =
          Experiment.turn(assignment, %{
            mode: safe_experiment_mode(opts),
            run_id: Map.get(Telemetry.current_context(), :run_id)
          })

        updated_opts =
          opts
          |> Keyword.put(:experiment_assignment, decision.assignment)
          |> Keyword.put(
            :experiment_suspension_pending,
            Keyword.get(opts, :experiment_suspension_pending, false) or decision.emit_suspension
          )

        {decision, [], updated_opts}

      _no_assignment ->
        {nil, [], opts}
    end
  rescue
    _error ->
      experiment_failure(issue, workspace, worker_host, "experiment.decision_failed")
      {nil, ["experiment.decision_failed"], opts}
  end

  defp prepare_turn_resume_packet(workspace, issue, recipient, worker_host, opts, turn_number, max_turns) do
    {previous, load_errors} = resume_packet_fallback(workspace, worker_host, opts, issue)

    {experiment_decision, experiment_errors, opts} =
      prepare_experiment_turn(opts, issue, workspace, worker_host)

    {budget_snapshot, budget_errors} =
      opts
      |> Keyword.get(:budget_collector)
      |> safe_budget_snapshot(issue, workspace, worker_host, opts)

    budget =
      budget_snapshot
      |> with_budget_thresholds(opts)

    warning_state = turn_no_progress_state(opts, previous)

    {restore_errors, opts} =
      maybe_restore_no_progress_latches(
        Keyword.get(opts, :budget_collector),
        warning_state,
        workspace,
        issue,
        worker_host,
        opts
      )

    errors =
      load_errors ++
        List.wrap(Keyword.get(opts, :resume_packet_errors)) ++
        repository_manifest_errors(Keyword.get(opts, :repository_manifest)) ++
        budget_errors ++ restore_errors ++ experiment_errors

    packet =
      ResumePacket.build(%{
        previous_packet: previous,
        issue: issue,
        identity: Telemetry.current_context(),
        turn_number: turn_number,
        max_turns: max_turns,
        repository: turn_repository_for_packet(opts, turn_number),
        verification: current_resume_verification(opts),
        budget: budget,
        no_progress_warnings: warning_state,
        experiment_assignment: Keyword.get(opts, :experiment_assignment),
        errors: errors,
        boundary_reason: :turn_start
      })

    persist_errors = persist_and_emit_resume_packet(workspace, issue, recipient, worker_host, packet)

    opts =
      opts
      |> Keyword.put(:resume_packet, packet)
      |> Keyword.put(:resume_packet_load_errors, [])
      |> Keyword.put(:no_progress_warnings, warning_state.items)
      |> Keyword.put(:experiment_turn_decision, experiment_decision)
      |> Keyword.put(:resume_packet_errors, persist_errors)

    {packet, opts}
  end

  defp refresh_after_turn(
         workspace,
         issue,
         recipient,
         worker_host,
         opts,
         budget,
         {turn_number, max_turns},
         boundary
       ) do
    before = Keyword.get(opts, :repository_manifest, %{})
    after_turn = refresh_scheduling_runtime_info(recipient, issue, worker_host, workspace, opts)
    maybe_emit_material_progress(issue, opts, before, after_turn)

    captured_at = DateTime.utc_now()
    previous_packet = Keyword.get(opts, :resume_packet)
    current_warning_state = ResumePacket.no_progress_state(previous_packet)

    errors =
      List.wrap(Keyword.get(opts, :resume_packet_errors)) ++
        repository_manifest_errors(after_turn)

    packet_context = %{
      previous_packet: previous_packet,
      issue: issue,
      identity: Telemetry.current_context(),
      turn_number: turn_number,
      max_turns: max_turns,
      repository: repository_for_packet(after_turn),
      verification: current_resume_verification(opts),
      budget: with_budget_thresholds(budget, opts),
      no_progress_warnings: current_warning_state,
      experiment_assignment: Keyword.get(opts, :experiment_assignment),
      errors: errors,
      boundary_reason: boundary
    }

    provisional_packet = ResumePacket.build(packet_context, now: captured_at)
    progress = ResumePacket.progress_evidence(previous_packet || %{}, provisional_packet)

    {assessment, assessment_errors} =
      assess_no_progress(
        Keyword.get(opts, :budget_collector),
        progress,
        issue,
        recipient,
        workspace,
        worker_host,
        opts
      )

    warning_state = next_no_progress_state(current_warning_state, assessment)

    packet =
      packet_context
      |> Map.put(:no_progress_warnings, warning_state)
      |> Map.update!(:errors, &(&1 ++ assessment_errors))
      |> ResumePacket.build(now: captured_at)

    persist_errors = persist_and_emit_resume_packet(workspace, issue, recipient, worker_host, packet)

    opts
    |> Keyword.put(:repository_manifest, after_turn)
    |> Keyword.put(:resume_packet, packet)
    |> Keyword.put(:no_progress_warnings, warning_state.items)
    |> Keyword.put(:resume_packet_errors, persist_errors)
  end

  defp turn_no_progress_state(opts, previous_packet) do
    previous = ResumePacket.no_progress_state(previous_packet)

    case Keyword.fetch(opts, :no_progress_warnings) do
      {:ok, items} -> %{previous | items: List.wrap(items)}
      :error -> previous
    end
  end

  defp maybe_restore_no_progress_latches(collector, state, workspace, issue, worker_host, opts) do
    if Keyword.get(opts, :no_progress_latches_restored, false),
      do: {[], opts},
      else: restore_no_progress_latches(collector, state, workspace, issue, worker_host, opts)
  end

  defp restore_no_progress_latches(collector, state, workspace, issue, worker_host, opts)
       when is_pid(collector) do
    restorer =
      Keyword.get(opts, :no_progress_latch_restorer, &AgentBudgetCollector.restore_no_progress_latches/2)

    :ok = restorer.(collector, state.latched_fingerprints)
    {[], Keyword.put(opts, :no_progress_latches_restored, true)}
  rescue
    _error -> no_progress_restore_failure(workspace, issue, worker_host, opts)
  catch
    _kind, _reason -> no_progress_restore_failure(workspace, issue, worker_host, opts)
  end

  defp restore_no_progress_latches(_collector, _state, workspace, issue, worker_host, opts),
    do: no_progress_restore_failure(workspace, issue, worker_host, opts)

  defp no_progress_restore_failure(workspace, issue, worker_host, opts) do
    resume_packet_failure(issue, workspace, worker_host, "no_progress.restore_failed", :collector_unavailable)
    {["no_progress.restore_failed"], opts}
  end

  defp assess_no_progress(collector, progress, issue, recipient, workspace, worker_host, opts)
       when is_pid(collector) do
    assessor = Keyword.get(opts, :no_progress_assessor, &AgentBudgetCollector.assess_no_progress/2)

    case assessor.(collector, progress) do
      %{decision: decision, progress: progress_state, summary: summary} = assessment
      when decision in [:none, :provisional, :alert, :suppressed_progress, :progress_unavailable, :reset] and
             progress_state in [:changed, :unchanged, :unavailable] and is_map(summary) ->
        send_no_progress_runtime_info(recipient, issue, summary)
        emit_no_progress_decision(issue, worker_host, progress, assessment)
        {assessment, []}

      _invalid ->
        no_progress_assessment_failure(issue, recipient, workspace, worker_host, progress)
    end
  rescue
    _error -> no_progress_assessment_failure(issue, recipient, workspace, worker_host, progress)
  catch
    _kind, _reason -> no_progress_assessment_failure(issue, recipient, workspace, worker_host, progress)
  end

  defp assess_no_progress(_collector, progress, issue, recipient, workspace, worker_host, _opts),
    do: no_progress_assessment_failure(issue, recipient, workspace, worker_host, progress)

  defp no_progress_assessment_failure(issue, recipient, workspace, worker_host, _progress) do
    assessment = %{
      version: 1,
      decision: :progress_unavailable,
      progress: :unavailable,
      warning: nil,
      checkpoint: nil,
      summary: %{
        version: 1,
        mode: "shadow",
        active_warning_count: 0,
        last_decision: :progress_unavailable,
        last_kind: :detector_unavailable,
        last_fingerprint: nil,
        turn_omissions: %{"assessment_failed" => 1}
      }
    }

    resume_packet_failure(issue, workspace, worker_host, "no_progress.assessment_failed", :collector_unavailable)
    send_no_progress_runtime_info(recipient, issue, assessment.summary)
    {assessment, ["no_progress.assessment_failed"]}
  end

  defp next_no_progress_state(current, assessment) do
    latches =
      case Map.get(assessment, :checkpoint) do
        %{latched_fingerprints: fingerprints} when is_list(fingerprints) -> fingerprints
        _assessment_unavailable -> current.latched_fingerprints
      end

    items =
      case Map.get(assessment, :warning) do
        %{fingerprint: fingerprint} = warning when is_binary(fingerprint) ->
          [warning]

        _no_new_warning ->
          []
      end

    %{items: items, latched_fingerprints: latches}
  end

  defp send_no_progress_runtime_info(recipient, %Issue{id: issue_id}, summary)
       when is_pid(recipient) and is_binary(issue_id) and is_map(summary) do
    compact = %{
      version: 1,
      mode: "shadow",
      active_warning_count: non_negative_count(summary[:active_warning_count]),
      completed_attempts: non_negative_count(summary[:completed_attempts]),
      alerts: non_negative_count(summary[:alerts]),
      progress_suppressions: non_negative_count(summary[:progress_suppressions]),
      progress_unavailable: non_negative_count(summary[:progress_unavailable]),
      fingerprint_evictions: non_negative_count(summary[:fingerprint_evictions]),
      signal_evictions: non_negative_count(summary[:signal_evictions]),
      last_decision: safe_no_progress_enum(summary[:last_decision], no_progress_decisions()),
      last_kind: safe_no_progress_enum(summary[:last_kind], no_progress_kinds()),
      last_fingerprint: safe_no_progress_digest(summary[:last_fingerprint]),
      omissions: safe_no_progress_omissions(summary[:turn_omissions])
    }

    send(recipient, {:worker_runtime_info, issue_id, %{no_progress_summary: compact}})
    :ok
  end

  defp send_no_progress_runtime_info(_recipient, _issue, _summary), do: :ok

  defp emit_no_progress_decision(issue, worker_host, channels, assessment) do
    if assessment.decision in [:alert, :suppressed_progress, :progress_unavailable, :reset] do
      summary = assessment.summary

      attrs = %{
        no_progress_version: 1,
        shadow: true,
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        worker_host: worker_host,
        decision: safe_no_progress_enum(assessment.decision, no_progress_decisions()),
        kind: safe_no_progress_enum(summary[:last_kind], no_progress_kinds()),
        tool_class: safe_no_progress_enum(summary[:last_operation], no_progress_operations()),
        result_class: safe_no_progress_enum(summary[:last_result_class], no_progress_results()),
        fingerprint: safe_no_progress_digest(summary[:last_fingerprint]),
        repeat_count: non_negative_count(summary[:last_repeat_count]),
        no_progress_turns: non_negative_count(summary[:last_no_progress_turns]),
        progress: safe_no_progress_enum(assessment.progress, ~w(changed unchanged unavailable)a),
        progress_channels: safe_progress_channels(channels),
        completed_attempts: non_negative_count(summary[:turn_completed_attempts]),
        signal_evictions: non_negative_count(summary[:signal_evictions]),
        omissions: safe_no_progress_omissions(summary[:turn_omissions]),
        warning_id: safe_no_progress_warning_id(get_in(assessment, [:warning, :warning_id]))
      }

      Telemetry.emit(:no_progress_loop, attrs)
    end

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp safe_progress_channels(channels) when is_map(channels) do
    Map.new(~w(repository workpad exact_head)a, fn key ->
      {key, safe_no_progress_enum(Map.get(channels, key), ~w(changed unchanged unavailable)a)}
    end)
  end

  defp safe_no_progress_omissions(omissions) when is_map(omissions) do
    omissions
    |> Enum.flat_map(fn
      {reason, count} when reason in @no_progress_omission_codes and is_integer(count) and count >= 0 ->
        [{reason, min(count, 1_000_000)}]

      _invalid ->
        []
    end)
    |> Enum.sort()
    |> Enum.take(12)
    |> Map.new()
  end

  defp safe_no_progress_omissions(_omissions), do: %{}

  defp safe_no_progress_digest(digest) when is_binary(digest) and byte_size(digest) == 64 do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, digest), do: digest
  end

  defp safe_no_progress_digest(_digest), do: nil

  defp safe_no_progress_warning_id("npw-" <> digest = warning_id) when byte_size(digest) == 24 do
    if Regex.match?(~r/\A[0-9a-f]{24}\z/, digest), do: warning_id
  end

  defp safe_no_progress_warning_id(_warning_id), do: nil

  defp safe_no_progress_enum(value, allowed) when is_atom(value),
    do: safe_no_progress_enum(Atom.to_string(value), allowed)

  defp safe_no_progress_enum(value, allowed) when is_binary(value) do
    if value in Enum.map(allowed, &to_string/1), do: value
  end

  defp safe_no_progress_enum(_value, _allowed), do: nil

  defp non_negative_count(value) when is_integer(value) and value >= 0, do: min(value, 1_000_000)
  defp non_negative_count(_value), do: 0

  defp no_progress_decisions,
    do: ~w(none provisional alert suppressed_progress progress_unavailable reset)a

  defp no_progress_kinds,
    do: ~w(repeated_error repeated_success_no_progress detector_unavailable)a

  defp no_progress_operations, do: ~w(shell read edit web mcp dynamic other)a

  defp no_progress_results,
    do: ~w(success failed nonzero_exit cancelled unsupported timeout unknown_failure)a

  defp resume_packet_fallback(workspace, worker_host, opts, issue) do
    cond do
      Keyword.get(opts, :resume_packet_loaded, false) ->
        {Keyword.get(opts, :resume_packet), List.wrap(Keyword.get(opts, :resume_packet_load_errors))}

      is_map(Keyword.get(opts, :resume_packet)) ->
        {Keyword.get(opts, :resume_packet), []}

      true ->
        load_resume_packet_fallback(workspace, worker_host, issue, opts)
    end
  end

  defp load_resume_packet_fallback(workspace, worker_host, issue, opts) do
    loader = Keyword.get(opts, :resume_packet_loader, &Workspace.load_resume_packet_with_diagnostics/2)

    case loader.(workspace, worker_host) do
      {:ok, packet, diagnostics} ->
        Enum.each(diagnostics, fn code ->
          resume_packet_failure(issue, workspace, worker_host, code, :persisted_packet_unavailable)
        end)

        {packet, diagnostics}

      {:error, reason} ->
        resume_packet_failure(issue, workspace, worker_host, "resume_packet_read_failed", reason)
        {nil, ["resume_packet_read_failed"]}
    end
  end

  defp persist_and_emit_resume_packet(workspace, issue, recipient, worker_host, packet) do
    persist_errors =
      case Workspace.persist_resume_packet(workspace, packet, worker_host) do
        :ok ->
          []

        {:error, reason} ->
          resume_packet_failure(issue, workspace, worker_host, "resume_packet_write_failed", reason)
          ["resume_packet_write_failed"]
      end

    metadata = %{
      resume_packet_id: packet["packet_id"],
      resume_packet_sha256: packet["packet_sha256"],
      resume_packet_ref: if(persist_errors == [], do: Path.basename(Workspace.resume_packet_path(workspace))),
      resume_packet_boundary: get_in(packet, ["boundary", "reason"]),
      resume_packet_evidence_refs: packet["evidence_refs"]
    }

    send_resume_packet_runtime_info(recipient, issue, metadata)

    Telemetry.emit(
      :resume_packet,
      Map.merge(metadata, telemetry_issue_attrs(issue, worker_host))
    )

    persist_errors
  end

  defp send_resume_packet_runtime_info(recipient, %Issue{id: issue_id}, metadata)
       when is_pid(recipient) and is_binary(issue_id) do
    send(recipient, {:worker_runtime_info, issue_id, metadata})
    :ok
  end

  defp send_resume_packet_runtime_info(_recipient, _issue, _metadata), do: :ok

  defp experiment_turn_effort(backend, opts) do
    if experiment_backend_name(%{backend: backend}, opts) == "codex" do
      case Keyword.get(opts, :experiment_turn_decision) do
        %{reasoning_effort: effort} when is_binary(effort) -> effort
        _no_experiment -> nil
      end
    end
  end

  defp emit_experiment_turn_event(issue, worker_host, opts, turn_number) do
    decision = Keyword.get(opts, :experiment_turn_decision)
    assignment = Keyword.get(opts, :experiment_assignment)

    cond do
      experiment_exposure_delivery?(decision, turn_number) ->
        Telemetry.emit(
          :experiment_exposure,
          experiment_exposure_attrs(issue, worker_host, assignment, decision, turn_number)
        )

      experiment_suspension_delivery?(
        assignment,
        Keyword.get(opts, :experiment_suspension_pending, false),
        turn_number
      ) ->
        Telemetry.emit(
          :experiment_suspended,
          experiment_suspension_attrs(
            issue,
            worker_host,
            assignment,
            turn_number,
            Keyword.get(opts, :experiment_suspension_pending, false)
          )
        )

      true ->
        :ok
    end
  end

  defp experiment_exposure_delivery?(%{action: "experiment", emit_exposure: true}, _turn_number),
    do: true

  defp experiment_exposure_delivery?(%{action: "experiment"}, 1), do: true
  defp experiment_exposure_delivery?(_decision, _turn_number), do: false

  defp experiment_suspension_delivery?(%{"state" => "suspended"}, true, _turn_number),
    do: true

  defp experiment_suspension_delivery?(%{"state" => "suspended"}, false, 1), do: true
  defp experiment_suspension_delivery?(_assignment, _pending, _turn_number), do: false

  defp experiment_exposure_attrs(issue, worker_host, assignment, decision, turn_number) do
    experiment_event_attrs(issue, worker_host, assignment)
    |> Map.merge(%{
      experiment_event_version: 1,
      exposure_id: decision.exposure_id,
      assignment_reason: "deterministic_opt_in",
      mode: "apply",
      reasoning_effort: assignment["reasoning_effort"],
      baseline_reasoning_effort: assignment["baseline_reasoning_effort"],
      turn_number: turn_number,
      delivery: if(decision.emit_exposure, do: "initial", else: "replay")
    })
  end

  defp experiment_suspension_attrs(issue, worker_host, assignment, turn_number, pending?) do
    experiment_event_attrs(issue, worker_host, assignment)
    |> Map.merge(%{
      experiment_event_version: 1,
      suspension_id: assignment["suspension_id"],
      mode: "baseline",
      reason: assignment["suspension_reason"],
      ever_exposed: assignment["ever_exposed"],
      contaminated: assignment["contaminated"],
      turn_number: turn_number,
      delivery: if(pending?, do: "initial", else: "replay")
    })
  end

  defp experiment_event_attrs(issue, worker_host, assignment) do
    %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      worker_host: worker_host || "local",
      experiment_id: assignment["experiment_id"],
      experiment_revision: assignment["revision"],
      experiment_manifest_digest: assignment["experiment_manifest_digest"],
      unit_id: assignment["unit_id"],
      assignment_id: assignment["assignment_id"],
      arm_id: assignment["arm_id"],
      arm_role: assignment["arm_role"],
      arm_config_digest: assignment["arm_config_digest"],
      control_config_digest: assignment["control_config_digest"]
    }
  end

  defp resume_packet_failure(issue, workspace, worker_host, code, reason) do
    Logger.warning(
      "resume_packet failure #{issue_context(issue)} workspace=#{workspace} " <>
        "worker_host=#{worker_host_for_log(worker_host)} code=#{code} reason_class=#{resume_failure_reason_class(reason)}"
    )

    Telemetry.emit(:resume_packet_error, %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      workspace: workspace,
      worker_host: worker_host,
      error_code: code
    })
  end

  defp resume_failure_reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp resume_failure_reason_class(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    reason |> elem(0) |> resume_failure_reason_class()
  end

  defp resume_failure_reason_class(%{__struct__: module}) when is_atom(module),
    do: inspect(module)

  defp resume_failure_reason_class(_reason), do: "unknown"

  defp safe_budget_snapshot(pid, issue, workspace, worker_host, opts) when is_pid(pid) do
    snapshotter = Keyword.get(opts, :budget_snapshotter, &AgentBudgetCollector.snapshot/1)
    {snapshotter.(pid), []}
  rescue
    _error ->
      resume_packet_failure(issue, workspace, worker_host, "budget.snapshot_failed", :collector_unavailable)
      {nil, ["budget.snapshot_failed"]}
  catch
    _kind, _reason ->
      resume_packet_failure(issue, workspace, worker_host, "budget.snapshot_failed", :collector_unavailable)
      {nil, ["budget.snapshot_failed"]}
  end

  defp safe_budget_snapshot(_pid, _issue, _workspace, _worker_host, _opts), do: {nil, []}

  defp with_budget_thresholds(runtime, opts) when is_map(runtime) do
    thresholds =
      case Keyword.get(opts, :efficiency_decision) do
        %{budget: budget} when is_map(budget) -> budget
        _decision -> %{}
      end

    Map.put(runtime, :thresholds, thresholds)
  end

  defp with_budget_thresholds(_runtime, _opts), do: nil

  defp repository_for_packet(manifest) when is_map(manifest) do
    if Enum.any?(
         [:head_sha, :base_sha, :worktree_status_fingerprint, :worktree_content_fingerprint],
         &is_binary(Map.get(manifest, &1))
       ) do
      manifest
    end
  end

  defp repository_for_packet(_manifest), do: nil

  defp turn_repository_for_packet(opts, 1),
    do: repository_for_packet(Keyword.get(opts, :repository_manifest))

  defp turn_repository_for_packet(_opts, _turn_number), do: nil

  defp repository_manifest_errors(manifest) when is_map(manifest),
    do: List.wrap(Map.get(manifest, :errors))

  defp repository_manifest_errors(_manifest), do: []

  defp repository_collection_failure_manifest do
    %{
      head_sha: nil,
      base_sha: nil,
      base_age_seconds: nil,
      candidate_base_sha: nil,
      actual_paths: [],
      dirty: true,
      diff_counts: nil,
      worktree_fingerprint: nil,
      worktree_status_fingerprint: nil,
      worktree_content_fingerprint: nil,
      worktree_fingerprint_complete: false,
      worktree_fingerprint_path_count: 0,
      errors: ["repository.collection_failed"]
    }
  end

  defp current_resume_verification(opts),
    do: Process.get(@resume_packet_verification_key) || Keyword.get(opts, :resume_verification)

  defp status_packet_max_bytes(opts) do
    case Keyword.get(opts, :efficiency_decision) do
      %{capsule_max_bytes: max_bytes} when is_integer(max_bytes) and max_bytes > 0 -> max_bytes
      _decision -> 4_000
    end
  end

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
    identity = RunManifest.execution_identity(Keyword.get(opts, :attempt), opts)
    opts = Keyword.merge(opts, Map.to_list(Map.delete(identity, :attempt)))

    Telemetry.with_context(identity, fn ->
      run_codex_turns(workspace, issue, recipient, opts, worker_host)
    end)
  end

  @doc false
  @spec prompt_built_telemetry_event() :: [atom()]
  def prompt_built_telemetry_event, do: @prompt_built_telemetry_event

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    Process.delete(@resume_packet_verification_key)

    try do
      run_codex_turns_body(workspace, issue, codex_update_recipient, opts, worker_host)
    after
      Process.delete(@resume_packet_verification_key)
    end
  end

  defp run_codex_turns_body(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, route} <- resolve_agent_route(workspace, issue, opts, worker_host),
         {:ok, efficiency} <-
           AgentEfficiency.decide(issue, route, Keyword.get(opts, :per_repo_workflow)) do
      {initial_packet, load_errors} = resume_packet_fallback(workspace, worker_host, opts, issue)

      {experiment_assignment, experiment_errors} =
        resolve_experiment_assignment(
          issue,
          route,
          efficiency,
          initial_packet,
          load_errors,
          workspace,
          worker_host,
          opts
        )

      opts =
        opts
        |> Keyword.put(:resume_packet, initial_packet)
        |> Keyword.put(:resume_packet_loaded, true)
        |> Keyword.put(:resume_packet_load_errors, load_errors)
        |> Keyword.put(:experiment_assignment, experiment_assignment)
        |> Keyword.put(
          :experiment_suspension_pending,
          newly_suspended_assignment?(initial_packet, experiment_assignment)
        )
        |> Keyword.update(:resume_packet_errors, experiment_errors, &(List.wrap(&1) ++ experiment_errors))

      emit_run_manifest(workspace, issue, route, efficiency, opts)

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

  defp emit_run_manifest(workspace, issue, route, efficiency, opts) do
    context = %{
      identity: Telemetry.current_context(),
      issue: issue,
      route: route,
      efficiency: efficiency,
      settings: Config.settings!(),
      workspace: workspace,
      repository_id: Keyword.get(opts, :repository_id),
      repository_manifest: Keyword.get(opts, :repository_manifest, %{}),
      repo_workflow: Keyword.get(opts, :per_repo_workflow),
      review_workflow: Keyword.get(opts, :per_repo_review_workflow),
      workflow_source: Keyword.get(opts, :workflow_source),
      review_workflow_source: Keyword.get(opts, :review_workflow_source),
      experiment_assignment: Keyword.get(opts, :experiment_assignment)
    }

    Telemetry.emit(:run_manifest, RunManifest.build(context))
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

    no_progress = Config.no_progress_settings(Keyword.get(opts, :per_repo_workflow))

    with {:ok, budget_collector} <-
           AgentBudgetCollector.start_link(efficiency, issue, Telemetry.current_context(), no_progress) do
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

  defp resolve_experiment_assignment(
         issue,
         route,
         efficiency,
         packet,
         load_errors,
         workspace,
         worker_host,
         opts
       ) do
    {manifest, manifest_errors} = repository_experiment_manifest(issue, workspace, worker_host, opts)
    previous = if is_map(packet), do: Map.get(packet, "experiment_assignment")
    fresh_task? = fresh_experiment_lineage?(packet, load_errors)

    context = %{
      previous_assignment: previous,
      fresh_task: fresh_task?,
      mode: if(fresh_task?, do: safe_experiment_mode(opts), else: :off),
      issue_id: issue.id,
      labels: Issue.label_names(issue),
      repository_id: Keyword.get(opts, :repository_id),
      task_family: efficiency.task_type,
      backend: experiment_backend_name(route, opts),
      baseline_reasoning_effort: Map.get(route.overrides, :reasoning_effort)
    }

    case Experiment.assign(manifest, context) do
      {:assigned, assignment} -> {assignment, manifest_errors}
      {:restored, assignment} -> {assignment, manifest_errors}
      {:suspended, assignment, _reason} -> {assignment, manifest_errors}
      {:skip, :invalid_previous_assignment} -> {nil, manifest_errors ++ ["experiment.assignment_invalid"]}
      {:skip, _reason} -> {nil, manifest_errors}
    end
  rescue
    _error ->
      experiment_failure(issue, workspace, worker_host, "experiment.assignment_failed")
      {nil, ["experiment.assignment_failed"]}
  end

  defp repository_experiment_manifest(issue, workspace, worker_host, opts) do
    case Config.experiment_settings(Keyword.get(opts, :per_repo_workflow)) do
      {:ok, manifest} ->
        {manifest, []}

      {:error, _reason} ->
        experiment_failure(issue, workspace, worker_host, "experiment.manifest_invalid")
        {nil, ["experiment.manifest_invalid"]}
    end
  rescue
    _error ->
      experiment_failure(issue, workspace, worker_host, "experiment.manifest_invalid")
      {nil, ["experiment.manifest_invalid"]}
  end

  defp fresh_experiment_lineage?(packet, load_errors) do
    identity = Telemetry.current_context()

    is_nil(packet) and load_errors == [] and Map.get(identity, :retry_attempt, 0) == 0 and
      is_nil(Map.get(identity, :parent_run_id)) and is_nil(Map.get(identity, :retry_id))
  end

  defp newly_suspended_assignment?(packet, %{"state" => "suspended"}) do
    get_in(packet || %{}, ["experiment_assignment", "state"]) != "suspended"
  end

  defp newly_suspended_assignment?(_packet, _assignment), do: false

  defp experiment_backend_name(route, opts) do
    AgentBackend.backend_name(route.backend) || Keyword.get(opts, :experiment_backend_name)
  end

  defp safe_experiment_mode(opts) do
    resolver = Keyword.get(opts, :experiment_mode_resolver, &Config.experiment_mode/0)

    case resolver.() do
      :apply -> :apply
      "apply" -> :apply
      _off_or_invalid -> :off
    end
  rescue
    _error -> :off
  end

  defp experiment_failure(issue, workspace, worker_host, code) do
    resume_packet_failure(issue, workspace, worker_host, code, :experiment_unavailable)
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
    case ensure_implementation_pr_draft(workspace, issue, opts) do
      :ok ->
        run_codex_turn(
          backend,
          app_session,
          workspace,
          issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
          {turn_number, max_turns}
        )

      {:error, reason} ->
        {:error, {:managed_pr_draft_failed, reason}}
    end
  end

  defp run_codex_turn(
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

    {_turn_start_packet, opts} =
      prepare_turn_resume_packet(
        workspace,
        issue,
        codex_update_recipient,
        app_session.worker_host,
        opts,
        turn_number,
        max_turns
      )

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

    emit_experiment_turn_event(issue, app_session.worker_host, opts, turn_number)
    opts = Keyword.put(opts, :experiment_suspension_pending, false)

    turn_opts =
      [
        on_message: codex_message_handler(codex_update_recipient, issue, budget_ref),
        tool_executor: tool_executor
      ]
      |> maybe_put(:reasoning_effort, experiment_turn_effort(backend, opts))

    turn_result =
      backend.run_turn(
        app_session,
        prompt,
        issue,
        turn_opts
      )

    budget_runtime =
      AgentBudgetCollector.finish_turn(
        budget_collector,
        System.monotonic_time(:millisecond)
      )

    send_budget_runtime_info(codex_update_recipient, issue, budget_runtime)

    case turn_result do
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

        handoff_gate_prompt =
          maybe_run_deferred_handoff_gate(
            pop_deferred_handoff_gate(),
            handoff_gate_prompt,
            codex_update_recipient,
            backend,
            issue_state_fetcher,
            opts
          )

        infrastructure_failure = pop_handoff_infrastructure_failure()
        wait_request = pop_agent_wait_request()
        continuation = continue_with_issue?(issue, issue_state_fetcher, opts)
        packet_issue = continuation_issue(continuation, issue)

        opts =
          refresh_after_turn(
            workspace,
            packet_issue,
            codex_update_recipient,
            app_session.worker_host,
            opts,
            budget_runtime,
            {turn_number, max_turns},
            successful_turn_boundary(continuation, wait_request)
          )

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
          maybe_run_deferred_review_handoff(
            pop_deferred_review_handoff(),
            nil,
            codex_update_recipient,
            backend
          )

        maybe_run_deferred_handoff_gate(
          pop_deferred_handoff_gate(),
          handoff_gate_prompt,
          codex_update_recipient,
          backend,
          issue_state_fetcher,
          opts
        )

        _opts =
          refresh_after_turn(
            workspace,
            issue,
            codex_update_recipient,
            app_session.worker_host,
            opts,
            budget_runtime,
            {turn_number, max_turns},
            :turn_error
          )

        Logger.warning("Agent turn ended abnormally for #{issue_context(issue)} turn=#{turn_number}/#{max_turns} reason=#{inspect(reason)}")
        error
    end
  end

  defp continuation_issue({_status, %Issue{} = issue}, _fallback), do: issue
  defp continuation_issue(_continuation, issue), do: issue

  defp successful_turn_boundary(_continuation, %{}), do: :turn_waiting
  defp successful_turn_boundary({:done, _issue}, _wait_request), do: :turn_terminal
  defp successful_turn_boundary({:error, _reason}, _wait_request), do: :turn_state_error
  defp successful_turn_boundary(_continuation, _wait_request), do: :turn_complete

  defp ensure_implementation_pr_draft(workspace, issue, opts) do
    opts
    |> Keyword.get(:per_repo_review_workflow)
    |> Config.review_settings()
    |> maybe_ensure_implementation_pr_draft(workspace, issue, opts)
  end

  defp maybe_ensure_implementation_pr_draft(%{draft_pr_lifecycle: false}, _workspace, _issue, _opts),
    do: :ok

  defp maybe_ensure_implementation_pr_draft(_settings, workspace, issue, opts) do
    pr_opts =
      opts
      |> Keyword.take([:pr_runner])
      |> maybe_put(:pr_url, List.first(Cardinality.pr_urls(issue)))

    workspace
    |> PrReviewSection.resolve_pr(pr_opts)
    |> ensure_resolved_pr_draft(workspace, pr_opts)
  end

  defp ensure_resolved_pr_draft({:skip, :no_pr}, _workspace, _opts), do: :ok
  defp ensure_resolved_pr_draft({:skip, reason}, _workspace, _opts), do: {:error, reason}

  defp ensure_resolved_pr_draft({:ok, pr}, workspace, opts) do
    case PrReviewSection.ensure_draft(workspace, pr, opts) do
      {:ok, _pr} -> :ok
      {:error, reason} -> {:error, reason}
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
          ),
          status_resume_packet_section(opts)
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

    sections =
      [
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
      ] ++ changed_for_prompt ++ [status_resume_packet_section(opts)]

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

  defp status_resume_packet_section(opts) do
    packet = Keyword.get(opts, :resume_packet, %{})

    prompt_section(
      "continuation.status_resume_packet",
      :status_resume_packet,
      "symphony:trusted_resume_packet/#{packet["packet_id"] || "unavailable"}",
      "resume-packet/v#{packet["protocol_version"] || ResumePacket.version()}",
      ResumePacket.render(packet, status_packet_max_bytes(opts)),
      false
    )
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

    metadata =
      Map.merge(Telemetry.current_context(), %{
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
      })

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
      |> maybe_put(:hook_command, per_repo_before_handoff)

    handoff_context =
      %{issue: issue, workspace: workspace, worker_host: worker_host}
      |> maybe_put_map(:before_handoff_command, per_repo_before_handoff)
      |> maybe_put_map(:before_handoff_timeout_ms, per_repo_before_handoff_timeout_ms)
      |> maybe_put_map(:before_handoff_stale_ms, per_repo_before_handoff_stale_ms)
      |> Map.put(:handoff_gate_start_callback, &persist_starting_handoff_gate/1)
      |> Map.put(:handoff_gate_clear_callback, &clear_starting_handoff_gate/1)
      |> Map.put(:deferred_handoff_gate_callback, &store_deferred_handoff_gate/1)
      |> Map.put(:handoff_infrastructure_failure_callback, &store_handoff_infrastructure_failure/2)
      |> Map.put(:handoff_gate_verification_callback, &remember_handoff_gate_verification/1)
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
        transition_pending_gate(recipient, issue, Map.put(gate, :job_id, gate_job_id))

      :finished, %{gate_job_id: gate_job_id, outcome: outcome} ->
        result =
          transition_agent_lifecycle(recipient, issue, :implementing, %{
            gate_job_id: gate_job_id,
            gate_outcome: outcome
          })

        clear_pending_gate_lifecycle(issue)
        result
    end
  end

  defp deferred_review_callback(nil), do: nil
  defp deferred_review_callback(_review_workflow), do: &store_deferred_review_handoff/1

  defp store_deferred_handoff_gate(request) when is_map(request) do
    existing = Process.get(@deferred_handoff_gate_key)

    if same_pending_candidate?(existing, request) do
      with :ok <- persist_deferred_handoff_gate(request) do
        :already_pending
      end
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

  defp persist_starting_handoff_gate(request) when is_map(request) do
    Workspace.persist_handoff_gate_state(
      Map.fetch!(request, :workspace),
      durable_handoff_request(request),
      Map.get(request, :worker_host)
    )
  end

  defp clear_starting_handoff_gate(request) when is_map(request) do
    Workspace.clear_handoff_gate_state(
      Map.fetch!(request, :workspace),
      Map.get(request, :worker_host)
    )
  end

  defp durable_handoff_request(request) do
    durable = %{
      "phase" => "starting",
      "query" => Map.fetch!(request, :query),
      "variables" => Map.get(request, :variables, %{}),
      "targetState" => Map.fetch!(request, :target_state)
    }

    durable =
      case encode_review_approval(Map.get(request, :review_approval)) do
        nil -> durable
        approval -> Map.put(durable, "reviewApproval", approval)
      end

    case Map.fetch(request, :gate) do
      {:ok, gate} ->
        Map.merge(durable, %{
          "phase" => "polling",
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
        })

      :error ->
        durable
    end
  end

  defp encode_review_approval(%{
         review_key: {:pull_request, issue_id, pr_identity, reviewed_sha},
         reviewed_sha: reviewed_sha
       })
       when is_binary(issue_id) and is_binary(pr_identity) and is_binary(reviewed_sha) do
    %{
      "kind" => "pull_request",
      "issueId" => issue_id,
      "prIdentity" => pr_identity,
      "reviewedSha" => reviewed_sha
    }
  end

  defp encode_review_approval(%{
         review_key: {:workspace, issue_id, reviewed_sha},
         reviewed_sha: reviewed_sha
       })
       when is_binary(issue_id) and is_binary(reviewed_sha) do
    %{"kind" => "workspace", "issueId" => issue_id, "reviewedSha" => reviewed_sha}
  end

  defp encode_review_approval(_approval), do: nil

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
          {:ok, %{phase: :starting} = request} ->
            Logger.info("handoff.gate resuming durable start #{issue_context(issue)}")

            resume_starting_handoff_gate(
              request,
              recipient,
              backend,
              issue_state_fetcher,
              opts
            )

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
         %{"phase" => "starting", "query" => query, "targetState" => target_state} = durable,
         workspace,
         issue,
         worker_host,
         opts
       )
       when is_binary(query) and is_binary(target_state) do
    with {:ok, request} <- restore_handoff_request_base(durable, workspace, issue, worker_host, opts) do
      {:ok, Map.put(request, :phase, :starting)}
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
    with {:ok, gate} <- restore_durable_gate(durable_gate),
         {:ok, request} <-
           restore_handoff_request_base(durable, workspace, issue, worker_host, opts) do
      {:ok, Map.merge(request, %{phase: :polling, gate: gate})}
    end
  end

  defp restore_handoff_request(_durable, _workspace, _issue, _worker_host, _opts),
    do: {:error, :invalid_request}

  defp restore_handoff_request_base(durable, workspace, issue, worker_host, opts) do
    review_opts =
      []
      |> maybe_put(:base_drift_ref, Keyword.get(opts, :base_drift_ref))
      |> maybe_put(:hook_command, Keyword.get(opts, :per_repo_before_handoff))

    request = %{
      query: Map.fetch!(durable, "query"),
      variables: Map.get(durable, "variables", %{}),
      workspace: workspace,
      issue: issue,
      worker_host: worker_host,
      target_state: Map.fetch!(durable, "targetState"),
      before_handoff_command: Keyword.get(opts, :per_repo_before_handoff),
      before_handoff_timeout_ms: Keyword.get(opts, :per_repo_before_handoff_timeout_ms),
      before_handoff_stale_ms: Keyword.get(opts, :per_repo_before_handoff_stale_ms),
      review_workflow: Keyword.get(opts, :per_repo_review_workflow),
      review_opts: review_opts,
      linear_client: Keyword.get(opts, :linear_client, &Client.graphql/3)
    }

    case restore_review_approval(Map.get(durable, "reviewApproval")) do
      {:ok, nil} -> {:ok, request}
      {:ok, approval} -> {:ok, Map.put(request, :review_approval, approval)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp restore_review_approval(nil), do: {:ok, nil}

  defp restore_review_approval(%{
         "kind" => "pull_request",
         "issueId" => issue_id,
         "prIdentity" => pr_identity,
         "reviewedSha" => reviewed_sha
       })
       when is_binary(issue_id) and is_binary(pr_identity) and is_binary(reviewed_sha) do
    {:ok,
     %{
       review_key: {:pull_request, issue_id, pr_identity, reviewed_sha},
       reviewed_sha: reviewed_sha
     }}
  end

  defp restore_review_approval(%{"kind" => "workspace", "issueId" => issue_id, "reviewedSha" => reviewed_sha})
       when is_binary(issue_id) and is_binary(reviewed_sha) do
    {:ok,
     %{
       review_key: {:workspace, issue_id, reviewed_sha},
       reviewed_sha: reviewed_sha
     }}
  end

  defp restore_review_approval(_approval), do: {:error, :invalid_review_approval}

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

  defp resume_starting_handoff_gate(request, recipient, backend, issue_state_fetcher, opts) do
    case refresh_handoff_issue(request.issue, issue_state_fetcher, opts) do
      {:continue, refreshed_issue} ->
        request
        |> Map.put(:issue, refreshed_issue)
        |> run_starting_handoff_gate(recipient, backend, issue_state_fetcher, opts)

      {:done, refreshed_issue} ->
        case Workspace.clear_handoff_gate_state(request.workspace, request.worker_host) do
          :ok -> {:completed, refreshed_issue}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_starting_handoff_gate(request, recipient, backend, issue_state_fetcher, opts) do
    case revalidate_starting_handoff_base(request, opts) do
      {:ok, decision} ->
        request
        |> put_request_base_drift_decision(decision)
        |> start_recovered_handoff_gate(recipient, backend, issue_state_fetcher, opts)

      {:defer, prompt, _decision} ->
        resume_after_starting_handoff_gate(request, prompt)

      {:error, reason} ->
        prompt =
          "Symphony could not revalidate origin/#{starting_handoff_base_ref(request)} before retrying the handoff gate " <>
            "(#{inspect(reason)}). Keep the issue in progress, restore base visibility, and re-attempt the handoff. " <>
            "No rebase was attempted."

        resume_after_starting_handoff_gate(request, prompt)
    end
  end

  defp start_recovered_handoff_gate(request, recipient, backend, issue_state_fetcher, opts) do
    starter = Keyword.get(opts, :handoff_gate_starter, &HandoffGate.run_before_handoff/5)

    start_opts =
      [async: true]
      |> maybe_put(:hook_command, request.before_handoff_command)
      |> maybe_put(:timeout_ms, request.before_handoff_timeout_ms)
      |> maybe_put(:stale_ms, request.before_handoff_stale_ms)

    result =
      starter.(
        request.workspace,
        request.issue,
        request.worker_host,
        request.target_state,
        start_opts
      )

    handle_starting_handoff_result(
      result,
      request,
      recipient,
      backend,
      issue_state_fetcher,
      opts
    )
  end

  defp revalidate_starting_handoff_base(request, opts) do
    base_opts =
      [worker_host: request.worker_host, hook_command: request.before_handoff_command]
      |> maybe_put(:git_runner, Keyword.get(opts, :base_drift_git_runner))
      |> maybe_put(:ssh_runner, Keyword.get(opts, :base_drift_ssh_runner))

    BaseDrift.assess(
      request.workspace,
      request.issue,
      starting_handoff_base_ref(request),
      base_opts
    )
  end

  defp starting_handoff_base_ref(request) do
    Keyword.get(request.review_opts, :base_drift_ref)
  end

  defp put_request_base_drift_decision(request, decision) do
    review_opts = Keyword.put(request.review_opts, :base_drift_decision, decision)
    Map.put(request, :review_opts, review_opts)
  end

  defp handle_starting_handoff_result(
         {:pending, gate},
         request,
         recipient,
         backend,
         issue_state_fetcher,
         opts
       ) do
    request = Map.merge(request, %{phase: :polling, gate: gate})

    case persist_deferred_handoff_gate(request) do
      :ok -> poll_pending_handoff_gate(request, recipient, backend, issue_state_fetcher, opts, true)
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_starting_handoff_result(
         {:infrastructure_error, prompt, gate},
         request,
         _recipient,
         _backend,
         _issue_state_fetcher,
         _opts
       ) do
    remember_gate_verification(gate)
    store_handoff_infrastructure_failure(prompt, gate)
    {:resume, prompt, request.issue}
  end

  defp handle_starting_handoff_result(
         {:passed, gate},
         request,
         recipient,
         backend,
         _issue_state_fetcher,
         _opts
       ) do
    remember_gate_verification(gate)
    finish_starting_handoff_gate(Map.put(request, :gate, gate), recipient, backend)
  end

  defp handle_starting_handoff_result(
         :ok,
         request,
         recipient,
         backend,
         _issue_state_fetcher,
         _opts
       ) do
    finish_starting_handoff_gate(request, recipient, backend)
  end

  defp handle_starting_handoff_result(
         {:blocked, prompt, gates},
         request,
         _recipient,
         _backend,
         _issue_state_fetcher,
         _opts
       ) do
    remember_blocked_gate_verification(gates)
    resume_after_starting_handoff_gate(request, prompt)
  end

  defp handle_starting_handoff_result(
         {status, prompt, gate},
         request,
         _recipient,
         _backend,
         _issue_state_fetcher,
         _opts
       )
       when status in [:failed, :invalidated] do
    remember_gate_verification(gate)
    resume_after_starting_handoff_gate(Map.put(request, :gate, gate), prompt)
  end

  defp finish_starting_handoff_gate(request, recipient, backend) do
    with :ok <- Workspace.clear_handoff_gate_state(request.workspace, request.worker_host) do
      apply_passed_handoff_gate(request, recipient, backend)
    end
  end

  defp resume_after_starting_handoff_gate(request, prompt) do
    case Workspace.clear_handoff_gate_state(request.workspace, request.worker_host) do
      :ok -> {:resume, prompt, request.issue}
      {:error, reason} -> {:error, reason}
    end
  end

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
    result =
      case Map.get(request, :gate) do
        nil ->
          resume_starting_handoff_gate(
            request,
            recipient,
            backend,
            issue_state_fetcher,
            opts
          )

        _gate ->
          poll_pending_handoff_gate(
            request,
            recipient,
            backend,
            issue_state_fetcher,
            opts,
            true
          )
      end

    case result do
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

    case refresh_handoff_issue(issue, issue_state_fetcher, opts) do
      {:continue, refreshed_issue} ->
        request = Map.put(request, :issue, refreshed_issue)
        poll_current_handoff_gate(request, recipient, backend, issue_state_fetcher, opts)

      {:done, refreshed_issue} ->
        case finish_pending_gate(request, recipient, :issue_no_longer_active) do
          :ok -> {:completed, refreshed_issue}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        # Tracker refresh is an operational precondition, not a gate verdict.
        # Keep the durable job and its lifecycle intact so recovery can attach
        # to the same exact candidate instead of starting an implementor turn.
        {:error, {:handoff_issue_refresh_failed, reason}}
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
    remember_gate_verification(gate)
    request = Map.put(request, :gate, gate)

    case finish_pending_gate(request, recipient, :passed) do
      :ok ->
        apply_passed_handoff_gate(request, recipient, backend)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_pending_gate_poll({:failed, prompt, gate}, request, recipient, _backend, _fetcher, _opts) do
    remember_gate_verification(gate)
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
    remember_gate_verification(gate)
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
    remember_gate_verification(terminal_gate)
    store_handoff_infrastructure_failure(prompt, gate)
    resume_after_terminal_gate(request, terminal_gate, prompt, recipient, :infrastructure_error)
  end

  defp handle_pending_gate_poll({:blocked, prompt, gates}, request, recipient, _backend, _fetcher, _opts) do
    remember_blocked_gate_verification(gates)

    case finish_pending_gate(request, recipient, :legacy_failure) do
      :ok -> {:resume, prompt, request.issue}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_pending_gate_poll(:ok, request, recipient, backend, _fetcher, _opts) do
    case finish_pending_gate(request, recipient, :legacy_passed) do
      :ok ->
        apply_passed_handoff_gate(request, recipient, backend)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resume_after_terminal_gate(request, gate, prompt, recipient, outcome) do
    owned_job_id = request.gate.job_id
    request = Map.put(request, :gate, gate)

    case finish_pending_gate(request, recipient, outcome, owned_job_id) do
      :ok -> {:resume, prompt, request.issue}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_passed_handoff_gate(request, recipient, backend) do
    case Map.get(request, :review_approval) do
      %{review_key: _review_key, reviewed_sha: _reviewed_sha} = approval ->
        apply_handoff_with_review_approval(request, approval)

      _no_review_approval ->
        apply_legacy_passed_handoff_gate(request, recipient, backend)
    end
  end

  defp apply_legacy_passed_handoff_gate(request, recipient, backend) do
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

  defp apply_handoff_with_review_approval(request, approval) do
    current_key =
      ReviewGate.current_review_key(
        request.workspace,
        request.issue,
        Map.get(request, :review_opts, [])
      )

    if current_key == approval.review_key and review_key_sha(current_key) == approval.reviewed_sha do
      case apply_deferred_review_handoff(request) do
        nil -> {:completed, request.issue}
        prompt -> {:resume, prompt, request.issue}
      end
    else
      Logger.warning(
        "review.gate approval changed before handoff #{issue_context(request.issue)} " <>
          "reviewed_key=#{inspect(approval.review_key)} current_key=#{inspect(current_key)}; withholding Linear handoff"
      )

      {:resume, deferred_review_head_changed_prompt(request.issue), request.issue}
    end
  end

  defp review_key_sha({:pull_request, _issue_id, _pr_identity, head_sha}), do: head_sha
  defp review_key_sha({:workspace, _issue_id, head_sha}), do: head_sha

  defp transition_pending_gate(recipient, issue, gate) do
    signature = pending_gate_lifecycle_signature(gate)
    lifecycles = Process.get(@handoff_gate_lifecycle_key, %{})

    unless Map.get(lifecycles, issue.id) == signature do
      :ok =
        transition_agent_lifecycle(recipient, issue, :handoff_pending_gate, %{
          gate_job_id: gate.job_id,
          gate: handoff_gate_lifecycle_payload(gate)
        })

      Process.put(@handoff_gate_lifecycle_key, Map.put(lifecycles, issue.id, signature))
    end

    :ok
  end

  defp finish_pending_gate(request, recipient, outcome, owned_job_id \\ nil) do
    gate = request.gate
    lifecycle_job_id = owned_job_id || gate.job_id

    with :ok <- Workspace.clear_handoff_gate_state(request.workspace, request.worker_host) do
      result =
        transition_agent_lifecycle(recipient, request.issue, :implementing, %{
          gate_job_id: lifecycle_job_id,
          gate_outcome: outcome
        })

      clear_pending_gate_lifecycle(request.issue)
      result
    end
  end

  defp pending_gate_lifecycle_signature(gate) do
    {
      Map.get(gate, :job_id),
      Map.get(gate, :status),
      Map.get(gate, :progress)
    }
  end

  defp clear_pending_gate_lifecycle(issue) do
    lifecycles = Process.get(@handoff_gate_lifecycle_key, %{})
    Process.put(@handoff_gate_lifecycle_key, Map.delete(lifecycles, issue.id))
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

  defp refresh_handoff_issue(issue, issue_state_fetcher, opts, retry_attempt \\ 0) do
    case continue_with_issue?(issue, issue_state_fetcher, opts) do
      {:error, reason} = error ->
        if transient_handoff_issue_refresh_failure?(reason) do
          delay_ms = handoff_issue_refresh_retry_delay_ms(issue, retry_attempt)

          Logger.warning(
            "handoff.gate issue refresh failed; retrying #{issue_context(issue)} " <>
              "attempt=#{retry_attempt + 1} delay_ms=#{delay_ms} reason=#{inspect(reason)}"
          )

          handoff_issue_refresh_sleep(delay_ms, opts)
          refresh_handoff_issue(issue, issue_state_fetcher, opts, retry_attempt + 1)
        else
          error
        end

      result ->
        result
    end
  end

  defp transient_handoff_issue_refresh_failure?(reason) do
    AgentFailure.classify(reason).class in [
      :rate_limited,
      :response_timeout_or_stall,
      :transient_infrastructure
    ]
  end

  defp handoff_issue_refresh_retry_delay_ms(issue, retry_attempt) do
    exponent = min(max(retry_attempt, 0), 5)

    base_delay_ms =
      min(
        @handoff_issue_refresh_retry_base_ms * Integer.pow(2, exponent),
        @handoff_issue_refresh_retry_max_ms
      )

    jitter_room_ms = max(@handoff_issue_refresh_retry_max_ms - base_delay_ms, 0)
    jitter_limit_ms = min(div(base_delay_ms, 5), jitter_room_ms)
    jitter_ms = :erlang.phash2({issue.id, retry_attempt}, jitter_limit_ms + 1)
    base_delay_ms + jitter_ms
  end

  defp handoff_issue_refresh_sleep(delay_ms, opts) do
    sleep = Keyword.get(opts, :handoff_issue_refresh_sleep, &Process.sleep/1)
    sleep.(delay_ms)
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
    review_timeout_ms = handoff_review_timeout_ms(AgentBackend.backend_name(backend))

    review_opts =
      review_opts_with_progress(request, recipient, issue, review_job_id, review_timeout_ms)

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

    remember_review_verification(review_outcome)

    :ok =
      transition_agent_lifecycle(recipient, issue, :implementing, %{
        review_job_id: review_job_id,
        review_outcome: outcome,
        review_state: ReviewOutcome.to_map(review_outcome)
      })

    handoff_gate_prompt
  end

  defp remember_review_verification(%ReviewOutcome{} = outcome) do
    captured_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    remember_resume_verification(%{
      source: "symphony:automated_review",
      captured_at: captured_at,
      review_source: "symphony:automated_review",
      review_captured_at: captured_at,
      exact_sha: outcome.reviewed_sha,
      reviewed_sha: outcome.reviewed_sha,
      review_outcome: outcome.outcome,
      review_packet_id: outcome.packet_id,
      open_finding_count: length(outcome.findings),
      severity_counts: outcome.severity_counts,
      attestation_report: outcome.attestation_report
    })
  end

  defp remember_gate_verification(gate) when is_map(gate) do
    identity = mixed_map_value(gate, :identity, "identity", %{})
    head_sha = mixed_map_value(identity, :head_sha, "headSha")
    source = "symphony:before_handoff_gate"

    captured_at =
      mixed_map_value(gate, :completed_at, "completedAt") || current_timestamp()

    remember_resume_verification(%{
      source: source,
      captured_at: captured_at,
      gate_source: source,
      gate_captured_at: captured_at,
      exact_sha: head_sha,
      gate_status: mixed_map_value(gate, :status, "status"),
      gate_job_id: mixed_map_value(gate, :job_id, "jobId"),
      checks: mixed_map_value(gate, :checks, "checks", []),
      evidence_refs: List.wrap(mixed_map_value(gate, :result_artifact, "resultArtifact"))
    })
  end

  defp remember_gate_verification(_gate), do: :ok

  defp mixed_map_value(map, atom_key, string_key, default \\ nil) do
    case Map.get(map, atom_key) do
      nil -> Map.get(map, string_key, default)
      value -> value
    end
  end

  defp current_timestamp,
    do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp remember_blocked_gate_verification(gates) when is_list(gates) do
    captured_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    source = "symphony:before_handoff_gate"

    remember_resume_verification(%{
      source: source,
      captured_at: captured_at,
      gate_source: source,
      gate_captured_at: captured_at,
      exact_sha: nil,
      gate_status: "blocked",
      gate_check_count: length(gates),
      checks: gates
    })
  end

  defp remember_blocked_gate_verification(_gates), do: :ok

  defp remember_handoff_gate_verification(gates) when is_list(gates),
    do: remember_blocked_gate_verification(gates)

  defp remember_handoff_gate_verification(gate) when is_map(gate),
    do: remember_gate_verification(gate)

  defp remember_handoff_gate_verification(_evidence), do: :ok

  defp remember_resume_verification(evidence) do
    existing = Process.get(@resume_packet_verification_key, %{})

    merged =
      existing
      |> Map.merge(evidence, fn
        :evidence_refs, left, right -> Enum.uniq(List.wrap(left) ++ List.wrap(right))
        _key, _left, right -> right
      end)
      |> truthful_verification_provenance()

    Process.put(@resume_packet_verification_key, merged)
    :ok
  end

  defp truthful_verification_provenance(evidence) do
    gate_source = Map.get(evidence, :gate_source)
    review_source = Map.get(evidence, :review_source)

    cond do
      is_binary(gate_source) and is_binary(review_source) ->
        evidence
        |> Map.put(:source, "symphony:combined_gate_review")
        |> Map.put(
          :captured_at,
          Enum.max([Map.get(evidence, :gate_captured_at), Map.get(evidence, :review_captured_at)])
        )

      is_binary(gate_source) ->
        evidence
        |> Map.put(:source, gate_source)
        |> Map.put(:captured_at, Map.get(evidence, :gate_captured_at))

      is_binary(review_source) ->
        evidence
        |> Map.put(:source, review_source)
        |> Map.put(:captured_at, Map.get(evidence, :review_captured_at))

      true ->
        evidence
    end
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
      case Map.get(request, :handoff_after_review) do
        %{} = handoff_request ->
          enqueue_reviewed_handoff_gate(
            handoff_request,
            review_key,
            review_outcome
          )

        _legacy_request ->
          apply_legacy_reviewed_handoff(request, review_outcome)
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

  defp apply_legacy_reviewed_handoff(request, review_outcome) do
    case apply_deferred_review_handoff(request) do
      nil ->
        {:approved, nil, review_outcome}

      failure_prompt ->
        unavailable = unavailable_review_outcome(review_outcome, :deferred_linear_mutation_failed)
        {:infrastructure_unavailable, failure_prompt, unavailable}
    end
  end

  defp enqueue_reviewed_handoff_gate(handoff_request, review_key, review_outcome) do
    request =
      Map.put(handoff_request, :review_approval, %{
        review_key: review_key,
        reviewed_sha: review_outcome.reviewed_sha
      })

    case store_deferred_handoff_gate(request) do
      result when result in [:ok, :already_pending] ->
        {:approved, nil, review_outcome}

      {:error, reason} ->
        unavailable = unavailable_review_outcome(review_outcome, {:handoff_gate_persistence_failed, reason})
        prompt = pending_gate_error_prompt(request.issue, reason)
        store_handoff_infrastructure_failure(prompt, %{reason: reason})
        {:infrastructure_unavailable, prompt, unavailable}
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

  defp review_opts_with_progress(request, recipient, issue, review_job_id, review_timeout_ms) do
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

    review_opts
    |> Keyword.put(:on_message, on_message)
    |> Keyword.put(:inactivity_timeout_ms, review_timeout_ms)
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

    Keep the issue in In Progress, inspect the Linear status transition, and re-attempt the handoff with Symphony's `linear_issue` tool using `operation: "transition"`.
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
    - A Linear wait may watch only this current ticket's comments or state. Do not park on a follow-up/tracking ticket you created; represent a true prerequisite with Linear's `blocks` relation, while operational reviewer/handoff failures remain active for orchestrator retry.
    - Never call `wait_for` because of local CPU or memory pressure, another validation running, local process or port contention, a desired time delay, or a Symphony-owned handoff job. Symphony polls accepted handoff jobs itself. Continue useful work and run repository validations with the configured per-run worker limit; Symphony intentionally permits validations from multiple agents to overlap.
    """

    handoff_guidance =
      if Keyword.has_key?(opts, :per_repo_before_handoff) or Keyword.has_key?(opts, :per_repo_review_workflow) do
        """
        Symphony handoff requirement:

        - To move this issue from In Progress to In Review or Human Review, use Symphony's `linear_issue` tool with `operation: "transition"` and the target `state`.
        - If that tool returns gate remediation, keep the issue In Progress and address the reported gate failures.
        - Do not construct a raw `linear_graphql` `issueUpdate` mutation or use the native Linear MCP `save_issue` tool for that handoff; neither is the supported typed transition boundary.
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
        # issue to Blocked (via the typed linear_issue transition), and that
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
