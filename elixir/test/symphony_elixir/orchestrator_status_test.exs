defmodule SymphonyElixir.OrchestratorStatusTest do
  use SymphonyElixir.TestSupport

  test "snapshot returns :timeout when snapshot server is unresponsive" do
    server_name = Module.concat(__MODULE__, :UnresponsiveSnapshotServer)
    parent = self()

    pid =
      spawn(fn ->
        Process.register(self(), server_name)
        send(parent, :snapshot_server_ready)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :snapshot_server_ready, 1_000
    assert Orchestrator.snapshot(server_name, 10) == :timeout

    send(pid, :stop)
  end

  test "snapshot and API surface repository scheduling waits", _context do
    orchestrator_name = Module.concat(__MODULE__, :SchedulingSnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    queued_at_ms = System.monotonic_time(:millisecond) - 2_000

    :sys.replace_state(pid, fn state ->
      %{
        state
        | queued: %{
            "queued-1" => %{
              issue_id: "queued-1",
              identifier: "UDPE-QUEUE",
              title: "Wait for overlapping work",
              state: "Todo",
              repository_id: "symphony",
              reason: "path_overlap",
              predicted_paths: ["lib/a.ex"],
              overlap_paths: ["lib/a.ex"],
              overlap_score: 1.0,
              suggested_order: ["UDPE-FIRST", "UDPE-QUEUE"],
              suggested_order_omitted: 3,
              override: false,
              policy: "serialize",
              max_concurrent: 2,
              base_age_seconds: 90,
              priority_rank: 2,
              created_at_key: 1,
              queued_at_ms: queued_at_ms
            }
          }
      }
    end)

    assert %{queued: [queued]} = Orchestrator.snapshot(orchestrator_name, 5_000)
    assert queued.reason == "path_overlap"
    assert queued.overlap_paths == ["lib/a.ex"]
    assert queued.base_age_seconds == 90
    assert queued.queue_time_ms >= 2_000

    payload = SymphonyElixirWeb.Presenter.state_payload(orchestrator_name, 5_000)
    assert payload.counts.queued == 1

    assert [
             %{
               issue_identifier: "UDPE-QUEUE",
               suggested_order: ["UDPE-FIRST", "UDPE-QUEUE"],
               suggested_order_omitted: 3
             }
           ] = payload.queued
  end

  test "orchestrator snapshot reflects last codex update and session id" do
    issue_id = "issue-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-188",
      title: "Snapshot test",
      description: "Capture codex state",
      state: "In Progress",
      url: "https://example.org/issues/MT-188"
    }

    orchestrator_name = Module.concat(__MODULE__, :SnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    started_at = DateTime.utc_now()

    review_state = %{
      outcome: "budget_exhausted_with_findings",
      iteration: 3,
      max_iterations: 3,
      reviewed_sha: "abc123exacthead",
      authoritative: false,
      severity_counts: %{"blocker" => 1, "major" => 2},
      failure_reason: "review_budget_exhausted",
      resume_condition: "Human decision required."
    }

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      recent_codex_events: [],
      review_state: review_state,
      started_at: started_at
    }

    state_with_issue =
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))

    :sys.replace_state(pid, fn _ -> state_with_issue end)

    now = DateTime.utc_now()

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :session_started,
         session_id: "thread-live-turn-live",
         timestamp: now
       }}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{method: "some-event"},
         timestamp: now
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.issue_id == issue_id
    assert snapshot_entry.session_id == "thread-live-turn-live"
    assert snapshot_entry.turn_count == 1
    assert snapshot_entry.last_codex_timestamp == now
    assert snapshot_entry.review_state == review_state

    assert snapshot_entry.last_codex_message == %{
             event: :notification,
             message: %{method: "some-event"},
             timestamp: now
           }

    assert snapshot_entry.recent_codex_events == [
             %{
               event: :session_started,
               message: %{session_id: "thread-live-turn-live"},
               timestamp: now
             },
             %{
               event: :notification,
               message: %{method: "some-event"},
               timestamp: now
             }
           ]

    state_payload =
      SymphonyElixirWeb.Presenter.state_payload(orchestrator_name, 5_000)

    assert [%{review: ^review_state}] = state_payload.running

    assert {:ok, %{running: %{review: ^review_state}}} =
             SymphonyElixirWeb.Presenter.issue_payload(issue.identifier, orchestrator_name, 5_000)
  end

  test "orchestrator snapshot captures the actual backend and model" do
    issue_id = "issue-agent-meta"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-200",
      title: "Agent meta test",
      description: "Capture backend/model",
      state: "In Progress",
      url: "https://example.org/issues/MT-200"
    }

    orchestrator_name = Module.concat(__MODULE__, :AgentMetaOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      backend: nil,
      model: nil,
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      recent_codex_events: [],
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn state ->
      state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    # AgentRunner reports the resolved backend + configured model/effort out-of-band.
    send(
      pid,
      {:worker_runtime_info, issue_id, %{backend: "claude_code", model: "opus", reasoning_effort: "high", profile: "standard"}}
    )

    # The agent then reports the model it actually resolved on `:session_started`,
    # which refines the configured value.
    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :session_started,
         session_id: "claude-session-1",
         model: "claude-opus-4-8",
         reasoning_effort: "xhigh",
         timestamp: DateTime.utc_now()
       }}
    )

    assert %{running: [snapshot_entry]} = GenServer.call(pid, :snapshot)
    assert snapshot_entry.backend == "claude_code"
    assert snapshot_entry.model == "claude-opus-4-8"
    assert snapshot_entry.reasoning_effort == "xhigh"
    assert snapshot_entry.profile == "standard"
  end

  test "orchestrator snapshot keeps the configured model when the agent reports none" do
    issue_id = "issue-agent-meta-codex"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-201",
      title: "Agent meta codex",
      description: "Configured model only",
      state: "In Progress",
      url: "https://example.org/issues/MT-201"
    }

    orchestrator_name = Module.concat(__MODULE__, :AgentMetaCodexOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      backend: nil,
      model: nil,
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      recent_codex_events: [],
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn state ->
      state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:worker_runtime_info, issue_id, %{backend: "acp", model: "opencode/north-mini-code-free", reasoning_effort: "high"}}
    )

    # A session_started without a model must not clobber the configured one.
    send(
      pid,
      {:codex_worker_update, issue_id, %{event: :session_started, session_id: "acp-session-1", timestamp: DateTime.utc_now()}}
    )

    assert %{running: [snapshot_entry]} = GenServer.call(pid, :snapshot)
    assert snapshot_entry.backend == "acp"
    assert snapshot_entry.model == "opencode/north-mini-code-free"
    assert snapshot_entry.reasoning_effort == "high"
  end

  test "orchestrator snapshot retains a bounded recent codex event history" do
    issue_id = "issue-event-history"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-189",
      title: "Event history test",
      description: "Retain recent codex updates",
      state: "In Progress",
      url: "https://example.org/issues/MT-189"
    }

    orchestrator_name = Module.concat(__MODULE__, :EventHistoryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      recent_codex_events: [],
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    for index <- 1..205 do
      send(
        pid,
        {:codex_worker_update, issue_id,
         %{
           event: :notification,
           payload: %{
             "method" => "codex/event/agent_message_delta",
             "params" => %{"msg" => %{"payload" => %{"delta" => "event-#{index}"}}}
           },
           timestamp: DateTime.utc_now()
         }}
      )
    end

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert length(snapshot_entry.recent_codex_events) == 200
    assert hd(snapshot_entry.recent_codex_events).message["params"]["msg"]["payload"]["delta"] == "event-6"
    assert List.last(snapshot_entry.recent_codex_events).message["params"]["msg"]["payload"]["delta"] == "event-205"
  end

  test "orchestrator writes codex session transcripts under the logs root" do
    issue_id = "issue-transcript"
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-codex-transcript-#{System.unique_integer([:positive])}")
    log_file = Path.join([test_root, "log", "symphony.log"])
    previous_log_file = Application.get_env(:symphony_elixir, :log_file)

    on_exit(fn ->
      if is_nil(previous_log_file) do
        Application.delete_env(:symphony_elixir, :log_file)
      else
        Application.put_env(:symphony_elixir, :log_file, previous_log_file)
      end

      File.rm_rf(test_root)
    end)

    Application.put_env(:symphony_elixir, :log_file, log_file)

    issue = %Issue{
      id: issue_id,
      identifier: "MT-190",
      title: "Transcript persistence test",
      description: "Write codex transcript events to disk",
      state: "In Progress",
      url: "https://example.org/issues/MT-190"
    }

    orchestrator_name = Module.concat(__MODULE__, :TranscriptOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      recent_codex_events: [],
      codex_session_logs: [],
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    now = DateTime.utc_now()

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :session_started,
         session_id: "thread-log-turn-log",
         timestamp: now
       }}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "codex/event/exec_command_begin",
           "params" => %{"msg" => %{"command" => "mix test"}}
         },
         timestamp: now
       }}
    )

    deferred_result = %{
      "success" => true,
      "status" => "deferred_review_started",
      "issueIdentifier" => issue.identifier,
      "review" => %{"deferred" => true},
      "instructions" => "End the turn now. Do not retry the Linear handoff mutation."
    }

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :tool_call_completed,
         payload: %{
           "method" => "item/tool/call",
           "params" => %{"tool" => "linear_graphql"}
         },
         details: %{
           result: %{
             "success" => true,
             "output" => deferred_result
           }
         },
         timestamp: now
       }}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "thread/compacted",
           "params" => %{"threadId" => "thread-log", "turnId" => "turn-log-compact"}
         },
         timestamp: now
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert [session_log] = snapshot_entry.codex_session_logs
    assert session_log.session_id == "thread-log-turn-log"
    assert File.exists?(session_log.path)
    assert String.starts_with?(session_log.path, Path.join(test_root, "log/codex_sessions"))
    assert Enum.any?(snapshot_entry.recent_codex_transcript_blocks, &(&1.kind == "compaction"))

    lines =
      session_log.path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert Enum.map(lines, & &1["event"]) == [
             "session_started",
             "notification",
             "tool_call_completed",
             "notification"
           ]

    assert Enum.all?(lines, &(&1["issue_id"] == issue_id))
    assert Enum.all?(lines, &(&1["session_id"] == "thread-log-turn-log"))

    persisted_tool_result =
      lines
      |> Enum.find(&(&1["event"] == "tool_call_completed"))
      |> get_in(["details", "result"])

    assert persisted_tool_result["success"] == true
    assert persisted_tool_result["output"] == deferred_result
    assert List.last(lines)["summary"] == "thread/compacted"
  end

  test "orchestrator renders native ACP session/update notifications into transcript blocks" do
    issue_id = "issue-acp-transcript"

    issue = %Issue{
      id: issue_id,
      identifier: "ACP-7",
      title: "Native ACP transcript",
      description: "Render session/update natively",
      state: "In Progress",
      url: "https://example.org/issues/ACP-7"
    }

    orchestrator_name = Module.concat(__MODULE__, :AcpTranscriptOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      recent_codex_events: [],
      codex_session_logs: [],
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    now = DateTime.utc_now()

    send(pid, {:codex_worker_update, issue_id, %{event: :session_started, session_id: "sess-acp", timestamp: now}})

    acp_update = fn update ->
      %{
        event: :notification,
        payload: %{"method" => "session/update", "params" => %{"sessionId" => "sess-acp", "update" => update}},
        timestamp: now
      }
    end

    send(pid, {:codex_worker_update, issue_id, acp_update.(%{"sessionUpdate" => "agent_message_chunk", "content" => %{"type" => "text", "text" => "Done."}})})

    send(
      pid,
      {:codex_worker_update, issue_id, acp_update.(%{"sessionUpdate" => "tool_call", "toolCallId" => "tc-1", "title" => "Update README", "kind" => "edit", "rawInput" => %{"path" => "README.md"}})}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       acp_update.(%{"sessionUpdate" => "plan", "entries" => [%{"content" => "write tests", "status" => "completed"}, %{"content" => "ship it", "status" => "pending"}]})}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    blocks = snapshot_entry.recent_codex_transcript_blocks

    assert Enum.any?(blocks, &(&1.kind == "agent" and &1.text == "Done."))

    tool_block = Enum.find(blocks, &(&1.kind == "tool"))
    assert tool_block.title == "edit: Update README"

    plan_block = Enum.find(blocks, &(&1.kind == "plan"))
    assert plan_block.text =~ "- [x] write tests"
    assert plan_block.text =~ "- [ ] ship it"
  end

  test "orchestrator renders codex item-lifecycle tool calls into transcript blocks" do
    issue_id = "issue-codex-items"

    issue = %Issue{
      id: issue_id,
      identifier: "CDX-7",
      title: "Codex item transcript",
      description: "Render item/started + item/completed tool calls",
      state: "In Progress",
      url: "https://example.org/issues/CDX-7"
    }

    orchestrator_name = Module.concat(__MODULE__, :CodexItemTranscriptOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      recent_codex_events: [],
      codex_session_logs: [],
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    now = DateTime.utc_now()

    send(pid, {:codex_worker_update, issue_id, %{event: :session_started, session_id: "sess-cdx", timestamp: now}})

    notification = fn payload ->
      %{event: :notification, payload: payload, timestamp: now}
    end

    item = fn method, item_map ->
      notification.(%{"method" => method, "params" => %{"item" => item_map}})
    end

    threaded_item = fn method, thread_id, item_map ->
      notification.(%{
        "method" => method,
        "params" => %{"threadId" => thread_id, "item" => item_map}
      })
    end

    # A long-running command can keep streaming output while an agent message is
    # emitted. Group both streams by item id rather than splitting on every
    # interleave (the exact shape seen in UDPE-6776).
    send(pid, {:codex_worker_update, issue_id, item.("item/started", %{"id" => "c1", "type" => "commandExecution", "command" => "mix test"})})
    send(pid, {:codex_worker_update, issue_id, notification.(%{"method" => "item/commandExecution/outputDelta", "params" => %{"itemId" => "c1", "delta" => "alpha"}})})
    send(pid, {:codex_worker_update, issue_id, item.("item/started", %{"id" => "a1", "type" => "agentMessage", "phase" => "commentary"})})
    send(pid, {:codex_worker_update, issue_id, notification.(%{"method" => "item/agentMessage/delta", "params" => %{"itemId" => "a1", "delta" => "The changed-s"}})})
    send(pid, {:codex_worker_update, issue_id, notification.(%{"method" => "item/commandExecution/outputDelta", "params" => %{"itemId" => "c1", "delta" => "beta"}})})
    send(pid, {:codex_worker_update, issue_id, notification.(%{"method" => "item/agentMessage/delta", "params" => %{"itemId" => "a1", "delta" => "cope suite"}})})

    partial_snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [partial_entry]} = partial_snapshot

    assert [partial_agent] =
             Enum.filter(
               partial_entry.recent_codex_transcript_blocks,
               &(Map.get(&1, :item_id) == "a1" and &1.kind == "agent")
             )

    assert partial_agent.text == "The changed-scope suite"

    assert [partial_output] =
             Enum.filter(
               partial_entry.recent_codex_transcript_blocks,
               &(Map.get(&1, :item_id) == "c1" and &1.kind == "output")
             )

    assert partial_output.text == "alphabeta"

    # Completion payloads are authoritative and replace (rather than duplicate)
    # the accumulated deltas.
    send(pid, {:codex_worker_update, issue_id, item.("item/completed", %{"id" => "a1", "type" => "agentMessage", "phase" => "commentary", "text" => "The changed-scope suite is green."})})
    send(pid, {:codex_worker_update, issue_id, item.("item/completed", %{"id" => "c1", "type" => "commandExecution", "command" => "mix test", "aggregatedOutput" => "1 test, 0 failures"})})
    send(pid, {:codex_worker_update, issue_id, item.("item/started", %{"id" => "f1", "type" => "fileChange", "changes" => [%{"path" => "lib/a.ex", "diff" => "@@\n+x"}]})})

    send(
      pid,
      {:codex_worker_update, issue_id,
       threaded_item.("item/started", "thread-parent", %{"id" => "m1", "type" => "mcpToolCall", "server" => "sentry", "tool" => "get_issue", "arguments" => %{"id" => 7}})}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       threaded_item.("item/started", "thread-child", %{"id" => "m1", "type" => "mcpToolCall", "server" => "github", "tool" => "get_pr", "arguments" => %{"number" => 8}})}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       threaded_item.("item/completed", "thread-parent", %{"id" => "m1", "type" => "mcpToolCall", "result" => %{"content" => [%{"type" => "text", "text" => "MCP-RESULT"}]}})}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       threaded_item.("item/completed", "thread-child", %{"id" => "m1", "type" => "mcpToolCall", "result" => %{"content" => [%{"type" => "text", "text" => "CHILD-RESULT"}]}})}
    )

    # dynamicToolCall is dispatched via item/tool/call and must not double up.
    send(pid, {:codex_worker_update, issue_id, item.("item/started", %{"id" => "d1", "type" => "dynamicToolCall", "tool" => "linear_graphql"})})

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    blocks = snapshot_entry.recent_codex_transcript_blocks

    command_block = Enum.find(blocks, &(&1.kind == "command"))
    assert command_block.text == "$ mix test"
    command_index = Enum.find_index(blocks, &(&1.kind == "command"))
    output_index = Enum.find_index(blocks, &(&1.kind == "output" and &1.text =~ "1 test, 0 failures"))
    assert command_index < output_index

    assert [agent_block] =
             Enum.filter(blocks, &(Map.get(&1, :item_id) == "a1" and &1.kind == "agent"))

    assert agent_block.text == "The changed-scope suite is green."

    assert [command_output] =
             Enum.filter(blocks, &(Map.get(&1, :item_id) == "c1" and &1.kind == "output"))

    assert command_output.text == "1 test, 0 failures"

    file_block = Enum.find(blocks, &(&1.kind == "tool" and &1.title == "edit: a.ex"))
    assert file_block.text =~ "+x"

    mcp_call = Enum.find(blocks, &(&1.kind == "tool" and &1.title == "sentry: get_issue"))
    assert mcp_call
    assert Enum.any?(blocks, &(&1.kind == "tool" and &1.title == "github: get_pr"))
    assert Enum.any?(blocks, &(&1.kind == "output" and &1.text == "MCP-RESULT"))
    assert Enum.any?(blocks, &(&1.kind == "output" and &1.text == "CHILD-RESULT"))

    refute Enum.any?(blocks, &(Map.get(&1, :title) == "linear_graphql"))
  end

  test "orchestrator snapshot tracks codex thread totals and app-server pid" do
    issue_id = "issue-usage-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-201",
      title: "Usage snapshot test",
      description: "Collect usage stats",
      state: "In Progress",
      url: "https://example.org/issues/MT-201"
    }

    orchestrator_name = Module.concat(__MODULE__, :UsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    now = DateTime.utc_now()

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :session_started,
         session_id: "thread-usage-turn-usage",
         timestamp: now
       }}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "thread/tokenUsage/updated",
           "params" => %{
             "tokenUsage" => %{
               "total" => %{"inputTokens" => 12, "outputTokens" => 4, "totalTokens" => 16},
               "last" => %{"inputTokens" => 9, "outputTokens" => 4, "totalTokens" => 13},
               "model_context_window" => 1_000_000
             }
           }
         },
         timestamp: now,
         codex_app_server_pid: "4242"
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_app_server_pid == "4242"
    assert snapshot_entry.codex_input_tokens == 12
    assert snapshot_entry.codex_output_tokens == 4
    assert snapshot_entry.codex_total_tokens == 16
    assert snapshot_entry.codex_context_tokens == 9
    assert snapshot_entry.codex_context_window == 1_000_000
    assert snapshot_entry.turn_count == 1
    assert is_integer(snapshot_entry.runtime_seconds)

    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = :sys.get_state(pid)

    assert completed_state.codex_totals.input_tokens == 12
    assert completed_state.codex_totals.output_tokens == 4
    assert completed_state.codex_totals.total_tokens == 16
    assert is_integer(completed_state.codex_totals.seconds_running)
  end

  test "orchestrator counts token usage reported by non-Codex backends" do
    issue_id = "issue-acp-usage"

    issue = %Issue{
      id: issue_id,
      identifier: "ACP-9",
      title: "ACP usage",
      description: "Count ACP/Claude usage",
      state: "In Progress",
      url: "https://example.org/issues/ACP-9"
    }

    orchestrator_name = Module.concat(__MODULE__, :AcpUsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    now = DateTime.utc_now()
    send(pid, {:codex_worker_update, issue_id, %{event: :session_started, session_id: "sess-acp", timestamp: now}})

    # ACP `usage_update` carries the counts under `params.update.usage`.
    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "session/update",
           "params" => %{
             "sessionId" => "sess-acp",
             "update" => %{"sessionUpdate" => "usage_update", "usage" => %{"input_tokens" => 30, "output_tokens" => 10, "total_tokens" => 40}}
           }
         },
         timestamp: now
       }}
    )

    # A backend may instead hand us a flat usage map (Claude Code `result.usage`)
    # with no total — the total is synthesized from input + output.
    send(
      pid,
      {:codex_worker_update, issue_id, %{event: :notification, usage: %{"input_tokens" => 130, "output_tokens" => 35}, timestamp: now}}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 130
    assert snapshot_entry.codex_output_tokens == 35
    assert snapshot_entry.codex_total_tokens == 165
  end

  test "orchestrator fills ACP tool arguments from updates and de-duplicates cumulative output" do
    issue_id = "issue-acp-tool"

    issue = %Issue{
      id: issue_id,
      identifier: "ACP-8",
      title: "ACP tool lifecycle",
      description: "Merge tool_call + tool_call_update",
      state: "In Progress",
      url: "https://example.org/issues/ACP-8"
    }

    orchestrator_name = Module.concat(__MODULE__, :AcpToolOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      recent_codex_events: [],
      codex_session_logs: [],
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    now = DateTime.utc_now()
    send(pid, {:codex_worker_update, issue_id, %{event: :session_started, session_id: "sess-acp", timestamp: now}})

    acp_update = fn update ->
      %{
        event: :notification,
        payload: %{"method" => "session/update", "params" => %{"sessionId" => "sess-acp", "update" => update}},
        timestamp: now
      }
    end

    # ACP sends the initial tool_call with an empty rawInput; the arguments and
    # the (cumulative) output then stream in via tool_call_update.
    send(pid, {:codex_worker_update, issue_id, acp_update.(%{"sessionUpdate" => "tool_call", "toolCallId" => "tc-9", "kind" => "read", "title" => "read", "rawInput" => %{}})})
    send(pid, {:codex_worker_update, issue_id, acp_update.(%{"sessionUpdate" => "tool_call_update", "toolCallId" => "tc-9", "rawInput" => %{"filePath" => "lib/foo.ex"}})})
    send(pid, {:codex_worker_update, issue_id, acp_update.(%{"sessionUpdate" => "tool_call_update", "toolCallId" => "tc-9", "content" => %{"type" => "text", "text" => "alpha\n"}})})
    send(pid, {:codex_worker_update, issue_id, acp_update.(%{"sessionUpdate" => "tool_call_update", "toolCallId" => "tc-9", "content" => %{"type" => "text", "text" => "alpha\nbeta\n"}})})

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    blocks = snapshot_entry.recent_codex_transcript_blocks

    tool_blocks = Enum.filter(blocks, &(&1.kind == "tool" and Map.get(&1, :tool_call_id) == "tc-9"))
    assert length(tool_blocks) == 1
    assert hd(tool_blocks).text =~ "lib/foo.ex"

    output_blocks = Enum.filter(blocks, &(&1.kind == "output" and Map.get(&1, :tool_call_id) == "tc-9"))
    assert length(output_blocks) == 1
    output_text = hd(output_blocks).text
    assert output_text =~ "beta"
    # Cumulative output is replaced, not concatenated — "alpha" appears once.
    assert length(String.split(output_text, "alpha")) == 2
  end

  test "orchestrator context occupancy tracks the main thread and ignores subagents" do
    issue_id = "issue-context-occupancy"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-211",
      title: "Context occupancy test",
      description: "Track main-thread context fill",
      state: "In Progress",
      url: "https://example.org/issues/MT-211"
    }

    orchestrator_name = Module.concat(__MODULE__, :ContextOccupancyOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    main_thread = "11111111-1111-1111-1111-111111111111"
    subagent_thread = "99999999-9999-9999-9999-999999999999"
    session_id = main_thread <> "-22222222-2222-2222-2222-222222222222"

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: session_id,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      codex_context_tokens: 0,
      codex_context_window: nil,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    now = DateTime.utc_now()

    token_usage_update = fn thread_id, input, window ->
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "thread/tokenUsage/updated",
           "params" => %{
             "thread_id" => thread_id,
             "tokenUsage" => %{
               "total" => %{"inputTokens" => input, "outputTokens" => 4, "totalTokens" => input + 4},
               "last" => %{"inputTokens" => input, "outputTokens" => 4, "totalTokens" => input + 4},
               "model_context_window" => window
             }
           }
         },
         timestamp: now
       }}
    end

    send(pid, token_usage_update.(main_thread, 100, 500_000))
    send(pid, token_usage_update.(subagent_thread, 999_999, 200_000))

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_context_tokens == 100
    assert snapshot_entry.codex_context_window == 500_000
  end

  test "orchestrator snapshot tracks turn completed usage when present" do
    issue_id = "issue-turn-completed-usage"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-202",
      title: "Turn completed usage test",
      description: "Track final turn usage",
      state: "In Progress",
      url: "https://example.org/issues/MT-202"
    }

    orchestrator_name = Module.concat(__MODULE__, :TurnCompletedUsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :turn_completed,
         payload: %{
           method: "turn/completed",
           usage: %{"input_tokens" => "12", "output_tokens" => 4, "total_tokens" => 16}
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 12
    assert snapshot_entry.codex_output_tokens == 4
    assert snapshot_entry.codex_total_tokens == 16

    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = :sys.get_state(pid)
    assert completed_state.codex_totals.input_tokens == 12
    assert completed_state.codex_totals.output_tokens == 4
    assert completed_state.codex_totals.total_tokens == 16
  end

  test "orchestrator snapshot tracks codex token-count cumulative usage payloads" do
    issue_id = "issue-token-count-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-220",
      title: "Token count snapshot test",
      description: "Validate token-count style payloads",
      state: "In Progress",
      url: "https://example.org/issues/MT-220"
    }

    orchestrator_name = Module.concat(__MODULE__, :TokenCountOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    now = DateTime.utc_now()

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "token_count",
               "info" => %{
                 "total_token_usage" => %{
                   "input_tokens" => "2",
                   "output_tokens" => 2,
                   "total_tokens" => 4
                 }
               }
             }
           }
         },
         timestamp: now
       }}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "token_count",
               "info" => %{
                 "total_token_usage" => %{
                   "prompt_tokens" => 10,
                   "completion_tokens" => 5,
                   "total_tokens" => 15
                 }
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 10
    assert snapshot_entry.codex_output_tokens == 5
    assert snapshot_entry.codex_total_tokens == 15

    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = :sys.get_state(pid)

    assert completed_state.codex_totals.input_tokens == 10
    assert completed_state.codex_totals.output_tokens == 5
    assert completed_state.codex_totals.total_tokens == 15
  end

  test "orchestrator snapshot tracks codex rate-limit payloads" do
    issue_id = "issue-rate-limit-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-221",
      title: "Rate limit snapshot test",
      description: "Capture codex rate limit state",
      state: "In Progress",
      url: "https://example.org/issues/MT-221"
    }

    orchestrator_name = Module.concat(__MODULE__, :RateLimitOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      backend: "codex",
      worker_host: nil,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    rate_limits = %{
      "limit_id" => "codex",
      "primary" => %{"remaining" => 90, "limit" => 100},
      "secondary" => nil,
      "credits" => %{"has_credits" => false, "unlimited" => false, "balance" => nil}
    }

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "event_msg",
               "payload" => %{
                 "type" => "token_count",
                 "rate_limits" => rate_limits
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.rate_limits == rate_limits

    assert [usage] = snapshot.backend_usage
    assert usage.backend == "codex"
    assert usage.account_scope == "local"
    assert usage.running_agents == 1
    assert usage.rate_limits == rate_limits
    assert %DateTime{} = usage.updated_at

    claude_issue_id = "issue-claude-rate-limit-snapshot"

    :sys.replace_state(pid, fn state ->
      claude_entry =
        Map.merge(running_entry, %{
          identifier: "MT-CLAUDE",
          backend: "claude_code",
          worker_host: nil
        })

      %{state | running: Map.put(state.running, claude_issue_id, claude_entry)}
    end)

    claude_rate_limits = %{
      "five_hour" => %{"used_percentage" => 24, "resets_at" => 1_800_000_000},
      "seven_day" => %{"used_percentage" => 62, "resets_at" => 1_800_100_000}
    }

    send(
      pid,
      {:codex_worker_update, claude_issue_id,
       %{
         event: :notification,
         payload: %{"type" => "rate_limit_event", "rate_limits" => claude_rate_limits},
         timestamp: DateTime.utc_now()
       }}
    )

    remote_codex_issue_id = "issue-remote-codex-rate-limit-snapshot"
    remote_rate_limits = put_in(rate_limits, ["primary", "remaining"], 40)

    :sys.replace_state(pid, fn state ->
      remote_entry =
        Map.merge(running_entry, %{
          identifier: "MT-REMOTE-CODEX",
          backend: "codex",
          worker_host: "worker-a"
        })

      %{state | running: Map.put(state.running, remote_codex_issue_id, remote_entry)}
    end)

    send(
      pid,
      {:codex_worker_update, remote_codex_issue_id,
       %{
         event: :notification,
         payload: %{"rate_limits" => remote_rate_limits},
         timestamp: DateTime.utc_now()
       }}
    )

    usage_by_backend_scope =
      pid
      |> GenServer.call(:snapshot)
      |> Map.fetch!(:backend_usage)
      |> Map.new(&{{&1.backend, &1.account_scope}, &1})

    assert usage_by_backend_scope[{"codex", "local"}].rate_limits == rate_limits
    assert usage_by_backend_scope[{"codex", "worker:worker-a"}].rate_limits == remote_rate_limits
    assert usage_by_backend_scope[{"claude_code", "local"}].rate_limits == claude_rate_limits
  end

  test "orchestrator token accounting prefers total_token_usage over last_token_usage in token_count payloads" do
    issue_id = "issue-token-precedence"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-222",
      title: "Token precedence",
      description: "Prefer per-event deltas",
      state: "In Progress",
      url: "https://example.org/issues/MT-222"
    }

    orchestrator_name = Module.concat(__MODULE__, :TokenPrecedenceOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "event_msg",
               "payload" => %{
                 "type" => "token_count",
                 "info" => %{
                   "last_token_usage" => %{
                     "input_tokens" => 2,
                     "output_tokens" => 1,
                     "total_tokens" => 3
                   },
                   "total_token_usage" => %{
                     "input_tokens" => 200,
                     "output_tokens" => 100,
                     "total_tokens" => 300
                   }
                 }
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 200
    assert snapshot_entry.codex_output_tokens == 100
    assert snapshot_entry.codex_total_tokens == 300
  end

  test "orchestrator token accounting accumulates monotonic thread token usage totals" do
    issue_id = "issue-thread-token-usage"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-223",
      title: "Thread token usage",
      description: "Accumulate absolute thread totals",
      state: "In Progress",
      url: "https://example.org/issues/MT-223"
    }

    orchestrator_name = Module.concat(__MODULE__, :ThreadTokenUsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    for usage <- [
          %{"input_tokens" => 8, "output_tokens" => 3, "total_tokens" => 11},
          %{"input_tokens" => 10, "output_tokens" => 4, "total_tokens" => 14}
        ] do
      send(
        pid,
        {:codex_worker_update, issue_id,
         %{
           event: :notification,
           payload: %{
             "method" => "thread/tokenUsage/updated",
             "params" => %{"tokenUsage" => %{"total" => usage}}
           },
           timestamp: DateTime.utc_now()
         }}
      )
    end

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 10
    assert snapshot_entry.codex_output_tokens == 4
    assert snapshot_entry.codex_total_tokens == 14
  end

  test "orchestrator token accounting ignores last_token_usage without cumulative totals" do
    issue_id = "issue-last-token-ignored"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-224",
      title: "Last token ignored",
      description: "Ignore delta-only token reports",
      state: "In Progress",
      url: "https://example.org/issues/MT-224"
    }

    orchestrator_name = Module.concat(__MODULE__, :LastTokenIgnoredOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "event_msg",
               "payload" => %{
                 "type" => "token_count",
                 "info" => %{
                   "last_token_usage" => %{
                     "input_tokens" => 8,
                     "output_tokens" => 3,
                     "total_tokens" => 11
                   }
                 }
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 0
    assert snapshot_entry.codex_output_tokens == 0
    assert snapshot_entry.codex_total_tokens == 0
  end

  test "orchestrator snapshot includes retry backoff entries" do
    orchestrator_name = Module.concat(__MODULE__, :RetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    retry_entry = %{
      attempt: 2,
      timer_ref: nil,
      due_at_ms: System.monotonic_time(:millisecond) + 5_000,
      identifier: "MT-500",
      error: "agent exited: :boom"
    }

    initial_state = :sys.get_state(pid)
    new_state = %{initial_state | retry_attempts: %{"mt-500" => retry_entry}}
    :sys.replace_state(pid, fn _ -> new_state end)

    snapshot = GenServer.call(pid, :snapshot)
    assert is_list(snapshot.retrying)

    assert [
             %{
               issue_id: "mt-500",
               attempt: 2,
               due_in_ms: due_in_ms,
               identifier: "MT-500",
               error: "agent exited: :boom"
             }
           ] = snapshot.retrying

    assert due_in_ms > 0
  end

  test "orchestrator snapshot includes poll countdown and checking status" do
    orchestrator_name = Module.concat(__MODULE__, :PollingSnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    now_ms = System.monotonic_time(:millisecond)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | poll_interval_ms: 30_000,
          tick_timer_ref: nil,
          tick_token: make_ref(),
          next_poll_due_at_ms: now_ms + 4_000,
          poll_check_in_progress: false
      }
    end)

    snapshot = GenServer.call(pid, :snapshot)

    assert %{
             polling: %{
               checking?: false,
               poll_interval_ms: 30_000,
               next_poll_in_ms: due_in_ms
             }
           } = snapshot

    assert is_integer(due_in_ms)
    assert due_in_ms >= 0
    assert due_in_ms <= 4_000

    :sys.replace_state(pid, fn state ->
      %{state | poll_check_in_progress: true, next_poll_due_at_ms: nil}
    end)

    snapshot = GenServer.call(pid, :snapshot)
    assert %{polling: %{checking?: true, next_poll_in_ms: nil}} = snapshot
  end

  test "orchestrator triggers an immediate poll cycle shortly after startup" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_ms: 5_000
    )

    orchestrator_name = Module.concat(__MODULE__, :ImmediateStartupOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    assert %{
             polling: %{
               checking?: false,
               next_poll_in_ms: next_poll_in_ms,
               poll_interval_ms: 5_000
             }
           } =
             wait_for_snapshot(
               pid,
               fn
                 %{polling: %{checking?: false, next_poll_in_ms: due_in_ms}}
                 when is_integer(due_in_ms) and due_in_ms > 0 and due_in_ms <= 5_000 ->
                   true

                 _ ->
                   false
               end,
               2_000
             )

    assert is_integer(next_poll_in_ms)
    assert next_poll_in_ms >= 0
  end

  test "orchestrator poll cycle resets next refresh countdown after a check" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_ms: 50
    )

    orchestrator_name = Module.concat(__MODULE__, :PollCycleOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | poll_interval_ms: 50,
          poll_check_in_progress: true,
          next_poll_due_at_ms: nil
      }
    end)

    send(pid, :run_poll_cycle)

    snapshot =
      wait_for_snapshot(pid, fn
        %{polling: %{checking?: false, poll_interval_ms: 50, next_poll_in_ms: next_poll_in_ms}}
        when is_integer(next_poll_in_ms) and next_poll_in_ms <= 50 ->
          true

        _ ->
          false
      end)

    assert %{
             polling: %{
               checking?: false,
               poll_interval_ms: 50,
               next_poll_in_ms: next_poll_in_ms
             }
           } = snapshot

    assert is_integer(next_poll_in_ms)
    assert next_poll_in_ms >= 0
    assert next_poll_in_ms <= 50
  end

  test "orchestrator restarts stalled workers with retry backoff" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      codex_stall_timeout_ms: 1_000
    )

    issue_id = "issue-stall"
    orchestrator_name = Module.concat(__MODULE__, :StallOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    worker_pid =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    stale_activity_at = DateTime.add(DateTime.utc_now(), -5, :second)
    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: "MT-STALL",
      issue: %Issue{id: issue_id, identifier: "MT-STALL", state: "In Progress"},
      session_id: "thread-stall-turn-stall",
      last_codex_message: nil,
      last_codex_timestamp: stale_activity_at,
      last_codex_event: :notification,
      started_at: stale_activity_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, :tick)
    Process.sleep(100)
    state = :sys.get_state(pid)

    refute Process.alive?(worker_pid)
    refute Map.has_key?(state.running, issue_id)

    assert %{
             attempt: 1,
             due_at_ms: due_at_ms,
             identifier: "MT-STALL",
             error: "stalled for " <> _
           } = state.retry_attempts[issue_id]

    assert is_integer(due_at_ms)
    remaining_ms = due_at_ms - System.monotonic_time(:millisecond)
    assert remaining_ms >= 9_500
    assert remaining_ms <= 10_500
  end

  test "pending handoff review suppresses implementor stall restart" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      codex_stall_timeout_ms: 1_000
    )

    issue_id = "issue-pending-review"
    orchestrator_name = Module.concat(__MODULE__, :PendingReviewOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    parent = self()

    worker_pid =
      spawn(fn ->
        receive do
          {:start_review, orchestrator} ->
            result =
              GenServer.call(
                orchestrator,
                {:agent_lifecycle, issue_id, :handoff_pending_review,
                 %{
                   timeout_ms: 30_000,
                   review_job_id: 17,
                   review_key: {:pull_request, issue_id, "PR_17", "head-17"}
                 }}
              )

            send(parent, {:review_started, result})
        end

        receive do
          :done -> :ok
        end
      end)

    stale_activity_at = DateTime.add(DateTime.utc_now(), -5, :second)
    initial_state = :sys.get_state(pid)

    issue = %Issue{id: issue_id, identifier: "MT-REVIEW", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: "MT-REVIEW",
      issue: issue,
      session_id: "thread-review-turn-review",
      last_codex_message: nil,
      last_codex_timestamp: stale_activity_at,
      last_codex_event: :turn_completed,
      lifecycle_state: :implementing,
      lifecycle_started_at: stale_activity_at,
      started_at: stale_activity_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(worker_pid, {:start_review, pid})
    assert_receive {:review_started, :ok}, 1_000

    send(pid, :tick)
    Process.sleep(100)
    state = :sys.get_state(pid)

    assert Process.alive?(worker_pid)
    assert state.running[issue_id].lifecycle_state == :handoff_pending_review
    assert state.running[issue_id].handoff_review_job_id == 17
    assert MapSet.member?(state.claimed, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)

    send(worker_pid, :done)
  end

  test "normal worker exit after waiting lifecycle parks the issue without a retry or agent slot" do
    issue_id = "issue-parked-wait"
    orchestrator_name = Module.concat(__MODULE__, :ParkedWaitOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    previous_probe = Application.get_env(:symphony_elixir, :wait_condition_probe)

    Application.put_env(:symphony_elixir, :wait_condition_probe, fn _request ->
      {:unchanged, %{"status" => "degraded"}}
    end)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      SymphonyElixir.WaitWatcher.acknowledge(issue_id)

      if is_nil(previous_probe) do
        Application.delete_env(:symphony_elixir, :wait_condition_probe)
      else
        Application.put_env(:symphony_elixir, :wait_condition_probe, previous_probe)
      end
    end)

    parent = self()

    worker_pid =
      spawn(fn ->
        receive do
          {:park, orchestrator, request} ->
            result =
              GenServer.call(
                orchestrator,
                {:agent_lifecycle, issue_id, :waiting, %{request: request}}
              )

            send(parent, {:parked_lifecycle, result})

            receive do
              :done -> :ok
            end
        end
      end)

    ref = make_ref()
    started_at = DateTime.utc_now()

    issue = %Issue{
      id: issue_id,
      identifier: "UDPE-WAIT-PARKED",
      title: "Park without polling",
      state: "In Progress",
      priority: 1,
      created_at: started_at
    }

    running_entry = %{
      pid: worker_pid,
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: "thread-waiting",
      backend: "codex",
      worker_host: nil,
      workspace_path: "/tmp/UDPE-WAIT-PARKED",
      codex_session_logs: [],
      recent_codex_transcript_blocks: [],
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      lifecycle_state: :implementing,
      lifecycle_started_at: started_at,
      started_at: started_at
    }

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: Map.put(state.running, issue_id, running_entry),
          claimed: MapSet.put(state.claimed, issue_id)
      }
    end)

    request = %{
      condition: %{"type" => "github_actions_recovered", "component" => "Actions"},
      condition_key: "parked-actions-condition",
      reason: "GitHub Actions is degraded",
      min_poll_ms: 15_000,
      max_poll_ms: 60_000
    }

    send(worker_pid, {:park, pid, request})
    assert_receive {:parked_lifecycle, :ok}, 1_000
    send(pid, {:DOWN, ref, :process, worker_pid, :normal})

    snapshot =
      wait_for_snapshot(pid, fn snapshot ->
        Enum.any?(snapshot.waiting, &(&1.issue_id == issue_id))
      end)

    assert Enum.any?(snapshot.waiting, &(&1.issue_id == issue_id))

    state = :sys.get_state(pid)
    refute Map.has_key?(state.running, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)
    assert MapSet.member?(state.claimed, issue_id)

    send(worker_pid, :done)
  end

  test "pending asynchronous handoff gate is observable and excluded from implementor stall retries" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      codex_stall_timeout_ms: 1_000
    )

    issue_id = "issue-pending-handoff-gate"
    orchestrator_name = Module.concat(__MODULE__, :PendingHandoffGateOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    parent = self()

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    worker_pid =
      spawn(fn ->
        receive do
          {:start_gate, orchestrator} ->
            result =
              GenServer.call(
                orchestrator,
                {:agent_lifecycle, issue_id, :handoff_pending_gate,
                 %{
                   gate_job_id: "job-7157",
                   gate: %{
                     job_id: "job-7157",
                     status: :running,
                     candidate_hash: "candidate-7157",
                     exact_hash: "exact-7157",
                     identity: %{"headSha" => "head-7157"},
                     heartbeat_at: "2026-08-02T12:00:00Z",
                     heartbeat_age_ms: 25,
                     next_poll_ms: 1_000,
                     progress: %{"stage" => "tests", "completed" => 2, "total" => 4},
                     started_at: "2026-08-02T11:59:00Z"
                   }
                 }}
              )

            send(parent, {:gate_started, result})
        end

        receive do
          :done -> :ok
        end
      end)

    stale_activity_at = DateTime.add(DateTime.utc_now(), -5, :second)
    issue = %Issue{id: issue_id, identifier: "UDPE-7157", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: "thread-pending-gate",
      codex_app_server_pid: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      last_codex_message: nil,
      last_codex_timestamp: stale_activity_at,
      last_codex_event: :turn_completed,
      lifecycle_state: :implementing,
      lifecycle_started_at: stale_activity_at,
      started_at: stale_activity_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(worker_pid, {:start_gate, pid})
    assert_receive {:gate_started, :ok}, 1_000
    send(pid, :tick)
    Process.sleep(100)

    state = :sys.get_state(pid)
    assert Process.alive?(worker_pid)
    assert state.running[issue_id].lifecycle_state == :handoff_pending_gate
    refute Map.has_key?(state.retry_attempts, issue_id)

    snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)
    [running] = Enum.filter(snapshot.running, &(&1.issue_id == issue_id))
    assert running.handoff_gate.job_id == "job-7157"
    assert running.handoff_gate.candidate_hash == "candidate-7157"
    assert running.handoff_gate.heartbeat_age_ms == 25
    assert get_in(running.handoff_gate, [:progress, "stage"]) == "tests"
    assert is_integer(running.handoff_gate.pending_age_seconds)

    send(worker_pid, :done)
  end

  test "stalled handoff review clears pending state and retries visibly" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      codex_stall_timeout_ms: 1_000
    )

    issue_id = "issue-review-timeout"
    orchestrator_name = Module.concat(__MODULE__, :ReviewTimeoutOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    worker_pid =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    stale_activity_at = DateTime.add(DateTime.utc_now(), -5, :second)
    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: "MT-REVIEW-TIMEOUT",
      issue: %Issue{id: issue_id, identifier: "MT-REVIEW-TIMEOUT", state: "In Progress"},
      session_id: "thread-review-timeout",
      last_codex_timestamp: stale_activity_at,
      lifecycle_state: :handoff_pending_review,
      lifecycle_started_at: stale_activity_at,
      handoff_review_job_id: 18,
      handoff_review_key: {:pull_request, issue_id, "PR_18", "head-18"},
      handoff_review_timeout_ms: 1_000,
      handoff_review_last_event_at: stale_activity_at,
      started_at: stale_activity_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    log =
      capture_log(fn ->
        send(pid, :tick)
        Process.sleep(100)
      end)

    state = :sys.get_state(pid)

    refute Process.alive?(worker_pid)
    refute Map.has_key?(state.running, issue_id)
    assert state.retry_attempts[issue_id].error =~ "handoff review timed out"
    assert log =~ "Handoff review timed out"
    assert log =~ "issue_identifier=MT-REVIEW-TIMEOUT"
  end

  test "reviewer heartbeat refreshes only the matching worker and review job" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      codex_stall_timeout_ms: 1_000
    )

    issue_id = "issue-review-heartbeat"
    orchestrator_name = Module.concat(__MODULE__, :ReviewHeartbeatOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    worker_pid =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    stale_activity_at = DateTime.add(DateTime.utc_now(), -5, :second)
    issue = %Issue{id: issue_id, identifier: "MT-REVIEW-HEARTBEAT", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: "thread-review-heartbeat",
      codex_app_server_pid: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      lifecycle_state: :handoff_pending_review,
      lifecycle_started_at: stale_activity_at,
      handoff_review_job_id: 19,
      handoff_review_key: {:pull_request, issue_id, "PR_19", "head-19"},
      handoff_review_timeout_ms: 30_000,
      last_codex_timestamp: stale_activity_at,
      last_codex_message: "Implementor turn completed",
      last_codex_event: :turn_completed,
      started_at: stale_activity_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    now = DateTime.utc_now()

    send(
      pid,
      {:handoff_review_heartbeat, issue_id, worker_pid, 18, now}
    )

    Process.sleep(20)
    assert :sys.get_state(pid).running[issue_id].last_codex_timestamp == stale_activity_at
    refute Map.has_key?(:sys.get_state(pid).running[issue_id], :handoff_review_last_event_at)

    send(
      pid,
      {:handoff_review_heartbeat, issue_id, worker_pid, 19, now}
    )

    Process.sleep(20)
    assert :sys.get_state(pid).running[issue_id].last_codex_timestamp == stale_activity_at
    assert :sys.get_state(pid).running[issue_id].handoff_review_last_event_at == now

    send(pid, :tick)
    Process.sleep(100)
    state = :sys.get_state(pid)

    assert Process.alive?(worker_pid)
    assert Map.has_key?(state.running, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)

    snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)
    [running] = Enum.filter(snapshot.running, &(&1.issue_id == issue_id))
    assert running.handoff_review.status == :running
    assert running.handoff_review.job_id == 19
    assert running.handoff_review.heartbeat_at == now
    assert is_integer(running.handoff_review.heartbeat_age_ms)
    assert is_integer(running.handoff_review.pending_age_seconds)

    send(worker_pid, :done)
  end

  test "status dashboard renders offline marker to terminal" do
    rendered =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = StatusDashboard.render_offline_status()
      end)

    assert rendered =~ "app_status=offline"
    refute rendered =~ "Timestamp:"
  end

  test "status dashboard renders linear project link in header" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)

    assert rendered =~ "https://linear.app/project/project/issues"
    refute rendered =~ "Dashboard:"
  end

  test "status dashboard renders dashboard url on its own line when server port is configured" do
    previous_port_override = Application.get_env(:symphony_elixir, :server_port_override)

    on_exit(fn ->
      if is_nil(previous_port_override) do
        Application.delete_env(:symphony_elixir, :server_port_override)
      else
        Application.put_env(:symphony_elixir, :server_port_override, previous_port_override)
      end
    end)

    Application.put_env(:symphony_elixir, :server_port_override, 4000)

    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)

    assert rendered =~ "│ Project:"
    assert rendered =~ "https://linear.app/project/project/issues"
    assert rendered =~ "│ Dashboard:"
    assert rendered =~ "http://127.0.0.1:4000/"
  end

  test "status dashboard prefers the bound server port and normalizes wildcard hosts" do
    assert StatusDashboard.dashboard_url_for_test("0.0.0.0", 0, 43_123) ==
             "http://127.0.0.1:43123/"

    assert StatusDashboard.dashboard_url_for_test("::1", 4000, nil) ==
             "http://[::1]:4000/"
  end

  test "status dashboard renders next refresh countdown and checking marker" do
    waiting_snapshot =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil,
         polling: %{checking?: false, next_poll_in_ms: 2_000, poll_interval_ms: 30_000}
       }}

    waiting_rendered = StatusDashboard.format_snapshot_content_for_test(waiting_snapshot, 0.0)
    assert waiting_rendered =~ "Next refresh:"
    assert waiting_rendered =~ "2s"

    checking_snapshot =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil,
         polling: %{checking?: true, next_poll_in_ms: nil, poll_interval_ms: 30_000}
       }}

    checking_rendered = StatusDashboard.format_snapshot_content_for_test(checking_snapshot, 0.0)
    assert checking_rendered =~ "checking now…"
  end

  test "status dashboard adds a spacer line before backoff queue when no agents are active" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)
    plain = Regex.replace(~r/\e\[[0-9;]*m/, rendered, "")

    assert plain =~ ~r/No active agents\r?\n│\s*\r?\n├─ Repository queue/
    assert plain =~ ~r/No repository-contention waits\r?\n│\s*\r?\n├─ Waiting work/
    assert plain =~ ~r/No parked external-condition waits\r?\n│\s*\r?\n├─ Backoff queue/
  end

  test "status dashboard adds a spacer line before backoff queue when agents are active" do
    snapshot_data =
      {:ok,
       %{
         running: [
           %{
             identifier: "MT-777",
             state: "running",
             session_id: "thread-1234567890",
             codex_app_server_pid: "4242",
             codex_total_tokens: 3_200,
             runtime_seconds: 75,
             turn_count: 7,
             last_codex_event: "turn_completed",
             last_codex_message: %{
               event: :notification,
               message: %{
                 "method" => "turn/completed",
                 "params" => %{"turn" => %{"status" => "completed"}}
               }
             }
           }
         ],
         retrying: [],
         codex_totals: %{
           input_tokens: 90,
           output_tokens: 12,
           total_tokens: 102,
           seconds_running: 75
         },
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)
    plain = Regex.replace(~r/\e\[[0-9;]*m/, rendered, "")

    assert plain =~ ~r/MT-777.*\r?\n│\s*\r?\n├─ Repository queue/s
  end

  test "status dashboard renders parked external-condition waits" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         waiting: [
           %{
             issue_id: "issue-7007",
             identifier: "UDPE-7007",
             status: :waiting,
             reason: "GitHub Actions is experiencing a major outage",
             condition: %{"type" => "github_actions_recovered", "component" => "actions"},
             next_probe_at: DateTime.add(DateTime.utc_now(), 30, :second),
             waiting_seconds: 1_200,
             probe_attempt: 6,
             last_error: ~s({:github_status_component_missing, "actions"})
           }
         ],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)
    plain = Regex.replace(~r/\e\[[0-9;]*m/, rendered, "")

    assert plain =~ "Waiting: 1"
    assert plain =~ "├─ Waiting work"
    assert plain =~ "UDPE-7007"
    assert plain =~ "github_actions_recovered:actions"
    assert plain =~ "probe=6"
    assert plain =~ "github_status_component_missing"
  end

  test "status dashboard renders an unstyled closing corner when the retry queue is empty" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)

    assert rendered |> String.split("\n") |> List.last() == "╰─"
  end

  test "status dashboard coalesces rapid updates to one render per interval" do
    dashboard_name = Module.concat(__MODULE__, :RenderDashboard)
    parent = self()
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    on_exit(fn ->
      if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    {:ok, pid} =
      StatusDashboard.start_link(
        name: dashboard_name,
        enabled: true,
        refresh_ms: 60_000,
        render_interval_ms: 16,
        render_fun: fn content ->
          send(parent, {:render, System.monotonic_time(:millisecond), content})
        end
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    StatusDashboard.notify_update(dashboard_name)
    assert_receive {:render, first_render_ms, _content}, 200

    :sys.replace_state(pid, fn state ->
      %{state | last_snapshot_fingerprint: :force_next_change, last_rendered_content: nil}
    end)

    StatusDashboard.notify_update(dashboard_name)
    StatusDashboard.notify_update(dashboard_name)

    assert_receive {:render, second_render_ms, _content}, 200
    assert second_render_ms > first_render_ms
    refute_receive {:render, _third_render_ms, _content}, 60
  end

  test "status dashboard computes rolling 5-second token throughput" do
    assert StatusDashboard.rolling_tps([], 10_000, 0) == 0.0

    assert StatusDashboard.rolling_tps([{9_000, 20}], 10_000, 40) == 20.0

    # sample older than 5s is dropped from the window
    assert StatusDashboard.rolling_tps([{4_900, 10}], 10_000, 90) == 0.0

    tps =
      StatusDashboard.rolling_tps(
        [{9_500, 10}, {9_000, 40}, {8_000, 80}],
        10_000,
        95
      )

    assert tps == 7.5
  end

  test "status dashboard throttles tps updates to once per second" do
    {first_second, first_tps} =
      StatusDashboard.throttled_tps(nil, nil, 10_000, [{9_000, 20}], 40)

    {same_second, same_tps} =
      StatusDashboard.throttled_tps(first_second, first_tps, 10_500, [{9_000, 20}], 200)

    assert same_second == first_second
    assert same_tps == first_tps

    {next_second, next_tps} =
      StatusDashboard.throttled_tps(same_second, same_tps, 11_000, [{10_500, 200}], 260)

    assert next_second == 11
    refute next_tps == same_tps
  end

  test "status dashboard formats timestamps at second precision" do
    dt = ~U[2026-02-15 21:36:38.987654Z]
    assert StatusDashboard.format_timestamp_for_test(dt) == "2026-02-15 21:36:38Z"
  end

  test "status dashboard renders 10-minute TPS graph snapshot for steady throughput" do
    now_ms = 600_000
    current_tokens = 6_000

    samples =
      for timestamp <- 575_000..0//-25_000 do
        {timestamp, div(timestamp, 100)}
      end

    assert StatusDashboard.tps_graph_for_test(samples, now_ms, current_tokens) ==
             "████████████████████████"
  end

  test "status dashboard renders 10-minute TPS graph snapshot for ramping throughput" do
    now_ms = 600_000

    rates_per_bucket =
      1..24
      |> Enum.map(&(&1 * 2))

    {current_tokens, samples} = graph_samples_from_rates(rates_per_bucket)

    assert StatusDashboard.tps_graph_for_test(samples, now_ms, current_tokens) ==
             "▁▂▂▂▃▃▃▃▄▄▄▅▅▅▆▆▆▆▇▇▇██▅"
  end

  test "status dashboard keeps historical TPS bars stable within the active bucket" do
    now_ms = 600_000
    current_tokens = 74_400
    next_current_tokens = current_tokens + 120
    samples = graph_samples_for_stability_test(now_ms)

    graph_at_now = StatusDashboard.tps_graph_for_test(samples, now_ms, current_tokens)

    graph_next_second =
      StatusDashboard.tps_graph_for_test(samples, now_ms + 1_000, next_current_tokens)

    historical_changes =
      graph_at_now
      |> String.graphemes()
      |> Enum.zip(String.graphemes(graph_next_second))
      |> Enum.take(23)
      |> Enum.count(fn {left, right} -> left != right end)

    assert historical_changes == 0
  end

  test "application configures a rotating file logger handler" do
    assert {:ok, handler_config} = :logger.get_handler_config(:symphony_disk_log)
    assert handler_config.module == :logger_disk_log_h

    disk_config = handler_config.config
    assert disk_config.type == :wrap
    assert is_list(disk_config.file)
    assert disk_config.max_no_bytes > 0
    assert disk_config.max_no_files > 0
  end

  test "status dashboard renders last codex message in EVENT column" do
    row =
      StatusDashboard.format_running_summary_for_test(%{
        identifier: "MT-233",
        state: "running",
        session_id: "thread-1234567890",
        codex_app_server_pid: "4242",
        codex_total_tokens: 12,
        runtime_seconds: 15,
        last_codex_event: :notification,
        last_codex_message: %{
          event: :notification,
          message: %{
            "method" => "turn/completed",
            "params" => %{"turn" => %{"status" => "completed"}}
          }
        }
      })

    plain = Regex.replace(~r/\e\[[\\d;]*m/, row, "")

    assert plain =~ "turn completed (completed)"
    assert (String.split(plain, "turn completed (completed)") |> length()) - 1 == 1
    refute plain =~ " notification "
  end

  test "status dashboard strips ANSI and control bytes from last codex message" do
    payload =
      "cmd: " <>
        <<27>> <>
        "[31mRED" <>
        <<27>> <>
        "[0m" <>
        <<0>> <>
        " after\nline"

    row =
      StatusDashboard.format_running_summary_for_test(%{
        identifier: "MT-898",
        state: "running",
        session_id: "thread-1234567890",
        codex_app_server_pid: "4242",
        codex_total_tokens: 12,
        runtime_seconds: 15,
        last_codex_event: :notification,
        last_codex_message: payload
      })

    plain = Regex.replace(~r/\e\[[0-9;]*m/, row, "")

    assert plain =~ "cmd: RED after line"
    refute plain =~ <<27>>
    refute plain =~ <<0>>
  end

  test "status dashboard expands running row to requested terminal width" do
    terminal_columns = 140

    row =
      StatusDashboard.format_running_summary_for_test(
        %{
          identifier: "MT-598",
          state: "running",
          session_id: "thread-1234567890",
          codex_app_server_pid: "4242",
          codex_total_tokens: 123,
          runtime_seconds: 15,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              "method" => "turn/completed",
              "params" => %{"turn" => %{"status" => "completed"}}
            }
          }
        },
        terminal_columns
      )

    plain = Regex.replace(~r/\e\[[\d;]*m/, row, "")

    assert String.length(plain) == terminal_columns
    assert plain =~ "turn completed (completed)"
  end

  test "status dashboard humanizes full codex app-server event set" do
    event_cases = [
      {"turn/started", %{"params" => %{"turn" => %{"id" => "turn-1"}}}, "turn started"},
      {"turn/completed", %{"params" => %{"turn" => %{"status" => "completed"}}}, "turn completed"},
      {"turn/diff/updated", %{"params" => %{"diff" => "line1\nline2"}}, "turn diff updated"},
      {"turn/plan/updated", %{"params" => %{"plan" => [%{"step" => "a"}, %{"step" => "b"}]}}, "plan updated"},
      {"thread/tokenUsage/updated",
       %{
         "params" => %{
           "usage" => %{"input_tokens" => 8, "output_tokens" => 3, "total_tokens" => 11}
         }
       }, "thread token usage updated"},
      {"item/started",
       %{
         "params" => %{
           "item" => %{
             "id" => "item-1234567890abcdef",
             "type" => "commandExecution",
             "status" => "running"
           }
         }
       }, "item started: command execution"},
      {"item/completed", %{"params" => %{"item" => %{"type" => "fileChange", "status" => "completed"}}}, "item completed: file change"},
      {"item/agentMessage/delta", %{"params" => %{"delta" => "hello"}}, "agent message streaming"},
      {"item/plan/delta", %{"params" => %{"delta" => "step"}}, "plan streaming"},
      {"item/reasoning/summaryTextDelta", %{"params" => %{"summaryText" => "thinking"}}, "reasoning summary streaming"},
      {"item/reasoning/summaryPartAdded", %{"params" => %{"summaryText" => "section"}}, "reasoning summary section added"},
      {"item/reasoning/textDelta", %{"params" => %{"textDelta" => "reason"}}, "reasoning text streaming"},
      {"item/commandExecution/outputDelta", %{"params" => %{"outputDelta" => "ok"}}, "command output streaming"},
      {"item/fileChange/outputDelta", %{"params" => %{"outputDelta" => "changed"}}, "file change output streaming"},
      {"item/commandExecution/requestApproval", %{"params" => %{"parsedCmd" => "git status"}}, "command approval requested (git status)"},
      {"item/fileChange/requestApproval", %{"params" => %{"fileChangeCount" => 2}}, "file change approval requested (2 files)"},
      {"item/tool/call", %{"params" => %{"tool" => "linear_graphql"}}, "dynamic tool call requested (linear_graphql)"},
      {"item/tool/requestUserInput", %{"params" => %{"question" => "Continue?"}}, "tool requires user input: Continue?"}
    ]

    Enum.each(event_cases, fn {method, payload, expected_fragment} ->
      message = Map.put(payload, "method", method)

      humanized =
        StatusDashboard.humanize_codex_message(%{event: :notification, message: message})

      assert humanized =~ expected_fragment
    end)
  end

  test "status dashboard humanizes dynamic tool wrapper events" do
    completed = %{
      event: :tool_call_completed,
      message: %{
        payload: %{"method" => "item/tool/call", "params" => %{"name" => "linear_graphql"}}
      }
    }

    failed = %{
      event: :tool_call_failed,
      message: %{
        payload: %{"method" => "item/tool/call", "params" => %{"tool" => "linear_graphql"}}
      }
    }

    unsupported = %{
      event: :unsupported_tool_call,
      message: %{
        payload: %{"method" => "item/tool/call", "params" => %{"tool" => "unknown_tool"}}
      }
    }

    assert StatusDashboard.humanize_codex_message(completed) =~
             "dynamic tool call completed (linear_graphql)"

    assert StatusDashboard.humanize_codex_message(failed) =~
             "dynamic tool call failed (linear_graphql)"

    assert StatusDashboard.humanize_codex_message(unsupported) =~
             "unsupported dynamic tool call rejected (unknown_tool)"
  end

  test "status dashboard unwraps nested codex payload envelopes" do
    wrapped = %{
      event: :notification,
      message: %{
        payload: %{
          "method" => "turn/completed",
          "params" => %{
            "turn" => %{"status" => "completed"},
            "usage" => %{"input_tokens" => "10", "output_tokens" => 2, "total_tokens" => 12}
          }
        },
        raw: "{\"method\":\"turn/completed\"}"
      }
    }

    assert StatusDashboard.humanize_codex_message(wrapped) =~ "turn completed"
    assert StatusDashboard.humanize_codex_message(wrapped) =~ "in 10"
  end

  test "status dashboard uses shell command line as exec command status text" do
    message = %{
      event: :notification,
      message: %{
        "method" => "codex/event/exec_command_begin",
        "params" => %{"msg" => %{"command" => "git status --short"}}
      }
    }

    assert StatusDashboard.humanize_codex_message(message) == "git status --short"
  end

  test "status dashboard formats auto-approval updates from codex" do
    message = %{
      event: :approval_auto_approved,
      message: %{
        payload: %{
          "method" => "item/commandExecution/requestApproval",
          "params" => %{"parsedCmd" => "mix test"}
        },
        decision: "acceptForSession"
      }
    }

    humanized = StatusDashboard.humanize_codex_message(message)
    assert humanized =~ "command approval requested"
    assert humanized =~ "auto-approved"
  end

  test "status dashboard formats auto-answered tool input updates from codex" do
    message = %{
      event: :tool_input_auto_answered,
      message: %{
        payload: %{
          "method" => "item/tool/requestUserInput",
          "params" => %{"question" => "Continue?"}
        },
        answer: "This is a non-interactive session. Operator input is unavailable."
      }
    }

    humanized = StatusDashboard.humanize_codex_message(message)
    assert humanized =~ "tool requires user input"
    assert humanized =~ "auto-answered"
  end

  test "status dashboard enriches wrapper reasoning and message streaming events with payload context" do
    reasoning_message = %{
      event: :notification,
      message: %{
        "method" => "codex/event/agent_reasoning",
        "params" => %{
          "msg" => %{
            "payload" => %{"summaryText" => "compare retry paths for Linear polling"}
          }
        }
      }
    }

    message_delta = %{
      event: :notification,
      message: %{
        "method" => "codex/event/agent_message_delta",
        "params" => %{
          "msg" => %{
            "payload" => %{"delta" => "writing workpad reconciliation update"}
          }
        }
      }
    }

    fallback_reasoning = %{
      event: :notification,
      message: %{
        "method" => "codex/event/agent_reasoning",
        "params" => %{"msg" => %{"payload" => %{}}}
      }
    }

    assert StatusDashboard.humanize_codex_message(reasoning_message) =~
             "reasoning update: compare retry paths for Linear polling"

    assert StatusDashboard.humanize_codex_message(message_delta) =~
             "agent message streaming: writing workpad reconciliation update"

    assert StatusDashboard.humanize_codex_message(fallback_reasoning) == "reasoning update"
  end

  test "application stop renders offline status" do
    rendered =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = SymphonyElixir.Application.stop(:normal)
      end)

    assert rendered =~ "app_status=offline"
    refute rendered =~ "Timestamp:"
  end

  test "poll cycle survives a transiently-invalid config and recovers when it becomes valid (UDPE-6990)" do
    workflow_path = Workflow.workflow_file_path()

    # Drive network-free poll cycles: the in-memory tracker returns no
    # candidates, so a valid cycle stays entirely local.
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    write_workflow_file!(workflow_path, tracker_kind: "memory", poll_interval_ms: 30_000)

    orchestrator_name = Module.concat(__MODULE__, :InvalidConfigPollOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      # Leave a valid config behind for the shared default orchestrator.
      write_workflow_file!(workflow_path, tracker_kind: "memory", poll_interval_ms: 30_000)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    # Neutralize the tick scheduled at init so only the messages we send drive
    # the loop (a stale {:tick, token} no longer matches tick_token).
    :sys.replace_state(pid, fn state ->
      %{
        state
        | poll_interval_ms: 30_000,
          tick_timer_ref: nil,
          tick_token: nil,
          poll_check_in_progress: false,
          next_poll_due_at_ms: nil
      }
    end)

    supervisor_pid = Process.whereis(SymphonyElixir.Supervisor)
    default_orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    # A half-saved / write-in-flight config: `Config.settings!/0` would raise
    # ArgumentError ("codex.command can't be blank") on this exact input.
    write_workflow_file!(workflow_path, tracker_kind: "memory", codex_command: "")
    assert {:error, {:invalid_workflow_config, _message}} = Config.settings()

    log =
      capture_log(fn ->
        send(pid, :run_poll_cycle)
        # FIFO mailbox: the poll cycle is fully handled before this returns.
        :sys.get_state(pid)
      end)

    assert log =~ "Skipping poll cycle"
    assert Process.alive?(pid)

    # Criterion 1: the app supervisor (and the sibling default orchestrator
    # under the same one_for_one strategy) is untouched — no crash cascade.
    assert Process.alive?(supervisor_pid)
    assert Process.whereis(SymphonyElixir.Supervisor) == supervisor_pid

    if is_pid(default_orchestrator_pid) do
      assert Process.alive?(default_orchestrator_pid)
      assert Process.whereis(SymphonyElixir.Orchestrator) == default_orchestrator_pid
    end

    # Criterion 2: last-good runtime values are kept while config is invalid.
    assert :sys.get_state(pid).poll_interval_ms == 30_000

    # Config becomes valid again with a distinct interval: polling resumes and
    # the fresh value is adopted on the next cycle.
    write_workflow_file!(workflow_path, tracker_kind: "memory", poll_interval_ms: 45_000)
    assert {:ok, _settings} = Config.settings()

    send(pid, :run_poll_cycle)
    recovered_state = :sys.get_state(pid)

    assert recovered_state.poll_interval_ms == 45_000
    assert recovered_state.poll_check_in_progress == false
    assert Process.alive?(pid)
  end

  test "tick handler survives a transiently-invalid config without crashing (UDPE-6990)" do
    workflow_path = Workflow.workflow_file_path()

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    write_workflow_file!(workflow_path, tracker_kind: "memory", poll_interval_ms: 30_000)

    orchestrator_name = Module.concat(__MODULE__, :InvalidConfigTickOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      write_workflow_file!(workflow_path, tracker_kind: "memory", poll_interval_ms: 30_000)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | poll_interval_ms: 30_000,
          tick_timer_ref: nil,
          tick_token: nil,
          poll_check_in_progress: false,
          next_poll_due_at_ms: nil
      }
    end)

    # `max_turns: 0` fails schema validation (`agent.max_turns` must be > 0),
    # so `Config.settings!/0` would raise on the tick's config read.
    write_workflow_file!(workflow_path, tracker_kind: "memory", max_turns: 0)
    assert {:error, {:invalid_workflow_config, _message}} = Config.settings()

    log =
      capture_log(fn ->
        send(pid, :tick)
        :sys.get_state(pid)
      end)

    assert log =~ "Skipping poll cycle"
    assert Process.alive?(pid)

    # The skipped tick keeps the loop idle and does NOT hand off to a poll
    # cycle (no `poll_check_in_progress` flip on the invalid path).
    state = :sys.get_state(pid)
    assert state.poll_check_in_progress == false
    assert state.poll_interval_ms == 30_000

    # Recovery: a valid config lets the next tick begin a poll check again.
    write_workflow_file!(workflow_path, tracker_kind: "memory", poll_interval_ms: 45_000)

    send(pid, :tick)
    recovered_state = :sys.get_state(pid)

    assert recovered_state.poll_check_in_progress == true
    assert recovered_state.poll_interval_ms == 45_000
    assert Process.alive?(pid)
  end

  defp wait_for_snapshot(pid, predicate, timeout_ms \\ 200) when is_function(predicate, 1) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_snapshot(pid, predicate, deadline_ms)
  end

  defp do_wait_for_snapshot(pid, predicate, deadline_ms) do
    snapshot = GenServer.call(pid, :snapshot)

    if predicate.(snapshot) do
      snapshot
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        flunk("timed out waiting for orchestrator snapshot state: #{inspect(snapshot)}")
      else
        Process.sleep(5)
        do_wait_for_snapshot(pid, predicate, deadline_ms)
      end
    end
  end

  defp graph_samples_from_rates(rates_per_bucket) do
    bucket_ms = 25_000

    {timestamp, tokens, samples} =
      Enum.reduce(rates_per_bucket, {0, 0, []}, fn rate, {timestamp, tokens, acc} ->
        next_timestamp = timestamp + bucket_ms
        next_tokens = tokens + trunc(rate * bucket_ms / 1000)
        {next_timestamp, next_tokens, [{timestamp, tokens} | acc]}
      end)

    {tokens, [{timestamp, tokens} | samples]}
  end

  defp graph_samples_for_stability_test(now_ms) do
    rates_per_bucket = Enum.map(1..24, &(&1 * 5))
    bucket_ms = 25_000

    rate_for_timestamp = fn timestamp ->
      bucket_idx = min(div(max(timestamp, 0), bucket_ms), 23)
      Enum.at(rates_per_bucket, bucket_idx, 0)
    end

    0..(now_ms - 1_000)//1_000
    |> Enum.reduce({0, []}, fn timestamp, {tokens, acc} ->
      next_tokens = tokens + rate_for_timestamp.(timestamp)
      {next_tokens, [{timestamp, next_tokens} | acc]}
    end)
    |> elem(1)
  end
end
