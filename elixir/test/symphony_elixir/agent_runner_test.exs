defmodule SymphonyElixir.AgentRunnerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Linear.Issue

  @idempotency_label "symphony:routing-warned"
  @needs_human_input_label "needs-human-input"
  @blocked_marker "<!-- symphony:blocked-on-giveup -->"

  setup do
    write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_available_labels, :all)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      Application.delete_env(:symphony_elixir, :memory_tracker_available_labels)
    end)

    :ok
  end

  describe "mark_blocked_on_giveup/2" do
    test "posts one comment, applies needs-human-input + idempotency label, transitions to Blocked on max_turns exhaustion" do
      issue = %Issue{id: "issue-123", identifier: "UDPE-100", labels: []}

      :ok =
        AgentRunner.mark_blocked_on_giveup(issue, %{
          reason: :max_turns_exhausted,
          turn_number: 20,
          max_turns: 20,
          workspace: "/tmp/symphony_workspaces/UDPE-100"
        })

      assert_received {:memory_tracker_comment, "issue-123", body}
      assert body =~ @blocked_marker
      assert body =~ "Symphony reached agent.max_turns (20/20)"
      assert body =~ "/tmp/symphony_workspaces/UDPE-100"

      assert_received {:memory_tracker_add_label, "issue-123", @needs_human_input_label}
      assert_received {:memory_tracker_add_label, "issue-123", @idempotency_label}
      assert_received {:memory_tracker_state_update, "issue-123", "Blocked"}
    end

    test "is idempotent: skips all writes when the issue already carries the routing-warned label" do
      issue = %Issue{
        id: "issue-456",
        identifier: "UDPE-101",
        labels: [@idempotency_label, "other-label"]
      }

      :ok =
        AgentRunner.mark_blocked_on_giveup(issue, %{
          reason: :max_turns_exhausted,
          turn_number: 20,
          max_turns: 20,
          workspace: "/tmp/x"
        })

      refute_received {:memory_tracker_comment, _id, _body}
      refute_received {:memory_tracker_add_label, _id, _label}
      refute_received {:memory_tracker_state_update, _id, _state}
    end

    test "continues with state transition even when needs-human-input label is missing in the workspace" do
      Application.put_env(:symphony_elixir, :memory_tracker_available_labels, [@idempotency_label])

      issue = %Issue{id: "issue-789", identifier: "UDPE-102", labels: []}

      :ok =
        AgentRunner.mark_blocked_on_giveup(issue, %{
          reason: :max_turns_exhausted,
          turn_number: 20,
          max_turns: 20,
          workspace: "/tmp/x"
        })

      assert_received {:memory_tracker_comment, "issue-789", _body}
      assert_received {:memory_tracker_add_label_missing, "issue-789", @needs_human_input_label}
      assert_received {:memory_tracker_add_label, "issue-789", @idempotency_label}
      assert_received {:memory_tracker_state_update, "issue-789", "Blocked"}
    end

    test "no-ops when called with a non-Issue map (defensive)" do
      :ok = AgentRunner.mark_blocked_on_giveup(%{}, %{reason: :max_turns_exhausted})

      refute_received {:memory_tracker_comment, _id, _body}
      refute_received {:memory_tracker_state_update, _id, _state}
    end
  end
end
