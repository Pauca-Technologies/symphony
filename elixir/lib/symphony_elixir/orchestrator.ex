defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{
    AgentBackend,
    AgentFailure,
    AgentRunner,
    Cardinality,
    Config,
    FleetEvent,
    LogFile,
    OrchestratorVersion,
    QuotaCircuitStore,
    RepoConfig,
    RepositoryScheduler,
    Router,
    SessionTranscript,
    StatusDashboard,
    Telemetry,
    TokenAccounting,
    Tracker,
    Workspace,
    WorkspaceGc
  }

  alias SymphonyElixir.Github.ReviewerRequest
  alias SymphonyElixir.Linear.Issue

  # States we treat as "the agent handed off to a human reviewer" — the
  # moment an issue lands in any of these, request the issue owner as PR
  # reviewer. Lowercased here because we normalize before membership-check.
  # Not configurable on purpose: every consumer repo uses the same Linear
  # convention for these state names, so a hardcoded set keeps config flat.
  @review_states_set MapSet.new([
                       "human review",
                       "in review",
                       "merging",
                       "ready to merge"
                     ])

  @doc """
  True when `state_name` is a review/merge state — one where the human is
  the actor and the repo prompt (`WORKFLOW.md`) forbids the agent from
  modifying, merging, or transitioning the PR.

  This is the single source of truth for "the agent's contract in this
  state is to do nothing": it drives both the reviewer-request path
  (`maybe_request_owner_review/1`) and the dispatch guard in
  `candidate_issue?/3`, and is reused by `AgentRunner` to stop an in-flight
  run that lands in one of these states. Case/whitespace-insensitive.
  """
  @spec review_state?(String.t()) :: boolean()
  def review_state?(state_name) when is_binary(state_name) do
    MapSet.member?(@review_states_set, normalize_issue_state(state_name))
  end

  def review_state?(_state_name), do: false

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  @quota_probe_default_ms 300_000
  @quota_probe_max_ms 1_800_000
  @quota_resume_spacing_ms 100
  # Fallback flood guard for issue warnings (routing / cardinality /
  # version gates). The persistent `symphony:routing-warned` label is the
  # primary idempotency marker, but if that label write itself fails
  # (e.g. Linear rate limiting) the marker never lands — and without this
  # the warning would be re-attempted, comment and all, on every poll. A
  # write storm like that can exhaust the tracker's hourly API budget and
  # block dispatch for every issue. So we refuse to re-attempt a warning
  # for the same issue within this cooldown, and stamp the marker BEFORE
  # posting the comment (see `emit_issue_warning/4`). One hour mirrors
  # Linear's rate-limit window.
  @warn_retry_cooldown_ms 3_600_000
  # When a poll comes back rate-limited, ease off the next tick instead of
  # hammering. Bounded so a stale/huge Retry-After can't wedge the loop.
  @default_rate_limit_backoff_ms 60_000
  @max_rate_limit_backoff_ms 300_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @recent_codex_events_limit 200
  @recent_codex_transcript_blocks_limit 80
  # Dead-man's-switch heartbeat (audit §9.10). The orchestrator writes
  # ~/.symphony/heartbeat every 60s with the current poll-loop state. A
  # cron-driven check-heartbeat script reads the file and surfaces a local
  # alert if the timestamp is stale. The interval is short enough that a
  # 5-minute cron poll catches a hang within one cycle.
  @heartbeat_interval_ms 60_000
  @heartbeat_filename "heartbeat"
  # Issue-state-driven worktree GC (T28). One pass at startup, then once
  # every 24h. The GC asks Linear for issues that recently transitioned
  # to a terminal state and runs `git worktree remove` (no --force) on
  # each, preserving any worktree that still holds local changes a
  # human added. See `SymphonyElixir.WorkspaceGc`.
  @workspace_gc_interval_ms 86_400_000
  @empty_codex_totals %{
    input_tokens: 0,
    cached_input_tokens: 0,
    output_tokens: 0,
    reasoning_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      :poll_backoff_until_ms,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      # issue_id => count of consecutive failed/stalled agent runs since the
      # issue last completed a turn normally. Only genuine run failures (crash,
      # stall, handoff-review timeout, spawn failure) bump it; capacity waits
      # and transient tracker errors don't. When it exceeds agent.max_retries we
      # give up and mark the issue Blocked (`:retries_exhausted`). Kept separate
      # from `retry_attempts` (which drives backoff timing) on purpose.
      failure_counts: %{},
      # issue_id => monotonic ms of the last warning attempt. Fallback
      # flood guard for the routing/cardinality/version gates when the
      # persistent `symphony:routing-warned` marker can't be written.
      warned_at: %{},
      codex_totals: nil,
      codex_rate_limits: nil,
      # "backend::account-scope" => provider/account quota circuit. Parked
      # retries remain claimed but have no per-issue timer while unavailable.
      quota_circuits: %{},
      queued: %{}
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()

    quota_circuits = QuotaCircuitStore.load()

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil,
      quota_circuits: quota_circuits,
      claimed: restored_quota_claims(quota_circuits)
    }

    state = arm_all_quota_circuits(state)

    run_terminal_workspace_cleanup()
    state = schedule_tick(state, 0)
    schedule_heartbeat(0)
    schedule_workspace_gc(0)

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    case refresh_runtime_config(state) do
      {:ok, state} ->
        {:noreply, begin_poll_check(state)}

      {:error, reason} ->
        {:noreply, skip_poll_cycle_on_invalid_config(state, reason)}
    end
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    case refresh_runtime_config(state) do
      {:ok, state} ->
        {:noreply, begin_poll_check(state)}

      {:error, reason} ->
        {:noreply, skip_poll_cycle_on_invalid_config(state, reason)}
    end
  end

  def handle_info(:run_poll_cycle, state) do
    case refresh_runtime_config(state) do
      {:ok, state} ->
        state = maybe_dispatch(state)
        state = schedule_tick(state, poll_delay_ms(state))
        state = %{state | poll_check_in_progress: false, poll_backoff_until_ms: nil}

        notify_dashboard()
        {:noreply, state}

      {:error, reason} ->
        {:noreply, skip_poll_cycle_on_invalid_config(state, reason)}
    end
  end

  def handle_info(:write_heartbeat, state) do
    write_heartbeat(state)
    schedule_heartbeat(@heartbeat_interval_ms)
    {:noreply, state}
  end

  def handle_info(:run_workspace_gc, state) do
    unless workspace_gc_disabled?() do
      try do
        WorkspaceGc.run_pass()
      rescue
        error ->
          Logger.warning("WorkspaceGc pass crashed: #{Exception.message(error)}")
      end
    end

    schedule_workspace_gc(@workspace_gc_interval_ms)
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)

        SessionTranscript.finalize(
          Map.get(running_entry, :codex_session_logs, []),
          if(reason == :normal, do: :success, else: :failure)
        )

        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        state =
          case reason do
            :normal ->
              Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

              state
              |> maybe_close_successful_quota_probe(running_entry)
              |> complete_issue(issue_id)
              |> schedule_issue_retry(issue_id, 1, %{
                identifier: running_entry.identifier,
                issue: Map.get(running_entry, :issue),
                delay_type: :continuation,
                backend: Map.get(running_entry, :backend),
                worker_host: Map.get(running_entry, :worker_host),
                workspace_path: Map.get(running_entry, :workspace_path),
                codex_session_logs: Map.get(running_entry, :codex_session_logs, []),
                recent_codex_transcript_blocks: Map.get(running_entry, :recent_codex_transcript_blocks, [])
              })

            _ ->
              failure = failure_from_exit(reason, running_entry)
              next_attempt = next_retry_attempt_from_running(running_entry)

              metadata = %{
                identifier: running_entry.identifier,
                issue: Map.get(running_entry, :issue),
                error: failure_error(reason, running_entry, failure),
                backend: failure.backend || Map.get(running_entry, :backend),
                failure: failure,
                worker_host: Map.get(running_entry, :worker_host),
                workspace_path: Map.get(running_entry, :workspace_path),
                codex_session_logs: Map.get(running_entry, :codex_session_logs, []),
                recent_codex_transcript_blocks: Map.get(running_entry, :recent_codex_transcript_blocks, [])
              }

              Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} failure_class=#{failure.class} reason=#{failure.message}; scheduling policy action")

              handle_typed_run_failure(
                state,
                issue_id,
                next_attempt,
                metadata,
                Map.get(running_entry, :quota_probe) == true
              )
          end

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])
          |> maybe_put_runtime_value(:backend, runtime_info[:backend])
          |> maybe_put_runtime_value(:model, runtime_info[:model])
          |> maybe_put_runtime_value(:reasoning_effort, runtime_info[:reasoning_effort])
          |> maybe_put_runtime_value(:profile, runtime_info[:profile])
          |> maybe_put_runtime_value(:task_type, runtime_info[:task_type])
          |> maybe_put_runtime_value(:routing_confidence, runtime_info[:routing_confidence])
          |> maybe_put_runtime_value(:budget_profile, runtime_info[:budget_profile])
          |> maybe_put_runtime_value(:budget_mode, runtime_info[:budget_mode])
          |> maybe_put_runtime_value(:budget_metrics, runtime_info[:budget_metrics])
          |> maybe_put_runtime_value(:budget_transitions, runtime_info[:budget_transitions])
          |> maybe_put_runtime_value(:repository_id, runtime_info[:repository_id])
          |> maybe_put_runtime_value(:scheduling_paths, runtime_info[:scheduling_paths])
          |> maybe_put_runtime_value(:scheduling_path_source, runtime_info[:scheduling_path_source])
          |> maybe_put_runtime_value(:base_sha, runtime_info[:base_sha])
          |> maybe_put_runtime_value(:base_age_seconds, runtime_info[:base_age_seconds])
          |> maybe_put_runtime_value(:candidate_base_sha, runtime_info[:candidate_base_sha])
          |> maybe_put_runtime_value(:workspace_dirty, runtime_info[:workspace_dirty])

        issue = Map.get(updated_running_entry, :issue, %{})

        Telemetry.emit(:lifecycle, %{
          action: "runtime_resolved",
          issue_id: Map.get(issue, :id),
          issue_identifier: Map.get(issue, :identifier),
          parent_issue_id: Map.get(issue, :parent_id),
          backend: Map.get(updated_running_entry, :backend),
          model: Map.get(updated_running_entry, :model),
          reasoning_effort: Map.get(updated_running_entry, :reasoning_effort),
          worker_host: Map.get(updated_running_entry, :worker_host) || "local"
        })

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:worker_run_failure, issue_id, worker_pid, %AgentFailure{} = failure},
        %{running: running} = state
      )
      when is_binary(issue_id) and is_pid(worker_pid) do
    case Map.get(running, issue_id) do
      %{pid: ^worker_pid} = running_entry ->
        updated = Map.put(running_entry, :run_failure, failure)
        {:noreply, %{state | running: Map.put(running, issue_id, updated)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)
        updated_running_entry = RepositoryScheduler.observe_plan(updated_running_entry, update)
        updated_running_entry = persist_codex_update(updated_running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update, running_entry)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info(
        {:handoff_review_heartbeat, issue_id, worker_pid, review_job_id, %DateTime{} = timestamp},
        %{running: running} = state
      )
      when is_binary(issue_id) and is_pid(worker_pid) and is_integer(review_job_id) do
    case Map.get(running, issue_id) do
      %{
        pid: ^worker_pid,
        lifecycle_state: :handoff_pending_review,
        handoff_review_job_id: ^review_job_id
      } = running_entry ->
        updated_running_entry = Map.put(running_entry, :last_codex_timestamp, timestamp)
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info({:quota_probe_due, circuit_key, timer_token}, state)
      when is_binary(circuit_key) and is_reference(timer_token) do
    state = handle_quota_probe_due(state, circuit_key, timer_token)
    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp transition_agent_lifecycle(
         running_entry,
         :handoff_pending_gate,
         %{gate_job_id: gate_job_id, gate: gate}
       )
       when is_map(running_entry) and is_binary(gate_job_id) and is_map(gate) do
    now = DateTime.utc_now()
    issue_id = running_entry |> Map.get(:issue, %{}) |> Map.get(:id)
    identifier = Map.get(running_entry, :identifier, issue_id)
    previous_state = Map.get(running_entry, :lifecycle_state, :implementing)
    session_id = running_entry_session_id(running_entry)

    lifecycle_started_at =
      if previous_state == :handoff_pending_gate,
        do: Map.get(running_entry, :lifecycle_started_at, now),
        else: now

    Logger.info(
      "Agent lifecycle transition: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} from=#{previous_state} to=handoff_pending_gate gate_job_id=#{gate_job_id} status=#{Map.get(gate, :status)}"
    )

    emit_agent_lifecycle(running_entry, previous_state, :handoff_pending_gate, %{
      gate_job_id: gate_job_id,
      gate_job_identity: Map.get(gate, :exact_hash),
      gate_status: Map.get(gate, :status),
      gate_stage: get_in(gate, [:progress, "stage"]) || get_in(gate, [:progress, :stage])
    })

    running_entry
    |> Map.put(:lifecycle_state, :handoff_pending_gate)
    |> Map.put(:lifecycle_started_at, lifecycle_started_at)
    |> Map.put(:handoff_gate_job_id, gate_job_id)
    |> Map.put(:handoff_gate_state, gate)
  end

  defp transition_agent_lifecycle(
         running_entry,
         :handoff_pending_review,
         %{
           timeout_ms: timeout_ms,
           review_job_id: review_job_id,
           review_key: review_key
         }
       )
       when is_map(running_entry) and is_integer(timeout_ms) and timeout_ms > 0 and
              is_integer(review_job_id) do
    now = DateTime.utc_now()
    issue_id = running_entry |> Map.get(:issue, %{}) |> Map.get(:id)
    identifier = Map.get(running_entry, :identifier, issue_id)
    previous_state = Map.get(running_entry, :lifecycle_state, :implementing)
    session_id = running_entry_session_id(running_entry)

    Logger.info(
      "Agent lifecycle transition: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} from=#{previous_state} to=handoff_pending_review review_job_id=#{review_job_id} review_key=#{inspect(review_key)} timeout_ms=#{timeout_ms}"
    )

    emit_agent_lifecycle(running_entry, previous_state, :handoff_pending_review, %{
      review_job_id: review_job_id,
      gate_job_identity: inspect(review_key),
      timeout_ms: timeout_ms
    })

    running_entry
    |> Map.put(:lifecycle_state, :handoff_pending_review)
    |> Map.put(:lifecycle_started_at, now)
    |> Map.put(:handoff_review_job_id, review_job_id)
    |> Map.put(:handoff_review_key, review_key)
    |> Map.put(:handoff_review_timeout_ms, timeout_ms)
  end

  defp transition_agent_lifecycle(
         %{lifecycle_state: :handoff_pending_gate} = running_entry,
         :implementing,
         metadata
       )
       when is_map(metadata) do
    if Map.get(running_entry, :handoff_gate_job_id) == Map.get(metadata, :gate_job_id) do
      now = DateTime.utc_now()
      issue_id = running_entry |> Map.get(:issue, %{}) |> Map.get(:id)
      identifier = Map.get(running_entry, :identifier, issue_id)
      previous_state = Map.get(running_entry, :lifecycle_state, :implementing)
      outcome = Map.get(metadata, :gate_outcome, :unknown)
      session_id = running_entry_session_id(running_entry)

      Logger.info("Agent lifecycle transition: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} from=#{previous_state} to=implementing gate_outcome=#{outcome}")

      emit_agent_lifecycle(running_entry, previous_state, :implementing, %{
        gate_job_id: Map.get(metadata, :gate_job_id),
        gate_outcome: outcome
      })

      running_entry
      |> Map.drop([:handoff_gate_job_id, :handoff_gate_state])
      |> Map.put(:lifecycle_state, :implementing)
      |> Map.put(:lifecycle_started_at, now)
    else
      running_entry
    end
  end

  defp transition_agent_lifecycle(running_entry, :implementing, %{review_job_id: review_job_id} = metadata)
       when is_map(running_entry) and is_integer(review_job_id) do
    if Map.get(running_entry, :handoff_review_job_id) == review_job_id do
      now = DateTime.utc_now()
      issue_id = running_entry |> Map.get(:issue, %{}) |> Map.get(:id)
      identifier = Map.get(running_entry, :identifier, issue_id)
      previous_state = Map.get(running_entry, :lifecycle_state, :implementing)
      outcome = Map.get(metadata, :review_outcome, :unknown)
      session_id = running_entry_session_id(running_entry)

      Logger.info("Agent lifecycle transition: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} from=#{previous_state} to=implementing review_outcome=#{outcome}")

      emit_agent_lifecycle(running_entry, previous_state, :implementing, %{
        review_job_id: Map.get(metadata, :review_job_id),
        review_outcome: outcome
      })

      running_entry
      |> Map.drop([
        :handoff_review_job_id,
        :handoff_review_key,
        :handoff_review_timeout_ms
      ])
      |> Map.put(:lifecycle_state, :implementing)
      |> Map.put(:lifecycle_started_at, now)
      |> Map.put(:review_state, Map.get(metadata, :review_state))
    else
      running_entry
    end
  end

  defp transition_agent_lifecycle(running_entry, _lifecycle_state, _metadata),
    do: running_entry

  defp emit_agent_lifecycle(running_entry, from, to, details) do
    issue = Map.get(running_entry, :issue, %{})

    Telemetry.emit(:lifecycle, %{
      action: "transition",
      issue_id: Map.get(issue, :id),
      issue_identifier: Map.get(issue, :identifier),
      parent_issue_id: Map.get(issue, :parent_id),
      session_id: Map.get(running_entry, :session_id),
      backend: Map.get(running_entry, :backend),
      from_state: from,
      state: to,
      details: details
    })

    phase =
      case to do
        :handoff_pending_review -> "review"
        :handoff_pending_gate -> "handoff_gate"
        _ -> "implementation"
      end

    Telemetry.emit(:phase, %{issue_identifier: Map.get(issue, :identifier), session_id: Map.get(running_entry, :session_id), phase: phase, action: "transition"})
  end

  defp maybe_dispatch(%State{} = state) do
    state = reconcile_running_issues(state)

    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_candidate_issues(),
         true <- available_slots(state) > 0 do
      choose_issues(issues, state)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Linear project slug missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:rate_limited, retry_after_ms}} ->
        Logger.warning("Linear rate limit hit during poll; backing off next tick. retry_after_ms=#{inspect(retry_after_ms)}")

        arm_poll_backoff(state, retry_after_ms)

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
        state

      false ->
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec repository_schedule_for_test(Issue.t(), map(), map()) :: RepositoryScheduler.decision()
  def repository_schedule_for_test(%Issue{} = issue, repo_config, running) do
    RepositoryScheduler.decide(issue, repo_config, running)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  @doc false
  @spec gate_routing_and_cardinality_for_test(Issue.t(), map(), MapSet.t()) :: term()
  def gate_routing_and_cardinality_for_test(%Issue{} = issue, repo_config, %MapSet{} = active_states) do
    gate_routing_and_cardinality(issue, repo_config, active_states)
  end

  @doc false
  @spec emit_issue_warning_for_test(term(), Issue.t(), String.t(), term()) :: term()
  def emit_issue_warning_for_test(%State{} = state, %Issue{} = issue, body, telemetry) do
    emit_issue_warning(state, issue, body, telemetry)
  end

  @doc false
  @spec ensure_observability_policy_for_test(map(), (-> map())) :: map()
  def ensure_observability_policy_for_test(running_entry, resolver)
      when is_map(running_entry) and is_function(resolver, 0) do
    ensure_observability_policy(running_entry, resolver)
  end

  @doc false
  @spec poll_delay_ms_for_test(term()) :: non_neg_integer()
  def poll_delay_ms_for_test(%State{} = state), do: poll_delay_ms(state)

  @doc false
  @spec arm_poll_backoff_for_test(term(), term()) :: term()
  def arm_poll_backoff_for_test(%State{} = state, retry_after_ms) do
    arm_poll_backoff(state, retry_after_ms)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        maybe_request_owner_review(issue)
        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  # Idempotent on the GitHub side (re-POSTing an already-requested reviewer
  # is a no-op), so we do not persist "we already asked for this" — calling
  # on every poll where the issue sits in a review state is fine.
  defp maybe_request_owner_review(%Issue{state: state_name} = issue) when is_binary(state_name) do
    if review_state?(state_name) do
      mapping = Config.settings!().linear_to_github || []
      ReviewerRequest.request_for_issue(issue, mapping)
    else
      :ok
    end
  end

  defp maybe_request_owner_review(_issue), do: :ok

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier, worker_host)
        end

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id),
            failure_counts: Map.delete(state.failure_counts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    if map_size(state.running) == 0 do
      state
    else
      now = DateTime.utc_now()

      Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
        # UDPE-6952: resolve the stall timeout from the issue's RUNNING backend
        # namespace. `running_entry.backend` is a name string ("codex"/"acp"/
        # "claude_code"), or nil before the backend reports in — nil correctly
        # falls back to codex.
        timeout_ms = Config.backend_stall_timeout_ms(Map.get(running_entry, :backend))
        reconcile_running_issue_timeout(state_acc, issue_id, running_entry, now, timeout_ms)
      end)
    end
  end

  defp reconcile_running_issue_timeout(
         state,
         _issue_id,
         %{lifecycle_state: :handoff_pending_gate},
         _now,
         _implementor_timeout_ms
       ) do
    state
  end

  defp reconcile_running_issue_timeout(
         state,
         issue_id,
         %{lifecycle_state: :handoff_pending_review} = running_entry,
         now,
         _implementor_timeout_ms
       ) do
    restart_timed_out_handoff_review(state, issue_id, running_entry, now)
  end

  defp reconcile_running_issue_timeout(state, issue_id, running_entry, now, timeout_ms) do
    if timeout_ms > 0 do
      restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms)
    else
      state
    end
  end

  defp restart_timed_out_handoff_review(state, issue_id, running_entry, now) do
    timeout_ms = Map.get(running_entry, :handoff_review_timeout_ms)
    elapsed_ms = handoff_review_elapsed_ms(running_entry, now)

    if is_integer(timeout_ms) and timeout_ms > 0 and is_integer(elapsed_ms) and
         elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      Logger.warning(
        "Handoff review timed out: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms} timeout_ms=#{timeout_ms}; clearing pending review and restarting with backoff"
      )

      next_attempt = next_retry_attempt_from_running(running_entry)

      state
      |> terminate_running_issue(issue_id, false)
      |> schedule_failure_retry(issue_id, next_attempt, %{
        identifier: identifier,
        issue: Map.get(running_entry, :issue),
        error: "handoff review timed out after #{elapsed_ms}ms without reviewer activity",
        backend: Map.get(running_entry, :backend),
        failure:
          AgentFailure.classify(:handoff_review_timeout,
            backend: Map.get(running_entry, :backend)
          )
      })
    else
      state
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

      next_attempt = next_retry_attempt_from_running(running_entry)

      state
      |> terminate_running_issue(issue_id, false)
      |> schedule_failure_retry(issue_id, next_attempt, %{
        identifier: identifier,
        issue: Map.get(running_entry, :issue),
        error: "stalled for #{elapsed_ms}ms without codex activity",
        backend: Map.get(running_entry, :backend),
        failure: AgentFailure.classify(:stalled, backend: Map.get(running_entry, :backend))
      })
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    [
      Map.get(running_entry, :last_codex_timestamp),
      Map.get(running_entry, :lifecycle_started_at),
      Map.get(running_entry, :started_at)
    ]
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp handoff_review_elapsed_ms(running_entry, now) do
    running_entry
    |> handoff_review_activity_timestamp()
    |> case do
      %DateTime{} = timestamp -> max(0, DateTime.diff(now, timestamp, :millisecond))
      _ -> nil
    end
  end

  defp handoff_review_activity_timestamp(running_entry) when is_map(running_entry) do
    last_activity_timestamp(running_entry)
  end

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()
    repo_config = load_repo_config_or_default()

    state = %{
      state
      | queued:
          retain_queue_timestamps(
            state.queued,
            issues,
            state,
            active_states,
            terminal_states
          )
    }

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      consider_issue_for_dispatch(issue, state_acc, repo_config, active_states, terminal_states)
    end)
  end

  defp consider_issue_for_dispatch(issue, state, repo_config, active_states, terminal_states) do
    if should_dispatch_issue?(issue, state, active_states, terminal_states) do
      issue
      |> gate_routing_and_cardinality(repo_config, active_states)
      |> apply_gate_decision(state, issue, repo_config)
    else
      state
    end
  end

  defp apply_gate_decision(:pass, state, issue, repo_config) do
    case RepositoryScheduler.decide(issue, repo_config, state.running) do
      {:allow, decision} ->
        state
        |> allow_scheduling_dispatch(issue, decision)
        |> dispatch_issue(issue)

      {:queue, decision} ->
        queue_scheduling_decision(state, issue, decision)
    end
  end

  defp apply_gate_decision(:skip_silent, state, _issue, _repo_config), do: state

  defp apply_gate_decision({:skip_warn, body, telemetry}, state, issue, _repo_config) do
    emit_issue_warning(state, issue, body, telemetry)
  end

  defp queue_scheduling_decision(%State{} = state, %Issue{} = issue, decision) do
    now_ms = System.monotonic_time(:millisecond)
    previous = Map.get(state.queued, issue.id)
    queued_at_ms = (previous && previous.queued_at_ms) || now_ms

    entry =
      decision
      |> Map.merge(%{
        issue_id: issue.id,
        identifier: issue.identifier,
        title: issue.title,
        state: issue.state,
        priority: issue.priority,
        priority_rank: priority_rank(issue.priority),
        created_at_key: issue_created_at_sort_key(issue),
        queued_at_ms: queued_at_ms
      })

    if is_nil(previous) or queue_fingerprint(previous) != queue_fingerprint(entry) do
      emit_scheduling_decision(issue, entry, "queue")
    end

    %{state | queued: Map.put(state.queued, issue.id, entry)}
  end

  defp emit_scheduling_decision(%Issue{} = issue, decision, action) do
    Telemetry.emit(:scheduling, %{
      action: action,
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      repository: decision.repository_id || "default",
      reason: decision.reason,
      policy: decision.policy,
      predicted_paths: decision.predicted_paths,
      overlap_paths: decision.overlap_paths,
      overlap_score: decision.overlap_score,
      suggested_order: decision.suggested_order,
      suggested_order_omitted: decision.suggested_order_omitted,
      override: decision.override,
      max_concurrent: decision.max_concurrent,
      queue_time_ms: Map.get(decision, :queue_time_ms, 0)
    })
  end

  defp queue_fingerprint(entry) do
    {entry.reason, entry.overlap_paths, entry.suggested_order, entry.suggested_order_omitted, entry.override}
  end

  defp drop_queued(%State{} = state, issue_id), do: %{state | queued: Map.delete(state.queued, issue_id)}

  defp maybe_add_queue_time(decision, %{queued_at_ms: queued_at_ms}) when is_integer(queued_at_ms) do
    Map.put(decision, :queue_time_ms, max(0, System.monotonic_time(:millisecond) - queued_at_ms))
  end

  defp maybe_add_queue_time(decision, _entry), do: decision

  defp allow_scheduling_dispatch(%State{} = state, %Issue{} = issue, decision) do
    decision = maybe_add_queue_time(decision, state.queued[issue.id])
    emit_scheduling_decision(issue, decision, "dispatch")
    drop_queued(state, issue.id)
  end

  defp retain_queue_timestamps(queued, issues, state, active_states, terminal_states) do
    eligible_ids =
      issues
      |> Enum.filter(fn
        %Issue{} = issue ->
          candidate_issue?(issue, active_states, terminal_states) and
            !issue_blocked_by_non_terminal?(issue, terminal_states) and
            (!MapSet.member?(state.claimed, issue.id) or Map.has_key?(state.retry_attempts, issue.id)) and
            !Map.has_key?(state.running, issue.id)

        _other ->
          false
      end)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    Map.filter(queued, fn {issue_id, _entry} -> MapSet.member?(eligible_ids, issue_id) end)
  end

  defp repository_id(%Issue{} = issue) do
    case RepoConfig.load() do
      {:ok, config} ->
        case RepoConfig.match_repo(config, issue.labels) do
          nil -> nil
          repo -> repo.id
        end

      _error ->
        nil
    end
  end

  defp scheduling_paths(%Issue{} = issue) do
    case RepoConfig.load() do
      {:ok, config} -> RepositoryScheduler.predicted_paths(issue, RepoConfig.match_repo(config, issue.labels))
      _error -> RepositoryScheduler.predicted_paths(issue, nil)
    end
  end

  defp load_repo_config_or_default do
    case RepoConfig.load() do
      {:ok, config} ->
        config

      {:error, reason} ->
        Logger.warning("Failed to load ~/.symphony/repos.yaml; using legacy single-repo mode: #{inspect(reason)}")
        RepoConfig.empty()
    end
  end

  # Apply the multi-repo routing and cardinality gates before dispatch.
  # When repos.yaml is unconfigured (`source == :default`), we run in
  # legacy single-repo mode and skip both gates — preserves backwards
  # compat for hosts that have not yet migrated to the multi-repo driver.
  #
  # Each gate is a *pure decision*: it returns `:pass`, `:skip_silent`, or
  # `{:skip_warn, body, {telemetry_event, meta}}`. Emitting the warning
  # (the only side effect) is centralized in `emit_issue_warning/4` so the
  # flood guard is applied uniformly. `with :pass <- ...` short-circuits on
  # the first gate that skips.
  defp gate_routing_and_cardinality(%Issue{} = _issue, %{source: :default}, _active_states), do: :pass

  defp gate_routing_and_cardinality(%Issue{} = issue, %{} = repo_config, %MapSet{} = active_states) do
    with :pass <- gate_orchestrator_version(issue),
         :pass <- gate_routing(issue, repo_config, active_states) do
      gate_cardinality(issue, repo_config)
    end
  end

  defp gate_orchestrator_version(%Issue{} = issue) do
    case OrchestratorVersion.check() do
      :ok ->
        :pass

      {:incompatible, requirement, current_version} ->
        body = OrchestratorVersion.incompatibility_comment(requirement, current_version)

        {:skip_warn, body,
         {:version_skip,
          %{
            issue_id: issue.id,
            identifier: issue.identifier,
            requirement: requirement,
            current: current_version
          }}}

      {:invalid_requirement, requirement} ->
        Logger.error("Ignoring invalid orchestrator_version_required in WORKFLOW.md: #{inspect(requirement)}")

        :pass
    end
  end

  defp gate_routing(%Issue{} = issue, %{} = repo_config, %MapSet{} = active_states) do
    case Router.route(issue, repo_config) do
      {:ok, _repo} ->
        :pass

      {:skip, :legacy_mode} ->
        :pass

      {:skip, reason, _ctx} = decision ->
        if Router.should_warn?(decision, issue, active_states) do
          body = Router.warning_comment(issue, decision, repo_config)

          {:skip_warn, body, {:routing_skip, %{issue_id: issue.id, identifier: issue.identifier, reason: Atom.to_string(reason)}}}
        else
          :skip_silent
        end
    end
  end

  defp gate_cardinality(%Issue{} = issue, %{} = repo_config) do
    case Cardinality.check(issue, repo_config) do
      :ok ->
        :pass

      {:not_enforced, _} ->
        :pass

      {:violations, violations} ->
        body = Cardinality.violation_comment(issue, violations)

        {:skip_warn, body,
         {:cardinality_skip,
          %{
            issue_id: issue.id,
            identifier: issue.identifier,
            violations: Enum.map(violations, &Atom.to_string/1)
          }}}
    end
  end

  # Flood-safe emitter shared by every gate warning. Two guards stop a
  # warning from becoming a per-poll write storm when the marker write
  # fails (the incident that motivated this):
  #
  #   1. Persistent — the `symphony:routing-warned` label. Once it lands,
  #      `Router.already_warned?/1` suppresses the warning permanently,
  #      across restarts.
  #   2. In-memory fallback — a per-issue cooldown (`warned_at`). If the
  #      label write keeps failing (e.g. Linear rate limiting) the marker
  #      never lands, so this bounds re-attempts to once per cooldown
  #      instead of once per 15s tick.
  #
  # The marker is stamped BEFORE the comment. If the stamp fails we post
  # nothing and record the attempt, so a partial failure can never leave
  # an un-suppressed comment that re-fires and re-comments next poll.
  defp emit_issue_warning(%State{} = state, %Issue{} = issue, body, {event, meta})
       when is_binary(body) do
    cond do
      Router.already_warned?(issue) ->
        state

      within_warn_cooldown?(state, issue) ->
        state

      true ->
        state = record_warn_attempt(state, issue)

        case Tracker.add_label(issue.id, Router.routing_warned_label()) do
          :ok ->
            _ = Tracker.create_comment(issue.id, body)
            Telemetry.emit(event, meta)
            Logger.info("Issue warning emitted (#{event}): #{issue_context(issue)}; routing-warned label applied")
            state

          {:error, reason} ->
            Logger.warning("Deferring #{event} warning for #{issue_context(issue)}; marker label write failed: #{inspect(reason)}")

            state
        end
    end
  end

  defp within_warn_cooldown?(%State{warned_at: warned_at}, %Issue{id: issue_id})
       when is_map(warned_at) and is_binary(issue_id) do
    case Map.get(warned_at, issue_id) do
      last when is_integer(last) ->
        System.monotonic_time(:millisecond) - last < warn_retry_cooldown_ms()

      _ ->
        false
    end
  end

  defp within_warn_cooldown?(_state, _issue), do: false

  defp record_warn_attempt(%State{warned_at: warned_at} = state, %Issue{id: issue_id})
       when is_map(warned_at) and is_binary(issue_id) do
    %{state | warned_at: Map.put(warned_at, issue_id, System.monotonic_time(:millisecond))}
  end

  defp record_warn_attempt(state, _issue), do: state

  defp warn_retry_cooldown_ms do
    Application.get_env(:symphony_elixir, :warn_retry_cooldown_ms, @warn_retry_cooldown_ms)
  end

  # Rate-limit backoff for the poll loop. `arm_poll_backoff/2` stamps a
  # deadline on the state; `poll_delay_ms/1` extends the next tick to
  # honor it (clamped to at least the normal interval). The deadline is a
  # one-shot: `run_poll_cycle` clears it after scheduling, so a recovered
  # budget resumes the normal cadence immediately.
  defp arm_poll_backoff(%State{} = state, retry_after_ms) do
    backoff = rate_limit_backoff_ms(retry_after_ms)
    %{state | poll_backoff_until_ms: System.monotonic_time(:millisecond) + backoff}
  end

  defp rate_limit_backoff_ms(retry_after_ms) when is_integer(retry_after_ms) and retry_after_ms > 0 do
    retry_after_ms
    |> max(@default_rate_limit_backoff_ms)
    |> min(@max_rate_limit_backoff_ms)
  end

  defp rate_limit_backoff_ms(_retry_after_ms), do: @default_rate_limit_backoff_ms

  defp poll_delay_ms(%State{poll_backoff_until_ms: until, poll_interval_ms: interval})
       when is_integer(until) do
    max(interval, until - System.monotonic_time(:millisecond))
  end

  defp poll_delay_ms(%State{poll_interval_ms: interval}), do: interval

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    issues
    |> Enum.sort_by(fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
    |> dependency_stable_sort()
  end

  defp dependency_stable_sort(issues) do
    ids =
      MapSet.new(
        Enum.flat_map(issues, fn
          %Issue{id: id} when is_binary(id) -> [id]
          _ -> []
        end)
      )

    {sorted, remaining} =
      Enum.reduce_while(1..max(length(issues), 1), {[], issues}, fn _pass, {sorted, remaining} ->
        sorted_ids = MapSet.new(Enum.map(sorted, & &1.id))

        {ready, blocked} =
          Enum.split_with(remaining, fn issue ->
            issue
            |> Map.get(:blocked_by, [])
            |> Enum.map(&Map.get(&1, :id))
            |> Enum.filter(&MapSet.member?(ids, &1))
            |> Enum.all?(&MapSet.member?(sorted_ids, &1))
          end)

        if ready == [], do: {:halt, {sorted, remaining}}, else: {:cont, {sorted ++ ready, blocked}}
      end)

    sorted ++ remaining
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !issue_blocked_by_non_terminal?(issue, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      backend_dispatch_available?(state, predicted_backend(issue)) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(state)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    # Never dispatch an implementor to a review/merge state (Human
    # Review, In Review, Merging, Ready to Merge). In those states the
    # human is the actor and the repo prompt (WORKFLOW.md) forbids the
    # agent from modifying/merging/transitioning the PR — humans merge.
    # Symphony has no merge logic of its own, so an agent dispatched here
    # can only no-op every turn: AgentRunner.do_run_codex_turns keeps
    # continuing while the tracker state stays "active", exhausts
    # agent.max_turns, and mark_blocked_on_giveup(:max_turns_exhausted)
    # demotes a human-approved, merge-ready issue to Blocked after ~40
    # wasted turns (UDPE-6950). This guard is authoritative regardless of
    # tracker.active_states: even if a host's config lists such a state as
    # active (the historical misconfiguration this fixes), we refuse to
    # pick it up as implementor work. These states are instead serviced by
    # the reviewer-request path (maybe_request_owner_review/1), which asks
    # the issue owner to review the PR and never spawns an agent.
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states) and
      !review_state?(state_name)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp issue_blocked_by_non_terminal?(%Issue{blocked_by: blockers}, terminal_states)
       when is_list(blockers) do
    Enum.any?(blockers, fn
      %{state: blocker_state} when is_binary(blocker_state) ->
        !terminal_issue_state?(blocker_state, terminal_states)

      _ ->
        true
    end)
  end

  defp issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
    {_outcome, state} = dispatch_issue_outcome(state, issue, attempt, preferred_worker_host)
    state
  end

  # Revalidates `issue` against the tracker immediately before dispatch and
  # reports the outcome so callers can react to a skip/error.
  #
  # The fresh-poll path (`choose_issues`) calls `dispatch_issue/4` and discards
  # the tag: the issue was never claimed there, so a skipped/failed
  # revalidation is a harmless no-op. The retry/continuation path
  # (`handle_active_retry`) calls this directly because it holds the issue's
  # claim and has already consumed its retry entry — a silently-dropped
  # skip/error there would strand the claim in `state.claimed` until the next
  # restart (every poll is gated on `!MapSet.member?(claimed, issue.id)`), so it
  # must release the claim or reschedule. See `dispatch_active_retry/4`.
  defp dispatch_issue_outcome(%State{} = state, issue, attempt, preferred_worker_host) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issue_states_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        {:dispatched, do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host)}

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        {:skip, state}

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        {:skip, state}

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        {:error, state}
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host) do
    recipient = self()
    backend = predicted_backend(issue)

    case select_worker_host_for_backend(state, preferred_worker_host, backend, issue.id) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host)
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host) do
    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           AgentRunner.run(issue, recipient, attempt: attempt, worker_host: worker_host)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            worker_host: worker_host,
            workspace_path: nil,
            backend: predicted_backend(issue),
            model: nil,
            reasoning_effort: nil,
            profile: nil,
            task_type: nil,
            routing_confidence: nil,
            budget_profile: nil,
            budget_mode: nil,
            budget_metrics: nil,
            budget_transitions: [],
            repository_id: repository_id(issue),
            scheduling_paths: scheduling_paths(issue),
            scheduling_path_source: "metadata",
            base_sha: nil,
            base_age_seconds: nil,
            candidate_base_sha: nil,
            workspace_dirty: nil,
            session_id: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            recent_codex_events: [],
            recent_codex_transcript_blocks: [],
            codex_session_logs: [],
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            codex_thread_token_high_waters: %{},
            observability_policy: Config.observability_settings(),
            codex_context_tokens: 0,
            codex_context_window: nil,
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            quota_probe:
              quota_probe_issue?(
                state,
                predicted_backend(issue),
                worker_host,
                issue.id
              ),
            lifecycle_state: :implementing,
            lifecycle_started_at: DateTime.utc_now(),
            started_at: DateTime.utc_now()
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_failure_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          issue: issue,
          error: "failed to spawn agent: #{inspect(reason)}",
          backend: predicted_backend(issue),
          failure: AgentFailure.classify({:spawn_failed, reason}, backend: predicted_backend(issue)),
          worker_host: worker_host
        })
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    # A normal turn completion is the "made progress" signal that resets the
    # consecutive-failure count, so only genuine stuck loops reach max_retries.
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        failure_counts: Map.delete(state.failure_counts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = metadata[:delay_ms_override] || retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    title = pick_retry_title(previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    backend = metadata[:backend] || Map.get(previous_retry, :backend)

    failure_class =
      metadata[:failure_class] || retry_failure_class(metadata[:failure]) ||
        Map.get(previous_retry, :failure_class)

    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    codex_session_logs = pick_retry_codex_session_logs(previous_retry, metadata)
    recent_codex_transcript_blocks = pick_retry_codex_transcript_blocks(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            title: title,
            error: error,
            backend: backend,
            failure_class: failure_class,
            worker_host: worker_host,
            workspace_path: workspace_path,
            codex_session_logs: codex_session_logs,
            recent_codex_transcript_blocks: recent_codex_transcript_blocks
          })
    }
    |> emit_retry_policy(issue_id, metadata, :scheduled, next_attempt, delay_ms)
  end

  # Schedule a retry for a *genuine* agent-run failure (crash, stall,
  # handoff-review timeout, spawn failure), counting it against the
  # `agent.max_retries` cap. Once an issue accumulates more consecutive
  # failures than the cap, give up: mark it Blocked (`:retries_exhausted`),
  # same terminal treatment as max-turns exhaustion. Capacity waits and
  # transient tracker/refresh errors call `schedule_issue_retry` directly and
  # never count here, so backpressure and infra blips can't block an issue.
  defp schedule_failure_retry(%State{} = state, issue_id, next_attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    {failures, state} = bump_failure_count(state, issue_id)
    max_retries = max_retries_setting()

    if is_integer(max_retries) and max_retries > 0 and failures > max_retries do
      give_up_retries_exhausted(state, issue_id, failures - 1, max_retries, metadata)
    else
      schedule_issue_retry(state, issue_id, next_attempt, metadata)
    end
  end

  defp retry_failure_class(%AgentFailure{class: class}), do: class
  defp retry_failure_class(_failure), do: nil

  defp give_up_retries_exhausted(%State{} = state, issue_id, retries, max_retries, metadata) do
    identifier = metadata[:identifier] || issue_id

    Logger.warning(
      "Retries exhausted for issue_id=#{issue_id} issue_identifier=#{identifier} after #{retries} retries (max_retries=#{max_retries}); marking Blocked with :retries_exhausted and releasing claim"
    )

    spawn_retries_exhausted_block(giveup_issue(metadata, issue_id, identifier), retries, max_retries, metadata)

    state
    |> drop_retry_attempt(issue_id)
    |> release_issue_claim(issue_id)
  end

  # Mark the issue Blocked off the GenServer loop: the Linear writes are
  # network I/O and best-effort, so they must not block dispatch. Reuses the
  # same give-up path as max-turns exhaustion (Blocked + needs-human-input +
  # one comment), keyed on the `:retries_exhausted` reason.
  defp spawn_retries_exhausted_block(%Issue{} = issue, retries, max_retries, metadata) do
    context = %{
      reason: :retries_exhausted,
      retries: retries,
      max_retries: max_retries,
      workspace: metadata[:workspace_path],
      error: metadata[:error]
    }

    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           AgentRunner.mark_blocked_on_giveup(issue, context)
         end) do
      {:ok, _pid} ->
        :ok

      other ->
        Logger.warning("Failed to spawn retries-exhausted Blocked transition for #{issue_context(issue)}: #{inspect(other)}")
        # Fall back to a synchronous best-effort mark so the give-up isn't lost.
        AgentRunner.mark_blocked_on_giveup(issue, context)
    end
  end

  defp giveup_issue(metadata, issue_id, identifier) when is_map(metadata) do
    case metadata[:issue] do
      %Issue{} = issue -> issue
      _ -> %Issue{id: issue_id, identifier: identifier, labels: []}
    end
  end

  defp bump_failure_count(%State{failure_counts: failure_counts} = state, issue_id) do
    count = Map.get(failure_counts, issue_id, 0) + 1
    {count, %{state | failure_counts: Map.put(failure_counts, issue_id, count)}}
  end

  # Cancel any pending retry timer for the issue and drop its retry entry, so a
  # give-up leaves nothing scheduled to re-dispatch it.
  defp drop_retry_attempt(%State{retry_attempts: retry_attempts} = state, issue_id) do
    case Map.get(retry_attempts, issue_id) do
      %{timer_ref: ref} when is_reference(ref) -> Process.cancel_timer(ref)
      _ -> :ok
    end

    %{state | retry_attempts: Map.delete(retry_attempts, issue_id)}
  end

  defp max_retries_setting do
    Config.settings!().agent.max_retries
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          backend: Map.get(retry_entry, :backend),
          failure_class: Map.get(retry_entry, :failure_class),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          codex_session_logs: Map.get(retry_entry, :codex_session_logs, []),
          recent_codex_transcript_blocks: Map.get(retry_entry, :recent_codex_transcript_blocks, [])
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue.identifier, metadata[:worker_host])
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_identifier, _worker_host), do: :ok

  defp run_terminal_workspace_cleanup do
    if multi_repo_configured?() do
      # In multi-repo mode (T24/T27), the issue-state-driven WorkspaceGc
      # (T28) owns terminal-workspace cleanup — it uses a non-forcing
      # `git worktree remove` to preserve any uncommitted work a human
      # added. This legacy startup path uses `File.rm_rf` underneath,
      # which is destructive, AND its underlying tracker query
      # (`fetch_issues_by_states/1`) requires `project_slug` and so
      # always fails under multi-repo. Skip silently.
      :ok
    else
      case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
        {:ok, issues} ->
          Enum.each(issues, &cleanup_terminal_issue_workspace/1)

        {:error, reason} ->
          Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
      end
    end
  end

  defp cleanup_terminal_issue_workspace(%Issue{identifier: identifier}) when is_binary(identifier) do
    cleanup_issue_workspace(identifier)
  end

  defp cleanup_terminal_issue_workspace(_issue), do: :ok

  defp multi_repo_configured? do
    case RepoConfig.load() do
      {:ok, %{linear: %{team_id: team_id}}} when is_binary(team_id) -> true
      _ -> false
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if backend_quota_blocked?(
         state,
         retry_backend(metadata, issue),
         metadata[:worker_host]
       ) do
      Logger.info("Parking retry while backend quota circuit is open: #{issue_context(issue)} backend=#{retry_backend(metadata, issue)}")

      metadata = Map.put(metadata, :issue, issue)

      state =
        state
        |> emit_retry_policy(issue.id, metadata, :suppressed, attempt, nil)
        |> park_issue_retry(issue.id, attempt, metadata)

      {:noreply, state}
    else
      do_handle_active_retry(state, issue, attempt, metadata)
    end
  end

  defp do_handle_active_retry(state, issue, attempt, metadata) do
    scheduling = RepositoryScheduler.decide(issue, load_repo_config_or_default(), state.running)

    cond do
      !retry_candidate_issue?(issue, terminal_state_set()) ->
        {:noreply, release_issue_claim(state, issue.id)}

      match?({:queue, _decision}, scheduling) ->
        {:queue, decision} = scheduling
        queued_state = queue_scheduling_decision(state, issue, decision)
        schedule_repository_retry(queued_state, issue, attempt, metadata, decision.reason)

      match?({:allow, _decision}, scheduling) and dispatch_slots_available?(issue, state) and
          worker_slots_available?(state, metadata[:worker_host]) ->
        {:allow, decision} = scheduling

        state
        |> allow_scheduling_dispatch(issue, decision)
        |> dispatch_active_retry(issue, attempt, metadata)

      true ->
        Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")
        schedule_repository_retry(state, issue, attempt, metadata, "no available orchestrator slots")
    end
  end

  defp schedule_repository_retry(state, issue, attempt, metadata, reason) do
    {:noreply,
     schedule_issue_retry(
       state,
       issue.id,
       attempt + 1,
       Map.merge(metadata, %{identifier: issue.identifier, error: reason})
     )}
  end

  # The issue's claim is held here and its retry entry has already been popped,
  # so every dispatch outcome must leave it tracked somewhere or it strands in
  # `state.claimed` until restart:
  #
  #   * `:dispatched` re-enters `running` (or reschedules on spawn failure) — keep state as-is.
  #   * `:skip` — the issue is gone or no longer a candidate at revalidation
  #     time; release the claim so a later poll can pick it up if it requalifies.
  #   * `:error` — a transient tracker-refresh failure; keep the claim and
  #     reschedule so the continuation check isn't lost.
  defp dispatch_active_retry(state, issue, attempt, metadata) do
    case dispatch_issue_outcome(state, issue, attempt, metadata[:worker_host]) do
      {:dispatched, state} ->
        {:noreply, state}

      {:skip, state} ->
        Logger.info("Releasing claim after dispatch revalidation skip: #{issue_context(issue)}")
        {:noreply, release_issue_claim(state, issue.id)}

      {:error, state} ->
        {:noreply,
         schedule_issue_retry(
           state,
           issue.id,
           attempt + 1,
           Map.merge(metadata, %{
             identifier: issue.identifier,
             error: "issue refresh failed during retry dispatch"
           })
         )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    # Releasing the claim means we're done working the issue for now (gone,
    # terminal, left active states, or gave up), so drop its failure count too.
    %{
      state
      | claimed: MapSet.delete(state.claimed, issue_id),
        queued: Map.delete(state.queued, issue_id),
        failure_counts: Map.delete(state.failure_counts, issue_id)
    }
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_title(previous_retry, metadata) do
    metadata[:title] || title_from_issue(metadata[:issue]) || Map.get(previous_retry, :title)
  end

  defp title_from_issue(%Issue{title: title}) when is_binary(title), do: title
  defp title_from_issue(_issue), do: nil

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp pick_retry_codex_session_logs(previous_retry, metadata) do
    metadata[:codex_session_logs] || Map.get(previous_retry, :codex_session_logs) || []
  end

  defp pick_retry_codex_transcript_blocks(previous_retry, metadata) do
    metadata[:recent_codex_transcript_blocks] ||
      Map.get(previous_retry, :recent_codex_transcript_blocks) ||
      []
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp select_worker_host_for_backend(%State{} = state, preferred_worker_host, backend, issue_id) do
    hosts = Config.settings!().worker.ssh_hosts
    select_worker_host_for_backend(state, preferred_worker_host, backend, issue_id, hosts)
  end

  defp select_worker_host_for_backend(state, _preferred_worker_host, backend, issue_id, []) do
    if backend_quota_dispatch_blocked?(state, backend, nil, issue_id),
      do: :no_worker_capacity,
      else: nil
  end

  defp select_worker_host_for_backend(state, preferred_worker_host, backend, issue_id, hosts)
       when is_binary(preferred_worker_host) do
    if preferred_worker_host in hosts and
         worker_host_slots_available?(state, preferred_worker_host) and
         !backend_quota_dispatch_blocked?(state, backend, preferred_worker_host, issue_id) do
      preferred_worker_host
    else
      :no_worker_capacity
    end
  end

  defp select_worker_host_for_backend(state, _preferred_worker_host, backend, issue_id, hosts) do
    hosts
    |> Enum.filter(fn host ->
      worker_host_slots_available?(state, host) and
        !backend_quota_dispatch_blocked?(state, backend, host, issue_id)
    end)
    |> case do
      [] -> :no_worker_capacity
      candidates -> least_loaded_worker_host(state, candidates)
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(
        {:agent_lifecycle, issue_id, lifecycle_state, metadata},
        {worker_pid, _tag},
        %{running: running} = state
      )
      when is_binary(issue_id) and is_atom(lifecycle_state) and is_map(metadata) do
    case Map.get(running, issue_id) do
      %{pid: ^worker_pid} = running_entry ->
        updated_running_entry =
          transition_agent_lifecycle(running_entry, lifecycle_state, metadata)

        notify_dashboard()

        {:reply, :ok, %{state | running: Map.put(running, issue_id, updated_running_entry)}}

      _ ->
        {:reply, :stale_worker, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    # Non-raising on a transiently-invalid config: keep the last-good runtime
    # values so a dashboard poll can't crash the orchestrator either (UDPE-6990).
    state =
      case refresh_runtime_config(state) do
        {:ok, refreshed_state} -> refreshed_state
        {:error, _reason} -> state
      end

    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          title: metadata.issue.title,
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          backend: Map.get(metadata, :backend),
          model: Map.get(metadata, :model),
          reasoning_effort: Map.get(metadata, :reasoning_effort),
          profile: Map.get(metadata, :profile),
          task_type: Map.get(metadata, :task_type),
          routing_confidence: Map.get(metadata, :routing_confidence),
          budget_profile: Map.get(metadata, :budget_profile),
          budget_mode: Map.get(metadata, :budget_mode),
          budget_metrics: Map.get(metadata, :budget_metrics),
          budget_transitions: Map.get(metadata, :budget_transitions, []),
          repository_id: Map.get(metadata, :repository_id),
          scheduling_paths: Map.get(metadata, :scheduling_paths, []),
          scheduling_path_source: Map.get(metadata, :scheduling_path_source),
          base_sha: Map.get(metadata, :base_sha),
          base_age_seconds: Map.get(metadata, :base_age_seconds),
          candidate_base_sha: Map.get(metadata, :candidate_base_sha),
          workspace_dirty: Map.get(metadata, :workspace_dirty),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          codex_context_tokens: Map.get(metadata, :codex_context_tokens, 0),
          codex_context_window: Map.get(metadata, :codex_context_window),
          turn_count: Map.get(metadata, :turn_count, 0),
          lifecycle_state: Map.get(metadata, :lifecycle_state, :implementing),
          lifecycle_started_at: Map.get(metadata, :lifecycle_started_at),
          handoff_gate: handoff_gate_snapshot(metadata, now),
          review_state: Map.get(metadata, :review_state),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          recent_codex_events: Map.get(metadata, :recent_codex_events, []),
          recent_codex_transcript_blocks: Map.get(metadata, :recent_codex_transcript_blocks, []),
          codex_session_logs: Map.get(metadata, :codex_session_logs, []),
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          status: :scheduled,
          identifier: Map.get(retry, :identifier),
          title: Map.get(retry, :title),
          error: Map.get(retry, :error),
          backend: Map.get(retry, :backend),
          failure_class: Map.get(retry, :failure_class),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path),
          codex_session_logs: Map.get(retry, :codex_session_logs, []),
          recent_codex_transcript_blocks: Map.get(retry, :recent_codex_transcript_blocks, [])
        }
      end)

    parked = quota_parked_snapshot(state.quota_circuits, now)

    queued =
      state.queued
      |> Map.values()
      |> Enum.map(fn entry ->
        Map.put(entry, :queue_time_ms, max(0, now_ms - entry.queued_at_ms))
      end)
      |> Enum.sort_by(&{&1.priority_rank, &1.created_at_key, &1.identifier})

    {:reply,
     %{
       running: running,
       queued: queued,
       retrying: retrying ++ parked,
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       quota_circuits: quota_circuit_snapshot(state.quota_circuits, now),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    running_entry = ensure_observability_policy(running_entry, &Config.observability_settings/0)
    codex_message = summarize_codex_update(update)
    resolved_session_id = session_id_for_update(running_entry.session_id, update)
    parent_thread_id = parent_thread_from_session_id(resolved_session_id) || resolved_session_id

    {thread_high_waters, token_observation} =
      TokenAccounting.observe(
        Map.get(running_entry, :codex_thread_token_high_waters, %{}),
        update,
        parent_thread_id
      )

    token_delta = token_delta_from_observation(token_observation)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    turn_count = Map.get(running_entry, :turn_count, 0)
    {context_tokens, context_window} = extract_main_context(update, parent_thread_id)
    prev_context_tokens = Map.get(running_entry, :codex_context_tokens, 0)
    prev_context_window = Map.get(running_entry, :codex_context_window)

    updated_entry =
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: codex_message,
        session_id: resolved_session_id,
        model: model_for_update(Map.get(running_entry, :model), update),
        reasoning_effort: reasoning_effort_for_update(Map.get(running_entry, :reasoning_effort), update),
        last_codex_event: event,
        recent_codex_events: append_recent_codex_event(Map.get(running_entry, :recent_codex_events, []), codex_message),
        recent_codex_transcript_blocks:
          append_recent_codex_transcript_block(
            Map.get(running_entry, :recent_codex_transcript_blocks, []),
            transcript_block_for_update(update, parent_thread_id)
          ),
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_last_reported_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_last_reported_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_thread_token_high_waters: thread_high_waters,
        codex_context_tokens: positive_or_keep(context_tokens, prev_context_tokens),
        codex_context_window: positive_or_keep(context_window, prev_context_window),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      })
      |> FleetEvent.observe(update, token_observation)

    {updated_entry, token_delta}
  end

  defp token_delta_from_observation(nil) do
    %{
      input_tokens: 0,
      cached_input_tokens: 0,
      output_tokens: 0,
      reasoning_tokens: 0,
      total_tokens: 0
    }
  end

  defp token_delta_from_observation(%{accepted_delta: delta}) do
    %{
      input_tokens: delta.input_tokens,
      cached_input_tokens: delta.cached_input_tokens,
      output_tokens: delta.output_tokens,
      reasoning_tokens: delta.reasoning_tokens,
      total_tokens: delta.total_tokens
    }
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  # An agent that reports its real model on the wire (e.g. Claude Code's
  # `system/init`) carries it on the `:session_started` event; prefer that over
  # the configured model already recorded from `:worker_runtime_info`.
  defp model_for_update(_existing, %{model: model}) when is_binary(model) and model != "",
    do: model

  defp model_for_update(existing, _update), do: existing

  defp reasoning_effort_for_update(_existing, %{reasoning_effort: effort})
       when is_binary(effort) and effort != "",
       do: effort

  defp reasoning_effort_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: summarized_codex_message(update),
      timestamp: update[:timestamp]
    }
  end

  defp append_recent_codex_event(events, event) when is_list(events) and is_map(event) do
    events
    |> Kernel.++([event])
    |> Enum.take(-@recent_codex_events_limit)
  end

  defp append_recent_codex_event(_events, event) when is_map(event), do: [event]

  defp append_recent_codex_transcript_block(blocks, nil) when is_list(blocks), do: blocks

  defp append_recent_codex_transcript_block(blocks, updates)
       when is_list(blocks) and is_list(updates) do
    Enum.reduce(updates, blocks, fn block, acc ->
      append_recent_codex_transcript_block(acc, block)
    end)
  end

  # ACP tool/output blocks carry a `tool_call_id`. ACP resends the cumulative
  # state of a tool call on every `tool_call_update`, so replace the matching
  # block in place (keeping its position and original timestamp) instead of
  # appending a duplicate — otherwise arguments never fill in and cumulative
  # output is concatenated into itself.
  defp append_recent_codex_transcript_block(blocks, %{kind: kind, tool_call_id: id} = block)
       when is_list(blocks) and is_binary(id) and kind in ["tool", "output"] do
    blocks
    |> upsert_keyed_transcript_block(kind, id, block)
    |> Enum.take(-@recent_codex_transcript_blocks_limit)
  end

  defp append_recent_codex_transcript_block(blocks, %{kind: kind, item_id: id} = block)
       when is_list(blocks) and is_binary(id) and
              kind in ["agent", "command", "output", "reasoning"] do
    blocks
    |> upsert_item_transcript_block(kind, id, block)
    |> Enum.take(-@recent_codex_transcript_blocks_limit)
  end

  defp append_recent_codex_transcript_block(blocks, %{kind: kind, text: text} = block)
       when is_list(blocks) and is_binary(kind) and is_binary(text) do
    thread_id = Map.get(block, :thread_id)

    merged_blocks =
      case Enum.reverse(blocks) do
        [%{kind: ^kind, text: existing_text, thread_id: ^thread_id} = previous | rest]
        when kind in ["agent", "output", "reasoning"] ->
          Enum.reverse([%{previous | text: existing_text <> text} | rest])

        reversed_blocks ->
          Enum.reverse([block | reversed_blocks])
      end

    Enum.take(merged_blocks, -@recent_codex_transcript_blocks_limit)
  end

  defp append_recent_codex_transcript_block(_blocks, block) when is_map(block), do: [block]

  defp upsert_keyed_transcript_block(blocks, kind, id, block) do
    if Enum.any?(blocks, &keyed_transcript_block?(&1, kind, id, block.thread_id)) do
      # Only the text changes between updates; the title/kind/timestamp are set
      # once (by the initial `tool_call`) and kept — a later update that omits
      # the title must not overwrite it with a generic placeholder.
      Enum.map(blocks, &refresh_keyed_block(&1, kind, id, block.thread_id, block.text))
    else
      blocks ++ [block]
    end
  end

  defp refresh_keyed_block(block, kind, id, thread_id, text) do
    if keyed_transcript_block?(block, kind, id, thread_id),
      do: %{block | text: text},
      else: block
  end

  defp keyed_transcript_block?(
         %{kind: kind, tool_call_id: id, thread_id: thread_id},
         kind,
         id,
         thread_id
       ),
       do: true

  defp keyed_transcript_block?(_block, _kind, _id, _thread_id), do: false

  defp upsert_item_transcript_block(blocks, kind, id, block) do
    if Enum.any?(blocks, &item_transcript_block?(&1, kind, id, block.thread_id)) do
      Enum.map(blocks, &merge_item_transcript_block(&1, block))
    else
      blocks ++ [Map.delete(block, :replace_item_text)]
    end
  end

  defp merge_item_transcript_block(existing, %{kind: kind, item_id: id} = incoming) do
    if item_transcript_block?(existing, kind, id, incoming.thread_id) do
      text =
        if Map.get(incoming, :replace_item_text),
          do: incoming.text,
          else: existing.text <> incoming.text

      %{existing | text: text}
    else
      existing
    end
  end

  defp item_transcript_block?(
         %{kind: kind, item_id: id, thread_id: thread_id},
         kind,
         id,
         thread_id
       ),
       do: true

  defp item_transcript_block?(_block, _kind, _id, _thread_id), do: false

  defp transcript_block_for_update(%{payload: %{} = payload, timestamp: timestamp}, parent_thread_id) do
    method = Map.get(payload, "method") || Map.get(payload, :method)
    origin = transcript_origin(payload, parent_thread_id)

    cond do
      spec = text_block_spec(method) ->
        {kind, paths} = spec
        build_streamed_transcript_block(kind, timestamp, payload, paths, origin)

      method == "codex/event/exec_command_begin" ->
        build_streamed_transcript_block(
          "command",
          timestamp,
          payload,
          extract_transcript_command(payload),
          origin
        )

      method == "item/tool/call" ->
        build_transcript_tool_block(timestamp, payload, origin)

      method in ["item/started", "item/completed"] ->
        codex_item_transcript_blocks(method, timestamp, payload, origin)

      method == "thread/compacted" ->
        build_transcript_compaction_block(timestamp, payload, origin)

      # Native ACP streaming notifications (Option B). The ACP backend forwards
      # `session/update` verbatim; dispatch on the `update.sessionUpdate`
      # discriminator so ACP-only data (tool kinds, plans) renders natively.
      method == "session/update" ->
        acp_transcript_block(timestamp, payload, origin)

      true ->
        nil
    end
  end

  defp transcript_block_for_update(_update, _parent_thread_id), do: nil

  # The streamed text-delta methods share one shape: a `kind` + the path list its
  # text lives at. Grouping them keeps `transcript_block_for_update/2` flat.
  defp text_block_spec(method) do
    cond do
      method in ["codex/event/agent_message_content_delta", "codex/event/agent_message_delta", "item/agentMessage/delta"] ->
        {"agent", agent_text_paths()}

      method in ["codex/event/exec_command_output_delta", "item/commandExecution/outputDelta"] ->
        {"output", output_text_paths()}

      method in reasoning_methods() ->
        {"reasoning", reasoning_text_paths()}

      true ->
        nil
    end
  end

  defp acp_transcript_block(timestamp, payload, origin) do
    update = acp_update(payload)

    case Map.get(update, "sessionUpdate") do
      "agent_message_chunk" ->
        build_transcript_block("agent", timestamp, acp_chunk_text(update), origin)

      "agent_thought_chunk" ->
        build_transcript_block("reasoning", timestamp, acp_chunk_text(update), origin)

      "tool_call" ->
        build_acp_tool_block(timestamp, update, origin)

      "tool_call_update" ->
        acp_tool_update_blocks(timestamp, update, origin)

      "plan" ->
        build_acp_plan_block(timestamp, update, origin)

      _ ->
        nil
    end
  end

  defp acp_update(payload) do
    case string_path_value(payload, ["params", "update"]) do
      %{} = update -> update
      _ -> %{}
    end
  end

  defp acp_chunk_text(update) when is_map(update), do: acp_content_text(Map.get(update, "content"))
  defp acp_chunk_text(_update), do: nil

  # ACP content is a single `{type:"text", text:...}` block, a list of blocks, or
  # a `{type:"content", content:{...}}` wrapper (tool-call output); pull the text
  # out of whichever shape arrives.
  defp acp_content_text(%{"content" => nested}), do: acp_content_text(nested)
  defp acp_content_text(%{"text" => text}) when is_binary(text), do: text

  defp acp_content_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.map(&acp_content_text/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.join("")
  end

  defp acp_content_text(_content), do: nil

  defp build_acp_tool_block(timestamp, update, origin) do
    Map.merge(
      %{
        kind: "tool",
        at: iso8601(timestamp),
        tool_call_id: acp_tool_call_id(update),
        title: acp_tool_title(update),
        text: normalize_transcript_text(acp_tool_arguments(update))
      },
      origin
    )
  end

  # A `tool_call_update` carries the cumulative state of an in-flight tool call:
  # its `rawInput` (arguments) fills in after the initial `tool_call` — which
  # usually arrives with an empty `rawInput` — and its `content` grows as output
  # streams. Emit a tool block to refresh the arguments and an output block for
  # the latest output. Both are keyed on `toolCallId` (see
  # `append_recent_codex_transcript_block/2`) so they update the existing blocks
  # in place rather than appending a duplicate per streamed update.
  defp acp_tool_update_blocks(timestamp, update, origin) do
    [
      acp_tool_args_block(timestamp, update, origin),
      acp_tool_output_block(timestamp, update, origin)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp acp_tool_args_block(timestamp, update, origin) do
    case acp_tool_arguments(update) do
      "" -> nil
      _args -> build_acp_tool_block(timestamp, update, origin)
    end
  end

  defp acp_tool_output_block(timestamp, update, origin) do
    with text when is_binary(text) <- acp_chunk_text(update),
         normalized when normalized != "" <- normalize_transcript_text(text) do
      Map.merge(
        %{kind: "output", at: iso8601(timestamp), tool_call_id: acp_tool_call_id(update), text: normalized},
        origin
      )
    else
      _ -> nil
    end
  end

  defp acp_tool_call_id(update), do: presence(Map.get(update, "toolCallId"))

  # Surface the ACP tool `kind` (read/edit/execute/think/…) alongside the
  # human-readable `title`, which Codex tool calls don't carry.
  defp acp_tool_title(update) do
    kind = presence(Map.get(update, "kind"))
    title = presence(Map.get(update, "title"))

    cond do
      kind && title -> "#{kind}: #{title}"
      title -> title
      kind -> kind
      true -> "tool"
    end
  end

  defp acp_tool_arguments(update) do
    case Map.get(update, "rawInput") do
      nil -> ""
      input -> format_tool_arguments(input)
    end
  end

  defp build_acp_plan_block(timestamp, update, origin) do
    case acp_plan_text(update) do
      "" -> nil
      text -> Map.merge(%{kind: "plan", at: iso8601(timestamp), text: text}, origin)
    end
  end

  # ACP `plan` updates are full snapshots of the agent's TODO list; render each
  # as a markdown checklist keyed on entry `status`.
  defp acp_plan_text(update) do
    update
    |> Map.get("entries", [])
    |> List.wrap()
    |> Enum.map(&acp_plan_entry/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp acp_plan_entry(%{"content" => content} = entry) when is_binary(content) do
    "#{acp_plan_marker(Map.get(entry, "status"))} #{String.trim(content)}"
  end

  defp acp_plan_entry(_entry), do: nil

  defp acp_plan_marker("completed"), do: "- [x]"
  defp acp_plan_marker("in_progress"), do: "- [~]"
  defp acp_plan_marker(_status), do: "- [ ]"

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp build_streamed_transcript_block(kind, timestamp, payload, paths, origin)
       when is_list(paths) do
    build_streamed_transcript_block(
      kind,
      timestamp,
      payload,
      extract_transcript_text(payload, paths),
      origin
    )
  end

  defp build_streamed_transcript_block(kind, timestamp, payload, text, origin) do
    build_item_transcript_block(kind, timestamp, text, codex_item_id(payload), origin)
  end

  defp build_item_transcript_block(kind, timestamp, text, item_id, origin) do
    case build_transcript_block(kind, timestamp, text, origin) do
      nil -> nil
      block when is_binary(item_id) -> Map.put(block, :item_id, item_id)
      block -> block
    end
  end

  defp build_completed_item_transcript_block(kind, timestamp, text, item_id, origin) do
    case build_item_transcript_block(kind, timestamp, text, item_id, origin) do
      %{item_id: _item_id} = block -> Map.put(block, :replace_item_text, true)
      block -> block
    end
  end

  defp codex_item_id(payload) when is_map(payload) do
    [
      ["params", "itemId"],
      ["params", "item_id"],
      ["params", "callId"],
      ["params", "call_id"],
      ["params", "item", "id"],
      ["params", "msg", "itemId"],
      ["params", "msg", "item_id"],
      ["params", "msg", "callId"],
      ["params", "msg", "call_id"],
      ["params", "msg", "id"],
      ["params", "id"]
    ]
    |> Enum.find_value(fn path -> presence(string_path_value(payload, path)) end)
  end

  defp build_transcript_block(kind, timestamp, text, origin) when is_binary(kind) and is_binary(text) do
    case normalize_transcript_text(text) do
      "" -> nil
      normalized -> Map.merge(%{kind: kind, at: iso8601(timestamp), text: normalized}, origin)
    end
  end

  defp build_transcript_block(_kind, _timestamp, _text, _origin), do: nil

  defp build_transcript_tool_block(timestamp, payload, origin) do
    {name, args_text} = extract_transcript_tool(payload)
    Map.merge(%{kind: "tool", at: iso8601(timestamp), title: name, text: normalize_transcript_text(args_text)}, origin)
  end

  # Codex reports each tool call's lifecycle as an `item/started` then an
  # `item/completed` notification. The streamed deltas handled by
  # `text_block_spec/1` cover the agent-message, reasoning and command *output*
  # items, but the call itself — the command line, the file diff, the
  # MCP/web-search/subagent invocation — only ever arrives inside these item
  # events. Mirror `Presenter.codex_item_fragments/4` so the live ring buffer and
  # the persisted transcript render identically. `dynamicToolCall` is skipped: it
  # is the Symphony-provided tool dispatched via `item/tool/call` and already
  # rendered by `build_transcript_tool_block/3`.
  defp codex_item_transcript_blocks(method, timestamp, payload, origin) do
    with %{} = item <- string_path_value(payload, ["params", "item"]),
         type when is_binary(type) <- Map.get(item, "type") do
      codex_item_transcript_block(method, type, timestamp, item, presence(Map.get(item, "id")), origin)
    else
      _ -> nil
    end
  end

  defp codex_item_transcript_block("item/started", "commandExecution", timestamp, item, id, origin),
    do: build_item_transcript_block("command", timestamp, codex_item_command_text(item), id, origin)

  defp codex_item_transcript_block("item/started", "fileChange", timestamp, item, id, origin),
    do: codex_item_tool_block(timestamp, id, codex_item_file_change_title(item), codex_item_file_change_text(item), origin)

  defp codex_item_transcript_block("item/started", "collabAgentToolCall", timestamp, item, id, origin),
    do: codex_item_tool_block(timestamp, id, codex_item_collab_title(item), codex_item_collab_text(item), origin)

  defp codex_item_transcript_block("item/started", "webSearch", timestamp, item, id, origin),
    do: codex_item_tool_block(timestamp, id, "web_search", presence(Map.get(item, "query")), origin)

  defp codex_item_transcript_block("item/started", "mcpToolCall", timestamp, item, id, origin),
    do: codex_item_tool_block(timestamp, id, codex_item_mcp_title(item), codex_item_mcp_args_text(item), origin)

  defp codex_item_transcript_block("item/completed", "mcpToolCall", timestamp, item, id, origin),
    do: codex_item_mcp_output_block(timestamp, id, item, origin)

  defp codex_item_transcript_block("item/completed", "agentMessage", timestamp, item, id, origin),
    do:
      build_completed_item_transcript_block(
        "agent",
        timestamp,
        Map.get(item, "text"),
        id,
        origin
      )

  defp codex_item_transcript_block("item/completed", "commandExecution", timestamp, item, id, origin) do
    [
      build_completed_item_transcript_block(
        "command",
        timestamp,
        codex_item_command_text(item),
        id,
        origin
      ),
      build_completed_item_transcript_block(
        "output",
        timestamp,
        Map.get(item, "aggregatedOutput"),
        id,
        origin
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp codex_item_transcript_block(_method, _type, _timestamp, _item, _id, _origin), do: nil

  defp codex_item_tool_block(timestamp, id, title, text, origin) do
    block = Map.merge(%{kind: "tool", at: iso8601(timestamp), title: title, text: normalize_transcript_text(text || "")}, origin)
    if is_binary(id), do: Map.put(block, :tool_call_id, id), else: block
  end

  defp codex_item_command_text(item) do
    case Map.get(item, "command") do
      command when is_binary(command) -> "$ #{String.trim(command)}"
      _ -> nil
    end
  end

  defp codex_item_file_change_title(item) do
    case codex_item_file_change_paths(item) do
      [] -> "edit"
      [path] -> "edit: #{Path.basename(path)}"
      paths -> "edit: #{length(paths)} files"
    end
  end

  defp codex_item_file_change_paths(item) do
    item
    |> Map.get("changes", [])
    |> List.wrap()
    |> Enum.map(&Map.get(&1, "path"))
    |> Enum.filter(&is_binary/1)
  end

  defp codex_item_file_change_text(item) do
    item
    |> Map.get("changes", [])
    |> List.wrap()
    |> Enum.map(&codex_item_file_change_entry/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> truncate_tool_text()
  end

  defp codex_item_file_change_entry(%{"path" => path} = change) when is_binary(path) do
    case Map.get(change, "diff") do
      diff when is_binary(diff) -> "#{path}\n#{diff}"
      _ -> path
    end
  end

  defp codex_item_file_change_entry(_change), do: nil

  defp codex_item_collab_title(item), do: presence(Map.get(item, "tool")) || "agent"

  defp codex_item_collab_text(item) do
    case presence(Map.get(item, "prompt")) do
      nil -> nil
      prompt -> truncate_tool_text(prompt)
    end
  end

  defp codex_item_mcp_title(item) do
    tool = presence(Map.get(item, "tool")) || "tool"

    case presence(Map.get(item, "server")) do
      nil -> tool
      server -> "#{server}: #{tool}"
    end
  end

  defp codex_item_mcp_args_text(item) do
    case Map.get(item, "arguments") do
      nil -> ""
      arguments -> format_tool_arguments(arguments)
    end
  end

  defp codex_item_mcp_output_block(timestamp, id, item, origin) do
    with text when is_binary(text) and text != "" <- codex_item_mcp_result_text(item),
         block when is_map(block) <- build_transcript_block("output", timestamp, truncate_tool_text(text), origin) do
      if is_binary(id), do: Map.put(block, :tool_call_id, id), else: block
    else
      _ -> nil
    end
  end

  defp codex_item_mcp_result_text(item) do
    case codex_item_mcp_error_text(item) do
      nil -> item |> Map.get("result") |> codex_item_mcp_content_text()
      error -> "Error: #{error}"
    end
  end

  defp codex_item_mcp_error_text(item) do
    case Map.get(item, "error") do
      error when is_binary(error) -> presence(error)
      %{} = error -> presence(inspect(error))
      _ -> nil
    end
  end

  defp codex_item_mcp_content_text(%{"content" => content}), do: acp_content_text(content)
  defp codex_item_mcp_content_text(_result), do: nil

  defp build_transcript_compaction_block(timestamp, payload, origin) do
    Map.merge(
      %{
        kind: "compaction",
        at: iso8601(timestamp),
        text: compaction_transcript_text(payload)
      },
      origin
    )
  end

  defp compaction_transcript_text(payload) when is_map(payload) do
    case string_path_value(payload, ["params", "turnId"]) || string_path_value(payload, ["params", "turn_id"]) do
      turn_id when is_binary(turn_id) and byte_size(turn_id) >= 8 ->
        "Context compacted for turn #{short_identifier(turn_id)}."

      _ ->
        "Context compacted."
    end
  end

  defp short_identifier(identifier) when is_binary(identifier) and byte_size(identifier) > 8,
    do: binary_part(identifier, 0, 8)

  defp short_identifier(identifier) when is_binary(identifier), do: identifier

  # Each Codex event carries the thread it belongs to (`params.threadId`); the
  # session's own thread is the first UUID of `session_id` (`"<thread>-<turn>"`).
  # An event from any other thread is a multiplexed subagent turn.
  defp transcript_origin(payload, parent_thread_id) do
    event_thread_id = event_thread_id(payload)
    %{thread_id: event_thread_id, subagent: subagent_thread?(event_thread_id, parent_thread_id)}
  end

  defp event_thread_id(payload) when is_map(payload) do
    string_path_value(payload, ["params", "threadId"]) || string_path_value(payload, ["params", "thread_id"])
  end

  defp subagent_thread?(event_thread_id, parent_thread_id)
       when is_binary(event_thread_id) and is_binary(parent_thread_id),
       do: event_thread_id != parent_thread_id

  defp subagent_thread?(_event_thread_id, _parent_thread_id), do: false

  # session_id is "<thread-uuid>-<turn-uuid>"; each UUID is a fixed 36 chars, so
  # the parent thread is the leading 36 characters followed by the joining "-".
  defp parent_thread_from_session_id(session_id)
       when is_binary(session_id) and byte_size(session_id) >= 73 do
    if binary_part(session_id, 36, 1) == "-", do: binary_part(session_id, 0, 36), else: nil
  end

  defp parent_thread_from_session_id(_session_id), do: nil

  defp agent_text_paths do
    [
      ["params", "msg", "content"],
      ["params", "msg", "delta"],
      ["params", "delta"],
      ["params", "text"],
      ["params", "content"]
    ]
  end

  defp output_text_paths do
    [
      ["params", "msg", "content"],
      ["params", "msg", "delta"],
      ["params", "delta"],
      ["params", "output"],
      ["params", "content"]
    ]
  end

  defp reasoning_methods do
    [
      "codex/event/agent_reasoning_delta",
      "codex/event/reasoning_content_delta",
      "codex/event/agent_reasoning",
      "item/reasoning/textDelta",
      "item/reasoning/summaryTextDelta"
    ]
  end

  defp reasoning_text_paths do
    [
      ["params", "textDelta"],
      ["params", "summaryText"],
      ["params", "delta"],
      ["params", "msg", "content"],
      ["params", "text"],
      ["params", "content"]
    ]
  end

  defp extract_transcript_text(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      case string_path_value(payload, path) do
        text when is_binary(text) -> text
        _ -> nil
      end
    end)
  end

  defp extract_transcript_command(payload) when is_map(payload) do
    [
      ["params", "msg", "command"],
      ["params", "command"],
      ["params", "cmd"]
    ]
    |> Enum.find_value(fn path ->
      case string_path_value(payload, path) do
        command when is_binary(command) -> "$ #{String.trim(command)}"
        _ -> nil
      end
    end)
  end

  defp extract_transcript_tool(payload) when is_map(payload) do
    name =
      string_path_value(payload, ["params", "tool"]) ||
        string_path_value(payload, ["params", "name"]) ||
        "tool"

    args_text =
      case string_path_value(payload, ["params", "arguments"]) do
        nil -> ""
        args -> format_tool_arguments(args)
      end

    {to_string(name), args_text}
  end

  defp format_tool_arguments(args) when is_binary(args), do: truncate_tool_text(args)
  defp format_tool_arguments(args) when is_map(args) and map_size(args) == 0, do: ""

  defp format_tool_arguments(args),
    do: args |> inspect(pretty: true, limit: :infinity, width: 100) |> truncate_tool_text()

  @max_tool_argument_chars 4_000
  defp truncate_tool_text(text) when is_binary(text) do
    if String.length(text) > @max_tool_argument_chars do
      String.slice(text, 0, @max_tool_argument_chars) <> "\n… [truncated]"
    else
      text
    end
  end

  defp normalize_transcript_text(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.replace(~r/\x1B\[[0-9;]*[A-Za-z]/, "")
    |> String.replace(~r/\x1B./, "")
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
  end

  defp string_path_value(value, []), do: value

  defp string_path_value(map, [key | rest]) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      nil -> nil
      nested -> string_path_value(nested, rest)
    end
  end

  defp string_path_value(_map, _path), do: nil

  defp persist_codex_update(running_entry, update) when is_map(running_entry) and is_map(update) do
    case session_log_for_update(running_entry, update) do
      {:ok, updated_entry, log_entry} ->
        case SessionTranscript.persist(
               log_entry,
               codex_session_log_record(updated_entry, update),
               updated_entry.observability_policy
             ) do
          {:ok, updated_log_entry} ->
            put_session_log_entry(updated_entry, updated_log_entry)

          {:error, reason} ->
            Logger.warning(
              "Failed to write Codex transcript issue_id=#{updated_entry.issue.id} issue_identifier=#{updated_entry.identifier} session_id=#{updated_entry.session_id || "n/a"} path=#{log_entry.path} reason=#{inspect(reason)}"
            )

            updated_entry
        end

      :skip ->
        running_entry
    end
  end

  defp ensure_observability_policy(running_entry, resolver) do
    if Map.has_key?(running_entry, :observability_policy) do
      running_entry
    else
      Map.put(running_entry, :observability_policy, resolver.())
    end
  end

  defp session_log_for_update(running_entry, update) do
    session_id = Map.get(running_entry, :session_id)

    if is_binary(session_id) and String.trim(session_id) != "" do
      timestamp = update[:timestamp] || DateTime.utc_now()
      log_entry = existing_or_new_session_log(running_entry, session_id, timestamp)
      updated_log_entry = refresh_session_log_entry(log_entry, running_entry, timestamp)
      {:ok, put_session_log_entry(running_entry, updated_log_entry), updated_log_entry}
    else
      :skip
    end
  end

  defp existing_or_new_session_log(running_entry, session_id, timestamp) do
    Enum.find(Map.get(running_entry, :codex_session_logs, []), fn
      %{session_id: ^session_id} -> true
      _ -> false
    end) ||
      %{
        session_id: session_id,
        path: codex_session_log_path(running_entry.identifier, session_id),
        started_at: timestamp
      }
  end

  defp refresh_session_log_entry(log_entry, running_entry, timestamp) do
    log_entry
    |> Map.put(:started_at, Map.get(log_entry, :started_at, timestamp))
    |> Map.put(:last_event_at, timestamp)
    |> maybe_put_runtime_value(:worker_host, Map.get(running_entry, :worker_host))
    |> maybe_put_runtime_value(:workspace_path, Map.get(running_entry, :workspace_path))
  end

  defp put_session_log_entry(running_entry, %{session_id: session_id} = log_entry) when is_binary(session_id) do
    session_logs =
      running_entry
      |> Map.get(:codex_session_logs, [])
      |> Enum.reject(fn
        %{session_id: ^session_id} -> true
        _ -> false
      end)
      |> Kernel.++([log_entry])

    Map.put(running_entry, :codex_session_logs, session_logs)
  end

  defp put_session_log_entry(running_entry, _log_entry), do: running_entry

  defp codex_session_log_path(issue_identifier, session_id)
       when is_binary(issue_identifier) and is_binary(session_id) do
    file_name =
      "#{sanitize_session_log_component(issue_identifier)}--#{sanitize_session_log_component(session_id)}.ndjson"

    codex_session_logs_dir()
    |> Path.join(file_name)
    |> Path.expand()
  end

  defp codex_session_logs_dir do
    :symphony_elixir
    |> Application.get_env(:log_file, LogFile.default_log_file())
    |> Path.expand()
    |> Path.dirname()
    |> Path.join("codex_sessions")
  end

  defp sanitize_session_log_component(value) when is_binary(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
    |> String.trim("_")
    |> case do
      "" -> "session"
      sanitized -> sanitized
    end
  end

  defp codex_session_log_record(running_entry, update) when is_map(running_entry) and is_map(update) do
    %{
      at: iso8601(update[:timestamp]),
      event: update[:event] |> to_string(),
      issue_id: running_entry.issue.id,
      issue_identifier: running_entry.identifier,
      session_id: Map.get(running_entry, :session_id),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      codex_app_server_pid: Map.get(running_entry, :codex_app_server_pid),
      summary:
        StatusDashboard.humanize_codex_message(%{
          event: update[:event],
          message: summarized_codex_message(update)
        }),
      payload: update[:payload],
      raw: update[:raw],
      details: json_safe_value(update[:details]),
      thread_id: update[:thread_id],
      turn_id: update[:turn_id],
      decision: update[:decision],
      answer: update[:answer],
      reason: json_safe_value(update[:reason])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp json_safe_value(nil), do: nil
  defp json_safe_value(%DateTime{} = value), do: iso8601(value)
  defp json_safe_value(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp json_safe_value(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe_value(value) when is_list(value), do: Enum.map(value, &json_safe_value/1)

  defp json_safe_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested_value} -> {to_string(key), json_safe_value(nested_value)} end)
    |> Map.new()
  end

  defp json_safe_value(value), do: inspect(value)

  defp iso8601(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp iso8601(_timestamp), do: nil

  defp summarized_codex_message(update) when is_map(update) do
    update[:payload] ||
      update[:raw] ||
      update
      |> Map.take([:session_id, :thread_id, :turn_id, :reason, :decision, :answer])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
      |> case do
        empty when map_size(empty) == 0 -> nil
        metadata -> metadata
      end
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp schedule_heartbeat(delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    Process.send_after(self(), :write_heartbeat, delay_ms)
    :ok
  end

  defp schedule_workspace_gc(delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    Process.send_after(self(), :run_workspace_gc, delay_ms)
    :ok
  end

  defp workspace_gc_disabled? do
    System.get_env("SYMPHONY_WORKSPACE_GC_DISABLED") == "1" or
      Application.get_env(:symphony_elixir, :workspace_gc_disabled, false) == true
  end

  defp write_heartbeat(%State{} = state) do
    path = heartbeat_path()

    body =
      Jason.encode!(%{
        ts: DateTime.to_iso8601(DateTime.utc_now()),
        running: map_size(state.running),
        claimed: MapSet.size(state.claimed),
        completed_recent: MapSet.size(state.completed),
        poll_check_in_progress: state.poll_check_in_progress,
        poll_interval_ms: state.poll_interval_ms
      })

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, body <> "\n") do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Orchestrator could not write heartbeat to #{path}: #{inspect(reason)}")
        :error
    end
  end

  defp heartbeat_path do
    base =
      System.get_env("SYMPHONY_HEARTBEAT_DIR") ||
        Path.join(System.user_home!(), ".symphony")

    Path.join(base, @heartbeat_filename)
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  # Shared body for a valid-config tick: flip the loop into "checking now…",
  # clear the fired tick timer, and hand off to the poll cycle.
  defp begin_poll_check(%State{} = state) do
    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    state
  end

  # Transiently-invalid config on the polled path (UDPE-6990): log a warning
  # and skip this cycle instead of letting `Config.settings!/0` crash the
  # GenServer. Keep the last-good `poll_interval_ms`/`max_concurrent_agents`
  # already in state, reschedule the next tick, and mark the loop idle so
  # polling resumes on its own the moment the config parses again.
  defp skip_poll_cycle_on_invalid_config(%State{} = state, reason) do
    Logger.warning(
      "Skipping poll cycle; WORKFLOW.md config is currently invalid: #{Config.describe_error(reason)}. Keeping last-good poll_interval_ms=#{state.poll_interval_ms} max_concurrent_agents=#{state.max_concurrent_agents}; retrying next tick"
    )

    state = schedule_tick(state, poll_delay_ms(state))
    state = %{state | poll_check_in_progress: false, poll_backoff_until_ms: nil}

    notify_dashboard()
    state
  end

  # Resolve live config at the poll boundary WITHOUT raising. A momentarily-
  # invalid WORKFLOW.md/host config (a half-saved edit, or a write in flight)
  # makes `Config.settings/0` return `{:error, reason}` where `settings!/0`
  # would raise `ArgumentError`. Returning the error lets the caller keep the
  # last-good `poll_interval_ms`/`max_concurrent_agents` already in state and
  # skip the cycle, so a transient bad config can't crash the GenServer and —
  # via the supervisor's restart intensity — take the whole app down
  # (UDPE-6990).
  defp refresh_runtime_config(%State{} = state) do
    case Config.settings() do
      {:ok, config} ->
        {:ok,
         %{
           state
           | poll_interval_ms: config.polling.interval_ms,
             max_concurrent_agents: config.agent.max_concurrent_agents
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp failure_from_exit(_reason, %{run_failure: %AgentFailure{} = failure}), do: failure

  defp failure_from_exit(reason, running_entry) do
    AgentFailure.classify(reason, backend: Map.get(running_entry, :backend))
  end

  defp failure_error(_reason, %{run_failure: %AgentFailure{}}, %AgentFailure{} = failure),
    do: failure.message

  defp failure_error(reason, _running_entry, _failure), do: "agent exited: #{inspect(reason)}"

  defp handle_typed_run_failure(
         state,
         issue_id,
         next_attempt,
         %{failure: %AgentFailure{class: :usage_quota_limit, trusted: true}} = metadata,
         _probe?
       ) do
    open_quota_circuit_and_park(state, issue_id, next_attempt, metadata)
  end

  defp handle_typed_run_failure(state, issue_id, next_attempt, metadata, true) do
    handle_failed_quota_probe(state, issue_id, next_attempt, metadata)
  end

  defp handle_typed_run_failure(state, issue_id, next_attempt, metadata, false) do
    schedule_failure_retry(state, issue_id, next_attempt, metadata)
  end

  defp open_quota_circuit_and_park(
         %State{} = state,
         issue_id,
         next_attempt,
         %{failure: %AgentFailure{} = failure} = metadata
       ) do
    backend = quota_failure_backend(failure, metadata)
    worker_host = metadata[:worker_host]
    circuit_key = quota_circuit_key(backend, worker_host)
    now = DateTime.utc_now()
    next_probe_at = quota_probe_at(failure, backend, now)
    previous = Map.get(state.quota_circuits, circuit_key)

    circuit =
      quota_circuit_from_failure(
        state,
        previous,
        failure,
        backend,
        worker_host,
        now,
        next_probe_at
      )

    state = %{state | quota_circuits: Map.put(state.quota_circuits, circuit_key, circuit)}

    action = if previous, do: :refreshed, else: :opened

    Logger.warning("Opening provider quota circuit backend=#{backend} account_scope=#{circuit.account_scope} next_probe_at=#{DateTime.to_iso8601(circuit.next_probe_at)} issue_id=#{issue_id}")

    state
    |> emit_quota_circuit(action, circuit)
    |> park_issue_retry(issue_id, next_attempt, metadata)
  end

  defp quota_failure_backend(%AgentFailure{backend: backend}, _metadata) when is_binary(backend),
    do: backend

  defp quota_failure_backend(_failure, %{backend: backend}) when is_binary(backend), do: backend
  defp quota_failure_backend(_failure, _metadata), do: "codex"

  defp quota_circuit_from_failure(
         state,
         previous,
         failure,
         backend,
         worker_host,
         now,
         next_probe_at
       ) do
    %{
      backend: backend,
      account_scope: quota_account_scope(worker_host),
      worker_host: worker_host,
      provider_limit_id: quota_provider_limit_id(state.codex_rate_limits),
      status: :open,
      reason: failure.message,
      opened_at: previous_value(previous, :opened_at, now),
      reset_at: later_datetime(previous_value(previous, :reset_at), failure.reset_at),
      next_probe_at: later_datetime(previous_value(previous, :next_probe_at), next_probe_at),
      probe_issue_id: nil,
      parked: previous_value(previous, :parked, []),
      timer_ref: previous_value(previous, :timer_ref),
      timer_token: nil
    }
  end

  defp previous_value(previous, key, fallback \\ nil)
  defp previous_value(previous, key, fallback) when is_map(previous), do: Map.get(previous, key, fallback)
  defp previous_value(_previous, _key, fallback), do: fallback

  defp handle_failed_quota_probe(%State{} = state, issue_id, next_attempt, metadata) do
    backend = metadata[:backend] || "codex"
    circuit_key = quota_circuit_key(backend, metadata[:worker_host])
    state = reopen_quota_circuit(state, circuit_key, metadata[:error])
    {failures, state} = bump_failure_count(state, issue_id)
    max_retries = max_retries_setting()

    if is_integer(max_retries) and max_retries > 0 and failures > max_retries do
      give_up_retries_exhausted(state, issue_id, failures - 1, max_retries, metadata)
    else
      park_issue_retry(state, issue_id, next_attempt, metadata)
    end
  end

  defp reopen_quota_circuit(%State{} = state, circuit_key, reason) do
    case Map.get(state.quota_circuits, circuit_key) do
      %{} = circuit ->
        next_probe_at = fallback_quota_probe_at(circuit.backend, DateTime.utc_now())

        updated = %{
          circuit
          | status: :open,
            reason: reason || circuit.reason,
            next_probe_at: next_probe_at,
            probe_issue_id: nil,
            timer_ref: nil,
            timer_token: nil
        }

        state
        |> put_quota_circuit(circuit_key, updated)
        |> emit_quota_circuit(:probe_failed, updated)

      _ ->
        state
    end
  end

  defp park_issue_retry(%State{} = state, issue_id, attempt, metadata) do
    backend = metadata[:backend] || retry_backend(metadata, metadata[:issue])
    circuit_key = quota_circuit_key(backend, metadata[:worker_host])

    case Map.get(state.quota_circuits, circuit_key) do
      %{} = circuit ->
        state = drop_retry_attempt(state, issue_id)
        parked_at = DateTime.utc_now()

        parked_entry = %{
          issue_id: issue_id,
          identifier: metadata[:identifier] || issue_identifier(metadata[:issue]) || issue_id,
          title: metadata[:title] || title_from_issue(metadata[:issue]),
          attempt: max(normalize_retry_attempt(attempt), 1),
          error: metadata[:error] || circuit.reason,
          backend: backend,
          failure_class: metadata[:failure_class] || retry_failure_class(metadata[:failure]),
          worker_host: metadata[:worker_host],
          workspace_path: metadata[:workspace_path],
          parked_at: parked_at
        }

        parked =
          circuit.parked
          |> Enum.reject(&(&1.issue_id == issue_id))
          |> Kernel.++([parked_entry])

        updated = %{circuit | parked: parked, status: :open, probe_issue_id: nil}

        state
        |> Map.update!(:claimed, &MapSet.put(&1, issue_id))
        |> put_quota_circuit(circuit_key, updated)
        |> emit_retry_policy(issue_id, metadata, :parked, parked_entry.attempt, nil)

      _ ->
        schedule_issue_retry(state, issue_id, attempt, metadata)
    end
  end

  defp handle_quota_probe_due(%State{} = state, circuit_key, timer_token) do
    case Map.get(state.quota_circuits, circuit_key) do
      %{status: :open, timer_token: ^timer_token} = circuit ->
        circuit = %{circuit | timer_ref: nil, timer_token: nil}
        state = %{state | quota_circuits: Map.put(state.quota_circuits, circuit_key, circuit)}

        if available_slots(state) > 0 and quota_probe_slot_available?(state, circuit.worker_host) do
          start_quota_probe(state, circuit_key)
        else
          defer_quota_probe(state, circuit_key)
        end

      _ ->
        state
    end
  end

  defp start_quota_probe(%State{} = state, circuit_key) do
    circuit = Map.fetch!(state.quota_circuits, circuit_key)

    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        case select_quota_probe_issue(state, circuit_key, issues) do
          {%Issue{} = issue, parked_entry} ->
            begin_quota_probe(state, circuit_key, issue, parked_entry)

          nil ->
            defer_quota_probe(state, circuit_key)
        end

      {:error, reason} ->
        Logger.warning("Quota probe candidate lookup failed backend=#{circuit.backend} account_scope=#{circuit.account_scope}: #{inspect(reason)}")
        defer_quota_probe(state, circuit_key)
    end
  end

  defp select_quota_probe_issue(%State{} = state, circuit_key, issues) when is_list(issues) do
    circuit = Map.fetch!(state.quota_circuits, circuit_key)

    select_parked_probe(circuit.parked, issues, circuit.backend) ||
      select_new_probe(issues, state, circuit.backend)
  end

  defp select_parked_probe(parked, issues, backend) do
    Enum.find_value(parked, fn entry ->
      issues
      |> find_issue_by_id(entry.issue_id)
      |> eligible_probe_tuple(entry, backend)
    end)
  end

  defp select_new_probe(issues, state, backend) do
    issues
    |> sort_issues_for_dispatch()
    |> Enum.find(&eligible_new_probe?(&1, state, backend))
    |> eligible_probe_tuple(nil, backend)
  end

  defp eligible_new_probe?(%Issue{} = issue, state, backend) do
    eligible_probe_issue?(issue, backend) and !Map.has_key?(state.running, issue.id) and
      !MapSet.member?(state.claimed, issue.id)
  end

  defp eligible_new_probe?(_issue, _state, _backend), do: false

  defp eligible_probe_tuple(%Issue{} = issue, entry, backend) do
    if eligible_probe_issue?(issue, backend), do: {issue, entry}
  end

  defp eligible_probe_tuple(_issue, _entry, _backend), do: nil

  defp eligible_probe_issue?(%Issue{} = issue, backend) do
    retry_candidate_issue?(issue, terminal_state_set()) and predicted_backend(issue) == backend
  end

  defp begin_quota_probe(%State{} = state, circuit_key, issue, parked_entry) do
    circuit = Map.fetch!(state.quota_circuits, circuit_key)
    backend = circuit.backend
    parked = Enum.reject(circuit.parked, &(&1.issue_id == issue.id))

    updated = %{
      circuit
      | status: :probe,
        probe_issue_id: issue.id,
        parked: parked,
        timer_ref: nil,
        timer_token: nil
    }

    attempt = parked_entry && parked_entry.attempt
    preferred_worker_host = (parked_entry && parked_entry.worker_host) || circuit.worker_host
    state = put_quota_circuit(state, circuit_key, updated)
    {_outcome, dispatched_state} = dispatch_issue_outcome(state, issue, attempt, preferred_worker_host)

    if Map.has_key?(dispatched_state.running, issue.id) do
      Logger.info("Started controlled provider quota probe backend=#{backend} issue_id=#{issue.id} issue_identifier=#{issue.identifier}")

      dispatched_state
      |> emit_retry_policy(
        issue.id,
        %{
          identifier: issue.identifier,
          backend: backend,
          failure_class: :usage_quota_limit
        },
        :probed,
        attempt || 1,
        nil
      )
      |> emit_quota_circuit(:probe_started, updated)
    else
      metadata = %{
        identifier: issue.identifier,
        title: issue.title,
        issue: issue,
        backend: backend,
        worker_host: preferred_worker_host,
        error: "quota probe could not be dispatched"
      }

      dispatched_state
      |> drop_retry_attempt(issue.id)
      |> reopen_quota_circuit(circuit_key, metadata.error)
      |> park_issue_retry(issue.id, attempt || 1, metadata)
    end
  end

  defp defer_quota_probe(%State{} = state, circuit_key) do
    case Map.get(state.quota_circuits, circuit_key) do
      %{} = circuit ->
        delay_ms = max(state.poll_interval_ms || 1_000, 1_000)
        updated = %{circuit | next_probe_at: DateTime.add(DateTime.utc_now(), delay_ms, :millisecond)}
        put_quota_circuit(state, circuit_key, updated)

      _ ->
        state
    end
  end

  defp maybe_close_successful_quota_probe(%State{} = state, running_entry) do
    backend = Map.get(running_entry, :backend)
    circuit_key = quota_circuit_key(backend, Map.get(running_entry, :worker_host))
    issue_id = running_entry |> Map.get(:issue, %{}) |> Map.get(:id)

    case Map.get(state.quota_circuits, circuit_key) do
      %{status: :probe, probe_issue_id: ^issue_id} ->
        close_quota_circuit(state, circuit_key, :successful_probe)

      _ ->
        state
    end
  end

  defp close_quota_circuit(%State{} = state, circuit_key, recovery_reason) do
    case Map.pop(state.quota_circuits, circuit_key) do
      {nil, _circuits} ->
        state

      {circuit, remaining_circuits} ->
        cancel_circuit_timer(circuit)
        state = %{state | quota_circuits: remaining_circuits}
        QuotaCircuitStore.save(remaining_circuits)

        Logger.info("Closing provider quota circuit backend=#{circuit.backend} account_scope=#{circuit.account_scope} recovery=#{recovery_reason} parked_issues=#{length(circuit.parked)}")

        state
        |> emit_quota_circuit(:closed, circuit, recovery_reason)
        |> resume_parked_retries(circuit.parked)
    end
  end

  defp resume_parked_retries(%State{} = state, parked) when is_list(parked) do
    parked
    |> Enum.sort_by(&DateTime.to_unix(&1.parked_at, :microsecond))
    |> Enum.with_index()
    |> Enum.reduce(state, fn {entry, index}, state_acc ->
      schedule_issue_retry(state_acc, entry.issue_id, entry.attempt, %{
        identifier: entry.identifier,
        title: entry.title,
        error: entry.error,
        backend: entry.backend,
        failure_class: Map.get(entry, :failure_class),
        worker_host: entry.worker_host,
        workspace_path: entry.workspace_path,
        delay_ms_override: (index + 1) * @quota_resume_spacing_ms,
        circuit_recovery: true
      })
    end)
  end

  defp put_quota_circuit(%State{} = state, circuit_key, circuit, persist? \\ true) do
    state = %{state | quota_circuits: Map.put(state.quota_circuits, circuit_key, circuit)}
    state = arm_quota_circuit(state, circuit_key)
    if persist?, do: QuotaCircuitStore.save(state.quota_circuits)
    state
  end

  defp arm_all_quota_circuits(%State{} = state) do
    Enum.reduce(Map.keys(state.quota_circuits), state, &arm_quota_circuit(&2, &1))
  end

  defp arm_quota_circuit(%State{} = state, circuit_key) do
    case Map.get(state.quota_circuits, circuit_key) do
      %{status: :open, next_probe_at: %DateTime{} = next_probe_at} = circuit ->
        cancel_circuit_timer(circuit)
        timer_token = make_ref()
        delay_ms = max(0, DateTime.diff(next_probe_at, DateTime.utc_now(), :millisecond))
        timer_ref = Process.send_after(self(), {:quota_probe_due, circuit_key, timer_token}, delay_ms)
        updated = %{circuit | timer_ref: timer_ref, timer_token: timer_token}
        %{state | quota_circuits: Map.put(state.quota_circuits, circuit_key, updated)}

      _ ->
        state
    end
  end

  defp cancel_circuit_timer(%{timer_ref: timer_ref}) when is_reference(timer_ref),
    do: Process.cancel_timer(timer_ref)

  defp cancel_circuit_timer(_circuit), do: :ok

  defp quota_probe_at(%AgentFailure{reset_at: %DateTime{} = reset_at}, _backend, now) do
    if DateTime.compare(reset_at, now) == :gt, do: reset_at, else: fallback_quota_probe_at("codex", now)
  end

  defp quota_probe_at(_failure, backend, now), do: fallback_quota_probe_at(backend, now)

  defp fallback_quota_probe_at(backend, now) do
    base_ms = min(@quota_probe_default_ms, @quota_probe_max_ms)
    jitter_ms = :erlang.phash2({backend, DateTime.to_unix(now, :second)}, max(div(base_ms, 10), 1))
    DateTime.add(now, base_ms + jitter_ms, :millisecond)
  end

  defp later_datetime(%DateTime{} = left, %DateTime{} = right) do
    if DateTime.compare(left, right) == :lt, do: right, else: left
  end

  defp later_datetime(%DateTime{} = datetime, _other), do: datetime
  defp later_datetime(_other, %DateTime{} = datetime), do: datetime
  defp later_datetime(_left, _right), do: nil

  defp backend_quota_blocked?(%State{} = state, backend, worker_host) when is_binary(backend) do
    circuit_key = quota_circuit_key(backend, worker_host)

    match?(
      %{status: status} when status in [:open, :probe],
      Map.get(state.quota_circuits, circuit_key)
    )
  end

  defp backend_quota_blocked?(_state, _backend, _worker_host), do: false

  defp backend_quota_dispatch_blocked?(%State{} = state, backend, worker_host, issue_id) do
    circuit_key = quota_circuit_key(backend, worker_host)

    case Map.get(state.quota_circuits, circuit_key) do
      %{status: :probe, probe_issue_id: ^issue_id} -> false
      %{status: status} when status in [:open, :probe] -> true
      _ -> false
    end
  end

  defp backend_dispatch_available?(%State{} = state, backend) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        !backend_quota_blocked?(state, backend, nil)

      hosts ->
        Enum.any?(hosts, fn host ->
          worker_host_slots_available?(state, host) and
            !backend_quota_blocked?(state, backend, host)
        end)
    end
  end

  defp quota_probe_slot_available?(%State{} = state, nil) do
    Config.settings!().worker.ssh_hosts == [] and worker_slots_available?(state)
  end

  defp quota_probe_slot_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    worker_host_slots_available?(state, worker_host)
  end

  defp predicted_backend(%Issue{} = issue) do
    {backend, _overrides} = AgentBackend.resolve_for_issue(issue)
    AgentBackend.backend_name(backend)
  end

  defp retry_backend(metadata, %Issue{} = issue), do: metadata[:backend] || predicted_backend(issue)
  defp retry_backend(metadata, _issue), do: metadata[:backend] || "codex"

  defp quota_probe_issue?(%State{} = state, backend, worker_host, issue_id) do
    circuit_key = quota_circuit_key(backend, worker_host)

    match?(
      %{status: :probe, probe_issue_id: ^issue_id},
      Map.get(state.quota_circuits, circuit_key)
    )
  end

  defp restored_quota_claims(circuits) when is_map(circuits) do
    circuits
    |> Enum.flat_map(fn {_backend, circuit} -> Enum.map(circuit.parked, & &1.issue_id) end)
    |> MapSet.new()
  end

  defp quota_circuit_key(backend, worker_host) when is_binary(backend) do
    backend <> "::" <> quota_account_scope(worker_host)
  end

  defp quota_circuit_key(_backend, worker_host), do: "unknown::" <> quota_account_scope(worker_host)

  defp quota_account_scope(worker_host) when is_binary(worker_host), do: "worker:#{worker_host}"
  defp quota_account_scope(_worker_host), do: "local"

  defp quota_provider_limit_id(rate_limits) when is_map(rate_limits) do
    Map.get(rate_limits, "limitId") || Map.get(rate_limits, :limitId) ||
      Map.get(rate_limits, "limit_id") || Map.get(rate_limits, :limit_id) || "default"
  end

  defp quota_provider_limit_id(_rate_limits), do: nil

  defp issue_identifier(%Issue{identifier: identifier}), do: identifier
  defp issue_identifier(_issue), do: nil

  defp quota_parked_snapshot(circuits, now) when is_map(circuits) do
    Enum.flat_map(circuits, fn {_backend, circuit} ->
      due_in_ms = max(0, DateTime.diff(circuit.next_probe_at, now, :millisecond))

      Enum.map(circuit.parked, fn entry ->
        %{
          issue_id: entry.issue_id,
          attempt: entry.attempt,
          due_in_ms: due_in_ms,
          status: :parked,
          identifier: entry.identifier,
          title: entry.title,
          error: entry.error,
          backend: entry.backend,
          failure_class: Map.get(entry, :failure_class),
          worker_host: entry.worker_host,
          workspace_path: entry.workspace_path,
          codex_session_logs: [],
          recent_codex_transcript_blocks: []
        }
      end)
    end)
  end

  defp quota_circuit_snapshot(circuits, now) when is_map(circuits) do
    circuits
    |> Map.values()
    |> Enum.sort_by(&{&1.backend, &1.account_scope})
    |> Enum.map(fn circuit ->
      %{
        backend: circuit.backend,
        account_scope: circuit.account_scope,
        worker_host: circuit.worker_host,
        provider_limit_id: circuit.provider_limit_id,
        state: circuit.status,
        reason: circuit.reason,
        opened_at: circuit.opened_at,
        reset_at: circuit.reset_at,
        next_probe_at: circuit.next_probe_at,
        next_probe_in_ms: max(0, DateTime.diff(circuit.next_probe_at, now, :millisecond)),
        probe_issue_id: circuit.probe_issue_id,
        parked_issue_count: length(circuit.parked)
      }
    end)
  end

  defp emit_retry_policy(%State{} = state, issue_id, metadata, action, attempt, delay_ms) do
    failure_class = metadata[:failure_class] || retry_failure_class(metadata[:failure])
    issue = metadata[:issue] || %{}

    Telemetry.emit(:retry_policy, %{
      issue_id: issue_id,
      issue_identifier: metadata[:identifier],
      parent_issue_id: Map.get(issue, :parent_id),
      repository: repository_for_issue(issue),
      backend: metadata[:backend],
      failure_class: failure_class && Atom.to_string(failure_class),
      action: Atom.to_string(action),
      attempt: attempt,
      delay_ms: delay_ms,
      retry_scheduled: action == :scheduled,
      retry_parked: action == :parked,
      retry_suppressed: action == :suppressed,
      circuit_probe: action == :probed
    })

    state
  end

  defp repository_for_issue(%Issue{labels: labels}) when is_list(labels) do
    Enum.find_value(labels, fn
      "repo:" <> name -> name
      _label -> nil
    end) || "default"
  end

  defp repository_for_issue(_issue), do: "default"

  defp emit_quota_circuit(%State{} = state, action, circuit, recovery_reason \\ nil) do
    Telemetry.emit(:quota_circuit, %{
      action: Atom.to_string(action),
      backend: circuit.backend,
      account_scope: circuit.account_scope,
      worker_host: circuit.worker_host,
      provider_limit_id: circuit.provider_limit_id,
      reason: circuit.reason,
      recovery_reason: recovery_reason && Atom.to_string(recovery_reason),
      opened_at: DateTime.to_iso8601(circuit.opened_at),
      reset_at: circuit.reset_at && DateTime.to_iso8601(circuit.reset_at),
      next_probe_at: circuit.next_probe_at && DateTime.to_iso8601(circuit.next_probe_at),
      parked_issue_count: length(circuit.parked)
    })

    state
  end

  @doc false
  @spec quota_probe_at_for_test(AgentFailure.t(), String.t(), DateTime.t()) :: DateTime.t()
  def quota_probe_at_for_test(%AgentFailure{} = failure, backend, %DateTime{} = now) do
    quota_probe_at(failure, backend, now)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update, running_entry)
       when is_map(update) and is_map(running_entry) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        state = %{state | codex_rate_limits: rate_limits}
        backend = Map.get(running_entry, :backend) || "codex"
        circuit_key = quota_circuit_key(backend, Map.get(running_entry, :worker_host))

        if AgentFailure.recovered_rate_limits?(rate_limits) and
             recovered_update_after_open?(state, circuit_key, update) do
          close_quota_circuit(state, circuit_key, :authoritative_rate_limit_update)
        else
          state
        end

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update, _running_entry), do: state

  defp recovered_update_after_open?(%State{} = state, circuit_key, update) do
    case {Map.get(state.quota_circuits, circuit_key), Map.get(update, :timestamp)} do
      {%{opened_at: %DateTime{} = opened_at}, %DateTime{} = updated_at} ->
        DateTime.compare(updated_at, opened_at) in [:eq, :gt]

      {nil, _updated_at} ->
        true

      _ ->
        false
    end
  end

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens

    cached_input_tokens =
      Map.get(codex_totals, :cached_input_tokens, 0) + Map.get(token_delta, :cached_input_tokens, 0)

    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens

    reasoning_tokens =
      Map.get(codex_totals, :reasoning_tokens, 0) + Map.get(token_delta, :reasoning_tokens, 0)

    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      cached_input_tokens: max(0, cached_input_tokens),
      output_tokens: max(0, output_tokens),
      reasoning_tokens: max(0, reasoning_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  # Current context occupancy of the *main* agent thread: the input (prompt) size
  # of the most recent request, divided later against the model context window.
  # Unlike the accumulated token totals (cumulative thread spend), this is a
  # momentary reading — it tracks up as context grows and down after compaction.
  # `last_token_usage`/`tokenUsage.last` is the only non-cumulative signal Codex
  # gives us; subagent threads are excluded so the gauge reflects the main agent.
  defp extract_main_context(update, parent_thread_id) do
    payload = update[:payload] || Map.get(update, "payload") || Map.get(update, :payload)

    if main_thread_update?(payload, parent_thread_id) do
      {extract_context_tokens(update), extract_context_window(update)}
    else
      {nil, nil}
    end
  end

  defp main_thread_update?(payload, parent_thread_id) when is_map(payload),
    do: not subagent_thread?(event_thread_id(payload), parent_thread_id)

  defp main_thread_update?(_payload, _parent_thread_id), do: false

  defp extract_context_tokens(update) do
    case find_map_at_paths(context_payload_roots(update), last_usage_paths()) do
      last when is_map(last) -> get_token_usage(last, :input)
      _ -> nil
    end
  end

  defp extract_context_window(update) do
    roots = context_payload_roots(update)

    Enum.find_value(roots, fn root ->
      Enum.find_value(context_window_paths(), fn path -> integer_like(map_at_path(root, path)) end)
    end)
  end

  defp context_payload_roots(update) do
    [
      update[:payload],
      Map.get(update, "payload"),
      Map.get(update, :payload),
      update[:usage],
      Map.get(update, "usage"),
      update
    ]
    |> Enum.filter(&is_map/1)
  end

  defp find_map_at_paths(roots, paths) do
    Enum.find_value(roots, fn root ->
      Enum.find_value(paths, &map_at_path_if_map(root, &1))
    end)
  end

  defp map_at_path_if_map(root, path) do
    case map_at_path(root, path) do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp last_usage_paths do
    [
      ["params", "msg", "payload", "info", "last_token_usage"],
      [:params, :msg, :payload, :info, :last_token_usage],
      ["params", "msg", "info", "last_token_usage"],
      [:params, :msg, :info, :last_token_usage],
      ["params", "tokenUsage", "last"],
      [:params, :tokenUsage, :last],
      ["tokenUsage", "last"],
      [:tokenUsage, :last]
    ]
  end

  defp context_window_paths do
    [
      ["params", "msg", "payload", "info", "model_context_window"],
      [:params, :msg, :payload, :info, :model_context_window],
      ["params", "msg", "info", "model_context_window"],
      [:params, :msg, :info, :model_context_window],
      ["params", "tokenUsage", "model_context_window"],
      [:params, :tokenUsage, :model_context_window],
      ["params", "tokenUsage", "modelContextWindow"],
      [:params, :tokenUsage, :modelContextWindow],
      ["tokenUsage", "model_context_window"],
      [:tokenUsage, :model_context_window],
      ["tokenUsage", "modelContextWindow"],
      [:tokenUsage, :modelContextWindow],
      ["model_context_window"],
      [:model_context_window],
      ["modelContextWindow"],
      [:modelContextWindow]
    ]
  end

  defp positive_or_keep(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_or_keep(_value, fallback), do: fallback

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct =
      Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits) ||
        Map.get(payload, "rateLimits") || Map.get(payload, :rateLimits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limitId") ||
        Map.get(payload, :limitId) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name) ||
        Map.get(payload, "limitName") ||
        Map.get(payload, :limitName)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp handoff_gate_snapshot(metadata, now) do
    case Map.get(metadata, :handoff_gate_state) do
      gate when is_map(gate) ->
        Map.put(
          gate,
          :pending_age_seconds,
          running_seconds(Map.get(metadata, :lifecycle_started_at), now)
        )

      _gate ->
        nil
    end
  end

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
