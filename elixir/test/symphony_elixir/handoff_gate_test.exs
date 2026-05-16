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
end
