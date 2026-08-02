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

  alias SymphonyElixir.AgentBudget

  @counter_slots 2
  @submitted 1
  @completed 2
  @token_keys ~w(input_tokens cached_input_tokens output_tokens reasoning_tokens total_tokens)a

  @type ref :: %{
          pid: pid(),
          table: :ets.tid(),
          counters: :atomics.atomics_ref()
        }

  @spec start_link(map(), map()) :: GenServer.on_start()
  def start_link(decision, issue) when is_map(decision) and is_map(issue) do
    GenServer.start_link(__MODULE__, {decision, issue})
  end

  @doc "Return the callback reference without exposing collector internals to callers."
  @spec ref(pid()) :: ref()
  def ref(pid) when is_pid(pid), do: GenServer.call(pid, :ref)

  @doc "Normalize and coalesce one event without sending the full event to any mailbox."
  @spec observe(ref(), map()) :: :ok
  def observe(%{table: table, counters: counters}, update) when is_map(update) do
    :atomics.add_get(counters, @submitted, 1)

    try do
      case AgentBudget.normalize_update(update) do
        nil -> :ok
        signal -> persist_signal(table, signal)
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

  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, :infinity)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init({decision, issue}) do
    table = :ets.new(__MODULE__, [:set, :public, read_concurrency: true, write_concurrency: true])
    :ets.insert(table, {:tool_output_bytes, 0})
    counters = :atomics.new(@counter_slots, signed: false)

    {:ok,
     %{
       budget: AgentBudget.new(decision, issue),
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

  @impl true
  def handle_info(:check_barriers, state), do: flush_waiting(state)

  defp wait_or_reply(state, from, operation) do
    target = :atomics.get(state.counters, @submitted)

    if completed(state) >= target do
      reply_operation(synchronize(state), from, operation)
    else
      Process.send_after(self(), :check_barriers, 1)
      {:noreply, %{state | waiting: state.waiting ++ [{from, operation, target}]}}
    end
  end

  defp flush_waiting(state) do
    {ready, waiting} = Enum.split_with(state.waiting, fn {_from, _operation, target} -> completed(state) >= target end)
    state = %{state | waiting: waiting}

    state =
      Enum.reduce(ready, synchronize(state), fn {from, operation, _target}, acc ->
        {:noreply, acc} = reply_operation(acc, from, operation)
        acc
      end)

    if waiting != [], do: Process.send_after(self(), :check_barriers, 1)
    {:noreply, state}
  end

  defp reply_operation(state, from, {:finish_turn, now_ms}) do
    budget = AgentBudget.finish_turn(state.budget, now_ms)
    GenServer.reply(from, runtime_snapshot(budget))
    {:noreply, %{state | budget: budget}}
  end

  defp reply_operation(state, from, :snapshot) do
    GenServer.reply(from, runtime_snapshot(state.budget))
    {:noreply, state}
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
  defp reported_thread(_thread_id), do: nil
end
