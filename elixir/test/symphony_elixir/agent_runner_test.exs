defmodule SymphonyElixir.AgentRunnerTest.Fix2AbnormalBackend do
  @moduledoc false
  # A backend whose turn completes abnormally *after* the agent captured a
  # deferred In Review handoff — the case where a silent drop both skips the
  # handoff and (pre-fix) fed the orchestrator claim leak. Seeds the captured
  # request the test prepared, then reports the abnormal completion.
  @behaviour SymphonyElixir.AgentBackend

  @impl true
  def start_session(_workspace, _opts), do: {:ok, %{worker_host: nil}}

  @impl true
  def run_turn(_session, _prompt, _issue, _opts) do
    request = Application.fetch_env!(:symphony_elixir, :fix2_deferred_request)
    SymphonyElixir.AgentRunner.store_deferred_review_handoff_for_test(request)
    {:error, {:turn_completed_abnormally, %{stop_reason: "interrupted"}}}
  end

  @impl true
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.AgentRunnerTest.Fix2AbnormalBackend
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

  describe "deferred review handoff on abnormal turn completion" do
    test "runs the captured handoff instead of dropping it when the turn aborts" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-fix2-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      test_pid = self()

      issue = %Issue{
        id: "issue-abnormal",
        identifier: "UDPE-6566",
        title: "Open the PR",
        state: "In Progress",
        labels: []
      }

      # Records the Linear handoff mutation `apply_deferred_review_handoff/1`
      # fires once the (no-PR) reviewer gate approves.
      linear_client = fn query, variables, _opts ->
        send(test_pid, {:handoff_mutation_applied, query, variables})
        {:ok, %{"data" => %{}}}
      end

      # No PR present -> the gate skips the reviewer and allows the handoff
      # (a deterministic `:ok`), so no reviewer session is spawned.
      no_pr = fn ["pr", "view" | _], _cwd -> {"no pull requests found", 1} end

      review_workflow = %{
        config: %{"review" => %{"max_iterations" => 3}},
        prompt: "Review {{ issue.identifier }}",
        prompt_template: "Review {{ issue.identifier }}"
      }

      request = %{
        query: "mutation { issueUpdate(input: {stateId: \"in-review\"}) { success } }",
        variables: %{},
        workspace: workspace,
        issue: issue,
        worker_host: nil,
        review_workflow: review_workflow,
        review_opts: [
          pr_runner: no_pr,
          comment_fn: fn _id, _body -> :ok end,
          linear_client: linear_client
        ],
        linear_client: linear_client
      }

      Application.put_env(:symphony_elixir, :fix2_deferred_request, request)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :fix2_deferred_request)
        File.rm_rf(workspace)
      end)

      state_fetcher = fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end

      assert {:error, {:turn_completed_abnormally, _}} =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {Fix2AbnormalBackend, %{}},
                   issue_state_fetcher: state_fetcher,
                   max_turns: 1
                 ],
                 nil
               )

      # The handoff mutation was applied despite the abnormal turn — it was not
      # silently dropped with the dying task's process dictionary.
      assert_received {:handoff_mutation_applied, query, _variables}
      assert query =~ "issueUpdate"
    end
  end
end
