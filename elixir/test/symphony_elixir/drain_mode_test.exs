defmodule SymphonyElixir.DrainModeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.DrainStore

  test "drain mode persists across restart and can be cancelled" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", poll_interval_ms: 50)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    assert :ok = DrainStore.persist(false, nil)

    first_name = :drain_mode_first
    {:ok, first} = Orchestrator.start_link(name: first_name)

    assert {:ok, %{draining: true, started_at: %DateTime{}}} =
             Orchestrator.set_drain_mode(first_name, true)

    assert %{mode: %{draining: true, started_at: %DateTime{}}} =
             Orchestrator.snapshot(first_name, 1_000)

    GenServer.stop(first)

    second_name = :drain_mode_second
    {:ok, second} = Orchestrator.start_link(name: second_name)

    assert %{mode: %{draining: true}} = Orchestrator.snapshot(second_name, 1_000)

    assert {:ok, %{draining: false, started_at: nil}} =
             Orchestrator.set_drain_mode(second_name, false)

    assert %{enabled: false, started_at: nil} = DrainStore.load()
    GenServer.stop(second)
  end

  test "drain mode keeps current work but prevents candidate dispatch" do
    issue = %Issue{
      id: "drain-candidate",
      identifier: "DRAIN-1",
      title: "Wait until drain is cancelled",
      state: "In Progress",
      labels: []
    }

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", poll_interval_ms: 50)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    assert :ok = DrainStore.persist(true, DateTime.utc_now())

    name = :drain_mode_dispatch_guard
    {:ok, pid} = Orchestrator.start_link(name: name)
    assert %{mode: %{draining: true}, running: []} = Orchestrator.snapshot(name, 1_000)

    _ = Orchestrator.request_refresh(name)
    Process.sleep(150)

    assert %{mode: %{draining: true}, running: []} = Orchestrator.snapshot(name, 1_000)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    GenServer.stop(pid)
  end

  test "cancelling drain immediately releases retries deferred by the mode" do
    retry_token = make_ref()
    timer_ref = Process.send_after(self(), :unused_retry_timer, 60_000)

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 10,
      draining: true,
      drain_started_at: DateTime.utc_now(),
      codex_totals: %{
        input_tokens: 0,
        cached_input_tokens: 0,
        output_tokens: 0,
        reasoning_tokens: 0,
        total_tokens: 0,
        seconds_running: 0
      },
      retry_attempts: %{
        "drain-retry" => %{
          attempt: 2,
          retry_token: retry_token,
          timer_ref: timer_ref,
          due_at_ms: System.monotonic_time(:millisecond),
          identifier: "DRAIN-RETRY"
        }
      }
    }

    assert {:noreply, deferred} =
             Orchestrator.handle_info({:retry_issue, "drain-retry", retry_token}, state)

    assert deferred.retry_attempts["drain-retry"].drain_deferred

    assert {:reply, {:ok, %{draining: false}}, resumed} =
             Orchestrator.handle_call({:set_drain_mode, false}, {self(), make_ref()}, deferred)

    refute Map.has_key?(resumed.retry_attempts["drain-retry"], :drain_deferred)
    assert resumed.retry_attempts["drain-retry"].due_at_ms <= System.monotonic_time(:millisecond)
    Process.cancel_timer(resumed.retry_attempts["drain-retry"].timer_ref)
    Process.cancel_timer(timer_ref)
  end

  test "invalid persisted state falls back to normal mode" do
    path = DrainStore.path()
    File.mkdir_p!(Path.dirname(path))

    for payload <- [
          Jason.encode!(%{"unexpected" => true}),
          Jason.encode!(%{"enabled" => true, "started_at" => "not-a-datetime"}),
          Jason.encode!(%{"enabled" => true, "started_at" => 123})
        ] do
      File.write!(path, payload)
      assert %{enabled: false, started_at: nil} = DrainStore.load()
    end
  end

  test "persistence reports filesystem failures and the default path is under the user home" do
    configured_path = DrainStore.path()
    Application.delete_env(:symphony_elixir, :drain_state_path)

    assert DrainStore.path() == Path.join([System.user_home!(), ".symphony", "drain-state.json"])

    Application.put_env(:symphony_elixir, :drain_state_path, "/proc/symphony-drain-state.json")
    assert {:error, _reason} = DrainStore.persist(true, DateTime.utc_now())

    Application.put_env(:symphony_elixir, :drain_state_path, configured_path)
  end
end
