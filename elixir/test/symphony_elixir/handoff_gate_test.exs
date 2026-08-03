defmodule SymphonyElixir.HandoffGateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.HandoffGate

  test "handoff transition only matches in-progress review handoffs" do
    assert HandoffGate.handoff_transition?(" In Progress ", "Human Review")
    assert HandoffGate.handoff_transition?("in progress", "In Review")
    refute HandoffGate.handoff_transition?("Todo", "Human Review")
    refute HandoffGate.handoff_transition?(nil, "Human Review")
  end

  test "run_before_handoff skips when hook is not configured" do
    workspace = temp_workspace!("handoff-skip")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.dirname(workspace))

    assert :ok = HandoffGate.run_before_handoff(workspace, issue("MT-HANDOFF-SKIP"), nil, "Human Review")
  end

  test "run_before_handoff passes and emits telemetry when hook succeeds" do
    workspace = temp_workspace!("handoff-pass")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(workspace),
      hook_before_handoff: ~s(printf '{"checks":[{"name":"lint","status":"passed","detail":"ok"}]}')
    )

    telemetry_ref = make_ref()
    parent = self()

    :telemetry.attach(
      telemetry_ref,
      HandoffGate.telemetry_event(),
      fn event, measurements, metadata, _config ->
        send(parent, {:handoff_telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(telemetry_ref) end)

    assert :ok = HandoffGate.run_before_handoff(workspace, issue("MT-HANDOFF-PASS"), nil, "Human Review")

    assert_receive {:handoff_telemetry, [:symphony_elixir, :gate, :before_handoff], %{count: 1}, metadata}
    assert %{outcome: :passed, issue_identifier: "MT-HANDOFF-PASS", target_state: "Human Review"} = metadata
    assert [%{name: "lint", status: "passed", passed: true, detail: "ok"}] = metadata.gates
  end

  test "run_before_handoff blocks generic hook failures" do
    workspace = temp_workspace!("handoff-timeout")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(workspace),
      hook_before_handoff: "sleep 1",
      hook_timeout_ms: 1
    )

    assert {:blocked, prompt, [gate]} =
             HandoffGate.run_before_handoff(workspace, issue("MT-HANDOFF-TIMEOUT"), nil, "Human Review")

    assert prompt =~ "workspace_hook_timeout"
    assert gate.name == "before_handoff"
    assert gate.passed == false
  end

  test "remediation prompt falls back to raw output when all gates pass" do
    prompt =
      HandoffGate.remediation_prompt(
        [%{name: "unit", status: "passed", passed: true, detail: nil}],
        "raw fallback"
      )

    assert prompt =~ "- before_handoff: raw fallback"
  end

  test "remediation prompt includes gate status when detail is blank" do
    prompt =
      HandoffGate.remediation_prompt(
        [%{name: "types", status: "failed", passed: false, detail: "  "}],
        ""
      )

    assert prompt =~ "- types: failed"
  end

  test "gate breakdown parses supported report shapes" do
    assert [
             %{name: "lint", status: "warn", passed: true, detail: "numeric"},
             %{name: "42", status: "true", passed: true, detail: nil}
           ] =
             HandoffGate.gate_breakdown(
               ~s({"checks":[{"name":"lint","status":"warn","detail":"numeric"},{"check":42,"result":true}]}),
               true
             )

    assert [%{name: "before_handoff", status: "failed", passed: false, detail: nil}] =
             HandoffGate.gate_breakdown(~s({"checks":[{"bad":1}]}), false)

    assert [%{name: "before_handoff", status: "failed", passed: false, detail: ~s(":bad")}] =
             HandoffGate.gate_breakdown(~s({"checks":[":bad"]}), false)

    assert [%{name: "types", passed: false, detail: "bad"}] =
             HandoffGate.gate_breakdown(~s(prefix {"gates":[{"gate":"types","result":"blocked","reason":"bad"}]} suffix), true)

    assert [%{name: "test", status: "failed", passed: false, detail: "failed"}] =
             HandoffGate.gate_breakdown(~s({"failures":[{"gate":"test","message":"failed"}]}), true)

    assert [%{name: "before_handoff", status: "failed", passed: false, detail: "123"}] =
             HandoffGate.gate_breakdown(~s({"failures":[123]}), true)

    assert [%{name: "before_handoff", status: "failed", passed: false, detail: "string failure"}] =
             HandoffGate.gate_breakdown(~s({"failures":["string failure"]}), true)

    assert [%{name: "before_handoff", status: "failed", passed: false, detail: "not-json"}] =
             HandoffGate.gate_breakdown("not-json", false)

    assert [%{name: "before_handoff", status: "passed", passed: true, detail: "prefix {bad} suffix"}] =
             HandoffGate.gate_breakdown("prefix {bad} suffix", true)

    assert [%{name: "before_handoff", status: "passed", passed: true, detail: nil}] =
             HandoffGate.gate_breakdown("[]", true)
  end

  test "protocol v1 distinguishes pending, passed, failed, invalidated, and infrastructure outcomes" do
    pending = protocol_report("running")
    passed = protocol_report("passed", %{"completedAt" => "2026-08-02T12:01:00Z"})
    failed = protocol_report("failed", %{"remediation" => "fix tests"})
    invalidated = protocol_report("invalidated", %{"summary" => "candidate changed"})
    infrastructure = protocol_report("infrastructure_error", %{"summary" => "runner lost"})

    assert {:ok, %{status: :running, job_id: "gate-1", next_poll_ms: 250}} =
             HandoffGate.parse_protocol_result(Jason.encode!(pending), 3, nil, 1_000)

    assert {:ok, %{status: :passed, candidate_hash: "candidate-1"}} =
             HandoffGate.parse_protocol_result(Jason.encode!(passed), 0, "candidate-1", 1_000)

    assert {:ok, %{status: :failed, remediation: "fix tests"}} =
             HandoffGate.parse_protocol_result(Jason.encode!(failed), 2, nil, 1_000)

    assert {:ok, %{status: :invalidated}} =
             HandoffGate.parse_protocol_result(Jason.encode!(invalidated), 2, nil, 1_000)

    assert {:ok, %{status: :infrastructure_error}} =
             HandoffGate.parse_protocol_result(Jason.encode!(infrastructure), 1, nil, 1_000)
  end

  test "protocol v1 rejects stale heartbeats, status/exit mismatches, and stale candidate passes" do
    pending = protocol_report("pending", %{"heartbeatAgeMs" => 2_001})
    passed = protocol_report("passed")

    assert {:error, reason, _report} =
             HandoffGate.parse_protocol_result(Jason.encode!(pending), 3, nil, 2_000)

    assert reason =~ "heartbeat is stale"

    assert {:error, reason, _report} =
             HandoffGate.parse_protocol_result(Jason.encode!(passed), 3, nil, 2_000)

    assert reason =~ "requires exit 0"

    assert {:candidate_changed, %{status: :invalidated, candidate_hash: "candidate-1"}} =
             HandoffGate.parse_protocol_result(Jason.encode!(passed), 0, "candidate-2", 2_000)
  end

  test "poll exports the protocol and durable job identity to the hook" do
    workspace = temp_workspace!("handoff-poll-env")
    report = protocol_report("passed", %{"jobId" => "gate-poll-1"})

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(workspace),
      hook_before_handoff: """
      test "$SYMPHONY_HANDOFF_GATE_JOB_ID" = "gate-poll-1"
      printf '%s' '#{Jason.encode!(report)}'
      """
    )

    assert {:passed, %{job_id: "gate-poll-1", candidate_hash: "candidate-1"}} =
             HandoffGate.poll_before_handoff(
               workspace,
               issue("MT-HANDOFF-POLL"),
               nil,
               "In Review",
               "gate-poll-1",
               expected_candidate_hash: "candidate-1"
             )
  end

  test "poll default options preserve fail-closed protocol outcomes" do
    workspace = temp_workspace!("handoff-poll-defaults")
    passed = protocol_report("passed", %{"jobId" => "gate-default-1"})

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(workspace),
      hook_before_handoff: hook_command(passed, 0)
    )

    assert {:passed, %{job_id: "gate-default-1"}} =
             HandoffGate.poll_before_handoff(
               workspace,
               issue("MT-HANDOFF-POLL-DEFAULTS"),
               nil,
               "In Review",
               "gate-default-1"
             )

    assert {:invalidated, candidate_prompt, %{status: :invalidated}} =
             HandoffGate.poll_before_handoff(
               workspace,
               issue("MT-HANDOFF-CANDIDATE-CHANGED"),
               nil,
               "In Review",
               "gate-default-1",
               hook_command: hook_command(passed, 0),
               expected_candidate_hash: "new-candidate"
             )

    assert candidate_prompt =~ "candidate `candidate-1`"

    assert {:pending, %{status: :pending, job_id: "gate-1"}} =
             HandoffGate.poll_before_handoff(
               workspace,
               issue("MT-HANDOFF-PENDING"),
               nil,
               "In Review",
               "gate-1",
               hook_command: hook_command(protocol_report("pending"), 3)
             )

    assert {:infrastructure_error, malformed_prompt, %{"status" => "unknown"}} =
             HandoffGate.poll_before_handoff(
               workspace,
               issue("MT-HANDOFF-MALFORMED"),
               nil,
               "In Review",
               "gate-default-1",
               hook_command: hook_command(protocol_report("unknown"), 1)
             )

    assert malformed_prompt =~ "unsupported protocol status"

    assert {:infrastructure_error, timeout_prompt, %{status: :infrastructure_error}} =
             HandoffGate.poll_before_handoff(
               workspace,
               issue("MT-HANDOFF-ASYNC-TIMEOUT"),
               nil,
               "In Review",
               "gate-default-1",
               hook_command: "sleep 1",
               timeout_ms: 1
             )

    assert timeout_prompt =~ "workspace_hook_timeout"
  end

  test "hook maps terminal protocol outcomes with compact remediation precedence" do
    workspace = temp_workspace!("handoff-terminal-outcomes")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(workspace)
    )

    assert {:failed, remediation_prompt, %{status: :failed}} =
             HandoffGate.run_before_handoff(
               workspace,
               issue("MT-HANDOFF-FAILED"),
               nil,
               "In Review",
               hook_command: hook_command(protocol_report("failed", %{"remediation" => "repair tests", "summary" => "summary fallback"}), 2)
             )

    assert remediation_prompt =~ "repair tests"
    refute remediation_prompt =~ "summary fallback"

    assert {:invalidated, summary_prompt, %{status: :invalidated}} =
             HandoffGate.run_before_handoff(
               workspace,
               issue("MT-HANDOFF-INVALIDATED"),
               nil,
               "In Review",
               hook_command: hook_command(protocol_report("invalidated", %{"summary" => "candidate moved"}), 2)
             )

    assert summary_prompt =~ "candidate moved"

    assert {:infrastructure_error, raw_prompt, %{status: :infrastructure_error}} =
             HandoffGate.run_before_handoff(
               workspace,
               issue("MT-HANDOFF-INFRASTRUCTURE"),
               nil,
               "In Review",
               hook_command: hook_command(protocol_report("infrastructure_error", %{"remediation" => "", "summary" => ""}), 1)
             )

    assert raw_prompt =~ "protocolVersion"

    assert {:blocked, legacy_prompt, [%{status: "failed", passed: false}]} =
             HandoffGate.run_before_handoff(
               workspace,
               issue("MT-HANDOFF-LEGACY-FAILED"),
               nil,
               "In Review",
               hook_command: "printf '%s' 'legacy gate failed'; exit 1"
             )

    assert legacy_prompt =~ "legacy gate failed"
  end

  test "protocol v1 rejects malformed identity and pending lifecycle fields" do
    identity = protocol_report("pending")["identity"]

    malformed_reports = [
      {protocol_report("unknown"), 1, "unsupported protocol status"},
      {Map.delete(protocol_report("pending"), "identity"), 3, "missing or invalid identity"},
      {put_in(protocol_report("pending"), ["identity", "headSha"], ""), 3, "missing or invalid identity.headSha"},
      {put_in(protocol_report("pending"), ["identity", "prNumber"], 0), 3, "missing or invalid identity.prNumber"},
      {put_in(protocol_report("pending"), ["progress", "stage"], ""), 3, "pending gate progress.stage is required"},
      {Map.delete(protocol_report("pending"), "progress"), 3, "pending gate progress is required"},
      {Map.delete(protocol_report("pending"), "heartbeatAt"), 3, "pending gate heartbeatAt"},
      {%{protocol_report("pending") | "heartbeatAgeMs" => -1}, 3, "pending gate heartbeatAt"},
      {%{protocol_report("pending") | "nextPollMs" => 0}, 3, "pending gate heartbeatAt"},
      {%{protocol_report("pending") | "identity" => %{identity | "candidateHash" => nil}}, 3, "missing or invalid identity.candidateHash"}
    ]

    Enum.each(malformed_reports, fn {report, exit_status, expected_reason} ->
      assert {:error, reason, ^report} =
               HandoffGate.parse_protocol_result(Jason.encode!(report), exit_status, nil, 1_000)

      assert reason =~ expected_reason
    end)
  end

  test "terminal protocol results normalize absent optional lifecycle fields" do
    report =
      protocol_report("failed", %{
        "progress" => nil,
        "heartbeatAt" => 123,
        "heartbeatAgeMs" => "unknown",
        "nextPollMs" => 0,
        "checks" => %{},
        "singleFlight" => true,
        "startedAt" => "",
        "completedAt" => 123,
        "resultArtifact" => nil
      })

    assert {:ok, gate} = HandoffGate.parse_protocol_result(Jason.encode!(report), 2, nil, 1_000)
    assert gate.progress == %{}
    assert gate.heartbeat_at == nil
    assert gate.heartbeat_age_ms == nil
    assert gate.next_poll_ms == nil
    assert gate.checks == []
    assert gate.single_flight == true
    assert gate.started_at == nil
    assert gate.completed_at == nil
    assert gate.result_artifact == nil
  end

  defp temp_workspace!(name) do
    root = Path.join(System.tmp_dir!(), "symphony-elixir-#{name}-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    workspace
  end

  defp issue(identifier) do
    %Issue{
      id: "issue-#{identifier}",
      identifier: identifier,
      title: "Handoff gate",
      state: "In Progress"
    }
  end

  defp protocol_report(status, overrides \\ %{}) do
    base = %{
      "protocolVersion" => 1,
      "jobId" => "gate-1",
      "status" => status,
      "identity" => %{
        "repositoryIdentity" => "repo-1",
        "worktreeIdentity" => "worktree-1",
        "prNumber" => 1854,
        "baseRef" => "develop",
        "baseSha" => "base-1",
        "headSha" => "head-1",
        "candidateFingerprint" => "fingerprint-1",
        "gateConfigHash" => "config-1",
        "mutablePrStateHash" => "mutable-1",
        "candidateHash" => "candidate-1",
        "exactHash" => "exact-1"
      },
      "heartbeatAt" => "2026-08-02T12:00:00Z",
      "heartbeatAgeMs" => 10,
      "nextPollMs" => 250,
      "progress" => %{"stage" => "tests", "completed" => 1, "total" => 3},
      "startedAt" => "2026-08-02T11:59:00Z",
      "checks" => []
    }

    Map.merge(base, overrides)
  end

  defp hook_command(report, exit_status) do
    "printf '%s' '#{Jason.encode!(report)}'; exit #{exit_status}"
  end
end
