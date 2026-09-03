defmodule SymphonyElixir.WaitWatcherTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{ResumePacket, WaitCondition, WaitStore, WaitWatcher}

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-waits-#{System.unique_integer([:positive])}")
    state_path = Path.join(root, "waits.json")
    previous_path = Application.get_env(:symphony_elixir, :wait_state_path)
    previous_probe = Application.get_env(:symphony_elixir, :wait_condition_probe)
    Application.put_env(:symphony_elixir, :wait_state_path, state_path)

    on_exit(fn ->
      restore_app_env(:wait_state_path, previous_path)
      restore_app_env(:wait_condition_probe, previous_probe)
      File.rm_rf(root)
    end)

    %{state_path: state_path}
  end

  test "normalizes the supported typed conditions" do
    context = %{workspace: "/tmp/workspace", worker_host: nil, issue: %{id: "issue-1"}}

    assert {:ok, git} =
             WaitCondition.normalize(
               %{
                 "reason" => "base branch has not advanced",
                 "condition" => %{
                   "type" => "git_ref_changed",
                   "ref" => "refs/heads/main"
                 }
               },
               context
             )

    assert git.baseline == nil
    assert git.condition["workspace"] == "/tmp/workspace"

    assert {:ok, linear} =
             WaitCondition.normalize(
               %{
                 "reason" => "await issue update",
                 "condition" => %{"type" => "linear_issue_changed"}
               },
               context
             )

    assert linear.condition["issue_id"] == "issue-1"

    assert {:error, :cross_issue_linear_wait_not_allowed} =
             WaitCondition.normalize(
               %{
                 "reason" => "await a tracking follow-up",
                 "condition" => %{
                   "type" => "linear_issue_changed",
                   "issue_id" => "issue-2"
                 }
               },
               context
             )

    assert {:ok, named_check} =
             WaitCondition.normalize(
               %{
                 "reason" => "await one check",
                 "condition" => %{
                   "type" => "github_pr_check_changed",
                   "pr_number" => 42,
                   "check_name" => "quality"
                 }
               },
               context
             )

    assert named_check.condition["check_name"] == "quality"

    assert {:ok, gate} =
             WaitCondition.normalize(
               %{
                 "reason" => "await terminal gate",
                 "condition" => %{"type" => "github_pr_gate_settled", "pr_number" => 42}
               },
               context
             )

    assert gate.condition["type"] == "github_pr_gate_settled"

    assert {:error, :agent_observation_not_allowed} =
             WaitCondition.normalize(
               %{
                 "reason" => "do not trust agent snapshots",
                 "condition" => %{
                   "type" => "git_ref_changed",
                   "ref" => "refs/heads/main",
                   "observed" => "abc123"
                 }
               },
               context
             )

    assert {:error, :agent_observation_not_allowed} =
             WaitCondition.normalize(
               %{
                 "reason" => "do not trust agent baselines",
                 "baseline" => %{"sha" => "abc123"},
                 "condition" => %{"type" => "linear_issue_changed"}
               },
               context
             )

    assert {:error, {:unsupported_condition_type, "time"}} =
             WaitCondition.normalize(
               %{
                 "reason" => "retry after local load drops",
                 "condition" => %{"type" => "time", "resume_at" => "2099-01-01T00:00:00Z"}
               },
               context
             )
  end

  test "wakes legacy persisted clock waits without accepting new ones" do
    assert {:changed, %{"now" => _now}} =
             WaitCondition.probe(%{
               condition: %{"type" => "time", "resume_at" => "2020-01-01T00:00:00Z"}
             })
  end

  test "matches GitHub status components without case sensitivity" do
    component = %{"name" => "Actions", "status" => "major_outage"}

    assert WaitCondition.github_component_match_for_test?(component, "actions")
    assert WaitCondition.github_component_match_for_test?(component, "Actions")
    refute WaitCondition.github_component_match_for_test?(component, "Git Operations")
  end

  test "treats incident monitoring as a controlled GitHub Actions recovery signal" do
    degraded_actions = %{"name" => "Actions", "status" => "major_outage"}

    monitoring_incident = %{
      "status" => "monitoring",
      "components" => [%{"name" => "Actions", "status" => "major_outage"}]
    }

    identified_incident = %{
      "status" => "identified",
      "components" => [%{"name" => "Actions", "status" => "major_outage"}]
    }

    unrelated_incident = %{
      "status" => "monitoring",
      "components" => [%{"name" => "Pages", "status" => "degraded_performance"}]
    }

    assert WaitCondition.github_recovery_signal_for_test(degraded_actions, [monitoring_incident]) ==
             :incident_monitoring

    assert WaitCondition.github_recovery_signal_for_test(degraded_actions, [identified_incident]) ==
             :waiting

    assert WaitCondition.github_recovery_signal_for_test(degraded_actions, [unrelated_incident]) ==
             :waiting

    assert WaitCondition.github_recovery_signal_for_test(degraded_actions, [
             monitoring_incident,
             identified_incident
           ]) == :waiting

    assert WaitCondition.github_recovery_signal_for_test(
             %{"name" => "Actions", "status" => "operational"},
             [identified_incident]
           ) == :component_operational
  end

  test "treats skipped PR checks as terminal-neutral" do
    checks = [
      %{"name" => "unit-tests", "state" => "SUCCESS", "bucket" => "pass", "workflow" => "Tests"},
      %{"name" => "docs:check", "state" => "SKIPPED", "bucket" => "skipping", "workflow" => "Lint PR"}
    ]

    assert %{"aggregate" => "pass", "checks" => normalized} =
             WaitCondition.checks_observation_for_test(checks)

    assert Enum.any?(normalized, &(&1["bucket"] == "skipping"))

    pending = [%{"name" => "e2e", "state" => "IN_PROGRESS", "bucket" => "pending"} | checks]
    assert %{"aggregate" => "pending"} = WaitCondition.checks_observation_for_test(pending)

    failing = [%{"name" => "quality", "state" => "FAILURE", "bucket" => "fail"} | pending]
    assert %{"aggregate" => "fail"} = WaitCondition.checks_observation_for_test(failing)
  end

  test "PR-check waits wake when relevant pull-request state changes" do
    pull_request = %{
      "state" => "OPEN",
      "isDraft" => false,
      "headRefOid" => "head-1",
      "baseRefOid" => "base-1",
      "mergeable" => "MERGEABLE",
      "mergeStateStatus" => "BLOCKED",
      "reviewDecision" => "REVIEW_REQUIRED"
    }

    baseline = %{
      "present" => true,
      "name" => "CodeRabbit",
      "state" => "PENDING",
      "bucket" => "pending",
      "workflow" => "",
      "pull_request" => pull_request
    }

    request = %{
      condition: %{"type" => "github_pr_check_changed"},
      baseline: baseline
    }

    refute WaitCondition.changed?(request, baseline)

    conflicted =
      put_in(baseline, ["pull_request", "mergeStateStatus"], "DIRTY")

    assert WaitCondition.changed?(request, conflicted)
  end

  test "PR gate waits wake on pull-request drift before checks settle" do
    pull_request = %{
      "state" => "OPEN",
      "headRefOid" => "head-1",
      "baseRefOid" => "base-1",
      "mergeable" => "MERGEABLE"
    }

    baseline = %{
      "aggregate" => "pending",
      "fingerprint" => "checks-1",
      "checks" => [],
      "pull_request" => pull_request
    }

    request = %{
      condition: %{"type" => "github_pr_gate_settled"},
      baseline: baseline
    }

    refute WaitCondition.changed?(request, baseline)
    assert WaitCondition.changed?(request, put_in(baseline, ["pull_request", "baseRefOid"], "base-2"))
    assert WaitCondition.changed?(request, %{baseline | "aggregate" => "pass"})
  end

  test "deduplicates identical probes and persists ready work", %{state_path: state_path} do
    test_pid = self()

    Application.put_env(:symphony_elixir, :wait_condition_probe, fn request ->
      send(test_pid, {:probe, request.condition_key})

      receive do
        :release_probe -> :ok
      end

      {:changed, %{"status" => "operational"}}
    end)

    name = :"wait-watcher-#{System.unique_integer([:positive])}"
    start_supervised!({WaitWatcher, name: name})

    request = %{
      condition: %{"type" => "github_actions_recovered", "component" => "Actions"},
      condition_key: "shared-actions-condition",
      reason: "GitHub Actions outage",
      min_poll_ms: 15_000,
      max_poll_ms: 60_000
    }

    :ok = WaitWatcher.park(name, entry("issue-1", "UDPE-1", request))
    assert_receive {:probe, "shared-actions-condition"}, 1_000
    :ok = WaitWatcher.park(name, entry("issue-2", "UDPE-2", request))
    probe_pid = :sys.get_state(name).probes[request.condition_key].pid
    send(probe_pid, :release_probe)
    refute_receive {:probe, "shared-actions-condition"}, 100

    assert eventually(fn -> Enum.all?(WaitWatcher.snapshot(name), &(&1.status == :ready)) end)
    assert File.exists?(state_path)
    restored = WaitStore.load()
    assert MapSet.new(Map.keys(restored)) == MapSet.new(["issue-1", "issue-2"])
    assert Enum.all?(restored, fn {_issue_id, entry} -> entry.run_id == nil end)

    :ok = WaitWatcher.acknowledge(name, "issue-1")
    assert WaitWatcher.issue_ids(name) == MapSet.new(["issue-2"])
  end

  test "wait persistence round-trips packet references and accepts legacy omissions" do
    packet = ResumePacket.build(%{boundary_reason: :wait_parked})
    packet_ref = ResumePacket.reference(packet, "wait.json.resume-packet.json")
    request = %{condition: %{"type" => "linear_issue_changed"}, condition_key: "wait-ref", reason: "wait"}

    with_ref = entry("issue-ref", "UDPE-REF", request) |> Map.put(:resume_packet_ref, packet_ref)
    legacy = entry("issue-legacy", "UDPE-LEGACY", request)

    assert :ok = WaitStore.save(%{"issue-ref" => with_ref, "issue-legacy" => legacy})
    restored = WaitStore.load()
    assert restored["issue-ref"].resume_packet_ref == packet_ref
    assert restored["issue-legacy"].resume_packet_ref == nil
  end

  test "probes restored waits immediately instead of preserving an old backoff deadline" do
    test_pid = self()
    previous_reset = Application.get_env(:symphony_elixir, :wait_state_reset_on_start)
    Application.put_env(:symphony_elixir, :wait_state_reset_on_start, false)

    on_exit(fn -> restore_app_env(:wait_state_reset_on_start, previous_reset) end)

    Application.put_env(:symphony_elixir, :wait_condition_probe, fn _request ->
      send(test_pid, {:restored_probe_started, self()})

      receive do
        :release_restored_probe -> {:ok, %{"sha" => "same-sha"}}
      end
    end)

    request = %{
      condition: %{"type" => "git_ref_changed", "ref" => "refs/heads/main"},
      condition_key: "restored-ref-condition",
      baseline: %{"sha" => "same-sha"},
      reason: "await main",
      min_poll_ms: 15_000,
      max_poll_ms: 1_800_000
    }

    future_probe_at = DateTime.add(DateTime.utc_now(), 2, :hour)

    persisted_entry =
      entry("issue-restored", "UDPE-RESTORED", request)
      |> Map.merge(%{
        status: :waiting,
        parked_at: DateTime.utc_now(),
        next_probe_at: future_probe_at,
        probe_attempt: 10,
        last_observation: %{"sha" => "same-sha"},
        last_error: nil
      })

    :ok = WaitStore.save(%{"issue-restored" => persisted_entry})

    name = :"wait-watcher-restored-#{System.unique_integer([:positive])}"
    start_supervised!({WaitWatcher, name: name})

    assert_receive {:restored_probe_started, probe_pid}, 1_000
    [restored] = WaitWatcher.snapshot(name)
    assert restored.request.baseline == %{"sha" => "same-sha"}
    send(probe_pid, :release_restored_probe)

    assert eventually(fn ->
             [restored] = WaitWatcher.snapshot(name)

             restored.probe_attempt == 11 and
               DateTime.compare(restored.next_probe_at, future_probe_at) == :lt
           end)
  end

  test "releases restored cross-issue Linear waits without probing the tracking issue" do
    test_pid = self()
    previous_reset = Application.get_env(:symphony_elixir, :wait_state_reset_on_start)
    Application.put_env(:symphony_elixir, :wait_state_reset_on_start, false)

    on_exit(fn -> restore_app_env(:wait_state_reset_on_start, previous_reset) end)

    Application.put_env(:symphony_elixir, :wait_condition_probe, fn _request ->
      send(test_pid, :unexpected_cross_issue_probe)
      {:unchanged, %{}}
    end)

    request = %{
      condition: %{
        "type" => "linear_issue_changed",
        "issue_id" => "tracking-issue"
      },
      condition_key: "legacy-cross-issue-wait",
      baseline: %{"state" => "Backlog"},
      reason: "await tracking follow-up",
      min_poll_ms: 60_000,
      max_poll_ms: 1_800_000
    }

    persisted_entry =
      entry("delivery-issue", "UDPE-DELIVERY", request)
      |> Map.merge(%{
        status: :waiting,
        parked_at: DateTime.utc_now(),
        next_probe_at: DateTime.add(DateTime.utc_now(), 1, :hour),
        probe_attempt: 4,
        last_observation: %{"state" => "Backlog"},
        last_error: nil
      })

    :ok = WaitStore.save(%{"delivery-issue" => persisted_entry})

    name = :"wait-watcher-cross-issue-#{System.unique_integer([:positive])}"
    start_supervised!({WaitWatcher, name: name})

    assert [restored] = WaitWatcher.snapshot(name)
    assert restored.status == :ready
    assert restored.last_observation["policy"] == "cross_issue_linear_wait_retired"
    assert restored.resume_prompt =~ "retired an unsafe cross-issue wait"
    assert restored.resume_prompt =~ "Use a Linear blocks relation"
    refute_receive :unexpected_cross_issue_probe, 100
  end

  test "caps polling while known PR checks remain active", %{state_path: state_path} do
    test_pid = self()
    previous_reset = Application.get_env(:symphony_elixir, :wait_state_reset_on_start)
    Application.put_env(:symphony_elixir, :wait_state_reset_on_start, false)

    on_exit(fn -> restore_app_env(:wait_state_reset_on_start, previous_reset) end)

    gate_observation = %{
      "aggregate" => "pending",
      "fingerprint" => "pending-checks",
      "checks" => [%{"name" => "e2e", "bucket" => "pending", "state" => "IN_PROGRESS"}],
      "pull_request" => %{"state" => "OPEN", "headRefOid" => "head-1"}
    }

    named_observation = %{
      "present" => true,
      "name" => "e2e",
      "bucket" => "pending",
      "state" => "QUEUED",
      "pull_request" => %{"state" => "OPEN", "headRefOid" => "head-2"}
    }

    Application.put_env(:symphony_elixir, :wait_condition_probe, fn request ->
      send(test_pid, {:active_checks_probed, request.condition_key})

      case request.condition["type"] do
        "github_pr_gate_settled" -> {:ok, gate_observation}
        "github_pr_check_changed" -> {:ok, named_observation}
      end
    end)

    gate_request = %{
      condition: %{"type" => "github_pr_gate_settled", "pr_number" => 42},
      condition_key: "active-pr-gate",
      baseline: gate_observation,
      reason: "await active CI",
      min_poll_ms: 60_000,
      max_poll_ms: 1_800_000
    }

    named_request = %{
      condition: %{
        "type" => "github_pr_check_changed",
        "pr_number" => 43,
        "check_name" => "e2e"
      },
      condition_key: "active-named-check",
      baseline: named_observation,
      reason: "await queued E2E",
      min_poll_ms: 60_000,
      max_poll_ms: 1_800_000
    }

    persisted_gate =
      entry("issue-active-ci", "UDPE-ACTIVE-CI", gate_request)
      |> Map.merge(%{
        status: :waiting,
        parked_at: DateTime.utc_now(),
        next_probe_at: DateTime.add(DateTime.utc_now(), 30, :minute),
        probe_attempt: 8,
        last_observation: gate_observation,
        last_error: nil
      })

    persisted_named =
      entry("issue-active-named", "UDPE-ACTIVE-NAMED", named_request)
      |> Map.merge(%{
        status: :waiting,
        parked_at: DateTime.utc_now(),
        next_probe_at: DateTime.add(DateTime.utc_now(), 30, :minute),
        probe_attempt: 8,
        last_observation: named_observation,
        last_error: nil
      })

    :ok =
      WaitStore.save(%{
        "issue-active-ci" => persisted_gate,
        "issue-active-named" => persisted_named
      })

    name = :"wait-watcher-active-ci-#{System.unique_integer([:positive])}"
    start_supervised!({WaitWatcher, name: name})

    assert_receive {:active_checks_probed, "active-pr-gate"}, 1_000
    assert_receive {:active_checks_probed, "active-named-check"}, 1_000

    assert eventually(fn ->
             updated = WaitWatcher.snapshot(name)

             length(updated) == 2 and
               Enum.all?(updated, fn entry ->
                 delay_ms = DateTime.diff(entry.next_probe_at, DateTime.utc_now(), :millisecond)
                 entry.probe_attempt == 9 and delay_ms > 0 and delay_ms <= 60_000
               end)
           end)

    assert %{
             "issue-active-ci" => %{request: %{baseline: ^gate_observation}},
             "issue-active-named" => %{request: %{baseline: ^named_observation}}
           } = WaitStore.load()

    assert File.exists?(state_path)
  end

  test "keeps exponential backoff for failed PR-check probes" do
    test_pid = self()
    previous_reset = Application.get_env(:symphony_elixir, :wait_state_reset_on_start)
    Application.put_env(:symphony_elixir, :wait_state_reset_on_start, false)

    on_exit(fn -> restore_app_env(:wait_state_reset_on_start, previous_reset) end)

    Application.put_env(:symphony_elixir, :wait_condition_probe, fn _request ->
      send(test_pid, :failed_checks_probe)
      {:error, :github_unavailable}
    end)

    observation = %{"aggregate" => "pending", "checks" => [], "pull_request" => %{}}

    request = %{
      condition: %{"type" => "github_pr_gate_settled", "pr_number" => 43},
      condition_key: "failed-pr-gate",
      baseline: observation,
      reason: "await active CI",
      min_poll_ms: 60_000,
      max_poll_ms: 1_800_000
    }

    persisted_entry =
      entry("issue-failed-ci-probe", "UDPE-FAILED-CI-PROBE", request)
      |> Map.merge(%{
        status: :waiting,
        parked_at: DateTime.utc_now(),
        next_probe_at: DateTime.utc_now(),
        probe_attempt: 4,
        last_observation: observation,
        last_error: nil
      })

    :ok = WaitStore.save(%{"issue-failed-ci-probe" => persisted_entry})

    name = :"wait-watcher-failed-ci-#{System.unique_integer([:positive])}"
    start_supervised!({WaitWatcher, name: name})

    assert_receive :failed_checks_probe, 1_000

    assert eventually(fn ->
             [updated] = WaitWatcher.snapshot(name)
             delay_ms = DateTime.diff(updated.next_probe_at, DateTime.utc_now(), :millisecond)

             updated.probe_attempt == 5 and delay_ms > 900_000
           end)
  end

  test "manual resume produces a compact resume prompt" do
    Application.put_env(:symphony_elixir, :wait_condition_probe, fn _request ->
      {:unchanged, %{"status" => "degraded"}}
    end)

    name = :"wait-watcher-#{System.unique_integer([:positive])}"
    start_supervised!({WaitWatcher, name: name})

    request = %{
      condition: %{"type" => "github_actions_recovered", "component" => "Actions"},
      condition_key: "manual-actions-condition",
      reason: "outage",
      min_poll_ms: 15_000,
      max_poll_ms: 60_000
    }

    :ok = WaitWatcher.park(name, entry("issue-3", "UDPE-3", request))
    assert {:ok, ready} = WaitWatcher.resume_now(name, "UDPE-3")
    assert ready.status == :ready
    assert ready.resume_prompt =~ "human requested an immediate resume"
    assert ready.resume_prompt =~ "Do not repeat the old polling loop"
  end

  test "one shared observation is compared against each wait's server baseline" do
    test_pid = self()

    Application.put_env(:symphony_elixir, :wait_condition_probe, fn _request ->
      send(test_pid, :baseline_probe_started)

      receive do
        :release_baseline_probe -> :ok
      end

      {:ok, %{"sha" => "sha-b"}}
    end)

    name = :"wait-watcher-baseline-#{System.unique_integer([:positive])}"
    start_supervised!({WaitWatcher, name: name})

    request = fn baseline ->
      %{
        condition: %{"type" => "git_ref_changed", "ref" => "refs/heads/main"},
        condition_key: "shared-ref-condition",
        baseline: %{"sha" => baseline},
        reason: "await main",
        min_poll_ms: 15_000,
        max_poll_ms: 60_000
      }
    end

    :ok = WaitWatcher.park(name, entry("issue-a", "UDPE-A", request.("sha-a")))
    assert_receive :baseline_probe_started, 1_000
    :ok = WaitWatcher.park(name, entry("issue-b", "UDPE-B", request.("sha-b")))

    probe_pid = :sys.get_state(name).probes["shared-ref-condition"].pid
    send(probe_pid, :release_baseline_probe)

    assert eventually(fn ->
             statuses = Map.new(WaitWatcher.snapshot(name), &{&1.issue_id, &1.status})
             statuses == %{"issue-a" => :ready, "issue-b" => :waiting}
           end)
  end

  defp entry(issue_id, identifier, request) do
    %{
      issue_id: issue_id,
      identifier: identifier,
      title: "Waiting issue",
      backend: "codex",
      worker_host: nil,
      workspace_path: "/tmp/#{identifier}",
      priority: 1,
      created_at: DateTime.utc_now(),
      request: request
    }
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
