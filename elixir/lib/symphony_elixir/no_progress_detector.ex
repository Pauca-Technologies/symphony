defmodule SymphonyElixir.NoProgressDetector do
  @moduledoc """
  Pure, bounded shadow-mode detection for repeated completed tool attempts.

  Protocol updates are reduced to hashes and small enums before they enter the
  detector. Raw arguments, call identifiers, command output, and canonicalized
  argument text are never retained in detector state or returned to callers.
  Starts exist only to correlate terminal events whose backend omits operation
  details at completion; starts alone never count as attempts.

  A caller supplies repository, workpad, and exact-head progress comparisons at
  a safe post-turn boundary. The detector performs no I/O and cannot change
  worker lifecycle behavior.
  """

  @version 1
  @max_pending 64
  @max_signals_per_turn 128
  @omission_reasons ~w(
    invalid_signal normalization_failed pending_evicted signal_evicted start_missing_correlation
    start_missing_operation start_without_terminal terminal_missing_operation terminal_unmatched
  )

  @default_config %{
    error_repeat_threshold: 3,
    success_repeat_threshold: 8,
    success_no_progress_turns: 2,
    max_fingerprints: 32
  }

  @failure_results ~w(failed nonzero_exit cancelled unsupported timeout unknown_failure)a
  @result_classes [:success | @failure_results]

  @type progress_state :: :changed | :unchanged | :unavailable

  @type state :: map()

  @doc "Return the fixed safety limits applied independently of workflow policy."
  @spec limits() :: map()
  def limits do
    %{
      max_pending: @max_pending,
      max_signals_per_turn: @max_signals_per_turn,
      max_omission_reasons: length(@omission_reasons)
    }
  end

  @doc "Create empty bounded detector state from the four supported thresholds."
  @spec new(map() | keyword()) :: state()
  def new(config \\ %{}) do
    %{
      version: @version,
      config: normalize_config(config),
      pending: %{},
      episodes: %{},
      failure_streak: nil,
      success_streak: nil,
      success_no_progress: nil,
      next_ordinal: 0,
      next_episode: 0,
      metrics: %{
        completed_attempts: 0,
        alerts: 0,
        progress_suppressions: 0,
        progress_unavailable: 0,
        episode_resets: 0,
        fingerprint_evictions: 0,
        signal_evictions: 0,
        omissions: %{}
      }
    }
  end

  @doc "Consume one bounded turn and decide a warning only from supplied progress evidence."
  @spec assess_turn(
          state(),
          [SymphonyElixir.ToolAttempt.signal()] | %{signals: [SymphonyElixir.ToolAttempt.signal()], omissions: map()},
          map() | keyword()
        ) :: {state(), map()}
  def assess_turn(state, signals, progress_evidence)
      when is_map(state) and is_list(signals) do
    assess_turn(state, %{signals: signals, omissions: %{}}, progress_evidence)
  end

  def assess_turn(state, %{signals: signals, omissions: omissions}, progress_evidence)
      when is_map(state) and is_list(signals) and is_map(omissions) do
    {signals, signal_evictions} = bounded_signals(signals)
    omissions = safe_omissions(omissions)

    {state, turn} =
      Enum.reduce(signals, {state, empty_turn(signal_evictions, omissions)}, fn signal, acc ->
        consume_signal(signal, acc)
      end)

    {state, turn} = discard_pending(state, turn)
    state = record_turn_metrics(state, turn)
    progress = progress_state(progress_evidence)
    candidate = candidate(state, turn)
    decide(state, turn, progress, candidate)
  end

  @doc "Return compact non-secret live metrics and deterministic detector state."
  @spec snapshot(state()) :: map()
  def snapshot(state) when is_map(state) do
    %{
      version: @version,
      metrics: state.metrics,
      failure_streak: compact_streak(state.failure_streak),
      success_streak: compact_streak(state.success_streak),
      success_no_progress: state.success_no_progress,
      tracked_fingerprints:
        state.episodes
        |> Enum.map(fn {fingerprint, episode} ->
          %{
            fingerprint: fingerprint,
            alerted: episode.alerted,
            last_seen: episode.last_seen
          }
        end)
        |> Enum.sort_by(&{&1.last_seen, &1.fingerprint})
    }
  end

  @doc "Restore only bounded alerted fingerprint latches from a trusted resume packet."
  @spec restore_latches(state(), [term()]) :: state()
  def restore_latches(state, fingerprints) when is_map(state) and is_list(fingerprints) do
    fingerprints
    |> Enum.filter(&valid_digest?/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce(state, &restore_latch/2)
  end

  defp restore_latch(fingerprint, state) do
    if Map.has_key?(state.episodes, fingerprint) do
      state
    else
      ordinal = state.next_ordinal + 1
      episodes = Map.put(state.episodes, fingerprint, %{alerted: true, last_seen: ordinal})
      {episodes, evictions} = trim_episodes(episodes, state.config.max_fingerprints)

      state
      |> Map.put(:episodes, episodes)
      |> Map.put(:next_ordinal, ordinal)
      |> update_in([:metrics, :fingerprint_evictions], &(&1 + evictions))
    end
  end

  defp bounded_signals(signals) do
    normalized =
      signals
      |> Enum.with_index()
      |> Enum.map(fn {signal, index} ->
        sequence =
          case signal do
            %{sequence: value} when is_integer(value) and value >= 0 -> value
            _missing_or_invalid -> index
          end

        signal = safe_signal(signal, sequence)
        {sequence, stable_signal_order(signal), signal}
      end)
      |> Enum.sort_by(fn {sequence, tie_breaker, _signal} -> {sequence, tie_breaker} end)
      |> Enum.uniq_by(fn {sequence, _tie_breaker, _signal} -> sequence end)

    evicted = max(length(normalized) - @max_signals_per_turn, 0)

    selected =
      normalized
      |> Enum.take(-@max_signals_per_turn)
      |> Enum.map(fn {sequence, _tie_breaker, signal} -> Map.put(signal, :sequence, sequence) end)

    {selected, evicted}
  end

  defp stable_signal_order(signal) do
    [
      :kind,
      :correlation_sha256,
      :thread_scope_sha256,
      :operation,
      :operation_identity_sha256,
      :arguments_sha256,
      :result_class,
      :reason
    ]
    |> Enum.map_join("\n", fn key -> signal |> Map.get(key) |> safe_order_value() end)
  end

  defp safe_order_value(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_order_value(value) when is_binary(value), do: binary_part(value, 0, min(byte_size(value), 80))

  defp safe_signal(
         %{
           kind: :start,
           correlation_sha256: correlation,
           thread_scope_sha256: thread_scope,
           operation: operation,
           operation_identity_sha256: identity,
           arguments_sha256: arguments
         } = signal,
         sequence
       )
       when is_binary(correlation) and is_binary(thread_scope) and is_binary(operation) and is_binary(identity) and
              is_binary(arguments) do
    if valid_start_signal?(correlation, thread_scope, operation, identity, arguments) do
      signal
      |> Map.take([
        :kind,
        :correlation_sha256,
        :thread_scope_sha256,
        :operation,
        :operation_identity_sha256,
        :arguments_sha256
      ])
      |> Map.put(:sequence, sequence)
    else
      %{kind: :omission, reason: "invalid_signal", sequence: sequence}
    end
  end

  defp safe_signal(%{kind: :terminal, result_class: result} = signal, sequence)
       when result in @result_classes do
    if valid_terminal_signal?(signal) do
      signal
      |> Map.take([
        :kind,
        :correlation_sha256,
        :thread_scope_sha256,
        :operation,
        :operation_identity_sha256,
        :arguments_sha256,
        :result_class
      ])
      |> Map.put(:sequence, sequence)
    else
      %{kind: :omission, reason: "invalid_signal", sequence: sequence}
    end
  end

  defp safe_signal(%{kind: :omission, reason: reason}, sequence)
       when reason in @omission_reasons,
       do: %{kind: :omission, reason: reason, sequence: sequence}

  defp safe_signal(_signal, sequence),
    do: %{kind: :omission, reason: "invalid_signal", sequence: sequence}

  defp valid_start_signal?(correlation, thread_scope, operation, identity, arguments) do
    valid_digest?(correlation) and valid_digest?(thread_scope) and valid_operation?(operation) and
      valid_digest?(identity) and valid_digest?(arguments)
  end

  defp valid_terminal_signal?(signal) do
    direct? =
      valid_operation?(Map.get(signal, :operation)) and
        valid_digest?(Map.get(signal, :thread_scope_sha256)) and
        valid_digest?(Map.get(signal, :operation_identity_sha256)) and
        valid_digest?(Map.get(signal, :arguments_sha256))

    direct? or valid_digest?(Map.get(signal, :correlation_sha256))
  end

  defp valid_operation?(operation),
    do: operation in ~w(shell read edit web mcp dynamic other)

  defp valid_digest?(digest) when is_binary(digest) and byte_size(digest) == 64,
    do: String.match?(digest, ~r/\A[0-9a-f]{64}\z/)

  defp valid_digest?(_digest), do: false

  defp empty_turn(signal_evictions, omissions) do
    omissions =
      if signal_evictions > 0,
        do: Map.update(omissions, "signal_evicted", signal_evictions, &(&1 + signal_evictions)),
        else: omissions

    %{
      completed: 0,
      signal_evictions: signal_evictions,
      omissions: omissions
    }
  end

  defp safe_omissions(omissions) do
    Map.new(omissions, fn
      {reason, count} when reason in @omission_reasons and is_integer(count) and count > 0 ->
        {reason, min(count, 1_000_000)}

      {_reason, _count} ->
        {"invalid_signal", 1}
    end)
  end

  defp consume_signal(%{kind: :start} = signal, {state, turn}) do
    pending = Map.put(state.pending, signal.correlation_sha256, pending_entry(signal))
    {pending, evicted} = trim_pending(pending)
    turn = if evicted > 0, do: add_omission(turn, "pending_evicted", evicted), else: turn
    {%{state | pending: pending}, turn}
  end

  defp consume_signal(%{kind: :terminal} = signal, {state, turn}) do
    correlation = Map.get(signal, :correlation_sha256)
    {matched, pending} = Map.pop(state.pending, correlation)
    state = %{state | pending: pending}

    completion =
      if is_binary(Map.get(signal, :operation)) and is_binary(Map.get(signal, :arguments_sha256)) do
        signal
      else
        merge_terminal(signal, matched)
      end

    if completion do
      state = record_completion(state, completion)
      {state, %{turn | completed: turn.completed + 1}}
    else
      {state, add_omission(turn, "terminal_unmatched", 1)}
    end
  end

  defp consume_signal(%{kind: :omission, reason: reason}, {state, turn}) do
    {state, add_omission(turn, reason, 1)}
  end

  defp pending_entry(signal) do
    %{
      operation: signal.operation,
      thread_scope_sha256: signal.thread_scope_sha256,
      operation_identity_sha256: signal.operation_identity_sha256,
      arguments_sha256: signal.arguments_sha256,
      sequence: signal.sequence
    }
  end

  defp merge_terminal(_signal, nil), do: nil

  defp merge_terminal(signal, pending) do
    signal
    |> Map.put(:operation, pending.operation)
    |> Map.put(:thread_scope_sha256, pending.thread_scope_sha256)
    |> Map.put(:operation_identity_sha256, pending.operation_identity_sha256)
    |> Map.put(:arguments_sha256, pending.arguments_sha256)
  end

  defp trim_pending(pending) when map_size(pending) <= @max_pending, do: {pending, 0}

  defp trim_pending(pending) do
    {key, _entry} = Enum.min_by(pending, fn {key, entry} -> {entry.sequence, key} end)
    {Map.delete(pending, key), 1}
  end

  defp discard_pending(state, turn) do
    count = map_size(state.pending)
    turn = if count > 0, do: add_omission(turn, "start_without_terminal", count), else: turn
    {%{state | pending: %{}}, turn}
  end

  defp record_completion(state, completion) do
    fingerprint = completion_fingerprint(completion)
    ordinal = state.next_ordinal + 1
    episode = Map.get(state.episodes, fingerprint, %{alerted: false})
    episodes = Map.put(state.episodes, fingerprint, Map.put(episode, :last_seen, ordinal))
    {episodes, evictions} = trim_episodes(episodes, state.config.max_fingerprints)

    base = %{
      fingerprint: fingerprint,
      operation: completion.operation,
      result_class: completion.result_class
    }

    {failure_streak, success_streak} =
      if completion.result_class in @failure_results do
        {increment_streak(state.failure_streak, base), nil}
      else
        {nil, increment_streak(state.success_streak, base)}
      end

    state
    |> Map.put(:episodes, episodes)
    |> Map.put(:failure_streak, failure_streak)
    |> Map.put(:success_streak, success_streak)
    |> Map.put(:next_ordinal, ordinal)
    |> update_in([:metrics, :completed_attempts], &(&1 + 1))
    |> update_in([:metrics, :fingerprint_evictions], &(&1 + evictions))
  end

  defp increment_streak(%{fingerprint: fingerprint} = streak, %{fingerprint: fingerprint}),
    do: %{streak | repeats: streak.repeats + 1}

  defp increment_streak(_different, base), do: Map.put(base, :repeats, 1)

  defp trim_episodes(episodes, max_fingerprints) when map_size(episodes) <= max_fingerprints,
    do: {episodes, 0}

  defp trim_episodes(episodes, max_fingerprints) do
    remove_count = map_size(episodes) - max_fingerprints

    keys =
      episodes
      |> Enum.sort_by(fn {fingerprint, entry} -> {entry.last_seen, fingerprint} end)
      |> Enum.take(remove_count)
      |> Enum.map(&elem(&1, 0))

    {Map.drop(episodes, keys), remove_count}
  end

  defp candidate(_state, %{completed: 0}), do: nil

  defp candidate(state, _turn) do
    cond do
      qualified?(state.failure_streak, state.config.error_repeat_threshold) ->
        Map.put(state.failure_streak, :kind, :repeated_error)

      qualified?(state.success_streak, state.config.success_repeat_threshold) ->
        Map.put(state.success_streak, :kind, :repeated_success_no_progress)

      true ->
        nil
    end
  end

  defp qualified?(%{repeats: repeats}, threshold), do: repeats >= threshold
  defp qualified?(_streak, _threshold), do: false

  defp decide(state, turn, :changed, candidate) do
    latched? = Enum.any?(state.episodes, fn {_fingerprint, episode} -> episode.alerted end)
    decision = if candidate, do: :suppressed_progress, else: if(latched?, do: :reset, else: :none)

    state =
      state
      |> reset_episodes()
      |> maybe_increment_metric(:progress_suppressions, decision == :suppressed_progress)
      |> maybe_increment_metric(:episode_resets, decision == :reset)

    {state, turn_result(turn, :changed, decision, candidate, nil)}
  end

  defp decide(state, turn, :unavailable, candidate) do
    state = %{state | success_no_progress: nil}

    if candidate && not alerted?(state, candidate.fingerprint) do
      state = update_in(state, [:metrics, :progress_unavailable], &(&1 + 1))
      {state, turn_result(turn, :unavailable, :progress_unavailable, candidate, nil)}
    else
      {state, turn_result(turn, :unavailable, :none, candidate, nil)}
    end
  end

  defp decide(state, turn, :unchanged, %{kind: :repeated_error} = candidate) do
    state = %{state | success_no_progress: nil}
    alert_or_none(state, turn, candidate)
  end

  defp decide(state, turn, :unchanged, %{kind: :repeated_success_no_progress} = candidate) do
    no_progress = increment_no_progress(state.success_no_progress, candidate.fingerprint)
    state = %{state | success_no_progress: no_progress}

    if no_progress.turns >= state.config.success_no_progress_turns do
      alert_or_none(state, turn, Map.put(candidate, :no_progress_turns, no_progress.turns))
    else
      {state, turn_result(turn, :unchanged, :provisional, candidate, nil)}
    end
  end

  defp decide(state, turn, :unchanged, nil) do
    state = %{state | success_no_progress: nil}
    {state, turn_result(turn, :unchanged, :none, nil, nil)}
  end

  defp alert_or_none(state, turn, candidate) do
    if alerted?(state, candidate.fingerprint) do
      {state, turn_result(turn, :unchanged, :none, candidate, nil)}
    else
      episode_number = state.next_episode + 1
      warning = warning(candidate, episode_number)

      state =
        state
        |> put_in([:episodes, candidate.fingerprint, :alerted], true)
        |> Map.put(:next_episode, episode_number)
        |> update_in([:metrics, :alerts], &(&1 + 1))

      {state, turn_result(turn, :unchanged, :alert, candidate, warning)}
    end
  end

  defp warning(candidate, episode_number) do
    warning_id =
      sha256([
        "no-progress-warning-v1\n",
        candidate.fingerprint,
        "\n",
        Integer.to_string(episode_number)
      ])

    %{
      version: @version,
      warning_id: "npw-" <> binary_part(warning_id, 0, 24),
      kind: candidate.kind,
      fingerprint: candidate.fingerprint,
      operation: candidate.operation,
      result_class: candidate.result_class,
      repeat_count: candidate.repeats,
      no_progress_turns: Map.get(candidate, :no_progress_turns)
    }
  end

  defp increment_no_progress(%{fingerprint: fingerprint} = current, fingerprint),
    do: %{current | turns: current.turns + 1}

  defp increment_no_progress(_different, fingerprint),
    do: %{fingerprint: fingerprint, turns: 1}

  defp alerted?(state, fingerprint),
    do: get_in(state, [:episodes, fingerprint, :alerted]) == true

  defp reset_episodes(state) do
    %{
      state
      | episodes: %{},
        failure_streak: nil,
        success_streak: nil,
        success_no_progress: nil
    }
  end

  defp turn_result(turn, progress, decision, candidate, warning) do
    %{
      version: @version,
      decision: decision,
      progress: progress,
      candidate: compact_streak(candidate),
      warning: warning,
      completed_attempts: turn.completed,
      signal_evictions: turn.signal_evictions,
      omissions: turn.omissions
    }
  end

  defp compact_streak(nil), do: nil

  defp compact_streak(streak) do
    Map.take(streak, [:fingerprint, :kind, :operation, :result_class, :repeats, :no_progress_turns])
  end

  defp record_turn_metrics(state, turn) do
    state
    |> update_in([:metrics, :signal_evictions], &(&1 + turn.signal_evictions))
    |> update_in([:metrics, :omissions], &merge_counts(&1, turn.omissions))
  end

  defp maybe_increment_metric(state, _key, false), do: state
  defp maybe_increment_metric(state, key, true), do: update_in(state, [:metrics, key], &(&1 + 1))

  defp add_omission(turn, reason, count) do
    omissions = bounded_increment(turn.omissions, reason, count)
    %{turn | omissions: omissions}
  end

  defp merge_counts(left, right) do
    Enum.reduce(right, left, fn {reason, count}, acc -> bounded_increment(acc, reason, count) end)
  end

  defp bounded_increment(counts, reason, count) do
    Map.update(counts, reason, count, &(&1 + count))
  end

  defp progress_state(evidence) do
    values =
      evidence
      |> Map.new()
      |> Map.take([:repository, :workpad, :exact_head, "repository", "workpad", "exact_head"])
      |> Map.values()
      |> Enum.map(&normalize_progress_value/1)

    cond do
      :changed in values -> :changed
      :unchanged in values -> :unchanged
      true -> :unavailable
    end
  end

  defp normalize_progress_value(value) when value in [:changed, "changed"], do: :changed
  defp normalize_progress_value(value) when value in [:unchanged, "unchanged"], do: :unchanged
  defp normalize_progress_value(_value), do: :unavailable

  defp normalize_config(config) do
    config = Map.new(config)

    %{
      error_repeat_threshold: bounded_integer(config_value(config, :error_repeat_threshold), 3, 2, 100),
      success_repeat_threshold: bounded_integer(config_value(config, :success_repeat_threshold), 8, 2, 1_000),
      success_no_progress_turns: bounded_integer(config_value(config, :success_no_progress_turns), 2, 1, 100),
      max_fingerprints: bounded_integer(config_value(config, :max_fingerprints), 32, 1, 32)
    }
  end

  defp config_value(config, key) do
    Map.get(config, key, Map.get(config, Atom.to_string(key), Map.fetch!(@default_config, key)))
  end

  defp bounded_integer(value, _default, minimum, maximum) when is_integer(value),
    do: value |> max(minimum) |> min(maximum)

  defp bounded_integer(_value, default, _minimum, _maximum), do: default

  defp completion_fingerprint(completion) do
    sha256([
      "no-progress-fingerprint-v1\n",
      completion.thread_scope_sha256,
      "\n",
      completion.operation_identity_sha256,
      "\n",
      completion.arguments_sha256,
      "\n",
      Atom.to_string(completion.result_class)
    ])
  end

  defp sha256(value) do
    value
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
