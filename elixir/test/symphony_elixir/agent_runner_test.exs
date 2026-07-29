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

defmodule SymphonyElixir.AgentRunnerTest.DeferredBackend do
  @moduledoc false
  @behaviour SymphonyElixir.AgentBackend

  @impl true
  def start_session(_workspace, _opts), do: {:ok, %{worker_host: nil}}

  @impl true
  def run_turn(_session, _prompt, _issue, _opts) do
    :symphony_elixir
    |> Application.fetch_env!(:deferred_requests_for_test)
    |> Enum.each(&SymphonyElixir.AgentRunner.store_deferred_review_handoff_for_test/1)

    {:ok, %{session_id: "deferred-test-session"}}
  end

  @impl true
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerTest.BlockingDeferredBackend do
  @moduledoc false
  @behaviour SymphonyElixir.AgentBackend

  @impl true
  def start_session(_workspace, _opts), do: {:ok, %{worker_host: nil}}

  @impl true
  def run_turn(_session, _prompt, _issue, _opts) do
    request = Application.fetch_env!(:symphony_elixir, :blocking_deferred_request_for_test)
    recipient = Application.fetch_env!(:symphony_elixir, :blocking_deferred_recipient_for_test)
    SymphonyElixir.AgentRunner.store_deferred_review_handoff_for_test(request)
    send(recipient, {:implementor_turn_ready, self()})

    receive do
      :finish_implementor_turn -> {:ok, %{session_id: "blocking-deferred-session"}}
    end
  end

  @impl true
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerTest.TurnCountingBackend do
  @moduledoc false
  # Records every turn it runs so a test can assert how many continuation turns
  # the loop actually drove. Each turn completes normally.
  @behaviour SymphonyElixir.AgentBackend

  @impl true
  def start_session(_workspace, _opts), do: {:ok, %{worker_host: nil}}

  @impl true
  def run_turn(_session, _prompt, _issue, _opts) do
    recipient = Application.fetch_env!(:symphony_elixir, :turn_count_recipient_for_test)
    send(recipient, :turn_ran)
    {:ok, %{session_id: "turn-counting-session"}}
  end

  @impl true
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerTest.HandoffPromptBackend do
  @moduledoc false
  @behaviour SymphonyElixir.AgentBackend

  @impl true
  def start_session(_workspace, _opts), do: {:ok, %{worker_host: nil}}

  @impl true
  def run_turn(_session, prompt, issue, _opts) do
    recipient = Application.fetch_env!(:symphony_elixir, :handoff_prompt_recipient_for_test)
    send(recipient, {:handoff_prompt, prompt, issue})

    {:ok, %{session_id: "handoff-prompt-session"}}
  end

  @impl true
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerTest.LifecycleRecipient do
  @moduledoc false
  use GenServer

  def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

  @impl true
  def init(owner), do: {:ok, owner}

  @impl true
  def handle_call(message, _from, owner) do
    send(owner, {:lifecycle_call, message})
    {:reply, :ok, owner}
  end

  @impl true
  def handle_info(message, owner) do
    send(owner, {:lifecycle_info, message})
    {:noreply, owner}
  end
end

