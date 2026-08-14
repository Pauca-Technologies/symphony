defmodule SymphonyElixir.PersistentWorkerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.PersistentWorker
  alias SymphonyElixir.PersistentWorker.{Client, Registry, Server}

  defmodule RelayTarget do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, %{test_pid: test_pid, checkpoint: nil}}

    @impl true
    def handle_call(
          {:persistent_worker_checkpoint, worker_id, seq, checkpoint},
          _from,
          state
        ) do
      send(state.test_pid, {:checkpoint, self(), worker_id, seq, checkpoint})
      {:reply, :ok, %{state | checkpoint: checkpoint}}
    end

    def handle_call({:persistent_worker_event, worker_id, seq, event}, _from, state) do
      send(state.test_pid, {:event, self(), worker_id, seq, event})

      case event do
        {:persistent_worker_completed, _reason} ->
          {:reply, {:terminal, state.checkpoint}, state}

        _other ->
          checkpoint = %{last_seq: seq, last_event: event}
          {:reply, {:ok, checkpoint}, %{state | checkpoint: checkpoint}}
      end
    end
  end

  test "registry creates one private discoverable record per issue" do
    issue = issue("registry")

    assert {:ok, manifest} = Registry.prepare(issue, 2, "worker-a")
    assert manifest.attempt == 2
    assert manifest.worker_host == "worker-a"
    assert {:existing, %{worker_id: worker_id}} = Registry.prepare(issue, 3, nil)
    assert worker_id == manifest.worker_id

    assert {:ok, spec} = Registry.load_spec(manifest)
    assert spec.issue == issue
    assert spec.attempt == 2
    assert [listed] = Registry.list()
    assert listed.worker_id == manifest.worker_id

    assert {:ok, updated} = Registry.update(manifest, %{port: 12_345, os_pid: 987, status: "running"})
    assert updated.port == 12_345
    assert updated.os_pid == 987
    assert updated.status == "running"

    assert :ok = Registry.cleanup(updated, updated.worker_id)
    assert Registry.list() == []
  end

  test "completed records are reclaimed instead of reattached as failed workers" do
    issue = issue("completed-record")
    assert {:ok, manifest} = Registry.prepare(issue, 1, nil)
    assert {:ok, completed} = Registry.update(manifest, %{status: "completed"})

    assert {:ok, replacement} = Registry.prepare(issue, 2, nil)
    refute replacement.worker_id == completed.worker_id
    assert replacement.attempt == 2

    assert {:ok, _completed_replacement} = Registry.update(replacement, %{status: "completed"})
    assert PersistentWorker.attach_all(self()) == []
    assert Registry.list() == []
  end

  test "dead running records are reclaimed before adoption" do
    issue = issue("dead-record")
    assert {:ok, manifest} = Registry.prepare(issue, 1, nil)

    assert {:ok, dead} =
             Registry.update(manifest, %{
               status: "running",
               os_pid: 2_147_483_647,
               port: 65_535
             })

    refute Registry.worker_alive?(dead)
    assert PersistentWorker.attach_all(self()) == []
    assert Registry.list() == []
  end

  test "detached server keeps the run alive and replays its checkpoint to a replacement relay" do
    test_pid = self()
    issue = issue("reconnect")
    assert {:ok, manifest} = Registry.prepare(issue, 1, nil)
    assert {:ok, spec} = Registry.load_spec(manifest)

    runner_fun = fn recipient ->
      send(test_pid, {:runner_started, self(), recipient})

      send(
        recipient,
        {:worker_runtime_info, issue.id, %{workspace_path: "/tmp/reconnected-workspace"}}
      )

      receive do
        :finish -> :ok
      end
    end

    {:ok, server} = Server.start_link(spec, runner_fun: runner_fun)
    server_ref = Process.monitor(server)
    assert_receive {:runner_started, runner_pid, ^server}

    {:ok, first_target} = RelayTarget.start_link(self())
    first_client = spawn(fn -> Client.run(manifest, first_target) end)

    assert_receive {:checkpoint, ^first_target, worker_id, 0, nil}, 5_000

    assert_receive {:event, ^first_target, ^worker_id, 1, {:worker_runtime_info, issue_id, %{workspace_path: "/tmp/reconnected-workspace"}}},
                   5_000

    assert issue_id == issue.id

    GenServer.stop(first_target)
    assert_eventually(fn -> not Process.alive?(first_client) end)
    assert Process.alive?(server)
    assert Process.alive?(runner_pid)

    {:ok, second_target} = RelayTarget.start_link(self())
    second_client = spawn(fn -> Client.run(manifest, second_target) end)

    assert_receive {:checkpoint, ^second_target, ^worker_id, 1, %{last_seq: 1, last_event: {:worker_runtime_info, ^issue_id, _runtime}}},
                   5_000

    send(runner_pid, :finish)

    assert_receive {:event, ^second_target, ^worker_id, 2, {:persistent_worker_completed, :normal}},
                   5_000

    assert_receive {:DOWN, ^server_ref, :process, ^server, :normal}, 5_000
    assert_eventually(fn -> not Process.alive?(second_client) end)
    assert Registry.list() == []
  end

  test "a replacement orchestrator adopts the same live worker after restart" do
    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, Orchestrator)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :persistent_workers_enabled, false)

      unless Process.whereis(Orchestrator) do
        _ = Supervisor.restart_child(SymphonyElixir.Supervisor, Orchestrator)
      end
    end)

    Application.put_env(:symphony_elixir, :persistent_workers_enabled, true)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", poll_interval_ms: 1_000)

    issue = issue("orchestrator-adoption")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    assert {:ok, manifest} = Registry.prepare(issue, 1, nil)
    assert {:ok, spec} = Registry.load_spec(manifest)
    test_pid = self()

    runner_fun = fn recipient ->
      send(test_pid, {:adoption_runner_started, self(), recipient})

      receive do
        :finish -> :ok
      end
    end

    {:ok, server} = Server.start_link(spec, runner_fun: runner_fun)
    server_ref = Process.monitor(server)
    assert_receive {:adoption_runner_started, runner_pid, ^server}

    Application.put_env(
      :symphony_elixir,
      :persistent_worker_liveness_check,
      fn candidate -> candidate.worker_id == manifest.worker_id end
    )

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :persistent_worker_liveness_check)
    end)

    first_name = :persistent_adoption_first
    {:ok, first} = Orchestrator.start_link(name: first_name)

    assert_eventually(fn ->
      case Orchestrator.snapshot(first_name, 1_000) do
        %{running: [%{issue_id: issue_id}]} -> issue_id == issue.id
        _other -> false
      end
    end)

    GenServer.stop(first)
    assert Process.alive?(runner_pid)
    assert Process.alive?(server)

    second_name = :persistent_adoption_second
    {:ok, second} = Orchestrator.start_link(name: second_name)

    assert_eventually(fn ->
      case Orchestrator.snapshot(second_name, 1_000) do
        %{running: [%{issue_id: issue_id}]} -> issue_id == issue.id
        _other -> false
      end
    end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    send(runner_pid, :finish)
    assert_receive {:DOWN, ^server_ref, :process, ^server, :normal}, 5_000
    if Process.alive?(second), do: GenServer.stop(second)
  end

  test "stopping a detached worker terminates its external child processes" do
    test_pid = self()
    issue = issue("stop-descendants")
    assert {:ok, manifest} = Registry.prepare(issue, 1, nil)
    assert {:ok, spec} = Registry.load_spec(manifest)

    runner_fun = fn _recipient ->
      receive do
        :never -> :ok
      end
    end

    process_terminator = fn ->
      send(test_pid, :worker_descendants_terminated)
      :ok
    end

    {:ok, server} =
      Server.start_link(spec,
        runner_fun: runner_fun,
        process_terminator: process_terminator
      )

    server_ref = Process.monitor(server)
    assert {:ok, _attachment} = GenServer.call(server, {:attach, self(), spec.auth_token})

    GenServer.cast(server, {:stop, self()})

    assert_receive :worker_descendants_terminated, 1_000
    assert_receive {:DOWN, ^server_ref, :process, ^server, :normal}, 1_000
    assert Registry.list() == []
  end

  test "default descendant cleanup preserves Erlang runtime helpers" do
    test_pid = self()
    issue = issue("runtime-helper-cleanup")
    assert {:ok, manifest} = Registry.prepare(issue, 1, nil)
    assert {:ok, spec} = Registry.load_spec(manifest)

    identities = [
      %{pid: 100, ppid: 1, start_time: "1", name: "beam.smp"},
      %{pid: 101, ppid: 100, start_time: "2", name: "erl_child_setup"},
      %{pid: 102, ppid: 101, start_time: "3", name: "inet_gethost"},
      %{pid: 103, ppid: 101, start_time: "4", name: "sh"},
      %{pid: 104, ppid: 103, start_time: "5", name: "node"}
    ]

    runner_fun = fn _recipient ->
      receive do
        :never -> :ok
      end
    end

    identity_terminator = fn selected ->
      send(test_pid, {:worker_processes_terminated, selected})
      :ok
    end

    {:ok, server} =
      Server.start_link(spec,
        runner_fun: runner_fun,
        process_snapshotter: fn -> identities end,
        identity_terminator: identity_terminator
      )

    server_ref = Process.monitor(server)
    assert {:ok, _attachment} = GenServer.call(server, {:attach, self(), spec.auth_token})

    GenServer.cast(server, {:stop, self()})

    assert_receive {:worker_processes_terminated, selected}, 1_000
    assert Enum.map(selected, & &1.pid) == [103, 104]
    assert_receive {:DOWN, ^server_ref, :process, ^server, :normal}, 1_000
    assert Registry.list() == []
  end

  defp issue(suffix) do
    %Issue{
      id: "persistent-worker-#{suffix}",
      identifier: "PW-#{suffix}",
      title: "Persistent worker #{suffix}",
      description: "Keep this run alive",
      state: "In Progress",
      labels: []
    }
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(20)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")
end
