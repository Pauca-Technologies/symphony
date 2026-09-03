defmodule SymphonyElixir.AgentBudgetCollector do
  @moduledoc """
  Bounded concurrent collector for one run's soft-budget signals.

  Backend callbacks normalize each full protocol event immediately, then
  coalesce cumulative usage into an ETS high-water table. No protocol event is
  sent to or retained by the runner/collector mailbox. A submitted/completed
  atomic barrier makes continuation-boundary snapshots wait for every callback
  that began before `run_turn/4` returned, including callbacks from another
  process. The collector process only receives turn-boundary control calls and
  owns the latched `AgentBudget` policy across continuation turns.
  """

  use GenServer

  alias SymphonyElixir.{AgentBudget, NoProgressDetector, ToolAttempt}

  @counter_slots 3
  @submitted 1
  @completed 2
  @tool_submitted 3
  @no_progress_ring_size 128
  @no_progress_evictions :no_progress_ring_evictions
  @token_keys ~w(input_tokens cached_input_tokens output_tokens reasoning_tokens total_tokens)a

  @type ref :: %{
          pid: pid(),
          table: :ets.tid(),
          counters: :atomics.atomics_ref()
        }

  @spec start_link(map(), map()) :: GenServer.on_start()
  def start_link(decision, issue) when is_map(decision) and is_map(issue) do
    start_link(decision, issue, %{}, %{})
  end

  @doc "Start a collector with immutable event-correlation context."
  @spec start_link(map(), map(), map()) :: GenServer.on_start()
  def start_link(decision, issue, event_context)
      when is_map(decision) and is_map(issue) and is_map(event_context) do
    start_link(decision, issue, event_context, %{})
  end

  @doc "Start a collector with explicit bounded shadow-mode detector thresholds."
  @spec start_link(map(), map(), map(), map()) :: GenServer.on_start()
  def start_link(decision, issue, event_context, no_progress_config)
      when is_map(decision) and is_map(issue) and is_map(event_context) and is_map(no_progress_config) do
    GenServer.start_link(__MODULE__, {decision, issue, event_context, no_progress_config})
  end

  @doc "Return the callback reference without exposing collector internals to callers."
  @spec ref(pid()) :: ref()
  def ref(pid) when is_pid(pid), do: GenServer.call(pid, :ref)

  @doc "Normalize and coalesce one event without sending the full event to any mailbox."
  @spec observe(ref(), map()) :: :ok
  def observe(%{table: table, counters: counters}, update) when is_map(update) do
    sequence = :atomics.add_get(counters, @submitted, 1)

    try do
      case AgentBudget.normalize_update(update) do
        nil -> :ok
        signal -> persist_signal(table, signal)
      end

      case ToolAttempt.normalize(update) do
        {:ok, signal} ->
          tool_sequence = :atomics.add_get(counters, @tool_submitted, 1)
          persist_no_progress_signal(table, tool_sequence, sequence, signal)

        :ignore ->
          :ok
      end
    after
      :atomics.add_get(counters, @completed, 1)
    end

    :ok
  rescue
    error in ArgumentError ->
      if :ets.info(table) == :undefined, do: :ok, else: reraise(error, __STACKTRACE__)
  end

  @doc "Record the turn prompt after synchronizing prior callback writes."
  @spec start_turn(pid(), String.t(), integer()) :: :ok
  def start_turn(pid, prompt, now_ms), do: GenServer.call(pid, {:start_turn, prompt, now_ms})

  @doc "Finalize a turn only after all submitted callback writes are visible."
  @spec finish_turn(pid(), integer()) :: map()
  def finish_turn(pid, now_ms), do: GenServer.call(pid, {:finish_turn, now_ms}, :infinity)

  @doc "Take and clear the next one-shot continuation capsule."
  @spec take_strategy_prompt(pid()) :: String.t() | nil
  def take_strategy_prompt(pid), do: GenServer.call(pid, :take_strategy_prompt)

  @doc "Return a synchronized metrics/latch snapshot."
  @spec snapshot(pid()) :: map()
  def snapshot(pid), do: GenServer.call(pid, :snapshot, :infinity)

  @doc "Assess completed attempts at a synchronized post-turn progress boundary."
  @spec assess_no_progress(pid(), map() | keyword()) :: map()
  def assess_no_progress(pid, progress_evidence),
    do: GenServer.call(pid, {:assess_no_progress, progress_evidence}, :infinity)

  @doc "Restore bounded alert latches from a trusted resume packet before a turn."
  @spec restore_no_progress_latches(pid(), [term()]) :: :ok
  def restore_no_progress_latches(pid, fingerprints) when is_pid(pid) and is_list(fingerprints),
    do: GenServer.call(pid, {:restore_no_progress_latches, fingerprints})

  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, :infinity)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init({decision, issue, event_context, no_progress_config}) do
    table = :ets.new(__MODULE__, [:set, :public, read_concurrency: true, write_concurrency: true])
    :ets.insert(table, {:tool_output_bytes, 0})
    initialize_no_progress_ring(table)
    counters = :atomics.new(@counter_slots, signed: false)

    {:ok,
     %{
       budget: AgentBudget.new(decision, issue, event_context),
       no_progress: NoProgressDetector.new(no_progress_config),
       no_progress_sequence: 0,
       no_progress_evictions: 0,
       table: table,
       counters: counters,
       waiting: []
     }}
  end

  @impl true
  def handle_call(:ref, _from, state) do
    {:reply, %{pid: self(), table: state.table, counters: state.counters}, state}
  end

  def handle_call({:start_turn, prompt, now_ms}, _from, state) do
    state = synchronize(state)
    {:reply, :ok, %{state | budget: AgentBudget.start_turn(state.budget, prompt, now_ms)}}
  end

  def handle_call({:finish_turn, now_ms}, from, state) do
    wait_or_reply(state, from, {:finish_turn, now_ms})
  end

  def handle_call(:take_strategy_prompt, _from, state) do
    state = synchronize(state)
    {prompt, budget} = AgentBudget.take_strategy_prompt(state.budget)
    {:reply, prompt, %{state | budget: budget}}
  end

  def handle_call(:snapshot, from, state) do
    wait_or_reply(state, from, :snapshot)
  end

  def handle_call({:assess_no_progress, progress_evidence}, from, state) do
    wait_or_reply(state, from, {:assess_no_progress, progress_evidence})
  end

  def handle_call({:restore_no_progress_latches, fingerprints}, _from, state) do
    no_progress = NoProgressDetector.restore_latches(state.no_progress, fingerprints)
    {:reply, :ok, %{state | no_progress: no_progress}}
  end

  @impl true
  def handle_info(:check_barriers, state), do: flush_waiting(state)

  defp wait_or_reply(state, from, operation) do
    target = :atomics.get(state.counters, @submitted)

    if completed(state) >= target do
      reply_operation(synchronize(state), from, operation, target)
    else
      Process.send_after(self(), :check_barriers, 1)
      {:noreply, %{state | waiting: state.waiting ++ [{from, operation, target}]}}
    end
  end

  defp flush_waiting(state) do
    {ready, waiting} = Enum.split_with(state.waiting, fn {_from, _operation, target} -> completed(state) >= target end)
    state = %{state | waiting: waiting}

    state =
      Enum.reduce(ready, synchronize(state), fn {from, operation, target}, acc ->
        {:noreply, acc} = reply_operation(acc, from, operation, target)
        acc
      end)

    if waiting != [], do: Process.send_after(self(), :check_barriers, 1)
    {:noreply, state}
  end

  defp reply_operation(state, from, {:finish_turn, now_ms}, _target) do
    budget = AgentBudget.finish_turn(state.budget, now_ms)
    GenServer.reply(from, runtime_snapshot(budget))
    {:noreply, %{state | budget: budget}}
  end

  defp reply_operation(state, from, :snapshot, _target) do
    GenServer.reply(from, runtime_snapshot(state.budget))
    {:noreply, state}
  end

  defp reply_operation(state, from, {:assess_no_progress, evidence}, target) do
    {signals, evictions, total_evictions} = drain_no_progress_ring(state, target)

    {detector, result} =
      NoProgressDetector.assess_turn(
        state.no_progress,
        %{signals: signals, omissions: eviction_omissions(evictions)},
        evidence
      )

    reply = no_progress_reply(detector, result)
    GenServer.reply(from, reply)

    {:noreply,
     %{
       state
       | no_progress: detector,
         no_progress_sequence: target,
         no_progress_evictions: total_evictions
     }}
  end

  defp synchronize(state) do
    snapshot = table_snapshot(state.table)
    %{state | budget: AgentBudget.reconcile(state.budget, snapshot)}
  end

  defp runtime_snapshot(budget) do
    %{
      metrics: AgentBudget.snapshot(budget),
      transitions: budget.crossed |> MapSet.to_list() |> Enum.sort()
    }
  end

  defp completed(state), do: :atomics.get(state.counters, @completed)

  defp initialize_no_progress_ring(table) do
    :ets.insert(table, {@no_progress_evictions, 0})

    Enum.each(0..(@no_progress_ring_size - 1), fn slot ->
      :ets.insert(table, {{:no_progress_signal, slot}, 0, 0, nil})
    end)
  end

  defp persist_no_progress_signal(table, tool_sequence, submitted_sequence, signal) do
    key = {:no_progress_signal, rem(tool_sequence - 1, @no_progress_ring_size)}
    replace_no_progress_slot(table, key, tool_sequence, submitted_sequence, signal)
  end

  defp replace_no_progress_slot(table, key, tool_sequence, submitted_sequence, signal) do
    case :ets.lookup(table, key) do
      [{^key, current_tool_sequence, _current_submitted_sequence, current_signal}]
      when current_tool_sequence < tool_sequence ->
        match_spec = [
          {
            {key, current_tool_sequence, :"$1", :"$2"},
            [],
            [{:const, {key, tool_sequence, submitted_sequence, signal}}]
          }
        ]

        table
        |> :ets.select_replace(match_spec)
        |> handle_no_progress_replace(table, key, tool_sequence, submitted_sequence, signal, current_signal)

      [{^key, _newer_tool_sequence, _submitted_sequence, _signal}] ->
        increment_no_progress_evictions(table)

      _missing ->
        :ok
    end
  end

  defp handle_no_progress_replace(1, table, _key, _tool_sequence, _submitted_sequence, _signal, current_signal) do
    if is_map(current_signal), do: increment_no_progress_evictions(table)
    :ok
  end

  defp handle_no_progress_replace(0, table, key, tool_sequence, submitted_sequence, signal, _current_signal),
    do: replace_no_progress_slot(table, key, tool_sequence, submitted_sequence, signal)

  defp increment_no_progress_evictions(table) do
    :ets.update_counter(table, @no_progress_evictions, {2, 1})
    :ok
  end

  defp drain_no_progress_ring(state, target) do
    rows =
      state.table
      |> :ets.tab2list()
      |> Enum.flat_map(fn
        {{:no_progress_signal, _slot} = key, tool_sequence, submitted_sequence, signal}
        when submitted_sequence > state.no_progress_sequence and submitted_sequence <= target and is_map(signal) ->
          [{submitted_sequence, tool_sequence, key, signal}]

        _other ->
          []
      end)
      |> Enum.sort_by(&elem(&1, 0))

    Enum.each(rows, fn {submitted_sequence, tool_sequence, key, _signal} ->
      :ets.select_replace(state.table, [
        {
          {key, tool_sequence, :"$1", :"$2"},
          [],
          [{:const, {key, tool_sequence, submitted_sequence, nil}}]
        }
      ])
    end)

    total_evictions = table_value(state.table, @no_progress_evictions) || 0
    evictions = max(total_evictions - state.no_progress_evictions, 0)

    signals =
      Enum.map(rows, fn {submitted_sequence, _tool_sequence, _key, signal} ->
        Map.put(signal, :sequence, submitted_sequence)
      end)

    {signals, evictions, total_evictions}
  end

  defp eviction_omissions(0), do: %{}
  defp eviction_omissions(count), do: %{"signal_evicted" => count}

  defp no_progress_reply(detector, result) do
    snapshot = NoProgressDetector.snapshot(detector)

    %{
      version: 1,
      decision: result.decision,
      progress: result.progress,
      warning: result.warning,
      checkpoint: %{
        latched_fingerprints:
          snapshot.tracked_fingerprints
          |> Enum.filter(& &1.alerted)
          |> Enum.map(& &1.fingerprint)
      },
      summary: %{
        version: 1,
        mode: "shadow",
        active_warning_count: Enum.count(snapshot.tracked_fingerprints, & &1.alerted),
        completed_attempts: snapshot.metrics.completed_attempts,
        alerts: snapshot.metrics.alerts,
        progress_suppressions: snapshot.metrics.progress_suppressions,
        progress_unavailable: snapshot.metrics.progress_unavailable,
        turn_completed_attempts: result.completed_attempts,
        turn_omissions: result.omissions,
        fingerprint_evictions: snapshot.metrics.fingerprint_evictions,
        signal_evictions: Map.get(snapshot.metrics.omissions, "signal_evicted", 0),
        last_decision: result.decision,
        last_kind: get_in(result, [:candidate, :kind]),
        last_fingerprint: get_in(result, [:candidate, :fingerprint]),
        last_operation: get_in(result, [:candidate, :operation]),
        last_result_class: get_in(result, [:candidate, :result_class]),
        last_repeat_count: get_in(result, [:candidate, :repeats]),
        last_no_progress_turns: get_in(result, [:candidate, :no_progress_turns])
      }
    }
  end

  defp persist_signal(table, signal) do
    maybe_parent(table, signal.parent_thread_id)
    maybe_usage(table, signal.thread_id, signal.usage)

    if signal.tool_output_bytes > 0 do
      :ets.update_counter(table, :tool_output_bytes, {2, signal.tool_output_bytes})
    end
  end

  defp maybe_parent(_table, nil), do: :ok
  defp maybe_parent(table, thread_id), do: :ets.insert(table, {:parent_thread_id, thread_id})

  defp maybe_usage(_table, _thread_id, nil), do: :ok

  defp maybe_usage(table, thread_id, usage) do
    parent = table_value(table, :parent_thread_id)
    thread_id = reported_thread(thread_id) || parent || "thread-unreported"
    if is_nil(parent), do: :ets.insert_new(table, {:parent_thread_id, thread_id})
    :ets.insert_new(table, {{:thread, thread_id}, true})

    Enum.each(@token_keys, fn key -> put_max(table, {:usage, thread_id, key}, usage[key] || 0) end)

    case usage.context_window do
      value when is_integer(value) -> put_max(table, {:usage, thread_id, :context_window}, value)
      _missing -> :ok
    end
  end

  defp put_max(table, key, value) when is_integer(value) and value >= 0 do
    if not :ets.insert_new(table, {key, value}) do
      replace_max(table, key, value)
    end
  end

  defp replace_max(table, key, value) do
    case :ets.lookup(table, key) do
      [{^key, current}] when value > current ->
        match_spec = [{{:"$1", current}, [{:==, :"$1", {:const, key}}], [{{:"$1", value}}]}]

        case :ets.select_replace(table, match_spec) do
          0 -> replace_max(table, key, value)
          1 -> :ok
        end

      _current_or_missing ->
        :ok
    end
  end

  defp table_snapshot(table) do
    high_waters =
      table
      |> :ets.tab2list()
      |> Enum.filter(&match?({{:thread, _thread_id}, true}, &1))
      |> Map.new(fn {{:thread, thread_id}, true} ->
        counters =
          Map.new(@token_keys ++ [:context_window], fn key ->
            {key, table_value(table, {:usage, thread_id, key}) || if(key == :context_window, do: nil, else: 0)}
          end)

        {thread_id, counters}
      end)

    %{
      parent_thread_id: table_value(table, :parent_thread_id),
      high_waters: high_waters,
      tool_output_bytes: table_value(table, :tool_output_bytes) || 0
    }
  end

  defp table_value(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> value
      _missing -> nil
    end
  end

  defp reported_thread("thread-unreported"), do: nil
  defp reported_thread(thread_id) when is_binary(thread_id), do: thread_id
end