defmodule SymphonyElixir.AgentRunnerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.AgentRunnerTest.BlockingDeferredBackend
  alias SymphonyElixir.AgentRunnerTest.DeferredBackend
  alias SymphonyElixir.AgentRunnerTest.Fix2AbnormalBackend
  alias SymphonyElixir.AgentRunnerTest.HandoffPromptBackend
  alias SymphonyElixir.AgentRunnerTest.LifecycleRecipient
  alias SymphonyElixir.AgentRunnerTest.TurnCountingBackend
  alias SymphonyElixir.Linear.Comment
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

  describe "handoff prompt guidance" do
    test "routes review handoffs through the gated GraphQL tool" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-handoff-prompt-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      Application.put_env(:symphony_elixir, :handoff_prompt_recipient_for_test, self())

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :handoff_prompt_recipient_for_test)
        File.rm_rf(workspace)
      end)

      issue = %Issue{
        id: "issue-handoff-prompt",
        identifier: "UDPE-7062",
        title: "Use the host-side handoff gate",
        state: "In Progress",
        labels: []
      }

      state_fetcher = fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {HandoffPromptBackend, %{}},
                   issue_state_fetcher: state_fetcher,
                   max_turns: 1,
                   per_repo_before_handoff: "scripts/hooks/before-handoff.sh"
                 ],
                 nil
               )

      assert_receive {:handoff_prompt, prompt, ^issue}
      assert prompt =~ "use Symphony's `linear_graphql` tool"
      assert prompt =~ "before_handoff and automated review gates"
      refute prompt =~ "LINEAR_API_KEY"
      refute prompt =~ "Symphony Linear access:"

      {task_prompt_position, _length} = :binary.match(prompt, "You are an agent for this repository.")
      {handoff_guidance_position, _length} = :binary.match(prompt, "Symphony handoff requirement:")
      assert handoff_guidance_position > task_prompt_position
    end
  end

  describe "injected issue activity" do
    test "fails the worker attempt instead of starting without required comments" do
      workspace_root =
        Path.join(System.tmp_dir!(), "symphony-issue-activity-failure-#{System.unique_integer([:positive])}")

      write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root
      )

      on_exit(fn -> File.rm_rf(workspace_root) end)

      issue = %Issue{
        id: "issue-comments-unavailable",
        identifier: "UDPE-7011",
        title: "Do not start with incomplete input",
        state: "In Progress"
      }

      assert_raise RuntimeError, ~r/issue_comments_fetch_failed.*linear_unavailable/, fn ->
        AgentRunner.run(issue, nil,
          issue_comments_fetcher: fn "issue-comments-unavailable" ->
            {:error, :linear_unavailable}
          end
        )
      end
    end

    test "places current Linear comments and blocked-resume guidance in the first turn" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-issue-activity-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      Application.put_env(:symphony_elixir, :handoff_prompt_recipient_for_test, self())

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :handoff_prompt_recipient_for_test)
        File.rm_rf(workspace)
      end)

      issue = %Issue{
        id: "issue-resumed",
        identifier: "UDPE-7011",
        title: "Resume after a product decision",
        state: "In Progress",
        labels: ["needs-human-input"],
        comments: [
          %Comment{
            id: "comment-workpad",
            body: "## Codex Workpad\n\nBlocked on the product decision.",
            author_name: "UDPAgent",
            created_at: ~U[2026-07-29 09:00:00Z]
          },
          %Comment{
            id: "comment-decision",
            body: "Decision: use option B and continue.",
            author_name: "Product owner",
            created_at: ~U[2026-07-29 10:00:00Z]
          }
        ],
        comments_truncated: true
      }

      state_fetcher = fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {HandoffPromptBackend, %{}},
                   issue_state_fetcher: state_fetcher,
                   max_turns: 1
                 ],
                 nil
               )

      assert_receive {:handoff_prompt, prompt, ^issue}
      assert prompt =~ "Symphony-captured Linear activity:"
      assert prompt =~ "Decision: use option B and continue."
      assert prompt =~ "This issue is marked `needs-human-input`"
      assert prompt =~ "Remove the label only after consuming that response."
      assert prompt =~ "Earlier Linear comments were omitted"
    end

    test "preserves injected comments when state refresh builds a continuation issue" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-issue-activity-refresh-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      Application.put_env(:symphony_elixir, :handoff_prompt_recipient_for_test, self())

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :handoff_prompt_recipient_for_test)
        File.rm_rf(workspace)
      end)

      issue = %Issue{
        id: "issue-refresh",
        identifier: "UDPE-7011",
        title: "Preserve comment context",
        state: "In Progress",
        comments: [%Comment{id: "comment-1", body: "Decision: continue."}]
      }

      state_fetcher = fn
        [_issue_id] ->
          call_count = Process.get(:comment_refresh_call_count, 0)
          Process.put(:comment_refresh_call_count, call_count + 1)

          if call_count == 0 do
            {:ok, [%Issue{issue | comments: [], state: "In Progress"}]}
          else
            {:ok, [%Issue{issue | comments: [], state: "Done"}]}
          end
      end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {HandoffPromptBackend, %{}},
                   issue_state_fetcher: state_fetcher,
                   max_turns: 2
                 ],
                 nil
               )

      assert_receive {:handoff_prompt, first_prompt, ^issue}
      assert first_prompt =~ "Decision: continue."
      assert_receive {:handoff_prompt, second_prompt, second_issue}
      refute second_prompt =~ "Symphony-captured Linear activity:"
      assert Enum.map(second_issue.comments, & &1.id) == ["comment-1"]
    end
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

  describe "deferred review lifecycle" do
    test "coalesces repeated handoff requests into one review and one mutation" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-coalesced-review-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      {_, 0} = System.cmd("git", ["-C", workspace, "init", "--quiet"])
      File.write!(Path.join(workspace, "README.md"), "review target\n")
      {_, 0} = System.cmd("git", ["-C", workspace, "add", "README.md"])

      {_, 0} =
        System.cmd("git", [
          "-C",
          workspace,
          "-c",
          "user.name=Symphony Test",
          "-c",
          "user.email=symphony@example.com",
          "commit",
          "--quiet",
          "-m",
          "test review target"
        ])

      test_pid = self()

      issue = %Issue{
        id: "issue-coalesced",
        identifier: "UDPE-6460",
        title: "Coalesce review",
        state: "In Progress",
        labels: []
      }

      linear_client = fn query, variables, _opts ->
        send(test_pid, {:handoff_mutation_applied, query, variables})
        {:ok, %{"data" => %{}}}
      end

      review_runner = fn ctx ->
        send(test_pid, :review_session_started)
        File.mkdir_p!(Path.dirname(ctx.verdict_path))
        File.write!(ctx.verdict_path, Jason.encode!(%{"verdict" => "approve"}))
        {:ok, %{}}
      end

      no_pr = fn ["pr", "view" | _], _cwd -> {"no pull requests found", 1} end

      review_workflow = %{
        config: %{"review" => %{"require_pr" => false}},
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
          session_runner: review_runner,
          comment_fn: fn _id, _body -> :ok end,
          linear_client: linear_client
        ],
        linear_client: linear_client
      }

      Application.put_env(:symphony_elixir, :deferred_requests_for_test, [request, request])

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :deferred_requests_for_test)
        File.rm_rf(workspace)
      end)

      state_fetcher = fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {DeferredBackend, %{}},
                   issue_state_fetcher: state_fetcher,
                   max_turns: 1
                 ],
                 nil
               )

      assert_received :review_session_started
      refute_received :review_session_started
      assert_received {:handoff_mutation_applied, query, %{}}
      assert query =~ "issueUpdate"
      refute_received {:handoff_mutation_applied, _, _}
    end

    test "withholds a reviewed handoff when the pull request head changes" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-head-change-review-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      test_pid = self()

      issue = %Issue{
        id: "issue-head-change",
        identifier: "UDPE-6460",
        title: "Revalidate review head",
        state: "In Progress",
        labels: []
      }

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      pr_runner = fn
        ["pr", "view" | _], _cwd ->
          call = Agent.get_and_update(counter, fn count -> {count, count + 1} end)
          head = if call == 0, do: "head-before-review", else: "head-after-review"

          {Jason.encode!(%{
             "id" => "PR_head_change",
             "number" => 64,
             "body" => "Body.",
             "headRefOid" => head
           }), 0}

        ["api", "graphql" | _], _cwd ->
          {"", 0}
      end

      review_runner = fn ctx ->
        File.mkdir_p!(Path.dirname(ctx.verdict_path))
        File.write!(ctx.verdict_path, Jason.encode!(%{"verdict" => "approve"}))
        {:ok, %{}}
      end

      linear_client = fn query, variables, _opts ->
        send(test_pid, {:unexpected_handoff_mutation, query, variables})
        {:ok, %{"data" => %{}}}
      end

      review_workflow = %{
        config: %{"review" => %{}},
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
          pr_runner: pr_runner,
          session_runner: review_runner,
          comment_fn: fn _id, _body -> :ok end,
          linear_client: linear_client
        ],
        linear_client: linear_client
      }

      Application.put_env(:symphony_elixir, :deferred_requests_for_test, [request])

      on_exit(fn ->
        if Process.alive?(counter), do: Agent.stop(counter)
        Application.delete_env(:symphony_elixir, :deferred_requests_for_test)
        File.rm_rf(workspace)
      end)

      state_fetcher = fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {DeferredBackend, %{}},
                   issue_state_fetcher: state_fetcher,
                   max_turns: 1
                 ],
                 nil
               )

      refute_received {:unexpected_handoff_mutation, _, _}
      assert Agent.get(counter, & &1) == 2
    end

    test "enters pending review before blocking PR target resolution" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-review-preflight-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      test_pid = self()
      {:ok, recipient} = LifecycleRecipient.start_link(test_pid)

      issue = %Issue{
        id: "issue-preflight",
        identifier: "UDPE-6460",
        title: "Track review preflight",
        state: "In Progress",
        labels: []
      }

      pr_runner = fn
        ["pr", "view" | _], _cwd ->
          unless Process.get(:preflight_released) do
            send(test_pid, {:review_preflight_waiting, self()})

            receive do
              :release_review_preflight -> Process.put(:preflight_released, true)
            end
          end

          {Jason.encode!(%{
             "id" => "PR_preflight",
             "number" => 65,
             "body" => "Body.",
             "headRefOid" => "head-preflight"
           }), 0}

        ["api", "graphql" | _], _cwd ->
          {"", 0}
      end

      review_runner = fn ctx ->
        File.mkdir_p!(Path.dirname(ctx.verdict_path))
        File.write!(ctx.verdict_path, Jason.encode!(%{"verdict" => "approve"}))
        {:ok, %{}}
      end

      linear_client = fn _query, _variables, _opts -> {:ok, %{"data" => %{}}} end

      review_workflow = %{
        config: %{"review" => %{}},
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
          pr_runner: pr_runner,
          session_runner: review_runner,
          comment_fn: fn _id, _body -> :ok end,
          linear_client: linear_client
        ],
        linear_client: linear_client
      }

      Application.put_env(:symphony_elixir, :deferred_requests_for_test, [request])

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :deferred_requests_for_test)
        File.rm_rf(workspace)
      end)

      state_fetcher = fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end

      task =
        Task.async(fn ->
          AgentRunner.run_codex_turns_for_test(
            workspace,
            issue,
            recipient,
            [
              agent_backend: {DeferredBackend, %{}},
              issue_state_fetcher: state_fetcher,
              max_turns: 1
            ],
            nil
          )
        end)

      assert_receive {:lifecycle_call, {:agent_lifecycle, "issue-preflight", :handoff_pending_review, %{review_key: {:resolving_review_target, "issue-preflight"}}}},
                     1_000

      assert_receive {:review_preflight_waiting, runner_pid}, 1_000
      send(runner_pid, :release_review_preflight)

      assert :ok = Task.await(task, 2_000)
    end

    test "live orchestrator does not redispatch while the shared runner reviews" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        codex_stall_timeout_ms: 1_000
      )

      workspace =
        Path.join(System.tmp_dir!(), "symphony-live-review-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      {_, 0} = System.cmd("git", ["-C", workspace, "init", "--quiet"])
      File.write!(Path.join(workspace, "README.md"), "live review target\n")
      {_, 0} = System.cmd("git", ["-C", workspace, "add", "README.md"])

      {_, 0} =
        System.cmd("git", [
          "-C",
          workspace,
          "-c",
          "user.name=Symphony Test",
          "-c",
          "user.email=symphony@example.com",
          "commit",
          "--quiet",
          "-m",
          "live review target"
        ])

      test_pid = self()

      issue = %Issue{
        id: "issue-live-review",
        identifier: "UDPE-6460",
        title: "Pause during review",
        state: "In Progress",
        labels: []
      }

      review_runner = fn ctx ->
        review_event_at = DateTime.utc_now()

        ctx.on_message.(%{
          event: :notification,
          timestamp: review_event_at,
          payload: %{"method" => "review/heartbeat"}
        })

        send(test_pid, {:review_runner_waiting, self(), review_event_at})

        receive do
          :finish_review -> :ok
        end

        File.mkdir_p!(Path.dirname(ctx.verdict_path))
        File.write!(ctx.verdict_path, Jason.encode!(%{"verdict" => "approve"}))
        {:ok, %{}}
      end

      no_pr = fn ["pr", "view" | _], _cwd -> {"no pull requests found", 1} end
      linear_client = fn _query, _variables, _opts -> {:ok, %{"data" => %{}}} end

      review_workflow = %{
        config: %{"review" => %{"require_pr" => false}},
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
          session_runner: review_runner,
          comment_fn: fn _id, _body -> :ok end,
          linear_client: linear_client
        ],
        linear_client: linear_client
      }

      Application.put_env(:symphony_elixir, :blocking_deferred_request_for_test, request)
      Application.put_env(:symphony_elixir, :blocking_deferred_recipient_for_test, test_pid)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      orchestrator_name = Module.concat(__MODULE__, :LiveReviewOrchestrator)
      {:ok, orchestrator} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(orchestrator), do: Process.exit(orchestrator, :normal)
        Application.delete_env(:symphony_elixir, :blocking_deferred_request_for_test)
        Application.delete_env(:symphony_elixir, :blocking_deferred_recipient_for_test)
        File.rm_rf(workspace)
      end)

      state_fetcher = fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end

      task =
        Task.async(fn ->
          AgentRunner.run_codex_turns_for_test(
            workspace,
            issue,
            orchestrator,
            [
              agent_backend: {BlockingDeferredBackend, %{}},
              issue_state_fetcher: state_fetcher,
              max_turns: 1
            ],
            nil
          )
        end)

      assert_receive {:implementor_turn_ready, worker_pid}, 1_000
      stale_at = DateTime.add(DateTime.utc_now(), -5, :second)
      initial_state = :sys.get_state(orchestrator)

      running_entry = %{
        pid: worker_pid,
        ref: make_ref(),
        identifier: issue.identifier,
        issue: issue,
        session_id: "live-review-session",
        last_codex_timestamp: stale_at,
        lifecycle_state: :implementing,
        lifecycle_started_at: stale_at,
        started_at: stale_at
      }

      :sys.replace_state(orchestrator, fn _ ->
        initial_state
        |> Map.put(:running, %{issue.id => running_entry})
        |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue.id))
      end)

      send(worker_pid, :finish_implementor_turn)
      assert_receive {:review_runner_waiting, ^worker_pid, review_event_at}, 1_000

      send(orchestrator, :tick)
      Process.sleep(100)
      state = :sys.get_state(orchestrator)

      assert Process.alive?(worker_pid)
      assert state.running[issue.id].lifecycle_state == :handoff_pending_review
      assert state.running[issue.id].last_codex_timestamp == review_event_at
      assert MapSet.member?(state.claimed, issue.id)
      refute Map.has_key?(state.retry_attempts, issue.id)

      send(worker_pid, :finish_review)
      assert :ok = Task.await(task, 2_000)
    end
  end

  describe "blocked mid-run halts continuation" do
    test "an agent transitioning its issue to Blocked stops being continued that turn" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-blocked-halt-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)

      Application.put_env(:symphony_elixir, :turn_count_recipient_for_test, self())

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :turn_count_recipient_for_test)
        File.rm_rf(workspace)
      end)

      issue = %Issue{
        id: "issue-blocked-halt",
        identifier: "UDPE-6954",
        title: "Stuck and self-reporting Blocked",
        state: "In Progress",
        labels: []
      }

      # The agent transitions the issue to Blocked during turn 1 (its sanctioned
      # "stop dispatching me" channel). The turn loop's post-turn state refresh
      # must observe the now-inactive state and end the run instead of driving
      # the remaining continuation turns.
      state_fetcher = fn [_issue_id] -> {:ok, [%{issue | state: "Blocked"}]} end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {TurnCountingBackend, %{}},
                   issue_state_fetcher: state_fetcher,
                   max_turns: 5
                 ],
                 nil
               )

      # Exactly one turn ran: the Blocked transition ended the run rather than
      # burning the other four continuation turns.
      assert_received :turn_ran
      refute_received :turn_ran
    end
  end
end
