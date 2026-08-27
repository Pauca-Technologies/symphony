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

defmodule SymphonyElixir.AgentRunnerTest.WaitingBackend do
  @moduledoc false
  @behaviour SymphonyElixir.AgentBackend

  @impl true
  def start_session(_workspace, _opts), do: {:ok, %{worker_host: nil}}

  @impl true
  def run_turn(_session, prompt, _issue, opts) do
    recipient = Application.fetch_env!(:symphony_elixir, :waiting_backend_recipient)
    send(recipient, {:waiting_prompt, prompt})

    result =
      Keyword.fetch!(opts, :tool_executor).(
        "wait_for",
        %{
          "reason" => "GitHub Actions is degraded",
          "condition" => %{"type" => "github_actions_recovered"}
        }
      )

    send(recipient, {:waiting_tool_result, result})
    {:ok, %{session_id: "waiting-session"}}
  end

  @impl true
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerTest.HandoffToolBackend do
  @moduledoc false
  @behaviour SymphonyElixir.AgentBackend

  @impl true
  def start_session(_workspace, _opts), do: {:ok, %{worker_host: nil}}

  @impl true
  def run_turn(_session, _prompt, issue, opts) do
    result =
      Keyword.fetch!(opts, :tool_executor).(
        "linear_graphql",
        %{
          "query" => "mutation Move($issueId: String!, $stateId: String!) { issueUpdate(id: $issueId, input: {stateId: $stateId}) { success } }",
          "variables" => %{"issueId" => issue.id, "stateId" => "state-review"}
        }
      )

    send(Application.fetch_env!(:symphony_elixir, :handoff_tool_recipient), {
      :handoff_tool_result,
      result
    })

    {:ok, %{session_id: "handoff-tool-session"}}
  end

  @impl true
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerTest.PendingGateBackend do
  @moduledoc false
  @behaviour SymphonyElixir.AgentBackend

  @impl true
  def start_session(_workspace, _opts), do: {:ok, %{worker_host: nil}}

  @impl true
  def run_turn(_session, prompt, _issue, _opts) do
    recipient = Application.fetch_env!(:symphony_elixir, :pending_gate_recipient_for_test)
    turn = Process.get(:pending_gate_turn, 0) + 1
    Process.put(:pending_gate_turn, turn)
    send(recipient, {:pending_gate_turn, turn, prompt})

    if turn == 1 do
      request = Application.fetch_env!(:symphony_elixir, :pending_gate_request_for_test)
      :ok = SymphonyElixir.AgentRunner.store_deferred_handoff_gate_for_test(request)
    end

    {:ok, %{session_id: "pending-gate-session-#{turn}"}}
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

