defmodule SymphonyElixir.WaitWatcher do
  @moduledoc """
  Durable, non-LLM watcher for parked agent work.

  Entries with the same condition key share one probe. Failed or unchanged
  probes use bounded exponential backoff, while ready entries remain persisted
  until the orchestrator acknowledges scheduling their resume.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{WaitCondition, WaitStore}

  @ready_notify_interval_ms 1_000

  defmodule State do
    @moduledoc false
    defstruct entries: %{}, timers: %{}, probes: %{}
  end

  @type entry :: map()

  @doc "Start the wait watcher."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Persist a newly parked issue."
  @spec park(entry()) :: :ok
  def park(entry), do: park(__MODULE__, entry)

  @spec park(GenServer.server(), entry()) :: :ok
  def park(server, entry), do: GenServer.call(server, {:park, entry})

  @doc "Return all parked and ready entries."
  @spec snapshot() :: [entry()]
  def snapshot, do: snapshot(__MODULE__)

  @spec snapshot(GenServer.server()) :: [entry()]
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @doc "Return issue ids currently owned by the watcher."
  @spec issue_ids() :: MapSet.t(String.t())
  def issue_ids, do: issue_ids(__MODULE__)

  @spec issue_ids(GenServer.server()) :: MapSet.t(String.t())
  def issue_ids(server), do: GenServer.call(server, :issue_ids)

  @doc "Wake one wait immediately and return its resume entry."
  @spec resume_now(String.t()) :: {:ok, entry()} | {:error, :not_found}
  def resume_now(identifier), do: resume_now(__MODULE__, identifier)

  @spec resume_now(GenServer.server(), String.t()) :: {:ok, entry()} | {:error, :not_found}
  def resume_now(server, identifier), do: GenServer.call(server, {:resume_now, identifier})

  @doc "Cancel one parked wait without scheduling it."
  @spec cancel(String.t()) :: {:ok, entry()} | {:error, :not_found}
  def cancel(identifier), do: cancel(__MODULE__, identifier)

  @spec cancel(GenServer.server(), String.t()) :: {:ok, entry()} | {:error, :not_found}
  def cancel(server, identifier), do: GenServer.call(server, {:cancel, identifier})

  @doc "Acknowledge that a ready entry has entered the scheduler."
  @spec acknowledge(String.t()) :: :ok
  def acknowledge(issue_id), do: acknowledge(__MODULE__, issue_id)

  @spec acknowledge(GenServer.server(), String.t()) :: :ok
  def acknowledge(server, issue_id), do: GenServer.call(server, {:acknowledge, issue_id})

  @impl true
  def init(_opts) do
    if Application.get_env(:symphony_elixir, :wait_state_reset_on_start, false) do
      _ = File.rm(WaitStore.path())
    end

    state = %State{entries: due_restored_waits(WaitStore.load())}
    send(self(), :arm_all)
    send(self(), :notify_ready)
    {:ok, state}
  end

  @impl true
  def handle_call({:park, entry}, _from, %State{} = state) do
    now = DateTime.utc_now()

    entry =
      entry
      |> Map.put(:status, :waiting)
      |> Map.put(:parked_at, now)
      |> Map.put(:next_probe_at, first_probe_at(entry, now))
      |> Map.put(:probe_attempt, 0)

    previous = Map.get(state.entries, entry.issue_id)
    state = %{state | entries: Map.put(state.entries, entry.issue_id, entry)}
    WaitStore.save(state.entries)

    state =
      state
      |> maybe_rearm_previous(previous)
      |> arm_condition(entry.request.condition_key)

    {:reply, :ok, state}
  end

  def handle_call(:snapshot, _from, %State{} = state) do
    entries =
      state.entries
      |> Map.values()
      |> Enum.sort_by(&entry_sort_key/1)

    {:reply, entries, state}
  end

  def handle_call(:issue_ids, _from, %State{} = state) do
    {:reply, state.entries |> Map.keys() |> MapSet.new(), state}
  end

  def handle_call({:resume_now, identifier}, _from, %State{} = state) do
    case find_entry(state.entries, identifier) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        observation = Map.get(entry, :last_observation) || %{"manual" => true}
        ready = ready_entry(entry, observation, :manual)
        state = %{state | entries: Map.put(state.entries, entry.issue_id, ready)}
        WaitStore.save(state.entries)
        notify_orchestrator([ready])
        {:reply, {:ok, ready}, state}
    end
  end

  def handle_call({:cancel, identifier}, _from, %State{} = state) do
    case find_entry(state.entries, identifier) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        ready = ready_entry(entry, %{"cancelled_by_human" => true}, :manual)
        state = %{state | entries: Map.put(state.entries, entry.issue_id, ready)}
        state = arm_condition(state, entry.request.condition_key)
        WaitStore.save(state.entries)
        notify_orchestrator([ready])
        {:reply, {:ok, ready}, state}
    end
  end

  def handle_call({:acknowledge, issue_id}, _from, %State{} = state) do
    case Map.pop(state.entries, issue_id) do
      {nil, _entries} ->
        {:reply, :ok, state}

      {entry, entries} ->
        state = %{state | entries: entries} |> arm_condition(entry.request.condition_key)
        WaitStore.save(entries)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info(:arm_all, %State{} = state) do
    state =
      state.entries
      |> Map.values()
      |> Enum.filter(&(&1.status == :waiting))
      |> Enum.map(& &1.request.condition_key)
      |> Enum.uniq()
      |> Enum.reduce(state, &arm_condition(&2, &1))

    {:noreply, state}
  end

  def handle_info(:notify_ready, %State{} = state) do
    ready = Enum.filter(Map.values(state.entries), &(&1.status == :ready))
    if ready != [], do: notify_orchestrator(ready)
    Process.send_after(self(), :notify_ready, @ready_notify_interval_ms)
    {:noreply, state}
  end

  def handle_info({:probe_due, condition_key, token}, %State{} = state) do
    case Map.get(state.timers, condition_key) do
      %{token: ^token} ->
        {:noreply, start_due_probe(state, condition_key)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:probe_result, condition_key, token, result}, %State{} = state) do
    case Map.get(state.probes, condition_key) do
      %{token: ^token} ->
        state = %{state | probes: Map.delete(state.probes, condition_key)}
        {:noreply, apply_probe_result(state, condition_key, result)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_due_probe(state, condition_key) do
    state = %{state | timers: Map.delete(state.timers, condition_key)}

    case List.first(waiting_entries(state, condition_key)) do
      nil -> state
      entry -> launch_probe(state, condition_key, entry)
    end
  end

  defp launch_probe(state, condition_key, entry) do
    parent = self()
    probe_token = make_ref()

    task_result =
      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
        result = safe_observe(entry.request)
        send(parent, {:probe_result, condition_key, probe_token, result})
      end)

    case task_result do
      {:ok, pid} ->
        probes = Map.put(state.probes, condition_key, %{token: probe_token, pid: pid})
        %{state | probes: probes}

      {:error, reason} ->
        update_backoff(state, condition_key, nil, inspect({:probe_start_failed, reason}))
    end
  end

  defp apply_probe_result(state, condition_key, {:changed, observation}) do
    {ready, entries} =
      Enum.reduce(waiting_entries(state, condition_key), {[], state.entries}, fn entry, {ready_acc, entries_acc} ->
        updated = ready_entry(entry, observation, :condition_changed)
        {[updated | ready_acc], Map.put(entries_acc, entry.issue_id, updated)}
      end)

    Logger.info("Wait condition changed condition_key=#{condition_key} resuming_issues=#{length(ready)}")
    state = %{state | entries: entries}
    WaitStore.save(entries)
    notify_orchestrator(ready)
    state
  end

  defp apply_probe_result(state, condition_key, {:unchanged, observation}) do
    update_backoff(state, condition_key, observation, nil)
  end

  defp apply_probe_result(state, condition_key, {:ok, observation}) when is_map(observation) do
    {ready, entries} =
      Enum.reduce(waiting_entries(state, condition_key), {[], state.entries}, fn entry, {ready_acc, entries_acc} ->
        if WaitCondition.changed?(entry.request, observation) do
          updated = ready_entry(entry, observation, :condition_changed)
          {[updated | ready_acc], Map.put(entries_acc, entry.issue_id, updated)}
        else
          updated = backoff_entry(entry, observation, nil)
          {ready_acc, Map.put(entries_acc, entry.issue_id, updated)}
        end
      end)

    if ready != [] do
      Logger.info("Wait condition changed condition_key=#{condition_key} resuming_issues=#{length(ready)}")
    end

    state = %{state | entries: entries}
    WaitStore.save(entries)
    notify_orchestrator(ready)
    arm_condition(state, condition_key)
  end

  defp apply_probe_result(state, condition_key, {:error, reason}) do
    Logger.warning("Wait condition probe failed condition_key=#{condition_key} reason=#{inspect(reason)}")
    update_backoff(state, condition_key, nil, inspect(reason))
  end

  defp update_backoff(state, condition_key, observation, error) do
    entries =
      Enum.reduce(waiting_entries(state, condition_key), state.entries, fn entry, acc ->
        Map.put(acc, entry.issue_id, backoff_entry(entry, observation, error))
      end)

    state = %{state | entries: entries}
    WaitStore.save(entries)
    arm_condition(state, condition_key)
  end

  defp ready_entry(entry, observation, trigger) do
    entry
    |> Map.put(:status, :ready)
    |> Map.put(:last_observation, observation)
    |> Map.put(:last_error, nil)
    |> Map.put(:resume_prompt, WaitCondition.resume_prompt(entry.request, observation, trigger))
  end

  defp backoff_entry(entry, observation, error) do
    attempt = entry.probe_attempt + 1

    delay_ms =
      min(
        entry.request.min_poll_ms * Integer.pow(2, min(attempt - 1, 10)),
        entry.request.max_poll_ms
      )

    entry
    |> Map.put(:probe_attempt, attempt)
    |> Map.put(:next_probe_at, DateTime.add(DateTime.utc_now(), delay_ms, :millisecond))
    |> Map.put(:last_observation, observation || entry.last_observation)
    |> Map.put(:last_error, error)
  end

  defp arm_condition(%State{} = state, condition_key) do
    if timer = Map.get(state.timers, condition_key), do: Process.cancel_timer(timer.ref)

    cond do
      Map.has_key?(state.probes, condition_key) ->
        %{state | timers: Map.delete(state.timers, condition_key)}

      waiting_entries(state, condition_key) == [] ->
        %{state | timers: Map.delete(state.timers, condition_key)}

      true ->
        entries = waiting_entries(state, condition_key)
        due_at = Enum.min_by(entries, &DateTime.to_unix(&1.next_probe_at, :millisecond)).next_probe_at
        delay_ms = max(0, DateTime.diff(due_at, DateTime.utc_now(), :millisecond))
        token = make_ref()
        ref = Process.send_after(self(), {:probe_due, condition_key, token}, delay_ms)
        %{state | timers: Map.put(state.timers, condition_key, %{token: token, ref: ref})}
    end
  end

  defp maybe_rearm_previous(state, nil), do: state
  defp maybe_rearm_previous(state, previous), do: arm_condition(state, previous.request.condition_key)

  defp waiting_entries(state, condition_key) do
    Enum.filter(Map.values(state.entries), fn entry ->
      entry.status == :waiting and entry.request.condition_key == condition_key
    end)
  end

  defp find_entry(entries, identifier) do
    Enum.find(Map.values(entries), fn entry -> entry.issue_id == identifier or entry.identifier == identifier end)
  end

  defp entry_sort_key(entry) do
    {Issue.dispatch_priority_rank(entry.priority), datetime_sort(entry.created_at), entry.identifier || entry.issue_id}
  end

  defp datetime_sort(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp datetime_sort(_datetime), do: 9_223_372_036_854_775_807

  defp first_probe_at(%{request: %{condition: %{"type" => "time", "resume_at" => resume_at}}}, fallback) do
    case DateTime.from_iso8601(resume_at) do
      {:ok, datetime, _offset} -> datetime
      _ -> fallback
    end
  end

  defp first_probe_at(_entry, fallback), do: fallback

  defp due_restored_waits(entries) when is_map(entries) do
    now = DateTime.utc_now()

    Map.new(entries, fn
      {issue_id, %{status: :waiting} = entry} ->
        {issue_id, Map.put(entry, :next_probe_at, now)}

      persisted_entry ->
        persisted_entry
    end)
  end

  defp observe(request) do
    case Application.get_env(:symphony_elixir, :wait_condition_probe) do
      fun when is_function(fun, 1) -> fun.(request)
      _ -> WaitCondition.observe(request)
    end
  end

  defp safe_observe(request) do
    observe(request)
  rescue
    error -> {:error, {:probe_crashed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:probe_crashed, kind, reason}}
  end

  defp notify_orchestrator(entries) do
    if orchestrator = Process.whereis(SymphonyElixir.Orchestrator) do
      send(orchestrator, {:wait_entries_ready, entries})
    end
  end
end
