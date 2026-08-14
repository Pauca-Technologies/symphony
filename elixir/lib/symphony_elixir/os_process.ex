defmodule SymphonyElixir.OSProcess do
  @moduledoc false

  @poll_interval_ms 50

  @type identity :: %{
          required(:pid) => pos_integer(),
          required(:ppid) => non_neg_integer(),
          required(:start_time) => String.t(),
          optional(:name) => String.t()
        }
  @type deps :: %{
          list_proc: (-> {:ok, [String.t()]} | {:error, term()}),
          read_stat: (pos_integer() -> {:ok, binary()} | {:error, term()}),
          find_kill: (-> Path.t() | nil),
          run_command: (Path.t(), [String.t()] -> {binary(), non_neg_integer()}),
          monotonic_ms: (-> integer()),
          sleep: (non_neg_integer() -> term())
        }

  @doc false
  @spec snapshot_tree(pos_integer()) :: [identity()]
  def snapshot_tree(root_pid) when is_integer(root_pid) and root_pid > 0 do
    snapshot_tree(root_pid, runtime_deps())
  end

  @doc false
  @spec snapshot_tree(pos_integer(), deps()) :: [identity()]
  def snapshot_tree(root_pid, deps) when is_integer(root_pid) and root_pid > 0 and is_map(deps) do
    process_tree(root_pid, deps)
  end

  @doc false
  @spec terminate_tree(pos_integer()) :: :ok | {:error, term()}
  def terminate_tree(root_pid), do: terminate_tree(root_pid, 2_000)

  @doc false
  @spec terminate_tree(pos_integer(), non_neg_integer()) :: :ok | {:error, term()}
  def terminate_tree(root_pid, timeout)
      when is_integer(root_pid) and root_pid > 0 and is_integer(timeout) and timeout >= 0 do
    terminate_tree(root_pid, timeout, runtime_deps())
  end

  @doc false
  @spec terminate_tree(pos_integer(), non_neg_integer(), deps()) :: :ok | {:error, term()}
  def terminate_tree(root_pid, timeout, deps)
      when is_integer(root_pid) and root_pid > 0 and is_integer(timeout) and timeout >= 0 and is_map(deps) do
    root_pid
    |> snapshot_tree(deps)
    |> terminate_identities(timeout, deps)
  end

  @doc false
  @spec terminate_identities([identity()]) :: :ok | {:error, term()}
  def terminate_identities(identities), do: terminate_identities(identities, 2_000)

  @doc false
  @spec terminate_identities([identity()], non_neg_integer()) :: :ok | {:error, term()}
  def terminate_identities(identities, timeout)
      when is_list(identities) and is_integer(timeout) and timeout >= 0 do
    terminate_identities(identities, timeout, runtime_deps())
  end

  @doc false
  @spec terminate_identities([identity()], non_neg_integer(), deps()) :: :ok | {:error, term()}
  def terminate_identities(identities, timeout, deps)
      when is_list(identities) and is_integer(timeout) and timeout >= 0 and is_map(deps) do
    with :ok <- signal(identities, "TERM", deps) do
      remaining = await_exit(identities, deadline(timeout, deps), deps)
      _ = signal(remaining, "KILL", deps)

      case await_exit(remaining, deadline(min(timeout, 1_000), deps), deps) do
        [] -> :ok
        survivors -> {:error, {:processes_still_running, Enum.map(survivors, & &1.pid)}}
      end
    end
  end

  @doc false
  @spec alive?(identity()) :: boolean()
  def alive?(%{pid: _pid, ppid: _ppid, start_time: _start_time} = identity) do
    alive?(identity, runtime_deps())
  end

  @doc false
  @spec alive?(identity(), deps()) :: boolean()
  def alive?(%{pid: pid, start_time: start_time}, deps) when is_map(deps) do
    case process_identity(pid, deps) do
      {:ok, %{start_time: ^start_time}} -> true
      _other -> false
    end
  end

  defp process_tree(root_pid, deps) do
    snapshot = process_snapshot(deps)

    descendants =
      snapshot
      |> descendant_pids([root_pid], MapSet.new())
      |> Enum.map(&Map.fetch!(snapshot, &1))

    case Map.get(snapshot, root_pid) do
      nil -> descendants
      root -> descendants ++ [root]
    end
  end

  defp descendant_pids(snapshot, parents, found) do
    children =
      snapshot
      |> Enum.flat_map(fn {pid, %{ppid: ppid}} -> if ppid in parents, do: [pid], else: [] end)
      |> Enum.reject(&MapSet.member?(found, &1))

    if children == [] do
      MapSet.to_list(found)
    else
      descendant_pids(snapshot, children, Enum.reduce(children, found, &MapSet.put(&2, &1)))
    end
  end

  defp process_snapshot(deps) do
    case deps.list_proc.() do
      {:ok, entries} ->
        Enum.reduce(entries, %{}, &put_process_entry(&1, &2, deps))

      {:error, _reason} ->
        %{}
    end
  end

  defp put_process_entry(entry, snapshot, deps) do
    case Integer.parse(entry) do
      {pid, ""} when pid > 0 -> put_process_identity(snapshot, pid, process_identity(pid, deps))
      _other -> snapshot
    end
  end

  defp put_process_identity(snapshot, pid, {:ok, identity}), do: Map.put(snapshot, pid, identity)
  defp put_process_identity(snapshot, _pid, _error), do: snapshot

  defp process_identity(pid, deps) do
    with {:ok, stat} <- deps.read_stat.(pid),
         {open, 1} <- :binary.match(stat, "("),
         close when is_integer(close) <- last_close_paren(stat),
         true <- close > open,
         name <- binary_part(stat, open + 1, close - open - 1),
         fields <- stat |> binary_part(close + 2, byte_size(stat) - close - 2) |> String.split(),
         [_, ppid_text | _] <- fields,
         {ppid, ""} <- Integer.parse(ppid_text),
         start_time when is_binary(start_time) <- Enum.at(fields, 19) do
      {:ok, %{pid: pid, ppid: ppid, start_time: start_time, name: name}}
    else
      _other -> {:error, :invalid_proc_stat}
    end
  end

  defp last_close_paren(stat) do
    case :binary.matches(stat, ")") do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  defp signal([], _name, _deps), do: :ok

  defp signal(identities, name, deps) do
    case deps.find_kill.() do
      nil ->
        {:error, :kill_executable_not_found}

      executable ->
        identities
        |> Enum.filter(&alive?(&1, deps))
        |> Enum.each(fn %{pid: pid} ->
          _ = deps.run_command.(executable, ["-#{name}", Integer.to_string(pid)])
        end)

        :ok
    end
  rescue
    error -> {:error, {:signal_failed, Exception.message(error)}}
  end

  defp await_exit(identities, deadline_ms, deps) do
    remaining = Enum.filter(identities, &alive?(&1, deps))

    cond do
      remaining == [] ->
        []

      deps.monotonic_ms.() >= deadline_ms ->
        remaining

      true ->
        deps.sleep.(@poll_interval_ms)
        await_exit(remaining, deadline_ms, deps)
    end
  end

  defp deadline(timeout, deps), do: deps.monotonic_ms.() + timeout

  defp runtime_deps do
    %{
      list_proc: fn -> File.ls("/proc") end,
      read_stat: fn pid -> File.read("/proc/#{pid}/stat") end,
      find_kill: fn -> System.find_executable("kill") end,
      run_command: fn executable, args ->
        System.cmd(executable, args, stderr_to_stdout: true)
      end,
      monotonic_ms: fn -> System.monotonic_time(:millisecond) end,
      sleep: &Process.sleep/1
    }
  end
end