defmodule SymphonyElixir.AgentRunnerTest.EfficiencyBackend do
  @moduledoc false
  @behaviour SymphonyElixir.AgentBackend

  @impl true
  def start_session(_workspace, _opts), do: {:ok, %{worker_host: nil}}

  @impl true
  def run_turn(_session, prompt, _issue, opts) do
    recipient = Application.fetch_env!(:symphony_elixir, :efficiency_recipient_for_test)
    turn = Process.get(:efficiency_turn, 0) + 1
    Process.put(:efficiency_turn, turn)
    send(recipient, {:efficiency_prompt, turn, prompt})

    on_message = Keyword.fetch!(opts, :on_message)
    on_message.(%{event: :session_started, thread_id: "parent-thread", timestamp: DateTime.utc_now()})

    on_message.(%{
      event: :token_usage,
      thread_id: "parent-thread",
      timestamp: DateTime.utc_now(),
      usage: %{input_tokens: 80 + turn * 20, output_tokens: 20, total_tokens: 100 + turn * 20}
    })

    {:ok, %{session_id: "efficiency-session-#{turn}"}}
  end

  @impl true
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerTest.BudgetStressBackend do
  @moduledoc false
  @behaviour SymphonyElixir.AgentBackend

  @impl true
  def start_session(_workspace, _opts), do: {:ok, %{worker_host: nil}}

  @impl true
  def run_turn(_session, _prompt, _issue, opts) do
    owner = Application.fetch_env!(:symphony_elixir, :budget_stress_owner_for_test)
    volume = Application.fetch_env!(:symphony_elixir, :budget_stress_volume_for_test)
    on_message = Keyword.fetch!(opts, :on_message)

    on_message.(%{event: :session_started, thread_id: "parent-thread", timestamp: DateTime.utc_now()})

    Enum.each(1..volume, fn sequence ->
      {thread_id, cumulative} =
        if rem(sequence, 2) == 1,
          do: {"parent-thread", div(sequence + 1, 2)},
          else: {"delegated-thread", div(sequence, 2)}

      on_message.(%{
        event: :token_usage,
        thread_id: thread_id,
        usage: %{input_tokens: cumulative, output_tokens: 0, total_tokens: cumulative}
      })
    end)

    {:message_queue_len, queue_len} = Process.info(self(), :message_queue_len)
    send(owner, {:budget_stress_runner_queue_len, queue_len})
    {:ok, %{session_id: "budget-stress-session"}}
  end

  @impl true
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerTest.BudgetRuntimeRecipient do
  @moduledoc false
  use GenServer

  def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

  @impl true
  def init(owner), do: {:ok, owner}

  @impl true
  def handle_info({:worker_runtime_info, issue_id, %{budget_metrics: _metrics} = info}, owner) do
    send(owner, {:budget_runtime_info, issue_id, info})
    {:noreply, owner}
  end

  def handle_info(_message, owner), do: {:noreply, owner}
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

  defp write_review_verdict(ctx, verdict) do
    exact =
      Map.merge(
        %{
          "packet_id" => ctx.packet.packet_id,
          "reviewed_sha" => ctx.reviewed_sha,
          "inspected" => ["authoritative full diff"],
          "attestations" => %{"reused" => [], "rerun" => []},
          "full_diff_inspected" => true
        },
        verdict
      )

    File.mkdir_p!(Path.dirname(ctx.verdict_path))
    File.write!(ctx.verdict_path, Jason.encode!(exact))
  end

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.AgentRunnerTest.BlockingDeferredBackend
  alias SymphonyElixir.AgentRunnerTest.BudgetRuntimeRecipient
  alias SymphonyElixir.AgentRunnerTest.BudgetStressBackend
  alias SymphonyElixir.AgentRunnerTest.DeferredBackend
  alias SymphonyElixir.AgentRunnerTest.EfficiencyBackend
  alias SymphonyElixir.AgentRunnerTest.Fix2AbnormalBackend
  alias SymphonyElixir.AgentRunnerTest.HandoffPromptBackend
  alias SymphonyElixir.AgentRunnerTest.HandoffToolBackend
  alias SymphonyElixir.AgentRunnerTest.LifecycleRecipient
  alias SymphonyElixir.AgentRunnerTest.PendingGateBackend
  alias SymphonyElixir.AgentRunnerTest.TurnCountingBackend
  alias SymphonyElixir.AgentRunnerTest.WaitingBackend
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

  test "routed after_create failures stop the run before an agent starts" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-routed-after-create-#{System.unique_integer([:positive])}"
      )

    origin = Path.join(root, "origin")
    workspace_root = Path.join(root, "workspaces")
    File.mkdir_p!(origin)
    on_exit(fn -> File.rm_rf(root) end)

    System.cmd("git", ["-C", origin, "init", "--quiet", "--initial-branch", "main"])
    System.cmd("git", ["-C", origin, "config", "user.name", "Test User"])
    System.cmd("git", ["-C", origin, "config", "user.email", "test@example.com"])

    File.write!(
      Path.join(origin, "WORKFLOW.md"),
      """
      ---
      hooks:
        after_create: exit 17
      ---
      Test routed workflow.
      """
    )

    System.cmd("git", ["-C", origin, "add", "WORKFLOW.md"])
    System.cmd("git", ["-C", origin, "commit", "--quiet", "-m", "initial"])

    write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root
    )

    File.write!(
      Application.fetch_env!(:symphony_elixir, :repo_config_path),
      """
      linear:
        team_id: UDPE
      repos:
        - id: test-repo
          label: repo:test-repo
          repo_url: #{origin}
          workflow_path: WORKFLOW.md
          base_branch: main
      """
    )

    issue = %Issue{
      id: "issue-after-create-failure",
      identifier: "UDPE-AFTER-CREATE",
      title: "Stop on fatal setup failure",
      state: "In Progress",
      labels: ["repo:test-repo"],
      comments: []
    }

    assert_raise RuntimeError, ~r/workspace_hook_failed.*after_create.*17/s, fn ->
      AgentRunner.run(issue)
    end
  end

  test "wait_for parks after one turn and emits a durable waiting lifecycle" do
    Application.put_env(:symphony_elixir, :waiting_backend_recipient, self())
    on_exit(fn -> Application.delete_env(:symphony_elixir, :waiting_backend_recipient) end)

    issue = %Issue{
      id: "issue-agent-wait",
      identifier: "UDPE-WAIT",
      title: "Wait efficiently",
      state: "In Progress",
      labels: [],
      comments: []
    }

    assert :ok =
             AgentRunner.run_codex_turns_for_test(
               System.tmp_dir!(),
               issue,
               self(),
               [
                 agent_backend: {WaitingBackend, %{}},
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [issue]} end,
                 issue_comments_fetcher: fn _issue_id ->
                   {:ok, %{comments: [], truncated: false}}
                 end,
                 wait_observer: fn _request ->
                   {:ok,
                    %{
                      "status" => "degraded",
                      "component" => "Actions",
                      "incident_statuses" => ["investigating"],
                      "recovery_signal" => "waiting"
                    }}
                 end,
                 max_turns: 5
               ],
               nil
             )

    assert_receive {:waiting_prompt, prompt}
    assert prompt =~ "call Symphony's `wait_for` tool once and end the turn"
    assert prompt =~ "Never call `wait_for` because of local CPU"
    assert prompt =~ "Symphony-owned handoff job"
    assert prompt =~ "permits validations from multiple agents to overlap"
    assert_receive {:waiting_tool_result, %{"success" => true}}

    assert_receive {:agent_lifecycle, "issue-agent-wait", :waiting, %{request: request}}
    assert request.condition["type"] == "github_actions_recovered"
    refute_receive {:waiting_prompt, _second_turn}, 100
  end

  test "synchronous handoff hooks publish a pending lifecycle around the tool call" do
    Application.put_env(:symphony_elixir, :handoff_tool_recipient, self())
    on_exit(fn -> Application.delete_env(:symphony_elixir, :handoff_tool_recipient) end)

    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-inline-handoff-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(workspace_root, "UDPE-INLINE-HANDOFF")
    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: workspace_root)
    on_exit(fn -> File.rm_rf(workspace_root) end)

    issue = %Issue{
      id: "issue-inline-handoff",
      identifier: "UDPE-INLINE-HANDOFF",
      title: "Keep a synchronous handoff alive",
      state: "In Progress",
      labels: [],
      comments: []
    }

    issue_id = issue.id

    linear_client = fn
      query, %{"issueId" => issue_id}, [] when issue_id == issue.id ->
        if String.contains?(query, "SymphonyResolveIssueTransition") do
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "state" => %{"name" => "In Progress"},
                 "team" => %{
                   "states" => %{
                     "nodes" => [%{"id" => "state-review", "name" => "In Review"}]
                   }
                 }
               }
             }
           }}
        else
          flunk("blocked handoff mutation should not reach Linear")
        end
    end

    assert :ok =
             AgentRunner.run_codex_turns_for_test(
               workspace,
               issue,
               self(),
               [
                 agent_backend: {HandoffToolBackend, %{}},
                 linear_client: linear_client,
                 per_repo_before_handoff: "sleep 0.2; exit 2",
                 per_repo_before_handoff_timeout_ms: 2_000,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end,
                 max_turns: 1
               ],
               nil
             )

    assert_receive {:agent_lifecycle, ^issue_id, :handoff_pending_gate, %{gate_job_id: gate_job_id, gate: %{status: :running}}}

    assert_receive {:agent_lifecycle, ^issue_id, :implementing, %{gate_job_id: ^gate_job_id, gate_outcome: :blocked}}

    assert_receive {:handoff_tool_result, %{"success" => false}}
    assert {:ok, nil} = Workspace.load_handoff_gate_state(workspace)
  end

  describe "soft-budget continuations" do
    test "includes changed Linear activity while reusing unchanged continuation sections" do
      recipient = self()
      Application.put_env(:symphony_elixir, :handoff_prompt_recipient_for_test, recipient)

      telemetry_handler_id =
        "agent-runner-activity-prompt-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        telemetry_handler_id,
        AgentRunner.prompt_built_telemetry_event(),
        fn _event, _measurements, metadata, _config ->
          send(recipient, {:activity_prompt_telemetry, metadata})
        end,
        nil
      )

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :handoff_prompt_recipient_for_test)
        :telemetry.detach(telemetry_handler_id)
      end)

      old_comment = %Comment{
        id: "old-comment",
        body: "Original activity.",
        author_name: "Owner",
        created_at: ~U[2026-08-02 09:00:00Z]
      }

      new_comment = %Comment{
        id: "new-comment",
        body: "New activity decision: preserve tenant isolation.",
        author_name: "Owner",
        created_at: ~U[2026-08-02 10:00:00Z]
      }

      issue = %Issue{
        id: "issue-activity-continuation",
        identifier: "UDPE-ACTIVITY",
        title: "Refresh current activity",
        description: "Use only the latest activity snapshot.",
        state: "In Progress",
        labels: [],
        comments: [old_comment],
        updated_at: ~U[2026-08-02 08:00:00Z]
      }

      fetcher = fn [_issue_id] ->
        count = Process.get(:activity_continuation_fetch_count, 0) + 1
        Process.put(:activity_continuation_fetch_count, count)

        refreshed =
          if count == 1 do
            %{issue | comments: [new_comment]}
          else
            %{issue | state: "Done", comments: [new_comment]}
          end

        {:ok, [refreshed]}
      end

      comments_fetcher = fn _issue_id ->
        {:ok, %{comments: [new_comment], truncated: false}}
      end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 System.tmp_dir!(),
                 issue,
                 nil,
                 [
                   agent_backend: {HandoffPromptBackend, %{}},
                   issue_state_fetcher: fetcher,
                   issue_comments_fetcher: comments_fetcher,
                   max_turns: 3
                 ],
                 nil
               )

      assert_receive {:handoff_prompt, initial_prompt, ^issue}
      assert initial_prompt =~ "Original activity."

      assert_receive {:handoff_prompt, continuation_prompt, refreshed_issue}
      assert refreshed_issue.comments == [new_comment]
      assert continuation_prompt =~ "New activity decision: preserve tenant isolation."
      assert continuation_prompt =~ "Current candidate metadata is unchanged"
      assert continuation_prompt =~ "Current Linear activity changed"
      refute continuation_prompt =~ "Original activity."

      assert_receive {:activity_prompt_telemetry, %{prompt_kind: "initial", prompt_sections: initial_sections}}

      assert Enum.map(initial_sections, & &1.id) == [
               "task.issue",
               "task.current_metadata",
               "task.activity",
               "repository.workflow",
               "symphony.test_worker_budget",
               "symphony.handoff_constraints"
             ]

      assert_receive {:activity_prompt_telemetry,
                      %{
                        prompt_kind: "continuation",
                        prompt_sections: continuation_sections,
                        prompt_section_decisions: continuation_decisions
                      }}

      assert Enum.map(continuation_sections, & &1.id) == [
               "continuation.resume_capsule",
               "task.activity"
             ]

      reused_ids =
        continuation_decisions
        |> Enum.filter(&(&1.decision == "reused"))
        |> Enum.map(& &1.section_id)

      assert Enum.sort(reused_ids) == [
               "repository.workflow",
               "symphony.handoff_constraints",
               "symphony.test_worker_budget",
               "task.current_metadata",
               "task.issue"
             ]
    end

    test "injects one bounded enforced transition on the next continuation" do
      Application.put_env(:symphony_elixir, :efficiency_recipient_for_test, self())
      on_exit(fn -> Application.delete_env(:symphony_elixir, :efficiency_recipient_for_test) end)

      issue = %Issue{
        id: "issue-efficiency-runner",
        identifier: "UDPE-EFF",
        title: "Small direct edit",
        description: "Change one bounded helper.",
        state: "In Progress",
        labels: ["budget:simple"],
        blocked_by: [],
        children: []
      }

      fetcher = fn [_issue_id] ->
        count = Process.get(:efficiency_fetch_count, 0) + 1
        Process.put(:efficiency_fetch_count, count)
        state = if count == 1, do: "In Progress", else: "Done"
        {:ok, [%{issue | state: state}]}
      end

      workflow = %{
        config: %{
          "agent" => %{
            "efficiency" => %{
              "mode" => "enforce",
              "capsule_max_bytes" => 1_000,
              "profiles" => %{"simple" => %{"total_tokens" => 100}}
            }
          }
        }
      }

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 "/tmp",
                 issue,
                 self(),
                 [
                   agent_backend: {EfficiencyBackend, %{}},
                   issue_state_fetcher: fetcher,
                   per_repo_workflow: workflow,
                   max_turns: 2
                 ],
                 nil
               )

      assert_received {:efficiency_prompt, 1, first_prompt}
      assert_received {:efficiency_prompt, 2, second_prompt}
      refute first_prompt =~ "soft-budget resume capsule"
      assert second_prompt =~ "soft-budget resume capsule"
      assert second_prompt =~ "compact_parent_resume_capsule"
      assert length(String.split(second_prompt, "compact_parent_resume_capsule")) == 2

      assert_received {:worker_runtime_info, "issue-efficiency-runner", %{budget_profile: "simple", budget_mode: "enforce"}}
      assert_received {:worker_runtime_info, "issue-efficiency-runner", %{budget_transitions: transitions}}
      assert "soft:total_tokens" in transitions
    end

    test "coalesces high-volume usage without accumulating full events in the runner mailbox" do
      volume = 10_000
      Application.put_env(:symphony_elixir, :budget_stress_owner_for_test, self())
      Application.put_env(:symphony_elixir, :budget_stress_volume_for_test, volume)
      {:ok, recipient} = BudgetRuntimeRecipient.start_link(self())

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :budget_stress_owner_for_test)
        Application.delete_env(:symphony_elixir, :budget_stress_volume_for_test)
        if Process.alive?(recipient), do: GenServer.stop(recipient)
      end)

      issue = %Issue{
        id: "issue-efficiency-stress",
        identifier: "UDPE-EFF-STRESS",
        title: "Stress budget accounting",
        description: "Exercise a bounded collector with many cumulative updates.",
        state: "In Progress",
        labels: ["budget:simple"],
        blocked_by: [],
        children: []
      }

      workflow = %{
        config: %{
          "agent" => %{
            "efficiency" => %{
              "mode" => "enforce",
              "profiles" => %{
                "simple" => %{
                  "total_tokens" => 200,
                  "delegated_tokens" => 100,
                  "per_thread_tokens" => 100
                }
              }
            }
          }
        }
      }

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 "/tmp",
                 issue,
                 recipient,
                 [
                   agent_backend: {BudgetStressBackend, %{}},
                   issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end,
                   per_repo_workflow: workflow,
                   max_turns: 1
                 ],
                 nil
               )

      assert_received {:budget_stress_runner_queue_len, queue_len}
      assert queue_len < 10

      assert_received {:budget_runtime_info, "issue-efficiency-stress", %{budget_metrics: metrics, budget_transitions: transitions}}

      assert metrics.total_tokens == volume
      assert metrics.parent_tokens == div(volume, 2)
      assert metrics.delegated_tokens == div(volume, 2)
      assert metrics.thread_count == 2
      assert "soft:total_tokens" in transitions
      assert "soft:delegated_tokens" in transitions
      assert "soft:per_thread_tokens" in transitions
    end
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
      assert prompt =~ "## Current Linear activity"
      assert prompt =~ "Decision: use option B and continue."
      assert prompt =~ "This issue is marked `needs-human-input`"
      assert prompt =~ "Remove the label only after consuming that response."
      assert prompt =~ "Earlier Linear comments were omitted"
      assert prompt =~ "## Host test-worker budget"
      assert prompt =~ "vitest --maxWorkers=2"
      assert prompt =~ "playwright test --workers=2"
    end

    test "treats a verified bot identity as authorized despite a stale auth blocker" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-bot-authorization-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      Application.put_env(:symphony_elixir, :handoff_prompt_recipient_for_test, self())

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :handoff_prompt_recipient_for_test)
        File.rm_rf(workspace)
      end)

      issue = %Issue{
        id: "issue-bot-authorization",
        identifier: "UDPE-7016",
        title: "Resume with injected GitHub App auth",
        state: "In Progress",
        labels: ["needs-human-input", "UDPAgent"],
        comments: [
          %Comment{
            id: "comment-stale-auth-blocker",
            body: "## Codex Workpad\n\nBlocked until a human separately authorizes UDPAgent attribution, even if bot authentication is injected.",
            author_name: "UDPAgent"
          }
        ]
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
                   automation_opt_in_label: "udpagent"
                 ],
                 nil
               )

      assert_receive {:handoff_prompt, prompt, ^issue}
      assert prompt =~ "Symphony automation identity authorization:"
      assert prompt =~ "configured opt-in label `udpagent`"
      assert prompt =~ "that is both authentication and authorization"
      assert prompt =~ "Do not require a second human comment"
      assert prompt =~ "treat that claim as stale"
      assert prompt =~ "remove `needs-human-input`"

      {stale_blocker_position, _length} = :binary.match(prompt, "Blocked until a human separately authorizes")
      {authorization_position, _length} = :binary.match(prompt, "Symphony automation identity authorization:")
      assert authorization_position > stale_blocker_position
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
      refute second_prompt =~ "## Current Linear activity"
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
    test "runs the captured gate but withholds mutation when review is inconclusive" do
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

      # Records any unexpected Linear handoff mutation. A missing required PR
      # is now explicitly inconclusive and must never be treated as approval.
      linear_client = fn query, variables, _opts ->
        send(test_pid, {:handoff_mutation_applied, query, variables})
        {:ok, %{"data" => %{}}}
      end

      # No PR present -> the gate does not spawn a reviewer, but it withholds
      # the deferred mutation and preserves a non-approval outcome.
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

      refute_received {:handoff_mutation_applied, _query, _variables}
    end
  end

  describe "deferred review lifecycle" do
    test "approves the exact head before starting and durably polling the handoff gate" do
      workspace_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-review-before-gate-#{System.unique_integer([:positive])}"
        )

      workspace = Path.join(workspace_root, "UDPE-7431")
      File.mkdir_p!(workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
      {_, 0} = System.cmd("git", ["-C", workspace, "init", "--quiet"])
      File.write!(Path.join(workspace, "README.md"), "review before gate\n")
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
          "review before gate"
        ])

      {head_sha, 0} = System.cmd("git", ["-C", workspace, "rev-parse", "HEAD"])
      head_sha = String.trim(head_sha)
      test_pid = self()

      issue = %Issue{
        id: "issue-review-before-gate",
        identifier: "UDPE-7431",
        title: "Review before final validation",
        state: "In Progress",
        labels: []
      }

      review_workflow = %{
        config: %{"review" => %{"require_pr" => false}},
        prompt: "Review {{ issue.identifier }}",
        prompt_template: "Review {{ issue.identifier }}"
      }

      no_pr = fn ["pr", "view" | _], _cwd -> {"no pull requests found", 1} end

      review_runner = fn ctx ->
        send(test_pid, :review_started_before_gate)
        refute_received :handoff_gate_started
        write_review_verdict(ctx, %{"verdict" => "approve"})
        {:ok, %{}}
      end

      linear_client = fn query, variables, _opts ->
        send(test_pid, {:reviewed_handoff_applied, query, variables})
        {:ok, %{"data" => %{}}}
      end

      review_opts = [
        pr_runner: no_pr,
        session_runner: review_runner,
        comment_fn: fn _id, _body -> :ok end,
        linear_client: linear_client
      ]

      handoff_request = %{
        query: "mutation { issueUpdate(input: {stateId: \"in-review\"}) { success } }",
        variables: %{},
        workspace: workspace,
        issue: issue,
        worker_host: nil,
        target_state: "In Review",
        before_handoff_command: nil,
        before_handoff_timeout_ms: nil,
        before_handoff_stale_ms: nil,
        review_workflow: review_workflow,
        review_opts: review_opts,
        linear_client: linear_client
      }

      review_request = %{
        query: handoff_request.query,
        variables: %{},
        workspace: workspace,
        issue: issue,
        worker_host: nil,
        review_workflow: review_workflow,
        review_opts: review_opts,
        linear_client: linear_client,
        handoff_after_review: handoff_request
      }

      Application.put_env(:symphony_elixir, :deferred_requests_for_test, [review_request])

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :deferred_requests_for_test)
        File.rm_rf(workspace_root)
      end)

      starter = fn ^workspace, ^issue, nil, "In Review", start_opts ->
        assert start_opts[:async] == true
        send(test_pid, :handoff_gate_started)
        {:pending, async_gate(:pending)}
      end

      poller = fn ^workspace, ^issue, nil, "In Review", "job-7157", _poll_opts ->
        assert {:ok,
                %{
                  "phase" => "polling",
                  "reviewApproval" => %{
                    "kind" => "workspace",
                    "issueId" => "issue-review-before-gate",
                    "reviewedSha" => ^head_sha
                  }
                }} = Workspace.load_handoff_gate_state(workspace)

        send(test_pid, :handoff_gate_polled)
        {:passed, async_gate(:passed)}
      end

      state_fetcher = fn ["issue-review-before-gate"] -> {:ok, [issue]} end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {DeferredBackend, %{}},
                   issue_state_fetcher: state_fetcher,
                   handoff_gate_starter: starter,
                   handoff_gate_poller: poller,
                   handoff_gate_sleep: fn _milliseconds -> :ok end,
                   max_turns: 1
                 ],
                 nil
               )

      assert_received :review_started_before_gate
      assert_received :handoff_gate_started
      assert_received :handoff_gate_polled
      assert_received {:reviewed_handoff_applied, query, %{}}
      assert query =~ "issueUpdate"
      refute_received :review_started_before_gate
      assert {:ok, nil} = Workspace.load_handoff_gate_state(workspace)
    end

    test "ends the worker attempt when review infrastructure is unavailable" do
      workspace =
        Path.join(
          System.tmp_dir!(),
          "symphony-review-infrastructure-#{System.unique_integer([:positive])}"
        )

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
          "review target"
        ])

      test_pid = self()

      issue = %Issue{
        id: "issue-review-infrastructure",
        identifier: "UDPE-7203",
        title: "Back off after review infrastructure failure",
        state: "In Progress",
        labels: []
      }

      linear_client = fn query, variables, _opts ->
        send(test_pid, {:unexpected_review_handoff, query, variables})
        {:ok, %{"data" => %{}}}
      end

      no_pr = fn ["pr", "view" | _], _cwd -> {"no pull requests found", 1} end

      request = %{
        query: "mutation { issueUpdate(input: {stateId: \"in-review\"}) { success } }",
        variables: %{},
        workspace: workspace,
        issue: issue,
        worker_host: nil,
        review_workflow: %{
          config: %{"review" => %{"require_pr" => false}},
          prompt: "Review {{ issue.identifier }}",
          prompt_template: "Review {{ issue.identifier }}"
        },
        review_opts: [
          pr_runner: no_pr,
          review_packet_builder: fn _workspace, _issue, _pr, _reviewed_sha, _prior_outcome, _settings, _opts ->
            send(test_pid, :review_packet_failed)
            {:error, :packet_builder_failed}
          end,
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

      state_fetcher = fn [_issue_id] -> {:ok, [issue]} end

      assert {:error,
              {:review_gate_infrastructure,
               %{
                 review: %{
                   outcome: "infrastructure_unavailable",
                   failure_reason: failure_reason
                 }
               }}} =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {DeferredBackend, %{}},
                   issue_state_fetcher: state_fetcher,
                   max_turns: 5
                 ],
                 nil
               )

      assert failure_reason =~ "review_packet_unavailable"
      assert_received :review_packet_failed
      refute_received {:unexpected_review_handoff, _, _}
    end

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
      {head_sha, 0} = System.cmd("git", ["-C", workspace, "rev-parse", "HEAD"])
      head_sha = String.trim(head_sha)

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
        send(test_pid, {:review_session_started, ctx.packet.validation_attestations})
        write_review_verdict(ctx, %{"verdict" => "approve"})
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
        gate: %{
          async_gate(:passed)
          | identity:
              Map.merge(async_gate(:passed).identity, %{
                "headSha" => head_sha,
                "mutablePrStateHash" => "mutable-state-7157",
                "prNumber" => "18"
              }),
            checks: [%{"id" => "check-evidence-fresh", "status" => "passed"}],
            result_artifact: ".artifacts/before-handoff/result.json"
        },
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

      assert_received {:review_session_started, attestations}

      assert Enum.any?(attestations, fn attestation ->
               attestation.command == "before_handoff/check-evidence-fresh" and
                 attestation.head_sha == head_sha and
                 attestation.exact_hash == "exact-7157" and
                 attestation.mutable_pr_state_hash == "mutable-state-7157"
             end)

      refute_received {:review_session_started, _attestations}
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
        write_review_verdict(ctx, %{"verdict" => "approve"})
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
        write_review_verdict(ctx, %{"verdict" => "approve"})
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

      assert_receive {:lifecycle_call, {:agent_lifecycle, "issue-preflight", :handoff_pending_review, %{review_key: {:pull_request, "issue-preflight", "PR_preflight", "head-preflight"}}}},
                     1_000

      assert_receive {:lifecycle_call,
                      {:agent_lifecycle, "issue-preflight", :implementing,
                       %{
                         review_outcome: :approved,
                         review_state: %{
                           outcome: "approved",
                           reviewed_sha: "head-preflight",
                           iteration: 1,
                           severity_counts: %{}
                         }
                       }}},
                     1_000
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

        write_review_verdict(ctx, %{"verdict" => "approve"})
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
      # Keep the orchestrator's immediate startup poll from racing this test's
      # deliberately injected running entry.
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      orchestrator_name = Module.concat(__MODULE__, :LiveReviewOrchestrator)
      {:ok, orchestrator} = Orchestrator.start_link(name: orchestrator_name)
      Process.sleep(50)

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

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

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

  describe "asynchronous handoff gate recovery" do
    test "retries a durable gate start without opening another model session" do
      workspace_root =
        Path.join(System.tmp_dir!(), "symphony-gate-start-recovery-#{System.unique_integer([:positive])}")

      workspace = Path.join(workspace_root, "UDPE-7370")
      File.mkdir_p!(workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-gate-start-recovery",
        identifier: "UDPE-7370",
        title: "Recover a gate start timeout",
        state: "In Progress",
        labels: []
      }

      query =
        "mutation Move { issueUpdate(id: \"issue-gate-start-recovery\", input: {stateId: \"review\"}) { success } }"

      assert :ok =
               Workspace.persist_handoff_gate_state(workspace, %{
                 "phase" => "starting",
                 "query" => query,
                 "variables" => %{},
                 "targetState" => "In Review"
               })

      Application.put_env(:symphony_elixir, :turn_count_recipient_for_test, self())
      {:ok, starts} = Agent.start_link(fn -> 0 end)
      test_pid = self()

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :turn_count_recipient_for_test)
        if Process.alive?(starts), do: Agent.stop(starts)
        File.rm_rf(workspace_root)
      end)

      starter = fn ^workspace, ^issue, nil, "In Review", start_opts ->
        assert start_opts[:async] == true
        attempt = Agent.get_and_update(starts, fn count -> {count, count + 1} end)
        send(test_pid, {:durable_gate_start_attempt, attempt + 1})

        if attempt == 0 do
          {:infrastructure_error, "gate start timed out", %{status: :infrastructure_error}}
        else
          {:pending, async_gate(:pending)}
        end
      end

      poller = fn ^workspace, ^issue, nil, "In Review", "job-7157", _poll_opts ->
        send(test_pid, :recovered_gate_polled)
        {:passed, async_gate(:passed)}
      end

      linear_client = fn ^query, %{}, [] ->
        send(test_pid, :recovered_gate_handoff_applied)
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      end

      state_fetcher = fn ["issue-gate-start-recovery"] -> {:ok, [issue]} end

      opts = [
        agent_backend: {TurnCountingBackend, %{}},
        issue_context_file: Workspace.issue_context_path(workspace),
        issue_state_fetcher: state_fetcher,
        handoff_gate_starter: starter,
        handoff_gate_poller: poller,
        handoff_gate_sleep: fn _milliseconds -> :ok end,
        linear_client: linear_client,
        max_turns: 1
      ]

      assert {:error, {:handoff_gate_infrastructure, %{message: "gate start timed out", gate: %{status: :infrastructure_error}}}} =
               AgentRunner.run_codex_turns_for_test(workspace, issue, nil, opts, nil)

      assert_received {:durable_gate_start_attempt, 1}
      refute_received :turn_ran

      assert {:ok, %{"phase" => "starting"}} = Workspace.load_handoff_gate_state(workspace)

      assert :ok = AgentRunner.run_codex_turns_for_test(workspace, issue, nil, opts, nil)

      assert_received {:durable_gate_start_attempt, 2}
      assert_received :recovered_gate_polled
      assert_received :recovered_gate_handoff_applied
      refute_received :turn_ran
      assert {:ok, nil} = Workspace.load_handoff_gate_state(workspace)
    end

    test "revalidates handoff runtime drift before retrying a durable gate start" do
      workspace_root =
        Path.join(System.tmp_dir!(), "symphony-gate-start-drift-#{System.unique_integer([:positive])}")

      workspace = Path.join(workspace_root, "UDPE-7370")
      File.mkdir_p!(workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-gate-start-drift",
        identifier: "UDPE-7370",
        title: "Refresh a stale handoff runtime",
        state: "In Progress",
        labels: []
      }

      assert :ok =
               Workspace.persist_handoff_gate_state(workspace, %{
                 "phase" => "starting",
                 "query" => "mutation Move { issueUpdate(id: \"issue-gate-start-drift\", input: {stateId: \"review\"}) { success } }",
                 "variables" => %{},
                 "targetState" => "In Review"
               })

      Application.put_env(:symphony_elixir, :handoff_prompt_recipient_for_test, self())
      test_pid = self()

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :handoff_prompt_recipient_for_test)
        File.rm_rf(workspace_root)
      end)

      starter = fn _workspace, _issue, _worker_host, _target_state, _start_opts ->
        send(test_pid, :stale_handoff_started)
        :ok
      end

      git_runner = fn
        ["rev-parse", "HEAD"], ^workspace ->
          {"candidate-head\n", 0}

        ["fetch", "--quiet", "origin", "develop"], ^workspace ->
          {"", 0}

        ["rev-parse", "refs/remotes/origin/develop"], ^workspace ->
          {"current-base\n", 0}

        ["merge-base", "candidate-head", "current-base"], ^workspace ->
          {"candidate-base\n", 0}

        ["diff", "--name-only", "candidate-base..HEAD"], ^workspace ->
          {"app/widget.tsx\n", 0}

        ["diff", "--name-only", "HEAD"], ^workspace ->
          {"", 0}

        ["diff", "--name-only", "--cached"], ^workspace ->
          {"", 0}

        ["ls-files", "--others", "--exclude-standard"], ^workspace ->
          {"", 0}

        ["diff", "--name-only", "candidate-base..current-base"], ^workspace ->
          {"scripts/hooks/before-handoff.sh\n", 0}

        ["status", "--porcelain", "--untracked-files=normal"], ^workspace ->
          {"", 0}
      end

      state_fetcher = fn ["issue-gate-start-drift"] -> {:ok, [issue]} end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {HandoffPromptBackend, %{}},
                   issue_context_file: Workspace.issue_context_path(workspace),
                   issue_state_fetcher: state_fetcher,
                   handoff_gate_starter: starter,
                   base_drift_ref: "develop",
                   base_drift_git_runner: git_runner,
                   per_repo_before_handoff: "scripts/hooks/before-handoff.sh",
                   max_turns: 1
                 ],
                 nil
               )

      assert_received {:handoff_prompt, prompt, ^issue}
      assert prompt =~ "paths required by the configured handoff runtime"
      assert prompt =~ "scripts/hooks/before-handoff.sh"
      refute_received :stale_handoff_started
      assert {:ok, nil} = Workspace.load_handoff_gate_state(workspace)
    end

    test "reattaches to a reviewed durable job and applies an exact-candidate pass without a model turn" do
      workspace_root =
        Path.join(System.tmp_dir!(), "symphony-gate-recovery-#{System.unique_integer([:positive])}")

      workspace = Path.join(workspace_root, "UDPE-7157")
      File.mkdir_p!(workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
      {_, 0} = System.cmd("git", ["-C", workspace, "init", "--quiet"])
      File.write!(Path.join(workspace, "README.md"), "reviewed durable handoff\n")
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
          "reviewed durable handoff"
        ])

      {reviewed_sha, 0} = System.cmd("git", ["-C", workspace, "rev-parse", "HEAD"])
      reviewed_sha = String.trim(reviewed_sha)

      issue = %Issue{
        id: "issue-gate-recovery",
        identifier: "UDPE-7157",
        title: "Recover pending gate",
        state: "In Progress",
        labels: []
      }

      pending_gate = async_gate(:pending)

      assert :ok =
               Workspace.persist_handoff_gate_state(workspace, %{
                 "query" => "mutation Move { issueUpdate(id: \"issue-gate-recovery\", input: {stateId: \"review\"}) { success } }",
                 "variables" => %{},
                 "targetState" => "In Review",
                 "reviewApproval" => %{
                   "kind" => "workspace",
                   "issueId" => "issue-gate-recovery",
                   "reviewedSha" => reviewed_sha
                 },
                 "gate" => %{
                   "jobId" => pending_gate.job_id,
                   "status" => "pending",
                   "candidateHash" => pending_gate.candidate_hash,
                   "exactHash" => pending_gate.exact_hash,
                   "identity" => pending_gate.identity,
                   "heartbeatAt" => pending_gate.heartbeat_at,
                   "heartbeatAgeMs" => pending_gate.heartbeat_age_ms,
                   "nextPollMs" => pending_gate.next_poll_ms,
                   "progress" => pending_gate.progress,
                   "startedAt" => pending_gate.started_at
                 }
               })

      Application.put_env(:symphony_elixir, :turn_count_recipient_for_test, self())
      test_pid = self()

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :turn_count_recipient_for_test)
        File.rm_rf(workspace_root)
      end)

      poller = fn ^workspace, ^issue, nil, "In Review", "job-7157", poll_opts ->
        assert poll_opts[:expected_candidate_hash] == "candidate-7157"
        send(test_pid, :durable_gate_polled)
        {:passed, async_gate(:passed)}
      end

      linear_client = fn query, %{}, [] ->
        send(test_pid, {:recovered_handoff_applied, query})
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      end

      state_fetcher = fn ["issue-gate-recovery"] -> {:ok, [issue]} end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {TurnCountingBackend, %{}},
                   issue_context_file: Workspace.issue_context_path(workspace),
                   issue_state_fetcher: state_fetcher,
                   handoff_gate_poller: poller,
                   linear_client: linear_client,
                   max_turns: 1
                 ],
                 nil
               )

      assert_received :durable_gate_polled
      assert_received {:recovered_handoff_applied, query}
      assert query =~ "issueUpdate"
      refute_received :turn_ran
      assert {:ok, nil} = Workspace.load_handoff_gate_state(workspace)
    end

    test "adopts a live replacement gate and finishes its lifecycle without a model turn" do
      workspace_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-gate-replacement-#{System.unique_integer([:positive])}"
        )

      workspace = Path.join(workspace_root, "UDPE-7372")
      File.mkdir_p!(workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-gate-replacement",
        identifier: "UDPE-7372",
        title: "Follow a replacement gate",
        state: "In Progress",
        labels: []
      }

      original_gate = async_gate(:pending)
      replacement_gate = %{original_gate | job_id: "job-86814", candidate_hash: "candidate-86814"}

      assert :ok =
               Workspace.persist_handoff_gate_state(workspace, %{
                 "query" => "mutation Move { issueUpdate(id: \"issue-gate-replacement\", input: {stateId: \"review\"}) { success } }",
                 "variables" => %{},
                 "targetState" => "In Review",
                 "gate" => %{
                   "jobId" => original_gate.job_id,
                   "status" => "pending",
                   "candidateHash" => original_gate.candidate_hash,
                   "exactHash" => original_gate.exact_hash,
                   "identity" => original_gate.identity,
                   "heartbeatAt" => original_gate.heartbeat_at,
                   "heartbeatAgeMs" => original_gate.heartbeat_age_ms,
                   "nextPollMs" => original_gate.next_poll_ms,
                   "progress" => original_gate.progress,
                   "startedAt" => original_gate.started_at
                 }
               })

      Application.put_env(:symphony_elixir, :turn_count_recipient_for_test, self())
      test_pid = self()

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :turn_count_recipient_for_test)
        File.rm_rf(workspace_root)
      end)

      poller = fn
        ^workspace, ^issue, nil, "In Review", "job-7157", _poll_opts ->
          send(test_pid, :replacement_gate_adopted)
          {:pending, replacement_gate}

        ^workspace, ^issue, nil, "In Review", "job-86814", _poll_opts ->
          send(test_pid, :replacement_gate_polled)
          {:passed, %{replacement_gate | status: :passed}}
      end

      linear_client = fn _query, %{}, [] ->
        send(test_pid, :replacement_gate_handoff_applied)
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 self(),
                 [
                   agent_backend: {TurnCountingBackend, %{}},
                   issue_context_file: Workspace.issue_context_path(workspace),
                   issue_state_fetcher: fn ["issue-gate-replacement"] -> {:ok, [issue]} end,
                   handoff_gate_poller: poller,
                   handoff_gate_sleep: fn _milliseconds -> :ok end,
                   linear_client: linear_client,
                   max_turns: 1
                 ],
                 nil
               )

      assert_received :replacement_gate_adopted
      assert_received :replacement_gate_polled
      assert_received :replacement_gate_handoff_applied
      assert_received {:agent_lifecycle, "issue-gate-replacement", :handoff_pending_gate, %{gate_job_id: "job-7157"}}

      assert_received {:agent_lifecycle, "issue-gate-replacement", :handoff_pending_gate, %{gate_job_id: "job-86814"}}

      assert_received {:agent_lifecycle, "issue-gate-replacement", :implementing, %{gate_job_id: "job-86814", gate_outcome: :passed}}

      refute_received :turn_ran
      assert {:ok, nil} = Workspace.load_handoff_gate_state(workspace)
    end

    test "finishes the owned lifecycle when a terminal replacement cannot be adopted" do
      workspace_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-gate-terminal-replacement-#{System.unique_integer([:positive])}"
        )

      workspace = Path.join(workspace_root, "UDPE-7372")
      File.mkdir_p!(workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-terminal-gate-replacement",
        identifier: "UDPE-7372",
        title: "Finish an invalidated replacement gate",
        state: "In Progress",
        labels: []
      }

      request = %{
        query: "mutation Move { issueUpdate(id: \"issue-terminal-gate-replacement\", input: {stateId: \"review\"}) { success } }",
        variables: %{},
        workspace: workspace,
        issue: issue,
        worker_host: nil,
        target_state: "In Review",
        gate: async_gate(:pending),
        linear_client: fn _query, _variables, _opts -> {:ok, %{}} end
      }

      Application.put_env(:symphony_elixir, :pending_gate_recipient_for_test, self())
      Application.put_env(:symphony_elixir, :pending_gate_request_for_test, request)
      {:ok, state_reads} = Agent.start_link(fn -> 0 end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :pending_gate_recipient_for_test)
        Application.delete_env(:symphony_elixir, :pending_gate_request_for_test)
        if Process.alive?(state_reads), do: Agent.stop(state_reads)
        File.rm_rf(workspace_root)
      end)

      terminal_gate = %{
        async_gate(:invalidated)
        | job_id: "job-replacement",
          candidate_hash: "candidate-replacement",
          summary: "candidate changed"
      }

      poller = fn _workspace, _issue, nil, "In Review", "job-7157", _opts ->
        {:invalidated, "candidate changed", terminal_gate}
      end

      state_fetcher = fn ["issue-terminal-gate-replacement"] ->
        read = Agent.get_and_update(state_reads, fn count -> {count, count + 1} end)
        state = if read == 0, do: "In Progress", else: "Done"
        {:ok, [%{issue | state: state}]}
      end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 self(),
                 [
                   agent_backend: {PendingGateBackend, %{}},
                   issue_state_fetcher: state_fetcher,
                   handoff_gate_poller: poller,
                   handoff_gate_sleep: fn _milliseconds -> :ok end,
                   max_turns: 1
                 ],
                 nil
               )

      assert_received {:agent_lifecycle, "issue-terminal-gate-replacement", :handoff_pending_gate, %{gate_job_id: "job-7157"}}

      assert_received {:agent_lifecycle, "issue-terminal-gate-replacement", :implementing, %{gate_job_id: "job-7157", gate_outcome: :invalidated}}
    end

    test "ends the worker attempt on handoff infrastructure failure without a remediation turn" do
      workspace_root =
        Path.join(System.tmp_dir!(), "symphony-gate-infrastructure-#{System.unique_integer([:positive])}")

      workspace = Path.join(workspace_root, "UDPE-7157")
      File.mkdir_p!(workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-gate-infrastructure",
        identifier: "UDPE-7157",
        title: "Back off after gate infrastructure failure",
        state: "In Progress",
        labels: []
      }

      request = %{
        query: "mutation Move { issueUpdate(id: \"issue-gate-infrastructure\", input: {stateId: \"review\"}) { success } }",
        variables: %{},
        workspace: workspace,
        issue: issue,
        worker_host: nil,
        target_state: "In Review",
        gate: async_gate(:pending),
        linear_client: fn _query, _variables, _opts -> {:ok, %{}} end
      }

      Application.put_env(:symphony_elixir, :pending_gate_recipient_for_test, self())
      Application.put_env(:symphony_elixir, :pending_gate_request_for_test, request)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :pending_gate_recipient_for_test)
        Application.delete_env(:symphony_elixir, :pending_gate_request_for_test)
        File.rm_rf(workspace_root)
      end)

      poller = fn _workspace, _issue, nil, "In Review", "job-7157", _opts ->
        gate = %{async_gate(:infrastructure_error) | summary: "gate runner unavailable"}
        {:infrastructure_error, "gate runner unavailable", gate}
      end

      state_fetcher = fn ["issue-gate-infrastructure"] -> {:ok, [issue]} end

      assert {:error, {:handoff_gate_infrastructure, %{message: "gate runner unavailable", gate: %{status: :infrastructure_error}}}} =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {PendingGateBackend, %{}},
                   issue_state_fetcher: state_fetcher,
                   handoff_gate_poller: poller,
                   handoff_gate_sleep: fn _milliseconds -> :ok end,
                   max_turns: 5
                 ],
                 nil
               )

      assert_received {:pending_gate_turn, 1, _initial_prompt}
      refute_received {:pending_gate_turn, 2, _remediation_prompt}
      refute_received {:memory_tracker_state_update, "issue-gate-infrastructure", "Blocked"}
      refute_received {:memory_tracker_add_label, "issue-gate-infrastructure", "needs-human-input"}
    end

    test "coalesces repeated requests for the same candidate into one durable job" do
      workspace_root =
        Path.join(System.tmp_dir!(), "symphony-gate-coalesce-#{System.unique_integer([:positive])}")

      workspace = Path.join(workspace_root, "UDPE-7157")
      File.mkdir_p!(workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-gate-coalesce",
        identifier: "UDPE-7157",
        title: "Coalesce pending gate",
        state: "In Progress",
        labels: []
      }

      request = %{
        query: "mutation Move { issueUpdate(id: \"issue-gate-coalesce\", input: {stateId: \"review\"}) { success } }",
        variables: %{},
        workspace: workspace,
        issue: issue,
        worker_host: nil,
        target_state: "In Review",
        gate: async_gate(:pending),
        linear_client: fn _query, _variables, _opts -> {:ok, %{}} end
      }

      on_exit(fn -> File.rm_rf(workspace_root) end)

      assert :ok = AgentRunner.store_deferred_handoff_gate_for_test(request)
      assert :already_pending = AgentRunner.store_deferred_handoff_gate_for_test(request)

      assert {:ok, %{"gate" => %{"jobId" => "job-7157"}}} =
               Workspace.load_handoff_gate_state(workspace)
    end

    test "a terminal gate failure gets one remediation turn even at max_turns" do
      workspace_root =
        Path.join(System.tmp_dir!(), "symphony-gate-remediation-#{System.unique_integer([:positive])}")

      workspace = Path.join(workspace_root, "UDPE-7157")
      File.mkdir_p!(workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-gate-remediation",
        identifier: "UDPE-7157",
        title: "Resume after failed gate",
        state: "In Progress",
        labels: []
      }

      request = %{
        query: "mutation Move { issueUpdate(id: \"issue-gate-remediation\", input: {stateId: \"review\"}) { success } }",
        variables: %{},
        workspace: workspace,
        issue: issue,
        worker_host: nil,
        target_state: "In Review",
        gate: async_gate(:pending),
        linear_client: fn _query, _variables, _opts -> {:ok, %{}} end
      }

      Application.put_env(:symphony_elixir, :pending_gate_recipient_for_test, self())
      Application.put_env(:symphony_elixir, :pending_gate_request_for_test, request)
      {:ok, state_reads} = Agent.start_link(fn -> 0 end)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :pending_gate_recipient_for_test)
        Application.delete_env(:symphony_elixir, :pending_gate_request_for_test)
        if Process.alive?(state_reads), do: Agent.stop(state_reads)
        File.rm_rf(workspace_root)
      end)

      state_fetcher = fn ["issue-gate-remediation"] ->
        read = Agent.get_and_update(state_reads, fn count -> {count, count + 1} end)
        state = if read < 2, do: "In Progress", else: "Done"
        {:ok, [%{issue | state: state}]}
      end

      failed_gate = %{async_gate(:failed) | remediation: "Fix the failing exact-head tests."}

      poller = fn _workspace, _issue, nil, "In Review", "job-7157", _opts ->
        {:failed, "Fix the failing exact-head tests.", failed_gate}
      end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {PendingGateBackend, %{}},
                   issue_state_fetcher: state_fetcher,
                   handoff_gate_poller: poller,
                   handoff_gate_sleep: fn _milliseconds -> :ok end,
                   max_turns: 1
                 ],
                 nil
               )

      assert_received {:pending_gate_turn, 1, _initial_prompt}
      assert_received {:pending_gate_turn, 2, remediation_prompt}
      assert remediation_prompt =~ "Fix the failing exact-head tests."
      refute_received {:pending_gate_turn, 3, _prompt}
    end
  end

  describe "max-turn session boundary" do
    test "ends the worker session without changing the issue to Blocked" do
      workspace =
        Path.join(System.tmp_dir!(), "symphony-max-turn-boundary-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      Application.put_env(:symphony_elixir, :turn_count_recipient_for_test, self())

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :turn_count_recipient_for_test)
        File.rm_rf(workspace)
      end)

      issue = %Issue{
        id: "issue-max-turn-boundary",
        identifier: "UDPE-7007",
        title: "Leave an active issue active",
        state: "In Progress",
        labels: []
      }

      state_fetcher = fn ["issue-max-turn-boundary"] -> {:ok, [issue]} end

      assert :ok =
               AgentRunner.run_codex_turns_for_test(
                 workspace,
                 issue,
                 nil,
                 [
                   agent_backend: {TurnCountingBackend, %{}},
                   issue_state_fetcher: state_fetcher,
                   max_turns: 1
                 ],
                 nil
               )

      assert_received :turn_ran
      refute_received :turn_ran
      refute_received {:memory_tracker_comment, "issue-max-turn-boundary", _body}
      refute_received {:memory_tracker_add_label, "issue-max-turn-boundary", _label}
      refute_received {:memory_tracker_state_update, "issue-max-turn-boundary", _state}
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

  defp async_gate(status) do
    %{
      protocol_version: 1,
      job_id: "job-7157",
      status: status,
      identity: %{"candidateHash" => "candidate-7157", "exactHash" => "exact-7157"},
      candidate_hash: "candidate-7157",
      exact_hash: "exact-7157",
      heartbeat_at: "2026-08-02T12:00:00Z",
      heartbeat_age_ms: 10,
      next_poll_ms: 1,
      progress: %{"stage" => "ci", "completed" => 1, "total" => 2},
      started_at: "2026-08-02T11:59:00Z",
      completed_at: if(status == :passed, do: "2026-08-02T12:01:00Z", else: nil),
      result_artifact: nil,
      checks: [],
      remediation: nil,
      summary: nil,
      single_flight: true
    }
  end
end
