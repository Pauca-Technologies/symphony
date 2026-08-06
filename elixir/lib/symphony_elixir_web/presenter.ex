defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard}

  @live_transcript_read_limit 1_000_000
  @live_transcript_block_limit 200
  @live_transcript_content_limit 512_000
  @transcript_sentinel_bytes 64

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            queued: length(Map.get(snapshot, :queued, [])),
            retrying: length(snapshot.retrying),
            waiting: length(Map.get(snapshot, :waiting, []))
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          queued: Enum.map(Map.get(snapshot, :queued, []), &queued_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          waiting: Enum.map(Map.get(snapshot, :waiting, []), &waiting_entry_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits,
          backend_usage: backend_usage_payload(snapshot),
          mode: mode_payload(snapshot),
          quota_circuits:
            snapshot
            |> Map.get(:quota_circuits, [])
            |> Enum.map(&quota_circuit_payload/1)
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case issue_payload_with_mode(issue_identifier, orchestrator, snapshot_timeout_ms, %{}, :full) do
      {:ok, payload, _transcript_cache} -> {:ok, payload}
      error -> error
    end
  end

  # Cache-aware variant used by the live detail page. It seeds a bounded tail of
  # the persisted transcript and parses only newly appended bytes thereafter.
  # The three-argument function remains the explicit full-history projection.
  @spec issue_payload(String.t(), GenServer.name(), timeout(), map()) ::
          {:ok, map(), map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms, transcript_cache)
      when is_binary(issue_identifier) and is_map(transcript_cache) do
    issue_payload_with_mode(issue_identifier, orchestrator, snapshot_timeout_ms, transcript_cache, :live)
  end

  defp issue_payload_with_mode(issue_identifier, orchestrator, snapshot_timeout_ms, transcript_cache, mode) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        waiting = Enum.find(Map.get(snapshot, :waiting, []), &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) and is_nil(waiting) do
          {:error, :issue_not_found}
        else
          {body, new_cache} = issue_payload_body(issue_identifier, running, retry, waiting, transcript_cache, mode)
          {:ok, body, new_cache}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  @spec drain_payload(GenServer.name(), boolean()) ::
          {:ok, map()} | {:error, :unavailable | term()}
  def drain_payload(orchestrator, enabled) when is_boolean(enabled) do
    case Orchestrator.set_drain_mode(orchestrator, enabled) do
      {:ok, mode} -> {:ok, mode_payload(%{mode: mode})}
      {:error, reason} -> {:error, reason}
      :unavailable -> {:error, :unavailable}
    end
  end

  @spec wait_control_payload(:resume | :cancel, String.t()) ::
          {:ok, map()} | {:error, :not_found | :unavailable}
  def wait_control_payload(action, identifier),
    do: wait_control_payload(action, identifier, Orchestrator)

  @spec wait_control_payload(:resume | :cancel, String.t(), GenServer.server()) ::
          {:ok, map()} | {:error, :not_found | :unavailable}
  def wait_control_payload(action, identifier, orchestrator)
      when action in [:resume, :cancel] and is_binary(identifier) do
    result =
      case action do
        :resume -> Orchestrator.resume_wait(orchestrator, identifier)
        :cancel -> Orchestrator.cancel_wait(orchestrator, identifier)
      end

    case result do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> {:error, reason}
      :unavailable -> {:error, :unavailable}
    end
  end

  defp mode_payload(snapshot) do
    mode = Map.get(snapshot, :mode, %{})

    %{
      draining: Map.get(mode, :draining, false),
      started_at: iso8601(Map.get(mode, :started_at))
    }
  end

  defp issue_payload_body(issue_identifier, running, retry, waiting, transcript_cache, mode) do
    secondary = secondary_issue_entry(retry, waiting)
    primary = primary_issue_entry(running, secondary)
    {transcript, new_transcript_cache} = transcript_payload(primary, transcript_cache, mode)

    body = %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, secondary),
      title: title_from_entries(running, secondary),
      status: issue_status(running, retry, waiting),
      workspace: %{
        path: workspace_path(issue_identifier, running, secondary),
        host: workspace_host(running, secondary)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      agent: agent_payload(primary || %{}),
      running: optional_payload(running, &running_issue_payload/1),
      retry: optional_payload(retry, &retry_issue_payload/1),
      waiting: optional_payload(waiting, &waiting_entry_payload/1),
      logs: %{
        codex_session_logs: codex_session_logs_payload(running, secondary)
      },
      transcript: transcript,
      recent_events: issue_recent_events(running),
      last_error: issue_last_error(retry, waiting),
      tracked: %{}
    }

    {body, new_transcript_cache}
  end

  defp secondary_issue_entry(%{} = retry, _waiting), do: retry
  defp secondary_issue_entry(nil, waiting), do: waiting
  defp primary_issue_entry(%{} = running, _secondary), do: running
  defp primary_issue_entry(nil, secondary), do: secondary
  defp optional_payload(nil, _mapper), do: nil
  defp optional_payload(entry, mapper), do: mapper.(entry)
  defp issue_recent_events(nil), do: []
  defp issue_recent_events(running), do: recent_events_payload(running)
  defp issue_last_error(%{} = retry, _waiting), do: Map.get(retry, :error)
  defp issue_last_error(nil, %{} = waiting), do: Map.get(waiting, :last_error)
  defp issue_last_error(nil, nil), do: nil

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp title_from_entries(running, retry),
    do: (running && Map.get(running, :title)) || (retry && Map.get(retry, :title))

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: Map.get(retry, :attempt, 0) || 0

  defp issue_status(_running, _retry, %{}), do: "waiting"
  defp issue_status(_running, nil, nil), do: "running"
  defp issue_status(nil, _retry, nil), do: "retrying"
  defp issue_status(_running, _retry, nil), do: "running"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: Map.get(entry, :title),
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      agent: agent_payload(entry),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      recent_events: recent_events_payload(entry),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      },
      context: context_payload(entry)
    }
    |> maybe_put_persistent_worker(entry)
    |> maybe_put_scheduling(entry)
    |> maybe_put_handoff_gate(entry)
    |> maybe_put_review(entry)
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: Map.get(entry, :title),
      attempt: entry.attempt,
      status: to_string(Map.get(entry, :status, :scheduled)),
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      backend: Map.get(entry, :backend),
      failure_class: stringify_atom(Map.get(entry, :failure_class)),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp waiting_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: entry.title,
      status: to_string(entry.status),
      reason: entry.reason,
      condition: entry.condition,
      condition_key: entry.condition_key,
      backend: entry.backend,
      worker_host: entry.worker_host,
      workspace_path: entry.workspace_path,
      parked_at: iso8601(entry.parked_at),
      next_probe_at: iso8601(entry.next_probe_at),
      waiting_seconds: entry.waiting_seconds,
      probe_attempt: entry.probe_attempt,
      last_observation: entry.last_observation,
      last_error: entry.last_error
    }
  end

  defp queued_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: entry.title,
      state: entry.state,
      repository: entry.repository_id,
      reason: entry.reason,
      queue_time_ms: entry.queue_time_ms,
      base_age_seconds: entry.base_age_seconds,
      overlap_score: entry.overlap_score,
      overlap_paths: entry.overlap_paths,
      predicted_paths: entry.predicted_paths,
      suggested_order: entry.suggested_order,
      suggested_order_omitted: entry.suggested_order_omitted,
      override: entry.override,
      policy: entry.policy,
      max_concurrent: entry.max_concurrent
    }
  end

  defp scheduling_payload(entry) do
    %{
      repository: Map.get(entry, :repository_id),
      path_source: Map.get(entry, :scheduling_path_source),
      paths: Map.get(entry, :scheduling_paths, []),
      base_sha: Map.get(entry, :base_sha),
      candidate_base_sha: Map.get(entry, :candidate_base_sha),
      base_age_seconds: Map.get(entry, :base_age_seconds),
      workspace_dirty: Map.get(entry, :workspace_dirty)
    }
  end

  defp quota_circuit_payload(circuit) do
    %{
      backend: Map.get(circuit, :backend),
      account_scope: Map.get(circuit, :account_scope),
      worker_host: Map.get(circuit, :worker_host),
      provider_limit_id: Map.get(circuit, :provider_limit_id),
      state: stringify_atom(Map.get(circuit, :state)),
      reason: Map.get(circuit, :reason),
      opened_at: iso8601(Map.get(circuit, :opened_at)),
      reset_at: iso8601(Map.get(circuit, :reset_at)),
      next_probe_at: iso8601(Map.get(circuit, :next_probe_at)),
      next_probe_in_ms: Map.get(circuit, :next_probe_in_ms),
      probe_issue_id: Map.get(circuit, :probe_issue_id),
      parked_issue_count: Map.get(circuit, :parked_issue_count, 0)
    }
  end

  defp backend_usage_payload(snapshot) do
    snapshot
    |> backend_usage_entries()
    |> Enum.map(fn entry ->
      rate_limits = Map.get(entry, :rate_limits)

      %{
        backend: Map.get(entry, :backend) || "unknown",
        account_scope: Map.get(entry, :account_scope) || "local",
        running_agents: Map.get(entry, :running_agents, 0),
        available: is_map(rate_limits),
        limit_id: rate_limit_value(rate_limits, ["limit_id", "limitId", "limit_name", "limitName"]),
        plan_type: rate_limit_value(rate_limits, ["plan_type", "planType"]),
        credits: rate_limit_credits_payload(rate_limits),
        updated_at: iso8601(Map.get(entry, :updated_at)),
        limits: %{
          five_hour: rate_limit_window_payload(rate_limits, 300, "primary"),
          weekly: rate_limit_window_payload(rate_limits, 10_080, "secondary")
        }
      }
    end)
  end

  defp backend_usage_entries(%{backend_usage: entries}) when is_list(entries), do: entries

  # Compatibility for snapshot producers that predate backend-scoped usage.
  # Only attach the legacy global snapshot to a local Codex run; never label a
  # stale Codex value as ACP or Claude usage.
  defp backend_usage_entries(snapshot) do
    snapshot
    |> Map.get(:running, [])
    |> Enum.group_by(fn entry ->
      backend = Map.get(entry, :backend) || "unknown"
      worker_host = Map.get(entry, :worker_host)
      {backend, account_scope(worker_host), worker_host}
    end)
    |> Enum.map(fn {{backend, account_scope, worker_host}, entries} ->
      rate_limits =
        if backend == "codex" and account_scope == "local",
          do: Map.get(snapshot, :rate_limits),
          else: nil

      %{
        backend: backend,
        account_scope: account_scope,
        worker_host: worker_host,
        running_agents: length(entries),
        rate_limits: rate_limits,
        updated_at: nil
      }
    end)
    |> Enum.sort_by(&{&1.backend, &1.account_scope})
  end

  defp account_scope(worker_host) when is_binary(worker_host), do: "worker:#{worker_host}"
  defp account_scope(_worker_host), do: "local"

  defp rate_limit_window_payload(rate_limits, window_minutes, fallback_key)
       when is_map(rate_limits) do
    named_key = if window_minutes == 300, do: "five_hour", else: "seven_day"

    bucket =
      Map.get(rate_limits, named_key) || rate_limit_atom_value(rate_limits, named_key) ||
        [Map.get(rate_limits, "primary") || Map.get(rate_limits, :primary), Map.get(rate_limits, "secondary") || Map.get(rate_limits, :secondary)]
        |> Enum.find(&rate_limit_window?(&1, window_minutes)) ||
        Map.get(rate_limits, fallback_key) || rate_limit_atom_value(rate_limits, fallback_key)

    normalize_rate_limit_bucket(bucket, window_minutes)
  end

  defp rate_limit_window_payload(_rate_limits, _window_minutes, _fallback_key), do: nil

  defp rate_limit_window?(bucket, window_minutes) when is_map(bucket) do
    rate_limit_value(bucket, [
      "window_minutes",
      "windowMinutes",
      "window_duration_mins",
      "windowDurationMins"
    ]) == window_minutes
  end

  defp rate_limit_window?(_bucket, _window_minutes), do: false

  defp normalize_rate_limit_bucket(bucket, default_window_minutes) when is_map(bucket) do
    used_percent =
      rate_limit_value(bucket, ["used_percent", "usedPercent", "used_percentage", "usedPercentage"]) ||
        used_percent_from_remaining(bucket)

    if is_number(used_percent) do
      used_percent = used_percent |> Kernel.*(1.0) |> max(0.0) |> min(100.0) |> Float.round(1)

      %{
        used_percent: used_percent,
        remaining_percent: Float.round(100 - used_percent, 1),
        window_minutes:
          rate_limit_value(bucket, [
            "window_minutes",
            "windowMinutes",
            "window_duration_mins",
            "windowDurationMins"
          ]) || default_window_minutes,
        resets_at: rate_limit_reset_at(bucket)
      }
    end
  end

  defp normalize_rate_limit_bucket(_bucket, _default_window_minutes), do: nil

  defp used_percent_from_remaining(bucket) do
    remaining = rate_limit_value(bucket, ["remaining"])
    limit = rate_limit_value(bucket, ["limit"])

    if is_number(remaining) and is_number(limit) and limit > 0,
      do: (limit - remaining) / limit * 100
  end

  defp rate_limit_reset_at(bucket) do
    case rate_limit_value(bucket, ["resets_at", "resetsAt", "reset_at", "resetAt"]) do
      unix when is_integer(unix) -> unix |> DateTime.from_unix!() |> DateTime.to_iso8601()
      %DateTime{} = datetime -> DateTime.to_iso8601(datetime)
      value when is_binary(value) -> value
      _value -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp rate_limit_value(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key -> Map.get(map, key) || rate_limit_atom_value(map, key) end)
  end

  defp rate_limit_value(_map, _keys), do: nil

  defp rate_limit_credits_payload(rate_limits) when is_map(rate_limits) do
    case rate_limit_value(rate_limits, ["credits"]) do
      credits when is_map(credits) ->
        %{
          unlimited: rate_limit_value(credits, ["unlimited"]) == true,
          available: rate_limit_value(credits, ["has_credits", "hasCredits"]) == true,
          balance: rate_limit_value(credits, ["balance"])
        }

      _credits ->
        nil
    end
  end

  defp rate_limit_credits_payload(_rate_limits), do: nil

  defp rate_limit_atom_value(map, key) when is_binary(key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      agent: agent_payload(running),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      recent_events: recent_events_payload(running),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      },
      context: context_payload(running)
    }
    |> maybe_put_persistent_worker(running)
    |> maybe_put_scheduling(running)
    |> maybe_put_handoff_gate(running)
    |> maybe_put_review(running)
  end

  defp maybe_put_scheduling(payload, entry) do
    scheduling = scheduling_payload(entry)

    if scheduling.repository || scheduling.base_sha || scheduling.candidate_base_sha ||
         scheduling.paths != [] || is_boolean(scheduling.workspace_dirty) do
      Map.put(payload, :scheduling, scheduling)
    else
      payload
    end
  end

  defp maybe_put_persistent_worker(payload, entry) do
    case Map.get(entry, :persistent_worker_id) do
      worker_id when is_binary(worker_id) -> Map.put(payload, :persistent_worker_id, worker_id)
      _other -> payload
    end
  end

  defp maybe_put_review(payload, entry) do
    case Map.get(entry, :review_state) do
      review when is_map(review) -> Map.put(payload, :review, review)
      _review -> payload
    end
  end

  defp maybe_put_handoff_gate(payload, entry) do
    case Map.get(entry, :handoff_gate) do
      gate when is_map(gate) -> Map.put(payload, :handoff_gate, gate)
      _gate -> payload
    end
  end

  # The actual backend + model/effort the run is using, captured from the running
  # session (not re-derived from the issue's labels). `backend` is the resolved
  # backend module's config name; `model` is what was handed to or resolved by
  # the agent (nil only until the run reports one, or when a backend omits it).
  defp agent_payload(entry) when is_map(entry) do
    %{
      backend: blank_to_nil(Map.get(entry, :backend)),
      model: blank_to_nil(Map.get(entry, :model)),
      reasoning_effort: blank_to_nil(Map.get(entry, :reasoning_effort)),
      profile: blank_to_nil(Map.get(entry, :profile))
    }
    |> maybe_put_efficiency(entry)
  end

  defp maybe_put_efficiency(agent, %{budget_profile: profile} = entry)
       when is_binary(profile) do
    Map.put(agent, :efficiency, %{
      task_type: Map.get(entry, :task_type),
      classifier_confidence: Map.get(entry, :routing_confidence),
      budget_profile: profile,
      mode: Map.get(entry, :budget_mode),
      metrics: Map.get(entry, :budget_metrics),
      transitions: Map.get(entry, :budget_transitions, [])
    })
  end

  defp maybe_put_efficiency(agent, _entry), do: agent

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp stringify_atom(nil), do: nil
  defp stringify_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_atom(value) when is_binary(value), do: value
  defp stringify_atom(_value), do: nil

  defp context_payload(entry) do
    tokens = Map.get(entry, :codex_context_tokens, 0)
    window = Map.get(entry, :codex_context_window)

    %{
      tokens: tokens,
      window: window,
      fill_ratio: context_fill_ratio(tokens, window)
    }
  end

  defp context_fill_ratio(tokens, window)
       when is_integer(tokens) and is_integer(window) and window > 0 do
    Float.round(min(tokens / window, 1.0), 4)
  end

  defp context_fill_ratio(_tokens, _window), do: nil

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      status: to_string(Map.get(retry, :status, :scheduled)),
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      backend: Map.get(retry, :backend),
      failure_class: stringify_atom(Map.get(retry, :failure_class)),
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp codex_session_logs_payload(running, retry) do
    logs =
      (running && Map.get(running, :codex_session_logs)) ||
        (retry && Map.get(retry, :codex_session_logs)) ||
        []

    Enum.map(logs, &codex_session_log_payload/1)
  end

  defp recent_events_payload(running) do
    running
    |> Map.get(:recent_codex_events, [])
    |> Enum.map(&recent_event_payload/1)
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp recent_event_payload(%{timestamp: timestamp, event: event} = message) do
    %{
      at: iso8601(timestamp),
      event: to_string(event),
      message: summarize_message(message)
    }
  end

  defp recent_event_payload(_message), do: %{at: nil, event: nil, message: nil}

  defp codex_session_log_payload(log_entry) when is_map(log_entry) do
    %{
      session_id: Map.get(log_entry, :session_id),
      path: Map.get(log_entry, :path),
      started_at: iso8601(Map.get(log_entry, :started_at)),
      last_event_at: iso8601(Map.get(log_entry, :last_event_at)),
      worker_host: Map.get(log_entry, :worker_host),
      workspace_path: Map.get(log_entry, :workspace_path)
    }
    |> maybe_put_log_field(:storage_schema_version, Map.get(log_entry, :storage_schema_version))
    |> maybe_put_log_field(:raw_trace_path, Map.get(log_entry, :raw_trace_path))
    |> maybe_put_log_field(:raw_trace_pending_path, Map.get(log_entry, :raw_trace_pending_path))
  end

  defp maybe_put_log_field(payload, _key, nil), do: payload
  defp maybe_put_log_field(payload, key, value), do: Map.put(payload, key, value)

  defp transcript_payload(entry, transcript_cache, mode) when is_map(entry) do
    case latest_session_log_entry(entry) do
      %{path: path} = log_entry when is_binary(path) ->
        {blocks, truncated, new_cache} =
          transcript_blocks_for_entry(entry, path, transcript_cache, mode)

        transcript = %{
          session_id: Map.get(log_entry, :session_id),
          path: path,
          started_at: iso8601(Map.get(log_entry, :started_at)),
          last_event_at: iso8601(Map.get(log_entry, :last_event_at)),
          blocks: blocks
        }

        transcript = if mode == :live, do: Map.put(transcript, :truncated, truncated), else: transcript
        {transcript, new_cache}

      _ ->
        {empty_transcript(mode), transcript_cache}
    end
  end

  defp transcript_payload(_entry, transcript_cache, mode),
    do: {empty_transcript(mode), transcript_cache}

  defp empty_transcript(:live),
    do: %{session_id: nil, path: nil, started_at: nil, last_event_at: nil, truncated: false, blocks: []}

  defp empty_transcript(:full),
    do: %{session_id: nil, path: nil, started_at: nil, last_event_at: nil, blocks: []}

  defp latest_session_log_entry(entry) do
    entry
    |> Map.get(:codex_session_logs, [])
    |> Enum.max_by(
      fn log_entry ->
        Map.get(log_entry, :last_event_at) || Map.get(log_entry, :started_at) || ~U[1970-01-01 00:00:00Z]
      end,
      fn -> nil end
    )
  end

  # Explicit API callers get the complete persisted history. The live page uses
  # a bounded tail and carries an append offset so frequent updates only parse
  # new NDJSON records.
  defp transcript_blocks_for_entry(entry, path, transcript_cache, :full)
       when is_map(entry) and is_binary(path) and is_map(transcript_cache) do
    case load_transcript_blocks(path) do
      blocks when is_list(blocks) and blocks != [] -> {blocks, false, transcript_cache}
      _unavailable -> {ring_buffer_blocks(entry), false, transcript_cache}
    end
  end

  defp transcript_blocks_for_entry(entry, path, transcript_cache, :live)
       when is_map(entry) and is_binary(path) and is_map(transcript_cache) do
    case transcript_file_info(path) do
      {:ok, file_info} ->
        live_transcript_blocks(entry, path, file_info, transcript_cache)

      :error ->
        {ring_buffer_blocks(entry), false, transcript_cache}
    end
  end

  defp live_transcript_blocks(entry, path, file_info, transcript_cache) do
    transcript_cache
    |> Map.get(path)
    |> resolve_live_transcript_cache(entry, path, file_info, transcript_cache)
  end

  defp resolve_live_transcript_cache(
         %{identity: identity, offset: offset, mtime: mtime} = cached,
         _entry,
         _path,
         file_info,
         transcript_cache
       )
       when identity == file_info.identity and offset == file_info.size and mtime == file_info.mtime,
       do: {cached.blocks, cached.truncated, transcript_cache}

  defp resolve_live_transcript_cache(
         %{identity: identity, offset: offset},
         entry,
         path,
         file_info,
         transcript_cache
       )
       when identity == file_info.identity and offset == file_info.size,
       do: seed_live_transcript(entry, path, file_info, transcript_cache)

  defp resolve_live_transcript_cache(
         %{identity: identity, offset: offset} = cached,
         entry,
         path,
         file_info,
         transcript_cache
       )
       when identity == file_info.identity and offset <= file_info.size and
              file_info.size - offset <= @live_transcript_read_limit,
       do: append_live_transcript(entry, path, file_info, cached, transcript_cache)

  defp resolve_live_transcript_cache(
         _stale_or_missing,
         entry,
         path,
         file_info,
         transcript_cache
       ),
       do: seed_live_transcript(entry, path, file_info, transcript_cache)

  defp append_live_transcript(entry, path, file_info, cached, transcript_cache) do
    if cached_sentinel_matches?(path, cached) do
      case read_file_range(path, cached.offset, file_info.size - cached.offset) do
        {:ok, appended} ->
          {lines, carry, carry_truncated} =
            split_complete_transcript_lines(cached.carry <> appended)

          fragments = transcript_fragments(lines)
          {blocks, blocks_truncated} = bound_live_transcript(cached.blocks ++ fragments)
          truncated = cached.truncated or carry_truncated or blocks_truncated
          new_entry = live_cache_entry(path, file_info, blocks, carry, truncated)

          {fallback_live_blocks(blocks, entry), truncated, %{path => new_entry}}

        :error ->
          {fallback_live_blocks(cached.blocks, entry), cached.truncated, transcript_cache}
      end
    else
      seed_live_transcript(entry, path, file_info, transcript_cache)
    end
  end

  defp seed_live_transcript(entry, path, file_info, transcript_cache) do
    start_offset = max(file_info.size - @live_transcript_read_limit, 0)

    case read_file_range(path, start_offset, file_info.size - start_offset) do
      {:ok, content} ->
        {content, leading_truncated} = drop_partial_leading_record(content, start_offset)
        {lines, carry, carry_truncated} = split_complete_transcript_lines(content)
        {blocks, blocks_truncated} = lines |> transcript_fragments() |> bound_live_transcript()
        truncated = leading_truncated or carry_truncated or blocks_truncated
        blocks = fallback_live_blocks(blocks, entry)
        new_entry = live_cache_entry(path, file_info, blocks, carry, truncated)

        {blocks, truncated, %{path => new_entry}}

      :error ->
        {ring_buffer_blocks(entry), false, transcript_cache}
    end
  end

  defp fallback_live_blocks([], entry), do: ring_buffer_blocks(entry)
  defp fallback_live_blocks(blocks, _entry), do: blocks

  defp live_cache_entry(path, file_info, blocks, carry, truncated) do
    %{
      identity: file_info.identity,
      mtime: file_info.mtime,
      offset: file_info.size,
      sentinel: transcript_sentinel(path, file_info.size),
      blocks: blocks,
      carry: carry,
      truncated: truncated
    }
  end

  defp cached_sentinel_matches?(_path, %{offset: 0}), do: true

  defp cached_sentinel_matches?(path, cached) do
    transcript_sentinel(path, cached.offset) == cached.sentinel
  end

  defp transcript_sentinel(path, offset) do
    length = min(offset, @transcript_sentinel_bytes)

    case read_file_range(path, offset - length, length) do
      {:ok, sentinel} -> sentinel
      :error -> nil
    end
  end

  defp drop_partial_leading_record(content, 0), do: {content, false}

  defp drop_partial_leading_record(content, _start_offset) do
    case :binary.match(content, "\n") do
      {index, 1} ->
        remaining = byte_size(content) - index - 1
        {binary_part(content, index + 1, remaining), true}

      :nomatch ->
        {<<>>, true}
    end
  end

  defp split_complete_transcript_lines(content) do
    parts = :binary.split(content, "\n", [:global])

    {lines, carry} =
      if binary_ends_with_newline?(content) do
        {Enum.drop(parts, -1), <<>>}
      else
        {Enum.drop(parts, -1), List.last(parts) || <<>>}
      end

    if byte_size(carry) > @live_transcript_read_limit do
      {lines, <<>>, true}
    else
      {lines, carry, false}
    end
  end

  defp binary_ends_with_newline?(<<>>), do: false
  defp binary_ends_with_newline?(content), do: :binary.last(content) == ?\n

  defp transcript_file_info(path) when is_binary(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} ->
        {:ok,
         %{
           identity: {stat.major_device, stat.minor_device, stat.inode},
           mtime: stat.mtime,
           size: stat.size
         }}

      {:error, _reason} ->
        :error
    end
  end

  defp read_file_range(_path, _offset, 0), do: {:ok, <<>>}

  defp read_file_range(path, offset, length) do
    case File.open(path, [:read, :binary]) do
      {:ok, io_device} ->
        result =
          case :file.pread(io_device, offset, length) do
            {:ok, content} -> {:ok, content}
            _ -> :error
          end

        File.close(io_device)
        result

      {:error, _reason} ->
        :error
    end
  end

  defp ring_buffer_blocks(entry),
    do: entry |> Map.get(:recent_codex_transcript_blocks) |> List.wrap()

  # Reads and parses the entire persisted session log. The on-disk log is the
  # complete history, so we deliberately read all of it — no byte/line/block
  # window — and never drop older entries. Callers memoize the result on the
  # file's stamp (see `transcript_blocks_for_entry/3`) to avoid re-parsing an
  # unchanged file on every dashboard refresh.
  defp load_transcript_blocks(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> transcript_fragments()

      {:error, _reason} ->
        []
    end
  end

  defp transcript_fragments(lines) when is_list(lines) do
    lines
    |> Enum.map(&transcript_record/1)
    |> Enum.reject(&is_nil/1)
    # `transcript_fragment/1` may yield a single fragment, nil, or a list
    # (an ACP `tool_call_update` produces both a tool and an output fragment).
    |> Enum.flat_map(fn record -> record |> transcript_fragment() |> List.wrap() end)
    |> merge_transcript_fragments()
  end

  defp bound_live_transcript(blocks) when is_list(blocks) do
    merged = merge_transcript_fragments(blocks)
    count_bounded = Enum.take(merged, -@live_transcript_block_limit)
    count_truncated = length(count_bounded) < length(merged)

    {kept_reversed, _bytes, content_truncated} =
      count_bounded
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0, false}, fn block, {kept, bytes, truncated} ->
        block_bytes = transcript_block_content_bytes(block)

        cond do
          bytes + block_bytes <= @live_transcript_content_limit ->
            {:cont, {[block | kept], bytes + block_bytes, truncated}}

          kept == [] ->
            trimmed = trim_transcript_block(block, @live_transcript_content_limit)
            {:halt, {[trimmed], @live_transcript_content_limit, true}}

          true ->
            {:halt, {kept, bytes, true}}
        end
      end)

    {kept_reversed, count_truncated or content_truncated}
  end

  defp transcript_block_content_bytes(block) do
    binary_field_bytes(block, :title) + binary_field_bytes(block, :text)
  end

  defp binary_field_bytes(block, field) do
    case Map.get(block, field) do
      value when is_binary(value) -> byte_size(value)
      _ -> 0
    end
  end

  defp trim_transcript_block(block, limit) do
    title = Map.get(block, :title)
    text = Map.get(block, :text)
    title_bytes = if is_binary(title), do: min(byte_size(title), limit), else: 0
    remaining = limit - title_bytes

    block
    |> maybe_replace_binary_field(:title, title, title_bytes)
    |> maybe_replace_binary_field(:text, text, remaining)
  end

  defp maybe_replace_binary_field(block, field, value, limit) when is_binary(value),
    do: Map.put(block, field, utf8_suffix(value, limit))

  defp maybe_replace_binary_field(block, _field, _value, _limit), do: block

  defp utf8_suffix(_value, 0), do: <<>>
  defp utf8_suffix(value, limit) when byte_size(value) <= limit, do: value

  defp utf8_suffix(value, limit) do
    value
    |> binary_part(byte_size(value) - limit, limit)
    |> ensure_valid_utf8_suffix()
  end

  defp ensure_valid_utf8_suffix(<<>>), do: <<>>

  defp ensure_valid_utf8_suffix(value) do
    if String.valid?(value) do
      value
    else
      <<_byte, rest::binary>> = value
      ensure_valid_utf8_suffix(rest)
    end
  end

  defp transcript_record(line) when is_binary(line) do
    line
    |> String.trim()
    |> case do
      "" ->
        nil

      content ->
        case Jason.decode(content) do
          {:ok, payload} when is_map(payload) -> payload
          _ -> nil
        end
    end
  end

  defp transcript_fragment(%{"payload" => %{} = payload} = record) do
    method = map_value(payload, ["method"])
    at = Map.get(record, "at")
    origin = transcript_origin(payload, parent_thread_from_session_id(Map.get(record, "session_id")))

    stream_transcript_fragment(method, at, payload, origin)
  end

  defp transcript_fragment(_record), do: nil

  defp stream_transcript_fragment(method, at, payload, origin) do
    cond do
      method in ["codex/event/agent_message_content_delta", "codex/event/agent_message_delta", "item/agentMessage/delta"] ->
        build_stream_fragment("agent", at, payload, agent_text_paths(), origin)

      method in ["codex/event/exec_command_output_delta", "item/commandExecution/outputDelta"] ->
        build_stream_fragment("output", at, payload, output_text_paths(), origin)

      method == "codex/event/exec_command_begin" ->
        build_stream_fragment("command", at, payload, extract_command(payload), origin)

      method in reasoning_methods() ->
        build_stream_fragment("reasoning", at, payload, reasoning_text_paths(), origin)

      true ->
        control_transcript_fragment(method, at, payload, origin)
    end
  end

  defp control_transcript_fragment(method, at, payload, origin) do
    cond do
      method == "item/tool/call" ->
        build_tool_fragment(at, payload, origin)

      method in ["item/started", "item/completed"] ->
        codex_item_fragments(method, at, payload, origin)

      method == "thread/compacted" ->
        build_compaction_fragment(at, payload, origin)

      # Native ACP streaming notifications (Option B): dispatch on the
      # `update.sessionUpdate` discriminator so tool kinds and plans render.
      method == "session/update" ->
        build_acp_fragment(at, payload, origin)

      true ->
        nil
    end
  end

  defp build_acp_fragment(at, payload, origin) do
    update = acp_update(payload)

    case map_value(update, ["sessionUpdate"]) do
      "agent_message_chunk" ->
        build_text_fragment("agent", at, acp_chunk_text(update), origin)

      "agent_thought_chunk" ->
        build_text_fragment("reasoning", at, acp_chunk_text(update), origin)

      "tool_call" ->
        build_acp_tool_fragment(at, update, origin)

      "tool_call_update" ->
        acp_tool_update_fragments(at, update, origin)

      "plan" ->
        build_acp_plan_fragment(at, update, origin)

      _ ->
        nil
    end
  end

  defp acp_update(payload) do
    case map_value(payload, ["params", "update"]) do
      %{} = update -> update
      _ -> %{}
    end
  end

  defp acp_chunk_text(update) when is_map(update), do: acp_content_text(Map.get(update, "content"))

  defp acp_content_text(%{"content" => nested}), do: acp_content_text(nested)
  defp acp_content_text(%{"text" => text}) when is_binary(text), do: text

  defp acp_content_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.map(&acp_content_text/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.join("")
  end

  defp acp_content_text(_content), do: nil

  defp build_acp_tool_fragment(at, update, origin) do
    Map.merge(
      %{
        kind: "tool",
        at: at,
        tool_call_id: acp_tool_call_id(update),
        title: acp_tool_title(update),
        text: normalize_transcript_text(acp_tool_arguments(update))
      },
      origin
    )
  end

  # See `Orchestrator.acp_tool_update_blocks/3`: a `tool_call_update` carries the
  # cumulative state of an in-flight tool call. Refresh the arguments and emit
  # the latest output, both keyed on `toolCallId` so `merge_transcript_fragments/1`
  # updates the existing fragments in place instead of duplicating them.
  defp acp_tool_update_fragments(at, update, origin) do
    [
      acp_tool_args_fragment(at, update, origin),
      acp_tool_output_fragment(at, update, origin)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp acp_tool_args_fragment(at, update, origin) do
    case acp_tool_arguments(update) do
      "" -> nil
      _args -> build_acp_tool_fragment(at, update, origin)
    end
  end

  defp acp_tool_output_fragment(at, update, origin) do
    case build_text_fragment("output", at, acp_chunk_text(update), origin) do
      nil -> nil
      fragment -> Map.put(fragment, :tool_call_id, acp_tool_call_id(update))
    end
  end

  defp acp_tool_call_id(update), do: presence(Map.get(update, "toolCallId"))

  defp acp_tool_title(update) do
    kind = presence(Map.get(update, "kind"))
    title = presence(Map.get(update, "title"))

    cond do
      kind && title && String.downcase(kind) == String.downcase(title) -> title
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

  defp build_acp_plan_fragment(at, update, origin) do
    case acp_plan_text(update) do
      "" -> nil
      text -> Map.merge(%{kind: "plan", at: at, text: text}, origin)
    end
  end

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

  defp build_tool_fragment(at, payload, origin) when is_map(payload) do
    {name, args_text} = extract_tool(payload)
    Map.merge(%{kind: "tool", at: at, title: name, text: normalize_transcript_text(args_text)}, origin)
  end

  # Codex reports each tool call's lifecycle as an `item/started` then an
  # `item/completed` notification. The streamed deltas handled above already
  # cover the agent-message, reasoning and command *output* items, but the call
  # itself — the command line, the file diff, the MCP/web-search/subagent
  # invocation — only ever arrives inside these item events. Without rendering
  # them the details page showed orphaned command output with no command above
  # it, and surfaced no MCP/web/subagent tool calls at all. `dynamicToolCall` is
  # intentionally skipped: it is the Symphony-provided tool the app-server
  # dispatches via `item/tool/call`, already rendered by `build_tool_fragment/3`.
  defp codex_item_fragments(method, at, payload, origin) do
    with %{} = item <- map_value(payload, ["params", "item"]),
         type when is_binary(type) <- Map.get(item, "type") do
      codex_item_fragment(method, type, at, item, presence(Map.get(item, "id")), origin)
    else
      _ -> nil
    end
  end

  defp codex_item_fragment("item/started", "commandExecution", at, item, id, origin),
    do: build_item_fragment("command", at, codex_command_text(item), id, origin)

  defp codex_item_fragment("item/started", "fileChange", at, item, id, origin),
    do: codex_item_tool_fragment(at, id, codex_file_change_title(item), codex_file_change_text(item), origin)

  defp codex_item_fragment("item/started", "collabAgentToolCall", at, item, id, origin),
    do: codex_item_tool_fragment(at, id, codex_collab_tool_title(item), codex_collab_tool_text(item), origin)

  defp codex_item_fragment("item/started", "webSearch", at, item, id, origin),
    do: codex_item_tool_fragment(at, id, "web_search", presence(Map.get(item, "query")), origin)

  defp codex_item_fragment("item/started", "mcpToolCall", at, item, id, origin),
    do: codex_item_tool_fragment(at, id, codex_mcp_tool_title(item), codex_mcp_args_text(item), origin)

  # The MCP result only lands on `item/completed`; emit it as an output block
  # keyed on the call id so it sits beside the tool block from `item/started`.
  defp codex_item_fragment("item/completed", "mcpToolCall", at, item, id, origin),
    do: codex_mcp_output_fragment(at, id, item, origin)

  defp codex_item_fragment("item/completed", "agentMessage", at, item, id, origin),
    do: build_completed_item_fragment("agent", at, Map.get(item, "text"), id, origin)

  defp codex_item_fragment("item/completed", "commandExecution", at, item, id, origin) do
    [
      build_completed_item_fragment("command", at, codex_command_text(item), id, origin),
      build_completed_item_fragment("output", at, Map.get(item, "aggregatedOutput"), id, origin)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp codex_item_fragment(_method, _type, _at, _item, _id, _origin), do: nil

  defp codex_item_tool_fragment(at, id, title, text, origin) do
    fragment = Map.merge(%{kind: "tool", at: at, title: title, text: normalize_transcript_text(text || "")}, origin)
    if is_binary(id), do: Map.put(fragment, :tool_call_id, id), else: fragment
  end

  defp codex_command_text(item) do
    case Map.get(item, "command") do
      command when is_binary(command) -> "$ #{String.trim(command)}"
      _ -> nil
    end
  end

  defp codex_file_change_title(item) do
    case codex_file_change_paths(item) do
      [] -> "edit"
      [path] -> "edit: #{Path.basename(path)}"
      paths -> "edit: #{length(paths)} files"
    end
  end

  defp codex_file_change_paths(item) do
    item
    |> Map.get("changes", [])
    |> List.wrap()
    |> Enum.map(&Map.get(&1, "path"))
    |> Enum.filter(&is_binary/1)
  end

  defp codex_file_change_text(item) do
    item
    |> Map.get("changes", [])
    |> List.wrap()
    |> Enum.map(&codex_file_change_entry/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> truncate_tool_text()
  end

  defp codex_file_change_entry(%{"path" => path} = change) when is_binary(path) do
    case Map.get(change, "diff") do
      diff when is_binary(diff) -> "#{path}\n#{diff}"
      _ -> path
    end
  end

  defp codex_file_change_entry(_change), do: nil

  defp codex_collab_tool_title(item), do: presence(Map.get(item, "tool")) || "agent"

  defp codex_collab_tool_text(item) do
    case presence(Map.get(item, "prompt")) do
      nil -> nil
      prompt -> truncate_tool_text(prompt)
    end
  end

  defp codex_mcp_tool_title(item) do
    tool = presence(Map.get(item, "tool")) || "tool"

    case presence(Map.get(item, "server")) do
      nil -> tool
      server -> "#{server}: #{tool}"
    end
  end

  defp codex_mcp_args_text(item) do
    case Map.get(item, "arguments") do
      nil -> ""
      arguments -> format_tool_arguments(arguments)
    end
  end

  defp codex_mcp_output_fragment(at, id, item, origin) do
    with text when is_binary(text) and text != "" <- codex_mcp_result_text(item),
         fragment when is_map(fragment) <- build_text_fragment("output", at, truncate_tool_text(text), origin) do
      if is_binary(id), do: Map.put(fragment, :tool_call_id, id), else: fragment
    else
      _ -> nil
    end
  end

  defp codex_mcp_result_text(item) do
    case codex_mcp_error_text(item) do
      nil -> item |> Map.get("result") |> codex_mcp_content_text()
      error -> "Error: #{error}"
    end
  end

  defp codex_mcp_error_text(item) do
    case Map.get(item, "error") do
      error when is_binary(error) -> presence(error)
      %{} = error -> presence(inspect(error))
      _ -> nil
    end
  end

  defp codex_mcp_content_text(%{"content" => content}), do: acp_content_text(content)
  defp codex_mcp_content_text(_result), do: nil

  defp build_stream_fragment(kind, at, payload, paths, origin) when is_list(paths) do
    build_stream_fragment(kind, at, payload, extract_text(payload, paths), origin)
  end

  defp build_stream_fragment(kind, at, payload, text, origin) do
    build_item_fragment(kind, at, text, codex_item_id(payload), origin)
  end

  defp build_item_fragment(kind, at, text, item_id, origin) do
    case build_text_fragment(kind, at, text, origin) do
      nil -> nil
      fragment when is_binary(item_id) -> Map.put(fragment, :item_id, item_id)
      fragment -> fragment
    end
  end

  defp build_completed_item_fragment(kind, at, text, item_id, origin) do
    case build_item_fragment(kind, at, text, item_id, origin) do
      %{item_id: _item_id} = fragment -> Map.put(fragment, :replace_item_text, true)
      fragment -> fragment
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
    |> Enum.find_value(fn path -> presence(map_value(payload, path)) end)
  end

  defp build_text_fragment(kind, at, text, origin) when is_binary(kind) and is_binary(text) do
    case normalize_transcript_text(text) do
      "" -> nil
      normalized -> Map.merge(%{kind: kind, at: at, text: normalized}, origin)
    end
  end

  defp build_text_fragment(_kind, _at, _text, _origin), do: nil

  defp build_compaction_fragment(at, payload, origin) when is_map(payload) do
    Map.merge(
      %{
        kind: "compaction",
        at: at,
        text: compaction_text(payload)
      },
      origin
    )
  end

  defp compaction_text(payload) when is_map(payload) do
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

  # Each event carries its thread (`params.threadId`); the session's own thread is
  # the first UUID of `session_id` ("<thread>-<turn>"). Anything else is a subagent.
  defp transcript_origin(payload, parent_thread_id) do
    event_thread_id = event_thread_id(payload)
    %{thread_id: event_thread_id, subagent: subagent_thread?(event_thread_id, parent_thread_id)}
  end

  defp event_thread_id(payload) when is_map(payload) do
    string_path_value(payload, ["params", "threadId"]) || string_path_value(payload, ["params", "thread_id"])
  end

  defp string_path_value(value, []), do: value

  defp string_path_value(map, [key | rest]) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      nil -> nil
      nested -> string_path_value(nested, rest)
    end
  end

  defp string_path_value(_map, _path), do: nil

  defp subagent_thread?(event_thread_id, parent_thread_id)
       when is_binary(event_thread_id) and is_binary(parent_thread_id),
       do: event_thread_id != parent_thread_id

  defp subagent_thread?(_event_thread_id, _parent_thread_id), do: false

  defp parent_thread_from_session_id(session_id)
       when is_binary(session_id) and byte_size(session_id) >= 73 do
    if binary_part(session_id, 36, 1) == "-", do: binary_part(session_id, 0, 36), else: nil
  end

  defp parent_thread_from_session_id(_session_id), do: nil

  defp merge_transcript_fragments(fragments) when is_list(fragments) do
    fragments
    |> Enum.reduce([], fn fragment, acc ->
      cond do
        # ACP tool/output fragments resend cumulative state per update; replace
        # the matching fragment in place (keyed on `tool_call_id`) so arguments
        # fill in and cumulative output isn't concatenated into itself.
        keyed_fragment?(fragment) ->
          upsert_keyed_fragment(acc, fragment)

        item_fragment?(fragment) ->
          upsert_item_fragment(acc, fragment)

        mergeable_text_head?(acc, fragment) ->
          [previous | rest] = acc
          [%{previous | text: previous.text <> fragment.text} | rest]

        true ->
          [fragment | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(&Map.delete(&1, :replace_item_text))
  end

  defp mergeable_text_head?([%{kind: kind, thread_id: prev_thread} | _rest], fragment) do
    kind == fragment.kind and kind in ["agent", "output", "reasoning"] and
      prev_thread == fragment.thread_id and not keyed_fragment?(fragment)
  end

  defp mergeable_text_head?(_acc, _fragment), do: false

  defp keyed_fragment?(%{kind: kind, tool_call_id: id}) when kind in ["tool", "output"] and is_binary(id),
    do: true

  defp keyed_fragment?(_fragment), do: false

  defp item_fragment?(%{kind: kind, item_id: id})
       when kind in ["agent", "command", "output", "reasoning"] and is_binary(id),
       do: true

  defp item_fragment?(_fragment), do: false

  defp upsert_item_fragment(acc, %{kind: kind, item_id: id} = fragment) do
    if Enum.any?(acc, &item_fragment_match?(&1, kind, id, fragment.thread_id)) do
      Enum.map(acc, &merge_item_fragment(&1, fragment))
    else
      [fragment | acc]
    end
  end

  defp merge_item_fragment(existing, %{kind: kind, item_id: id} = incoming) do
    if item_fragment_match?(existing, kind, id, incoming.thread_id) do
      text =
        if Map.get(incoming, :replace_item_text),
          do: incoming.text,
          else: existing.text <> incoming.text

      %{existing | text: text}
    else
      existing
    end
  end

  defp item_fragment_match?(
         %{kind: kind, item_id: id, thread_id: thread_id},
         kind,
         id,
         thread_id
       ),
       do: true

  defp item_fragment_match?(_fragment, _kind, _id, _thread_id), do: false

  defp upsert_keyed_fragment(acc, %{kind: kind, tool_call_id: id} = fragment) do
    if Enum.any?(acc, &keyed_fragment_match?(&1, kind, id, fragment.thread_id)) do
      # Only the text changes between updates; keep the title/timestamp the
      # initial `tool_call` established (see `Orchestrator.upsert_keyed_transcript_block/4`).
      Enum.map(
        acc,
        &refresh_keyed_fragment(&1, kind, id, fragment.thread_id, fragment.text)
      )
    else
      [fragment | acc]
    end
  end

  defp refresh_keyed_fragment(fragment, kind, id, thread_id, text) do
    if keyed_fragment_match?(fragment, kind, id, thread_id),
      do: %{fragment | text: text},
      else: fragment
  end

  defp keyed_fragment_match?(
         %{kind: kind, tool_call_id: id, thread_id: thread_id},
         kind,
         id,
         thread_id
       ),
       do: true

  defp keyed_fragment_match?(_fragment, _kind, _id, _thread_id), do: false

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

  defp extract_text(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      case map_value(payload, path) do
        text when is_binary(text) -> text
        _ -> nil
      end
    end)
  end

  defp extract_command(payload) when is_map(payload) do
    [
      ["params", "msg", "command"],
      ["params", "command"],
      ["params", "cmd"]
    ]
    |> Enum.find_value(fn path ->
      case map_value(payload, path) do
        command when is_binary(command) -> "$ #{String.trim(command)}"
        _ -> nil
      end
    end)
  end

  defp extract_tool(payload) when is_map(payload) do
    name =
      tool_name_value(map_value(payload, ["params", "tool"])) ||
        tool_name_value(map_value(payload, ["params", "name"])) ||
        "tool"

    args_text =
      case map_value(payload, ["params", "arguments"]) do
        nil -> ""
        args -> format_tool_arguments(args)
      end

    {name, args_text}
  end

  defp tool_name_value(name) when is_binary(name), do: name
  defp tool_name_value(_name), do: nil

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

  defp map_value(value, []), do: value

  defp map_value(map, [key | rest]) when is_map(map) do
    case fetch_either_key(map, key) do
      {:ok, nested} -> map_value(nested, rest)
      :error -> nil
    end
  end

  defp map_value(_map, _path), do: nil

  # Look a key up under both string and atom representations without bouncing
  # between them (the previous mutual recursion infinite-looped on absent keys).
  defp fetch_either_key(map, key) when is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> fetch_existing_atom_key(map, key)
    end
  end

  defp fetch_either_key(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp fetch_existing_atom_key(map, key) do
    Map.fetch(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> :error
  end

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
