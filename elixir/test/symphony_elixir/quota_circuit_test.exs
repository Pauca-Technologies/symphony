defmodule SymphonyElixir.QuotaCircuitTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentFailure, QuotaCircuitStore, Telemetry}

  test "simultaneous trusted failures create one circuit and park without consuming failure counts" do
    pid = start_orchestrator!(:SimultaneousQuotaOrchestrator)
    reset_at = DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.truncate(:second)
    failure = usage_failure(reset_at)
    issue_a = issue("issue-a", "MT-1")
    issue_b = issue("issue-b", "MT-2")
    ref_a = make_ref()
    ref_b = make_ref()

    install_running(pid, [
      {issue_a, running_entry(issue_a, ref_a)},
      {issue_b, running_entry(issue_b, ref_b)}
    ])

    send(pid, {:worker_run_failure, issue_a.id, self(), failure})
    send(pid, {:DOWN, ref_a, :process, self(), {:shutdown, :quota}})
    send(pid, {:worker_run_failure, issue_b.id, self(), failure})
    send(pid, {:DOWN, ref_b, :process, self(), {:shutdown, :quota}})

    state = :sys.get_state(pid)

    assert %{status: :open, reset_at: ^reset_at, parked: parked} =
             state.quota_circuits["codex::local"]

    assert Enum.map(parked, & &1.issue_id) == [issue_a.id, issue_b.id]
    assert state.failure_counts == %{}
    assert state.retry_attempts == %{}
    assert MapSet.subset?(MapSet.new([issue_a.id, issue_b.id]), state.claimed)

    snapshot = GenServer.call(pid, :snapshot, 1_000)
    assert [%{backend: "codex", state: :open, parked_issue_count: 2}] = snapshot.quota_circuits
    assert Enum.all?(snapshot.retrying, &(&1.status == :parked))

    dashboard_payload =
      SymphonyElixirWeb.Presenter.state_payload(
        Module.concat(__MODULE__, :SimultaneousQuotaOrchestrator),
        1_000
      )

    assert [
             %{
               backend: "codex",
               account_scope: "local",
               worker_host: nil,
               state: "open",
               parked_issue_count: 2
             }
           ] = dashboard_payload.quota_circuits

    assert Enum.all?(dashboard_payload.retrying, &(&1.status == "parked"))
  end

  test "future reset is honored while past or missing reset uses a bounded probe" do
    now = ~U[2026-08-01 12:00:00Z]
    future = DateTime.add(now, 3_600, :second)

    assert Orchestrator.quota_probe_at_for_test(usage_failure(future), "codex", now) == future

    for reset_at <- [DateTime.add(now, -1, :second), nil] do
      next_probe = Orchestrator.quota_probe_at_for_test(usage_failure(reset_at), "codex", now)
      delay = DateTime.diff(next_probe, now, :millisecond)
      assert delay >= 300_000
      assert delay < 330_000
    end
  end

  test "an open Codex circuit suppresses Codex but permits an unrelated backend" do
    issue = issue("issue-backend", "MT-3")

    state = %Orchestrator.State{
      max_concurrent_agents: 10,
      running: %{},
      claimed: MapSet.new(),
      quota_circuits: %{
        "codex::local" => %{
          status: :open,
          backend: "codex",
          account_scope: "local",
          worker_host: nil,
          parked: [],
          next_probe_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
        }
      }
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)

    write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "acp")
    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "a worker-account circuit permits the same backend on another worker" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    worker_a_circuit =
      circuit(:open, nil, [])
      |> Map.merge(%{account_scope: "worker:worker-a", worker_host: "worker-a"})

    state = %Orchestrator.State{
      max_concurrent_agents: 10,
      running: %{},
      claimed: MapSet.new(),
      quota_circuits: %{"codex::worker:worker-a" => worker_a_circuit}
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue("issue-worker", "MT-4"), state)
  end

  test "ambiguous quota-like text stays on the ordinary per-issue retry path" do
    pid = start_orchestrator!(:AmbiguousFailureOrchestrator)
    ambiguous_issue = issue("issue-ambiguous", "MT-6")
    ref = make_ref()
    entry = running_entry(ambiguous_issue, ref)
    failure = AgentFailure.classify({:mystery, "usage limit"}, backend: "codex")

    install_running(pid, [{ambiguous_issue, entry}])
    send(pid, {:worker_run_failure, ambiguous_issue.id, self(), failure})
    send(pid, {:DOWN, ref, :process, self(), {:shutdown, :ambiguous}})

    state = :sys.get_state(pid)
    assert state.quota_circuits == %{}
    assert state.failure_counts == %{ambiguous_issue.id => 1}
    assert %{failure_class: :agent_protocol_failure} = state.retry_attempts[ambiguous_issue.id]
  end

  test "a trusted quota failure from the controlled probe remains failure-count neutral" do
    pid = start_orchestrator!(:RepeatedQuotaProbeOrchestrator)
    probe = issue("issue-probe-quota", "MT-8")
    ref = make_ref()
    probe_running_entry = running_entry(probe, ref, quota_probe: true)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{probe.id => probe_running_entry},
          claimed: MapSet.new([probe.id]),
          failure_counts: %{},
          quota_circuits: %{"codex::local" => circuit(:probe, probe.id, [])}
      }
    end)

    send(pid, {:worker_run_failure, probe.id, self(), usage_failure(nil)})
    send(pid, {:DOWN, ref, :process, self(), {:shutdown, :quota}})

    state = :sys.get_state(pid)
    assert state.failure_counts == %{}

    assert %{status: :open, parked: [%{issue_id: "issue-probe-quota"}]} =
             state.quota_circuits["codex::local"]
  end

  test "a due circuit starts exactly its designated probe and keeps other work suppressed" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      hook_before_run: "sleep 30"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    pid = start_orchestrator!(:DueProbeOrchestrator)
    Process.sleep(50)

    probe = issue("issue-due-probe", "MT-9")
    parked_issue = issue("issue-still-parked", "MT-10")
    fresh_issue = issue("issue-still-suppressed", "MT-11")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [probe, parked_issue, fresh_issue])

    timer_token = make_ref()

    due_circuit =
      circuit(:open, nil, [
        parked_entry(probe.id, probe.identifier, DateTime.utc_now()),
        parked_entry(parked_issue.id, parked_issue.identifier, DateTime.utc_now())
      ])
      |> Map.merge(%{next_probe_at: DateTime.utc_now(), timer_token: timer_token})

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{},
          claimed: MapSet.new([probe.id, parked_issue.id]),
          quota_circuits: %{"codex::local" => due_circuit}
      }
    end)

    send(pid, {:quota_probe_due, "codex::local", timer_token})
    state = :sys.get_state(pid)

    assert %{quota_probe: true, pid: worker_pid} = state.running[probe.id]
    assert map_size(state.running) == 1

    assert %{status: :probe, probe_issue_id: probe_id, parked: parked} =
             state.quota_circuits["codex::local"]

    assert probe_id == probe.id
    assert Enum.map(parked, & &1.issue_id) == [parked_issue.id]
    refute Orchestrator.should_dispatch_issue_for_test(fresh_issue, state)

    assert :ok = Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, worker_pid)
  end

  test "an existing retry emits suppressed before it is parked by an open circuit" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    pid = start_orchestrator!(:SuppressedTelemetryOrchestrator)
    Process.sleep(50)

    retry_issue = issue("issue-suppressed", "MT-12")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [retry_issue])
    Application.put_env(:symphony_elixir, :telemetry_enabled, true)
    on_exit(fn -> Application.put_env(:symphony_elixir, :telemetry_enabled, false) end)

    retry_token = make_ref()

    retry_entry = %{
      attempt: 2,
      retry_token: retry_token,
      timer_ref: nil,
      due_at_ms: System.monotonic_time(:millisecond),
      identifier: retry_issue.identifier,
      error: "quota circuit open",
      backend: "codex",
      failure_class: :usage_quota_limit,
      worker_host: nil,
      workspace_path: nil
    }

    :sys.replace_state(pid, fn state ->
      %{
        state
        | claimed: MapSet.new([retry_issue.id]),
          retry_attempts: %{retry_issue.id => retry_entry},
          quota_circuits: %{"codex::local" => circuit(:open, nil, [])}
      }
    end)

    send(pid, {:retry_issue, retry_issue.id, retry_token})
    state = :sys.get_state(pid)

    assert %{parked: [%{issue_id: "issue-suppressed"}]} =
             state.quota_circuits["codex::local"]

    events =
      Telemetry.read_events(nil, nil)
      |> Enum.filter(&(&1["event"] == "retry_policy" and &1["issue_id"] == retry_issue.id))

    assert Enum.map(events, & &1["action"]) == ["suppressed", "parked"]
    assert Enum.at(events, 0)["retry_suppressed"] == true
    assert Enum.at(events, 1)["retry_parked"] == true
  end

  test "a successful controlled probe closes the circuit and resumes parked issues FIFO" do
    pid = start_orchestrator!(:ProbeRecoveryOrchestrator)
    probe = issue("issue-probe", "MT-10")
    ref = make_ref()
    now = DateTime.utc_now()

    parked = [
      parked_entry("issue-first", "MT-11", now),
      parked_entry("issue-second", "MT-12", DateTime.add(now, 1, :millisecond))
    ]

    circuit = circuit(:probe, probe.id, parked)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{probe.id => running_entry(probe, ref, quota_probe: true)},
          claimed: MapSet.new([probe.id, "issue-first", "issue-second"]),
          retry_attempts: %{},
          quota_circuits: %{"codex::local" => circuit}
      }
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    state = :sys.get_state(pid)

    assert state.quota_circuits == %{}
    assert state.failure_counts == %{}
    assert state.retry_attempts["issue-first"].due_at_ms < state.retry_attempts["issue-second"].due_at_ms
    assert state.retry_attempts["issue-second"].due_at_ms < state.retry_attempts[probe.id].due_at_ms
    refute File.read!(QuotaCircuitStore.path()) =~ "codex"
  end

  test "authoritative recovered rate limits close a restored circuit" do
    pid = start_orchestrator!(:RateLimitRecoveryOrchestrator)
    issue = issue("issue-update", "MT-20")
    ref = make_ref()
    parked = [parked_entry("issue-parked", "MT-21", DateTime.utc_now())]

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{issue.id => running_entry(issue, ref)},
          claimed: MapSet.new([issue.id, "issue-parked"]),
          quota_circuits: %{"codex::local" => circuit(:open, nil, parked)}
      }
    end)

    send(pid, {
      :codex_worker_update,
      issue.id,
      %{
        event: :notification,
        timestamp: DateTime.utc_now(),
        payload: %{
          "method" => "account/rateLimits/updated",
          "params" => %{
            "rateLimits" => %{
              "limitId" => "premium",
              "credits" => %{"hasCredits" => true, "unlimited" => false}
            }
          }
        }
      }
    })

    state = :sys.get_state(pid)
    assert state.quota_circuits == %{}
    assert Map.has_key?(state.retry_attempts, "issue-parked")
  end

  test "restored circuit retains claims and suppresses immediate fan-out" do
    now = DateTime.utc_now()
    circuit = circuit(:open, nil, [parked_entry("issue-restored", "MT-30", now)])
    QuotaCircuitStore.save(%{"codex::local" => circuit})

    pid = start_orchestrator!(:RestartedQuotaOrchestrator)
    state = :sys.get_state(pid)

    assert Map.has_key?(state.quota_circuits, "codex::local")
    assert MapSet.member?(state.claimed, "issue-restored")
    refute Orchestrator.should_dispatch_issue_for_test(issue("issue-new", "MT-31"), state)
  end

  defp start_orchestrator!(suffix) do
    name = Module.concat(__MODULE__, suffix)
    {:ok, pid} = Orchestrator.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)
    pid
  end

  defp install_running(pid, entries) do
    :sys.replace_state(pid, fn state ->
      running = Map.new(entries, fn {issue, entry} -> {issue.id, entry} end)
      claimed = entries |> Enum.map(fn {issue, _entry} -> issue.id end) |> MapSet.new()
      %{state | running: running, claimed: claimed, retry_attempts: %{}, failure_counts: %{}}
    end)
  end

  defp issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Quota circuit #{identifier}",
      description: "Exercise quota handling",
      state: "In Progress",
      labels: [],
      assigned_to_worker: true
    }
  end

  defp running_entry(issue, ref, opts \\ []) do
    %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      backend: "codex",
      retry_attempt: Keyword.get(opts, :retry_attempt, 0),
      quota_probe: Keyword.get(opts, :quota_probe, false),
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      recent_codex_events: [],
      recent_codex_transcript_blocks: [],
      codex_session_logs: [],
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: DateTime.utc_now()
    }
  end

  defp parked_entry(issue_id, identifier, parked_at) do
    %{
      issue_id: issue_id,
      identifier: identifier,
      title: "Parked #{identifier}",
      attempt: 1,
      error: "quota exhausted",
      backend: "codex",
      failure_class: :usage_quota_limit,
      worker_host: nil,
      workspace_path: nil,
      parked_at: parked_at
    }
  end

  defp circuit(status, probe_issue_id, parked) do
    now = DateTime.utc_now()

    %{
      backend: "codex",
      account_scope: "local",
      worker_host: nil,
      provider_limit_id: "premium",
      status: status,
      reason: "quota exhausted",
      opened_at: now,
      reset_at: DateTime.add(now, 3_600, :second),
      next_probe_at: DateTime.add(now, 3_600, :second),
      probe_issue_id: probe_issue_id,
      parked: parked,
      timer_ref: nil,
      timer_token: nil
    }
  end

  defp usage_failure(reset_at) do
    details = %{
      "error" => %{
        "codexErrorInfo" => "usageLimitExceeded",
        "message" => "You've hit your usage limit."
      }
    }

    details = if reset_at, do: put_in(details, ["error", "resetAt"], DateTime.to_iso8601(reset_at)), else: details
    AgentFailure.classify(details, backend: "codex")
  end
end
