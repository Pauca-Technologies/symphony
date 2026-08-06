defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker.Memory

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end

    def handle_call({:set_drain_mode, enabled}, _from, state) do
      if recipient = Keyword.get(state, :recipient), do: send(recipient, {:drain_mode, enabled})

      {:reply,
       {:ok,
        %{
          draining: enabled,
          started_at: if(enabled, do: DateTime.utc_now(), else: nil)
        }}, state}
    end

    def handle_call({action, identifier}, _from, state)
        when action in [:resume_wait, :cancel_wait] and is_binary(identifier) do
      if recipient = Keyword.get(state, :recipient), do: send(recipient, {action, identifier})
      action_name = if action == :resume_wait, do: "resumed", else: "cancelled"
      {:reply, {:ok, %{action: action_name, issue_id: "issue-wait", identifier: identifier}}, state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Process.exit(manual_pid, :normal)
    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["issue-1"])

    assert {:ok, %{comments: [], truncated: false}} =
             SymphonyElixir.Tracker.fetch_issue_comments("issue-1")

    assert :ok = SymphonyElixir.Tracker.create_comment("issue-1", "comment")
    assert :ok = SymphonyElixir.Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}

    Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == Adapter
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             Adapter.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"

    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             Adapter.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Odd")
  end

  test "linear adapter add_label reuses an existing label id" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "team" => %{"id" => "team-1", "labels" => %{"nodes" => [%{"id" => "label-1"}]}}
             }
           }
         }},
        {:ok, %{"data" => %{"issueAddLabel" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.add_label("issue-1", "symphony:routing-warned")

    assert_receive {:graphql_called, lookup_query, %{issueId: "issue-1", labelName: "symphony:routing-warned"}}
    assert lookup_query =~ "labels(filter"

    assert_receive {:graphql_called, add_query, %{issueId: "issue-1", labelId: "label-1"}}
    assert add_query =~ "issueAddLabel"

    # No create mutation is issued when the label already exists (the create
    # mutation is the only call carrying `name`/`teamId` variables).
    refute_received {:graphql_called, _create_query, %{name: _, teamId: _}}
  end

  test "linear adapter add_label creates the label when it is missing" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"id" => "team-1", "labels" => %{"nodes" => []}}}
           }
         }},
        {:ok,
         %{
           "data" => %{
             "issueLabelCreate" => %{"success" => true, "issueLabel" => %{"id" => "label-new"}}
           }
         }},
        {:ok, %{"data" => %{"issueAddLabel" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.add_label("issue-1", "symphony:routing-warned")

    assert_receive {:graphql_called, _lookup_query, %{issueId: "issue-1", labelName: "symphony:routing-warned"}}

    assert_receive {:graphql_called, create_query, %{name: "symphony:routing-warned", teamId: "team-1"}}

    assert create_query =~ "issueLabelCreate"

    assert_receive {:graphql_called, _add_query, %{issueId: "issue-1", labelId: "label-new"}}
  end

  test "linear adapter add_label surfaces missing team and create failures" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    # No team id and no matching label -> cannot resolve or create.
    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"issue" => %{"team" => %{"labels" => %{"nodes" => []}}}}}}
    )

    assert {:error, :label_missing} = Adapter.add_label("issue-1", "symphony:routing-warned")

    # Team present, label missing, but the create mutation returns no id.
    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"id" => "team-1", "labels" => %{"nodes" => []}}}
           }
         }},
        {:ok, %{"data" => %{"issueLabelCreate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :label_create_failed} = Adapter.add_label("issue-1", "symphony:routing-warned")
  end

  test "presenter maps active backend usage by reported window duration" do
    orchestrator_name = Module.concat(__MODULE__, :BackendUsageOrchestrator)
    reset_at = 1_800_000_000

    snapshot = %{
      static_snapshot()
      | backend_usage: [
          %{
            backend: "codex",
            account_scope: "local",
            running_agents: 3,
            updated_at: ~U[2026-08-05 12:00:00Z],
            rate_limits: %{
              "plan_type" => "pro",
              "primary" => %{
                "used_percent" => 61,
                "window_minutes" => 10_080,
                "resets_at" => reset_at
              },
              "secondary" => %{
                "usedPercent" => 23,
                "windowDurationMins" => 300,
                "resetsAt" => reset_at
              },
              "credits" => %{"unlimited" => true}
            }
          },
          %{
            backend: "claude_code",
            account_scope: "local",
            running_agents: 2,
            updated_at: ~U[2026-08-05 12:01:00Z],
            rate_limits: %{
              "five_hour" => %{"used_percentage" => 24, "resets_at" => reset_at},
              "seven_day" => %{"used_percentage" => 62, "resets_at" => reset_at}
            }
          },
          %{
            backend: "acp",
            account_scope: "worker:gpu-1",
            running_agents: 1,
            updated_at: nil,
            rate_limits: nil
          }
        ]
    }

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot})

    payload = SymphonyElixirWeb.Presenter.state_payload(orchestrator_name, 50)

    assert [codex, claude, acp] = payload.backend_usage
    assert codex.backend == "codex"
    assert codex.running_agents == 3
    assert codex.plan_type == "pro"
    assert codex.credits == %{unlimited: true, available: false, balance: nil}
    assert codex.limits.five_hour.used_percent == 23.0
    assert codex.limits.weekly.used_percent == 61.0
    assert codex.limits.five_hour.resets_at == "2027-01-15T08:00:00Z"
    assert claude.backend == "claude_code"
    assert claude.limits.five_hour.used_percent == 24.0
    assert claude.limits.weekly.used_percent == 62.0

    assert acp == %{
             backend: "acp",
             account_scope: "worker:gpu-1",
             running_agents: 1,
             available: false,
             limit_id: nil,
             plan_type: nil,
             credits: nil,
             updated_at: nil,
             limits: %{five_hour: nil, weekly: nil}
           }
  end

  test "web dashboard promotes parked waits above the fold" do
    orchestrator_name = Module.concat(__MODULE__, :WaitingDashboardOrchestrator)

    snapshot =
      static_snapshot()
      |> Map.put(:waiting, [
        %{
          issue_id: "issue-wait",
          identifier: "UDPE-7007",
          title: "Recover durable work",
          status: :waiting,
          reason: "GitHub Actions outage",
          condition: %{"type" => "github_actions_recovered", "component" => "actions"},
          condition_key: "actions-wait",
          backend: "codex",
          worker_host: nil,
          workspace_path: "/tmp/UDPE-7007",
          parked_at: DateTime.utc_now(),
          next_probe_at: DateTime.add(DateTime.utc_now(), 30, :second),
          waiting_seconds: 60,
          probe_attempt: 6,
          last_observation: nil,
          last_error: nil
        }
      ])

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "status-badge-waiting"
    assert html =~ "1 waiting"
    assert html =~ ~s(href="#waiting-work")
    assert html =~ ~s(id="waiting-work")
    assert html =~ "UDPE-7007"
    assert html =~ "github_actions_recovered: actions"
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        recipient: self(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{"running" => 1, "queued" => 0, "retrying" => 1, "waiting" => 0},
             "queued" => [],
             "waiting" => [],
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "title" => "Wire up the HTTP server",
                 "state" => "In Progress",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "agent" => %{
                   "backend" => "claude_code",
                   "model" => "claude-opus-4-8",
                   "reasoning_effort" => "xhigh",
                   "profile" => "deep"
                 },
                 "session_id" => "thread-http",
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "recent_events" => [
                   %{
                     "at" =>
                       state_payload["running"]
                       |> List.first()
                       |> Map.fetch!("recent_events")
                       |> List.first()
                       |> Map.fetch!("at"),
                     "event" => "notification",
                     "message" => "mix test"
                   }
                 ],
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12},
                 "context" => %{"tokens" => 0, "window" => nil, "fill_ratio" => nil}
               }
             ],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "title" => "Retry the flaky migration",
                 "attempt" => 2,
                 "status" => "scheduled",
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "backend" => nil,
                 "failure_class" => nil,
                 "worker_host" => nil,
                 "workspace_path" => nil
               }
             ],
             "codex_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "rate_limits" => %{"primary" => %{"remaining" => 11}},
             "backend_usage" => [
               %{
                 "backend" => "claude_code",
                 "account_scope" => "local",
                 "running_agents" => 1,
                 "available" => false,
                 "limit_id" => nil,
                 "plan_type" => nil,
                 "credits" => nil,
                 "updated_at" => nil,
                 "limits" => %{"five_hour" => nil, "weekly" => nil}
               }
             ],
             "mode" => %{"draining" => false, "started_at" => nil},
             "quota_circuits" => []
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "title" => "Wire up the HTTP server",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "agent" => %{
               "backend" => "claude_code",
               "model" => "claude-opus-4-8",
               "reasoning_effort" => "xhigh",
               "profile" => "deep"
             },
             "running" => %{
               "worker_host" => nil,
               "workspace_path" => nil,
               "agent" => %{
                 "backend" => "claude_code",
                 "model" => "claude-opus-4-8",
                 "reasoning_effort" => "xhigh",
                 "profile" => "deep"
               },
               "session_id" => "thread-http",
               "turn_count" => 7,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "recent_events" => [
                 %{
                   "at" =>
                     issue_payload["running"]
                     |> Map.fetch!("recent_events")
                     |> List.first()
                     |> Map.fetch!("at"),
                   "event" => "notification",
                   "message" => "mix test"
                 }
               ],
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12},
               "context" => %{"tokens" => 0, "window" => nil, "fill_ratio" => nil}
             },
             "retry" => nil,
             "waiting" => nil,
             "logs" => %{
               "codex_session_logs" => [
                 %{
                   "session_id" => "thread-http",
                   "path" => "/tmp/symphony/log/codex_sessions/MT-HTTP--thread-http.ndjson",
                   "started_at" => issue_payload["logs"]["codex_session_logs"] |> List.first() |> Map.fetch!("started_at"),
                   "last_event_at" => issue_payload["logs"]["codex_session_logs"] |> List.first() |> Map.fetch!("last_event_at"),
                   "worker_host" => nil,
                   "workspace_path" => nil
                 }
               ]
             },
             "transcript" => %{
               "session_id" => "thread-http",
               "path" => "/tmp/symphony/log/codex_sessions/MT-HTTP--thread-http.ndjson",
               "started_at" => issue_payload["transcript"]["started_at"],
               "last_event_at" => issue_payload["transcript"]["last_event_at"],
               "blocks" => []
             },
             "recent_events" => [
               %{
                 "at" => issue_payload["recent_events"] |> List.first() |> Map.fetch!("at"),
                 "event" => "notification",
                 "message" => "mix test"
               }
             ],
             "last_error" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn = post(build_conn(), "/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)

    assert %{"mode" => %{"draining" => true, "started_at" => started_at}} =
             build_conn() |> post("/api/v1/drain", %{}) |> json_response(200)

    assert is_binary(started_at)

    assert %{"mode" => %{"draining" => false, "started_at" => nil}} =
             build_conn() |> post("/api/v1/resume", %{}) |> json_response(200)

    assert %{"wait" => %{"action" => "resumed", "issue_id" => "issue-wait", "identifier" => "MT-WAIT"}} =
             build_conn()
             |> post("/api/v1/waits/MT-WAIT/resume", %{})
             |> json_response(200)

    assert_receive {:resume_wait, "MT-WAIT"}

    assert %{"wait" => %{"action" => "cancelled", "identifier" => "MT-WAIT"}} =
             build_conn()
             |> post("/api/v1/waits/MT-WAIT/cancel", %{})
             |> json_response(200)

    assert_receive {:cancel_wait, "MT-WAIT"}
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/waits/MT-1/resume"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }

    assert json_response(post(build_conn(), "/api/v1/drain", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }

    assert json_response(post(build_conn(), "/api/v1/waits/MT-1/resume", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ "/dashboard.css"
    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "dashboard renders five-hour and weekly usage for an active backend" do
    orchestrator_name = Module.concat(__MODULE__, :BackendUsageDashboardOrchestrator)

    snapshot =
      static_snapshot()
      |> put_in([:running, Access.at(0), :backend], "codex")
      |> put_in([:running, Access.at(0), :model], "gpt-5.5")
      |> Map.put(:backend_usage, [
        %{
          backend: "codex",
          account_scope: "local",
          running_agents: 1,
          updated_at: ~U[2026-08-05 12:00:00Z],
          rate_limits: %{
            "plan_type" => "pro",
            "primary" => %{"used_percent" => 23, "window_minutes" => 300},
            "secondary" => %{"used_percent" => 61, "window_minutes" => 10_080},
            "credits" => %{"unlimited" => true}
          }
        }
      ])

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Backend usage"
    assert html =~ "5-hour"
    assert html =~ "Weekly"
    assert html =~ "23% used"
    assert html =~ "61% used"
    assert html =~ "Plan pro"
    assert html =~ "Credits unlimited"
  end

  test "dashboard liveview keeps the list compact and renders transcript text on the issue page" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    transcript_file =
      write_transcript_fixture!([
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "codex/event/agent_message_content_delta",
            "params" => %{"msg" => %{"content" => "OLD-BEGINNING " <> String.duplicate("x", 1_200_000)}}
          }
        },
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "codex/event/agent_message_content_delta",
            "params" => %{"msg" => %{"content" => "Investigating the failure"}}
          }
        },
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "codex/event/agent_message_content_delta",
            "params" => %{
              "msg" => %{
                "content" =>
                  " and updating the fix.\n\n```elixir\nassert {:ok, view} = live(conn, \"/\")\n```\n\n- renders `code`\n- links [docs](https://example.com/docs)\n\n<script>alert(1)</script>"
              }
            }
          }
        },
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "thread/compacted",
            "params" => %{
              "threadId" => "thread-http",
              "turnId" => "turn-http-compact"
            }
          }
        },
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "codex/event/exec_command_begin",
            "params" => %{"msg" => %{"command" => "mix test --cover"}}
          }
        },
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "codex/event/exec_command_output_delta",
            "params" => %{"msg" => %{"content" => "Compiling 3 files\\n"}}
          }
        },
        # Native Codex item streams can interleave while a command remains in
        # flight. These deltas are one logical agent message and one logical
        # command output, not a new transcript card per alternating fragment.
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "item/started",
            "params" => %{
              "item" => %{
                "id" => "cmd-interleaved",
                "type" => "commandExecution",
                "command" => "mix test interleaved"
              }
            }
          }
        },
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "item/commandExecution/outputDelta",
            "params" => %{"itemId" => "cmd-interleaved", "delta" => "alpha"}
          }
        },
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "item/started",
            "params" => %{
              "item" => %{
                "id" => "agent-interleaved",
                "type" => "agentMessage",
                "phase" => "commentary"
              }
            }
          }
        },
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "item/agentMessage/delta",
            "params" => %{"itemId" => "agent-interleaved", "delta" => "The changed-s"}
          }
        },
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "item/commandExecution/outputDelta",
            "params" => %{"itemId" => "cmd-interleaved", "delta" => "beta"}
          }
        },
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "item/agentMessage/delta",
            "params" => %{"itemId" => "agent-interleaved", "delta" => "cope suite."}
          }
        },
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "item/completed",
            "params" => %{
              "item" => %{
                "id" => "agent-interleaved",
                "type" => "agentMessage",
                "phase" => "commentary",
                "text" => "The changed-scope suite is green."
              }
            }
          }
        },
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "item/completed",
            "params" => %{
              "item" => %{
                "id" => "cmd-interleaved",
                "type" => "commandExecution",
                "command" => "mix test interleaved",
                "aggregatedOutput" => "canonical interleaved output"
              }
            }
          }
        },
        # Legacy codex/event wrappers use ids nested under `params.msg` and can
        # interleave in exactly the same way as native v2 item notifications.
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "codex/event/exec_command_begin",
            "params" => %{
              "msg" => %{"call_id" => "legacy-command", "command" => "mix test legacy"}
            }
          }
        },
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "codex/event/exec_command_output_delta",
            "params" => %{
              "msg" => %{"call_id" => "legacy-command", "content" => "legacy-left"}
            }
          }
        },
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "codex/event/agent_message_content_delta",
            "params" => %{
              "msg" => %{"item_id" => "legacy-agent", "content" => "Legacy coherent"}
            }
          }
        },
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "codex/event/exec_command_output_delta",
            "params" => %{
              "msg" => %{"call_id" => "legacy-command", "content" => "-right"}
            }
          }
        },
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "codex/event/agent_message_content_delta",
            "params" => %{
              "msg" => %{"item_id" => "legacy-agent", "content" => " message."}
            }
          }
        },
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "tool_call_completed",
          "payload" => %{
            "method" => "item/tool/call",
            "params" => %{"tool" => "linear.get_issue", "arguments" => %{"id" => "UDPE-1"}}
          }
        },
        # Native ACP `session/update` notifications (Option B): the presenter
        # renders these via `update.sessionUpdate`, surfacing the ACP tool `kind`
        # and `plan` checklist that Option-A flattening would have dropped.
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "session/update",
            "params" => %{
              "sessionId" => "sess-acp",
              "update" => %{
                "sessionUpdate" => "tool_call",
                "toolCallId" => "tc-acp",
                "title" => "Edit changelog",
                "kind" => "edit",
                "rawInput" => %{"path" => "CHANGELOG.md"}
              }
            }
          }
        },
        # tool_call_update records carry the cumulative state of tc-acp: the
        # arguments fill in (filePath) and the output is resent in full each
        # time. The presenter keys these on toolCallId so the arguments land on
        # the existing tool block and the output renders once, not concatenated.
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "session/update",
            "params" => %{
              "sessionId" => "sess-acp",
              "update" => %{
                "sessionUpdate" => "tool_call_update",
                "toolCallId" => "tc-acp",
                "kind" => "edit",
                "title" => "Edit changelog",
                "rawInput" => %{"path" => "CHANGELOG.md", "newText" => "ACP-EDIT-ARG"}
              }
            }
          }
        },
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "session/update",
            "params" => %{
              "sessionId" => "sess-acp",
              "update" => %{
                "sessionUpdate" => "tool_call_update",
                "toolCallId" => "tc-acp",
                "content" => %{"type" => "text", "text" => "ACP-EDIT-OUTPUT line"}
              }
            }
          }
        },
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "session/update",
            "params" => %{
              "sessionId" => "sess-acp",
              "update" => %{
                "sessionUpdate" => "plan",
                "entries" => [
                  %{"content" => "draft the migration", "status" => "completed"},
                  %{"content" => "run the suite", "status" => "pending"}
                ]
              }
            }
          }
        },
        # Codex item-lifecycle tool calls (item/started + item/completed). Before
        # the fix only their streamed output rendered; the call header — the
        # command line, the file diff, the MCP/subagent invocation — was dropped,
        # leaving orphaned output. dynamicToolCall is excluded because it doubles
        # the item/tool/call above (linear.get_issue).
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "item/started",
            "params" => %{
              "item" => %{
                "id" => "call_cmd_codex",
                "type" => "commandExecution",
                "command" => "pnpm run codex-check",
                "status" => "inProgress"
              }
            }
          }
        },
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "item/commandExecution/outputDelta",
            "params" => %{"itemId" => "call_cmd_codex", "delta" => "CODEX-CMD-OUTPUT line\n"}
          }
        },
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "item/started",
            "params" => %{
              "item" => %{
                "id" => "call_file_codex",
                "type" => "fileChange",
                "changes" => [%{"path" => "lib/codex_edit.ex", "diff" => "@@ -1 +1 @@\n-old\n+CODEX-FILE-DIFF"}]
              }
            }
          }
        },
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "item/started",
            "params" => %{
              "item" => %{
                "id" => "call_collab_codex",
                "type" => "collabAgentToolCall",
                "tool" => "spawnAgent",
                "prompt" => "CODEX-COLLAB-PROMPT review the diff"
              }
            }
          }
        },
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "item/started",
            "params" => %{
              "item" => %{
                "id" => "call_mcp_codex",
                "type" => "mcpToolCall",
                "server" => "sentry",
                "tool" => "get_sentry_resource",
                "arguments" => %{"url" => "https://sentry.example/issue/1"}
              }
            }
          }
        },
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "item/completed",
            "params" => %{
              "item" => %{
                "id" => "call_mcp_codex",
                "type" => "mcpToolCall",
                "server" => "sentry",
                "tool" => "get_sentry_resource",
                "arguments" => %{"url" => "https://sentry.example/issue/1"},
                "result" => %{"content" => [%{"type" => "text", "text" => "CODEX-MCP-RESULT body"}]},
                "status" => "completed"
              }
            }
          }
        },
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "item/started",
            "params" => %{
              "item" => %{"id" => "call_dyn_codex", "type" => "dynamicToolCall", "tool" => "linear_graphql"}
            }
          }
        },
        %{
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "event" => "notification",
          "payload" => %{
            "method" => "item/completed",
            "params" => %{
              "item" => %{"id" => "call_dyn_codex", "type" => "dynamicToolCall", "tool" => "linear_graphql"}
            }
          }
        }
      ])

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        recipient: self(),
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Operations Dashboard"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "rendered"
    assert html =~ "Runtime"
    assert html =~ "Live"
    assert html =~ "Offline"
    assert html =~ "Copy ID"
    assert html =~ "Last activity"
    assert html =~ "Issue details"
    refute html =~ "mix test --cover"
    refute html =~ "Investigating the failure"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-offline"
    assert html =~ "Enable drain mode"
    assert html =~ "Wire up the HTTP server"
    assert html =~ "Retry the flaky migration"
    assert html =~ "claude-opus-4-8"
    assert html =~ "effort xhigh"
    assert html =~ "deep"
    assert html =~ "Backend usage"
    assert html =~ "Claude Code"
    assert html =~ "has not reported account-limit usage"
    refute html =~ "11 left"
    refute html =~ ~s(%{&quot;primary&quot;)

    _ = render_click(view, "enable-drain")
    assert_receive {:drain_mode, true}

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          title: "Wire up the HTTP server",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          codex_session_logs: [
            %{
              session_id: "thread-http",
              path: transcript_file,
              started_at: DateTime.utc_now(),
              last_event_at: DateTime.utc_now(),
              worker_host: nil,
              workspace_path: nil
            }
          ],
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "agent message content streaming: structured update" and
        not String.contains?(rendered, "mix test --cover")
    end)

    {:ok, issue_view, issue_html} = live(build_conn(), "/issues/MT-HTTP")
    assert issue_html =~ ~r/<h2[^>]*>Transcript<\/h2>/
    assert issue_html =~ "Investigating the failure and updating the fix."
    assert issue_html =~ "<pre><code class=\"language-elixir\">assert {:ok, view} = live(conn, &quot;/&quot;)</code></pre>"
    assert issue_html =~ "<li>renders <code>code</code></li>"
    assert issue_html =~ "<a href=\"https://example.com/docs\" rel=\"noreferrer\">docs</a>"
    assert issue_html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    assert issue_html =~ "$ mix test --cover"
    assert issue_html =~ "Compiling 3 files"
    assert issue_html =~ "Compaction"
    assert issue_html =~ "Context compacted for turn turn-htt"
    assert issue_html =~ "transcript-block-compaction"
    assert issue_html =~ "Showing the latest bounded transcript window."
    refute issue_html =~ "OLD-BEGINNING"
    refute issue_html =~ "agent message content streaming: structured update"
    refute issue_html =~ "<script>alert(1)</script>"
    assert issue_html =~ "Wire up the HTTP server"
    assert issue_html =~ "linear.get_issue"
    assert issue_html =~ "transcript-block-tool"
    # Native ACP rendering: the tool `kind` is surfaced and the plan checklist
    # renders as its own block.
    assert issue_html =~ "edit: Edit changelog"
    # tool_call_update fills the arguments onto the existing tool block and emits
    # the tool output (the presenter returns both fragments for one update, and
    # keys them on toolCallId so they merge in place). Block-level de-duplication
    # of cumulative output is covered by the orchestrator/renderer unit tests.
    assert issue_html =~ "ACP-EDIT-ARG"
    assert issue_html =~ "ACP-EDIT-OUTPUT line"
    assert issue_html =~ "transcript-block-plan"
    assert issue_html =~ "draft the migration"
    assert issue_html =~ "run the suite"
    # Codex item-lifecycle tool calls now surface the call, not just its output:
    # the command header folds with its output, and file/MCP/subagent calls that
    # previously rendered nothing now appear.
    assert issue_html =~ "$ pnpm run codex-check"
    assert issue_html =~ "CODEX-CMD-OUTPUT line"
    assert issue_html =~ "edit: codex_edit.ex"
    assert issue_html =~ "CODEX-FILE-DIFF"
    assert issue_html =~ "spawnAgent"
    assert issue_html =~ "CODEX-COLLAB-PROMPT review the diff"
    assert issue_html =~ "sentry: get_sentry_resource"
    assert issue_html =~ "CODEX-MCP-RESULT body"
    # dynamicToolCall is the Symphony tool dispatched via item/tool/call
    # (linear.get_issue, asserted above); its item/started + item/completed
    # lifecycle must not render a duplicate tool block.
    refute issue_html =~ "linear_graphql"

    {:ok, reconstructed} =
      SymphonyElixirWeb.Presenter.issue_payload("MT-HTTP", orchestrator_name, 5_000)

    assert Enum.any?(
             reconstructed.transcript.blocks,
             &String.contains?(Map.get(&1, :text, ""), "OLD-BEGINNING")
           )

    refute Map.has_key?(reconstructed.transcript, :truncated)

    assert [interleaved_agent] =
             Enum.filter(
               reconstructed.transcript.blocks,
               &(Map.get(&1, :item_id) == "agent-interleaved" and &1.kind == "agent")
             )

    assert interleaved_agent.text == "The changed-scope suite is green."
    refute Map.has_key?(interleaved_agent, :replace_item_text)

    assert [interleaved_output] =
             Enum.filter(
               reconstructed.transcript.blocks,
               &(Map.get(&1, :item_id) == "cmd-interleaved" and &1.kind == "output")
             )

    assert interleaved_output.text == "canonical interleaved output"

    assert [legacy_agent] =
             Enum.filter(
               reconstructed.transcript.blocks,
               &(Map.get(&1, :item_id) == "legacy-agent" and &1.kind == "agent")
             )

    assert legacy_agent.text == "Legacy coherent message."

    assert [legacy_output] =
             Enum.filter(
               reconstructed.transcript.blocks,
               &(Map.get(&1, :item_id) == "legacy-command" and &1.kind == "output")
             )

    assert legacy_output.text == "legacy-left-right"
    assert issue_html =~ "The changed-scope suite is green."
    assert issue_html =~ "$ mix test interleaved"
    assert issue_html =~ "canonical interleaved output"
    assert issue_html =~ "Legacy coherent message."
    assert issue_html =~ "$ mix test legacy"
    assert issue_html =~ "legacy-left-right"
    assert issue_html =~ "Arguments:"
    assert issue_html =~ "Output:"
    # Every output in this fixture belongs to a command/tool and is folded into
    # that activity; no stream fragment leaks into a standalone Output card.
    refute issue_html =~ "transcript-block-output"

    appended_record = %{
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "event" => "notification",
      "payload" => %{
        "method" => "codex/event/agent_message_content_delta",
        "params" => %{"msg" => %{"content" => " Incremental append is visible."}}
      }
    }

    File.write!(transcript_file, Jason.encode!(appended_record) <> "\n", [:append])
    StatusDashboard.notify_update()

    assert_eventually(fn ->
      render(issue_view) =~ "Incremental append is visible."
    end)

    updated_issue_snapshot =
      put_in(updated_snapshot.running, [
        %{List.first(updated_snapshot.running) | last_codex_timestamp: DateTime.utc_now()}
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_issue_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      rendered = render(issue_view)
      rendered =~ "Investigating the failure and updating the fix." and rendered =~ "$ mix test --cover"
    end)
  end

  test "transcript distinguishes subagent turns from the main agent" do
    parent_thread = "11111111-1111-1111-1111-111111111111"
    parent_turn = "22222222-2222-2222-2222-222222222222"
    session_id = parent_thread <> "-" <> parent_turn
    subagent_thread = "99999999-9999-9999-9999-999999999999"

    transcript_file =
      write_transcript_fixture!([
        agent_delta_record(session_id, "Main agent planning the work", parent_thread, parent_turn),
        agent_delta_record(
          session_id,
          "Subagent exploring the codebase",
          subagent_thread,
          "33333333-3333-3333-3333-333333333333"
        ),
        codex_item_record(
          session_id,
          "item/started",
          parent_thread,
          %{
            "id" => "shared-call-id",
            "type" => "mcpToolCall",
            "server" => "parent",
            "tool" => "lookup",
            "arguments" => %{"scope" => "main"}
          }
        ),
        codex_item_record(
          session_id,
          "item/started",
          subagent_thread,
          %{
            "id" => "shared-call-id",
            "type" => "mcpToolCall",
            "server" => "child",
            "tool" => "lookup",
            "arguments" => %{"scope" => "subagent"}
          }
        ),
        codex_item_record(
          session_id,
          "item/completed",
          parent_thread,
          %{
            "id" => "shared-call-id",
            "type" => "mcpToolCall",
            "result" => %{"content" => [%{"type" => "text", "text" => "parent result"}]}
          }
        ),
        codex_item_record(
          session_id,
          "item/completed",
          subagent_thread,
          %{
            "id" => "shared-call-id",
            "type" => "mcpToolCall",
            "result" => %{"content" => [%{"type" => "text", "text" => "subagent result"}]}
          }
        )
      ])

    orchestrator_name = Module.concat(__MODULE__, :SubagentOrchestrator)

    snapshot = %{
      running: [
        %{
          issue_id: "issue-sub",
          identifier: "SUB-1",
          title: "Has a subagent",
          state: "In Progress",
          session_id: session_id,
          turn_count: 1,
          codex_app_server_pid: nil,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          recent_codex_events: [],
          codex_session_logs: [
            %{
              session_id: session_id,
              path: transcript_file,
              started_at: DateTime.utc_now(),
              last_event_at: DateTime.utc_now(),
              worker_host: nil,
              workspace_path: nil
            }
          ],
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0.0},
      rate_limits: nil
    }

    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)

    {:ok, payload} = SymphonyElixirWeb.Presenter.issue_payload("SUB-1", orchestrator_name, 5_000)
    blocks = payload.transcript.blocks

    assert Enum.any?(blocks, &(&1.text =~ "Main agent planning the work" and &1.subagent == false))

    assert Enum.any?(
             blocks,
             &(&1.text =~ "Subagent exploring the codebase" and &1.subagent == true and
                 &1.thread_id == subagent_thread)
           )

    # Distinct threads must not be merged into a single agent block.
    assert Enum.count(blocks, &(&1.kind == "agent")) == 2

    shared_tools =
      Enum.filter(
        blocks,
        &(Map.get(&1, :tool_call_id) == "shared-call-id" and &1.kind == "tool")
      )

    assert Enum.sort(Enum.map(shared_tools, & &1.title)) == ["child: lookup", "parent: lookup"]

    shared_outputs =
      Enum.filter(
        blocks,
        &(Map.get(&1, :tool_call_id) == "shared-call-id" and &1.kind == "output")
      )

    assert Enum.sort(Enum.map(shared_outputs, & &1.text)) == ["parent result", "subagent result"]

    # The rendered issue page flags the subagent block.
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 5_000)
    {:ok, _view, issue_html} = live(build_conn(), "/issues/SUB-1")
    assert issue_html =~ "transcript-block-subagent"
    assert issue_html =~ "Subagent"
    assert issue_html =~ "Subagent exploring the codebase"
    assert issue_html =~ "parent: lookup"
    assert issue_html =~ "child: lookup"
    assert issue_html =~ "parent result"
    assert issue_html =~ "subagent result"
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200
    assert response.body["counts"] == %{"running" => 1, "queued" => 0, "retrying" => 1, "waiting" => 0}

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  test "http server falls back to loopback when a well-formed host does not resolve" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :UnresolvableHostOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    server_opts = [
      # `.invalid` is reserved (RFC 6761) and never resolves — models a
      # Tailscale MagicDNS host while tailscaled is logged out.
      host: "symphony-test.invalid",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    log =
      capture_log(fn ->
        start_supervised!({HttpServer, server_opts})
        assert is_integer(wait_for_bound_port())
      end)

    assert log =~ "symphony-test.invalid"
    assert log =~ "binding to 127.0.0.1 instead"

    port = HttpServer.bound_port()
    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200
    assert response.body["counts"] == %{"running" => 1, "queued" => 0, "retrying" => 1, "waiting" => 0}
  end

  test "http server also listens on loopback when bound to a non-loopback host" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :LoopbackOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    port = free_tcp_port()

    server_opts = [
      # 127.0.0.2 is a loopback alias that is NOT 127.0.0.1, so the primary
      # listener alone would refuse `localhost`/`127.0.0.1` connections.
      host: "127.0.0.2",
      port: port,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({HttpServer, server_opts})

    assert wait_for_bound_port() == port

    # Reachable via the configured host...
    primary = Req.get!("http://127.0.0.2:#{port}/api/v1/state")
    assert primary.status == 200

    # ...and always via loopback, thanks to the extra listener.
    loopback = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert loopback.status == 200
    assert loopback.body["counts"] == %{"running" => 1, "queued" => 0, "retrying" => 1, "waiting" => 0}
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          title: "Wire up the HTTP server",
          state: "In Progress",
          backend: "claude_code",
          model: "claude-opus-4-8",
          reasoning_effort: "xhigh",
          profile: "deep",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          recent_codex_events: [
            %{
              event: :notification,
              message: %{
                "method" => "codex/event/exec_command_begin",
                "params" => %{"msg" => %{"command" => "mix test"}}
              },
              timestamp: DateTime.utc_now()
            }
          ],
          codex_session_logs: [
            %{
              session_id: "thread-http",
              path: "/tmp/symphony/log/codex_sessions/MT-HTTP--thread-http.ndjson",
              started_at: DateTime.utc_now(),
              last_event_at: DateTime.utc_now(),
              worker_host: nil,
              workspace_path: nil
            }
          ],
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          title: "Retry the flaky migration",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}},
      backend_usage: [
        %{
          backend: "claude_code",
          account_scope: "local",
          worker_host: nil,
          running_agents: 1,
          rate_limits: nil,
          updated_at: nil
        }
      ]
    }
  end

  defp agent_delta_record(session_id, delta, thread_id, turn_id) do
    %{
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "event" => "notification",
      "session_id" => session_id,
      "payload" => %{
        "method" => "item/agentMessage/delta",
        "params" => %{"delta" => delta, "threadId" => thread_id, "turnId" => turn_id}
      }
    }
  end

  defp codex_item_record(session_id, method, thread_id, item) do
    %{
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "event" => "notification",
      "session_id" => session_id,
      "payload" => %{
        "method" => method,
        "params" => %{
          "item" => item,
          "threadId" => thread_id,
          "turnId" => "44444444-4444-4444-4444-444444444444"
        }
      }
    }
  end

  defp write_transcript_fixture!(entries) when is_list(entries) do
    transcript_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-transcript-fixtures-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(transcript_root)
    transcript_file = Path.join(transcript_root, "session.ndjson")

    body =
      Enum.map_join(entries, "\n", &Jason.encode!/1)

    File.write!(transcript_file, body <> "\n")
    transcript_file
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp free_tcp_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, reuseaddr: true)
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
