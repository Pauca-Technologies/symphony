defmodule SymphonyElixir.ShutdownPolicyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{OSProcess, Shutdown, ShutdownPolicyStore}

  test "defaults to preserving workers and persists either shutdown policy" do
    assert ShutdownPolicyStore.load() == :preserve_workers

    assert :ok = ShutdownPolicyStore.persist(:terminate_workers)
    assert ShutdownPolicyStore.load() == :terminate_workers

    assert :ok = ShutdownPolicyStore.persist(:preserve_workers)
    assert ShutdownPolicyStore.load() == :preserve_workers
  end

  test "invalid persisted state falls back to preserving workers" do
    File.mkdir_p!(Path.dirname(ShutdownPolicyStore.path()))
    File.write!(ShutdownPolicyStore.path(), ~s({"policy":"unknown"}))

    assert capture_log(fn ->
             assert ShutdownPolicyStore.load() == :preserve_workers
           end) =~ "Failed to load shutdown policy"
  end

  test "write failures leave the selected policy unchanged" do
    assert :ok = ShutdownPolicyStore.persist(:terminate_workers)
    Application.put_env(:symphony_elixir, :shutdown_policy_path, "/proc/symphony-shutdown-policy.json")

    assert {:error, _reason} = ShutdownPolicyStore.persist(:preserve_workers)
  end

  test "orchestrator publishes and reloads the persisted policy" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", poll_interval_ms: 30_000)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    first_name = :shutdown_policy_first
    {:ok, first} = Orchestrator.start_link(name: first_name)

    assert {:ok, %{shutdown_policy: :terminate_workers}} =
             Orchestrator.set_shutdown_policy(first_name, :terminate_workers)

    assert %{mode: %{shutdown_policy: :terminate_workers}} = Orchestrator.snapshot(first_name, 1_000)
    GenServer.stop(first)

    second_name = :shutdown_policy_second
    {:ok, second} = Orchestrator.start_link(name: second_name)
    assert %{mode: %{shutdown_policy: :terminate_workers}} = Orchestrator.snapshot(second_name, 1_000)

    assert {:ok, %{shutdown_policy: :preserve_workers}} =
             Orchestrator.set_shutdown_policy(second_name, :preserve_workers)

    GenServer.stop(second)
  end

  test "process-tree termination includes subprocesses in their own session" do
    shell = System.find_executable("sh")
    setsid = System.find_executable("setsid")
    assert is_binary(shell)
    assert is_binary(setsid)

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(shell)},
        [:binary, :exit_status, args: [~c"-c", String.to_charlist("#{setsid} sleep 30 & echo $!; wait")], line: 1_024]
      )

    assert_receive {^port, {:data, {:eol, child_pid_text}}}, 1_000
    child_pid = child_pid_text |> String.trim() |> String.to_integer()
    {:os_pid, shell_pid} = :erlang.port_info(port, :os_pid)

    assert File.exists?("/proc/#{child_pid}")
    assert Enum.any?(OSProcess.snapshot_tree(shell_pid), &(&1.pid == child_pid))
    assert :ok = OSProcess.terminate_tree(shell_pid)
    assert_receive {^port, {:exit_status, _status}}, 1_000
    refute File.exists?("/proc/#{child_pid}")
    refute OSProcess.alive?(%{pid: child_pid, ppid: shell_pid, start_time: "missing"})
    assert :ok = OSProcess.terminate_tree(2_147_483_647, 0)
    assert :ok = OSProcess.terminate_identities([])
    assert :ok = OSProcess.terminate_identities([], 0)
  end

  test "process-tree helpers handle proc and signal failures without targeting recycled pids" do
    identity = %{pid: 100, ppid: 1, start_time: "55"}

    tree_deps =
      os_deps(%{
        list_proc: fn -> {:ok, ["100", "101", "not-a-pid"]} end,
        read_stat: fn
          100 -> {:ok, proc_stat(100, 1, "55")}
          101 -> {:ok, proc_stat(101, 100, "56")}
        end
      })

    assert OSProcess.snapshot_tree(100, tree_deps) |> Enum.map(& &1.pid) |> Enum.sort() == [100, 101]
    assert OSProcess.snapshot_tree(100, tree_deps) |> Enum.map(& &1.name) == ["test process", "test process"]
    assert OSProcess.alive?(identity, tree_deps)

    assert OSProcess.snapshot_tree(100, os_deps(%{list_proc: fn -> {:error, :enoent} end})) == []

    malformed = os_deps(%{list_proc: fn -> {:ok, ["100"]} end, read_stat: fn _pid -> {:ok, "bad"} end})
    assert OSProcess.snapshot_tree(100, malformed) == []
    refute OSProcess.alive?(identity, malformed)

    unterminated =
      os_deps(%{
        list_proc: fn -> {:ok, ["100"]} end,
        read_stat: fn _pid -> {:ok, "100 (unterminated"} end
      })

    assert OSProcess.snapshot_tree(100, unterminated) == []

    no_kill = os_deps(%{read_stat: fn _pid -> {:ok, proc_stat(100, 1, "55")} end, find_kill: fn -> nil end})
    assert {:error, :kill_executable_not_found} = OSProcess.terminate_identities([identity], 0, no_kill)

    command_failure =
      os_deps(%{
        read_stat: fn _pid -> {:ok, proc_stat(100, 1, "55")} end,
        run_command: fn _executable, _args -> raise "signal failed" end
      })

    assert {:error, {:signal_failed, "signal failed"}} =
             OSProcess.terminate_identities([identity], 0, command_failure)
  end

  test "process-tree termination escalates survivors and polls graceful exits" do
    identity = %{pid: 100, ppid: 1, start_time: "55"}
    always_alive = fn _pid -> {:ok, proc_stat(100, 1, "55")} end

    survivor_deps = os_deps(%{read_stat: always_alive})

    assert {:error, {:processes_still_running, [100]}} =
             OSProcess.terminate_tree(100, 0, survivor_deps)

    Process.put(:shutdown_test_alive, true)

    graceful_deps =
      os_deps(%{
        read_stat: fn _pid ->
          if Process.get(:shutdown_test_alive),
            do: {:ok, proc_stat(100, 1, "55")},
            else: {:error, :enoent}
        end,
        sleep: fn _milliseconds -> Process.put(:shutdown_test_alive, false) end
      })

    assert :ok = OSProcess.terminate_identities([identity], 100, graceful_deps)
    Process.delete(:shutdown_test_alive)
  end

  test "shutdown applies preserve, terminate, and fallback outcomes" do
    preserve_deps = shutdown_deps(%{load_policy: fn -> :preserve_workers end})

    assert capture_log(fn -> assert :ok = Shutdown.prepare(preserve_deps) end) =~
             "preserving detached workers"

    terminate_deps =
      shutdown_deps(%{
        load_policy: fn -> :terminate_workers end,
        stop_all_workers: fn -> {:ok, 2} end,
        terminate_all: fn [:captured] -> :ok end
      })

    log = capture_log(fn -> assert :ok = Shutdown.prepare(terminate_deps) end)
    assert log =~ "terminating all active workers"
    assert log =~ "Requested shutdown for 2 tracked worker(s)"

    fallback_deps =
      shutdown_deps(%{
        load_policy: fn -> :terminate_workers end,
        stop_all_workers: fn -> :unavailable end,
        terminate_all: fn [:captured] -> {:error, :still_running} end
      })

    log = capture_log(fn -> assert :ok = Shutdown.prepare(fallback_deps) end)
    assert log =~ "registry fallback"
    assert log =~ "Unable to terminate every persistent worker cleanly"
  end

  test "application prep_stop applies policy only in the main process" do
    assert capture_log(fn -> assert :test_state = SymphonyElixir.Application.prep_stop(:test_state) end) =~
             "preserving detached workers"

    Application.put_env(:symphony_elixir, :persistent_worker_mode, true)

    assert capture_log(fn ->
             assert :worker_state = SymphonyElixir.Application.prep_stop(:worker_state)
           end) == ""

    Application.put_env(:symphony_elixir, :persistent_worker_mode, false)
  end

  defp shutdown_deps(overrides) do
    Map.merge(
      %{
        load_policy: fn -> :preserve_workers end,
        termination_targets: fn -> [:captured] end,
        stop_all_workers: fn -> {:ok, 0} end,
        terminate_all: fn _targets -> :ok end
      },
      overrides
    )
  end

  defp os_deps(overrides) do
    Map.merge(
      %{
        list_proc: fn -> {:ok, ["100"]} end,
        read_stat: fn _pid -> {:error, :enoent} end,
        find_kill: fn -> "/bin/kill" end,
        run_command: fn _executable, _args -> {"", 0} end,
        monotonic_ms: fn -> 0 end,
        sleep: fn _milliseconds -> :ok end
      },
      overrides
    )
  end

  defp proc_stat(pid, ppid, start_time) do
    fields = ["S", Integer.to_string(ppid)] ++ List.duplicate("0", 17) ++ [start_time]
    "#{pid} (test process) " <> Enum.join(fields, " ")
  end
end
