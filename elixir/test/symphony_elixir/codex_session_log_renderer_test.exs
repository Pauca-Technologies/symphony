defmodule SymphonyElixir.CodexSessionLogRendererTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SymphonyElixir.CodexSessionLogRenderer

  test "renders agent text, reasoning, commands, output, and tool calls distinctly" do
    log =
      [
        %{
          "at" => "2026-04-23T12:00:00Z",
          "event" => "session_started",
          "session_id" => "thread-1-turn-1",
          "issue_identifier" => "TEST-1",
          "workspace_path" => "/tmp/workspace"
        },
        %{
          "at" => "2026-04-23T12:00:01Z",
          "event" => "notification",
          "payload" => %{
            "method" => "item/completed",
            "params" => %{
              "item" => %{
                "type" => "userMessage",
                "id" => "user-1",
                "content" => [%{"type" => "text", "text" => "Please inspect the failing session log."}]
              }
            }
          }
        },
        %{
          "at" => "2026-04-23T12:00:02Z",
          "event" => "notification",
          "payload" => %{
            "method" => "item/started",
            "params" => %{"item" => %{"type" => "reasoning", "id" => "reason-1"}}
          }
        },
        %{
          "at" => "2026-04-23T12:00:03Z",
          "event" => "notification",
          "payload" => %{
            "method" => "item/reasoning/summaryTextDelta",
            "params" => %{"itemId" => "reason-1", "summaryText" => "compare tool calls with command output"}
          }
        },
        %{
          "at" => "2026-04-23T12:00:04Z",
          "event" => "notification",
          "payload" => %{
            "method" => "item/completed",
            "params" => %{"item" => %{"type" => "reasoning", "id" => "reason-1", "summary" => [], "content" => []}}
          }
        },
        %{
          "at" => "2026-04-23T12:00:05Z",
          "event" => "notification",
          "payload" => %{
            "method" => "item/started",
            "params" => %{
              "item" => %{
                "type" => "commandExecution",
                "id" => "cmd-1",
                "commandActions" => [%{"command" => "git status --short --branch"}]
              }
            }
          }
        },
        %{
          "at" => "2026-04-23T12:00:06Z",
          "event" => "notification",
          "payload" => %{
            "method" => "item/commandExecution/outputDelta",
            "params" => %{"itemId" => "cmd-1", "delta" => "## feature-branch\n M lib/example.ex\n"}
          }
        },
        %{
          "at" => "2026-04-23T12:00:07Z",
          "event" => "notification",
          "payload" => %{
            "method" => "item/completed",
            "params" => %{
              "item" => %{
                "type" => "commandExecution",
                "id" => "cmd-1",
                "commandActions" => [%{"command" => "git status --short --branch"}],
                "exitCode" => 0,
                "durationMs" => 21
              }
            }
          }
        },
        %{
          "at" => "2026-04-23T12:00:08Z",
          "event" => "notification",
          "payload" => %{
            "method" => "item/started",
            "params" => %{"item" => %{"type" => "agentMessage", "id" => "msg-1", "phase" => "commentary"}}
          }
        },
        %{
          "at" => "2026-04-23T12:00:09Z",
          "event" => "notification",
          "payload" => %{
            "method" => "item/agentMessage/delta",
            "params" => %{"itemId" => "msg-1", "delta" => "I found the mismatch and I am checking the failing command next."}
          }
        },
        %{
          "at" => "2026-04-23T12:00:10Z",
          "event" => "notification",
          "payload" => %{
            "method" => "item/completed",
            "params" => %{
              "item" => %{
                "type" => "agentMessage",
                "id" => "msg-1",
                "phase" => "commentary",
                "text" => "I found the mismatch and I am checking the failing command next."
              }
            }
          }
        },
        %{
          "at" => "2026-04-23T12:00:11Z",
          "event" => "tool_call_completed",
          "payload" => %{
            "method" => "item/tool/call",
            "params" => %{
              "tool" => "linear_graphql",
              "arguments" => %{
                "query" => "query SearchIssue($term: String!) { searchIssues(term: $term) { nodes { id } } }",
                "variables" => %{
                  "term" => "TEST-1",
                  "body" => String.duplicate("x", 400)
                }
              }
            }
          }
        },
        %{
          "at" => "2026-04-23T12:00:11Z",
          "event" => "notification",
          "payload" => %{
            "method" => "thread/compacted",
            "params" => %{"threadId" => "thread-1", "turnId" => "turn-compact-1"}
          }
        },
        %{
          "at" => "2026-04-23T12:00:12Z",
          "event" => "tool_call_failed",
          "payload" => %{
            "method" => "item/tool/call",
            "params" => %{
              "tool" => "linear_graphql",
              "arguments" => %{
                "query" => "mutation UpdateIssue($id: String!) { issueUpdate(id: $id, input: {}) { success } }"
              }
            }
          }
        }
      ]
      |> Enum.map_join("\n", &Jason.encode!/1)

    output = CodexSessionLogRenderer.render_string(log, path: "/tmp/session.ndjson", use_color: false)

    assert output =~ "Session: thread-1-turn-1"
    assert output =~ "Issue: TEST-1"
    assert output =~ "Workspace: /tmp/workspace"
    assert output =~ "File: /tmp/session.ndjson"
    assert output =~ "USER"
    assert output =~ "Please inspect the failing session log."
    assert output =~ "REASONING"
    assert output =~ "compare tool calls with command output"
    assert output =~ "CMD"
    assert output =~ "git status --short --branch"
    assert output =~ "OUT (exit=0, 21ms)"
    assert output =~ "## feature-branch"
    assert output =~ "AGENT"
    assert output =~ "I found the mismatch and I am checking the failing command next."
    assert output =~ "TOOL OK linear_graphql"
    assert output =~ "COMPACTION"
    assert output =~ "Context compacted for turn turn-com"
    assert output =~ "TOOL FAILED linear_graphql"
    assert output =~ "… [400 chars]"
  end

  test "renders alternate event names and partial buffered items" do
    log =
      [
        "not-json",
        "   ",
        %{"at" => "2026-04-23T12:00:00Z", "event" => "startup_failed", "summary" => "startup failed"},
        %{"at" => "2026-04-23T12:00:00Z", "payload" => %{"method" => "unknown/event"}},
        %{
          "at" => "2026-04-23T12:00:00Z",
          "payload" => %{
            "method" => "item/started",
            "params" => %{
              "item" => %{
                "type" => "userMessage",
                "content" => [
                  %{"text" => "started user"},
                  %{"type" => "image"}
                ]
              }
            }
          }
        },
        %{
          "at" => "2026-04-23T12:00:00Z",
          "payload" => %{
            "method" => "item/started",
            "params" => %{"item" => %{"type" => "unknown", "id" => "unknown-start"}}
          }
        },
        %{"payload" => %{"method" => "item/started", "params" => "bad"}},
        %{
          "at" => "2026-04-23T12:00:00Z",
          "payload" => %{
            "method" => "item/agentMessage/delta",
            "params" => %{"delta" => "missing id"}
          }
        },
        %{
          "at" => "2026-04-23T12:00:01Z",
          "payload" => %{
            "method" => "codex/event/agent_message_delta",
            "params" => %{"id" => "msg-partial", "delta" => "partial agent"}
          }
        },
        %{
          "at" => "2026-04-23T12:00:02Z",
          "payload" => %{
            "method" => "codex/event/agent_message_content_delta",
            "params" => %{"item" => %{"id" => "msg-final"}, "msg" => %{"content" => "final partial"}}
          }
        },
        %{
          "at" => "2026-04-23T12:00:03Z",
          "payload" => %{
            "method" => "item/started",
            "params" => %{"item" => %{"type" => "agentMessage", "id" => "msg-final-partial", "phase" => "final"}}
          }
        },
        %{
          "at" => "2026-04-23T12:00:03Z",
          "payload" => %{
            "method" => "item/started",
            "params" => %{"item" => %{"type" => "agentMessage", "id" => "msg-complete", "phase" => "final"}}
          }
        },
        %{
          "at" => "2026-04-23T12:00:04Z",
          "payload" => %{
            "method" => "item/completed",
            "params" => %{"item" => %{"type" => "agentMessage", "id" => "msg-complete", "phase" => "final"}}
          }
        },
        %{
          "at" => "2026-04-23T12:00:04Z",
          "payload" => %{
            "method" => "item/completed",
            "params" => %{"item" => %{"type" => "agentMessage", "id" => "msg-final-text", "phase" => "final", "text" => "complete final"}}
          }
        },
        %{
          "at" => "2026-04-23T12:00:04Z",
          "payload" => %{
            "method" => "item/agentMessage/delta",
            "params" => %{"itemId" => "msg-final-partial", "delta" => "partial final"}
          }
        },
        %{
          "at" => "2026-04-23T12:00:05Z",
          "payload" => %{
            "method" => "codex/event/agent_reasoning",
            "params" => %{"content" => "standalone reasoning"}
          }
        },
        %{
          "at" => "2026-04-23T12:00:05Z",
          "payload" => %{
            "method" => "item/reasoning/summaryPartAdded",
            "params" => %{"part" => %{"summaryText" => "summary part"}}
          }
        },
        %{
          "at" => "2026-04-23T12:00:05Z",
          "payload" => %{
            "method" => "codex/event/agent_reasoning_delta",
            "params" => %{"text" => "reasoning text"}
          }
        },
        %{
          "at" => "2026-04-23T12:00:05Z",
          "payload" => %{
            "method" => "item/reasoning/textDelta",
            "params" => %{}
          }
        },
        %{
          "at" => "2026-04-23T12:00:06Z",
          "payload" => %{
            "method" => "codex/event/reasoning_content_delta",
            "params" => %{"itemId" => "reason-partial", "content" => "partial reasoning"}
          }
        },
        %{
          "at" => "2026-04-23T12:00:07Z",
          "payload" => %{
            "method" => "item/reasoning/textDelta",
            "params" => %{"item" => %{"id" => "reason-complete"}, "textDelta" => "completed reasoning"}
          }
        },
        %{
          "at" => "2026-04-23T12:00:08Z",
          "payload" => %{
            "method" => "item/completed",
            "params" => %{
              "item" => %{
                "type" => "reasoning",
                "id" => "reason-complete",
                "content" => [%{"text" => "content reasoning"}],
                "summary" => [%{"text" => "summary reasoning"}]
              }
            }
          }
        },
        %{
          "at" => "2026-04-23T12:00:09Z",
          "payload" => %{
            "method" => "item/started",
            "params" => %{"item" => %{"type" => "commandExecution", "id" => "cmd-partial", "command" => "echo partial"}}
          }
        },
        %{
          "at" => "2026-04-23T12:00:10Z",
          "payload" => %{
            "method" => "codex/event/exec_command_output_delta",
            "params" => %{"id" => "cmd-partial", "output" => "partial output"}
          }
        },
        %{
          "at" => "2026-04-23T12:00:10Z",
          "payload" => %{
            "method" => "item/started",
            "params" => %{"item" => %{"type" => "commandExecution", "id" => "cmd-no-output-at", "command" => "echo no-output-at"}}
          }
        },
        %{
          "payload" => %{
            "method" => "item/commandExecution/outputDelta",
            "params" => %{"itemId" => "cmd-no-output-at", "delta" => "output without at"}
          }
        },
        %{
          "payload" => %{
            "method" => "item/commandExecution/outputDelta",
            "params" => %{"itemId" => "cmd-orphan", "delta" => "orphan output"}
          }
        },
        %{
          "at" => "2026-04-23T12:00:10Z",
          "payload" => %{
            "method" => "item/commandExecution/outputDelta",
            "params" => %{"delta" => "missing command id"}
          }
        },
        %{
          "at" => "2026-04-23T12:00:11Z",
          "payload" => %{
            "method" => "item/completed",
            "params" => %{"item" => %{"type" => "commandExecution", "id" => "cmd-aggregate", "command" => "echo aggregate", "aggregatedOutput" => "aggregate output"}}
          }
        },
        %{
          "at" => "2026-04-23T12:00:11Z",
          "payload" => %{
            "method" => "item/completed",
            "params" => %{
              "item" => %{"type" => "commandExecution", "id" => "cmd-int-output", "command" => "echo int", "aggregatedOutput" => 123}
            }
          }
        },
        %{
          "at" => "2026-04-23T12:00:12Z",
          "payload" => %{
            "method" => "item/completed",
            "params" => %{"item" => %{"type" => "unknown", "id" => "unknown"}}
          }
        },
        %{
          "at" => "2026-04-23T12:00:13Z",
          "payload" => %{
            "method" => "tool/requestUserInput",
            "params" => %{"questions" => [%{"question" => "Need input?"}]}
          }
        },
        %{
          "at" => "2026-04-23T12:00:13Z",
          "payload" => %{
            "method" => "item/tool/requestUserInput",
            "params" => %{"questions" => []}
          }
        },
        %{
          "at" => "2026-04-23T12:00:13Z",
          "payload" => %{
            "method" => "tool/requestUserInput",
            "params" => "bad"
          }
        },
        %{
          "at" => "2026-04-23T12:00:14Z",
          "event" => "unsupported_tool_call",
          "payload" => %{
            "method" => "item/tool/call",
            "params" => %{
              "name" => "unknown_tool",
              "arguments" => %{
                "items" => Enum.to_list(1..10),
                "short_items" => [1, 2, 3],
                "lines" => Enum.map_join(1..7, "\n", &"line #{&1}")
              }
            }
          }
        },
        %{
          "at" => "2026-04-23T12:00:15Z",
          "payload" => %{"method" => "item/tool/call", "params" => %{"tool" => "plain_tool"}}
        },
        %{
          "at" => "2026-04-23T12:00:16Z",
          "payload" => %{"method" => "thread/compacted", "params" => %{}}
        },
        %{
          "at" => "2026-04-23T12:00:17Z",
          "payload" => %{
            "method" => "thread/compacted",
            "params" => %{"turnId" => "turn1234"}
          }
        }
      ]
      |> Enum.map_join("\n", fn
        value when is_map(value) -> Jason.encode!(value)
        value -> value
      end)

    output = CodexSessionLogRenderer.render_string(log, use_color: true)

    assert output =~ "startup failed"
    assert output =~ "started user"
    assert output =~ "AGENT FINAL"
    assert output =~ "AGENT FINAL (partial)"
    assert output =~ "final partial"
    assert output =~ "AGENT (partial)"
    assert output =~ "partial agent"
    assert output =~ "partial final"
    assert output =~ "REASONING (partial)"
    assert output =~ "partial reasoning"
    assert output =~ "summary part"
    assert output =~ "reasoning text"
    assert output =~ "content reasoning"
    assert output =~ "CMD"
    assert output =~ "echo aggregate"
    assert output =~ "aggregate output"
    assert output =~ "OUT (partial)"
    assert output =~ "partial output"
    assert output =~ "output without at"
    assert output =~ "orphan output"
    assert output =~ "INPUT"
    assert output =~ "Need input?"
    assert output =~ "tool requires user input"
    assert output =~ "TOOL REJECTED unknown_tool"
    assert output =~ "TOOL plain_tool"
    assert output =~ "Context compacted."
    assert output =~ "Context compacted for turn turn1234"
    assert output =~ "… [48 chars]"
    assert output =~ "… [2 more]"
    assert output =~ IO.ANSI.reset()
  end

  test "renders with default options and render_file default arity" do
    content =
      [
        %{"event" => "turn_failed", "summary" => "turn failed"},
        %{"payload" => %{"method" => "item/completed", "params" => %{"item" => %{"type" => "userMessage", "content" => []}}}}
      ]
      |> Enum.map_join("\n", &Jason.encode!/1)

    assert CodexSessionLogRenderer.render_string(content) =~ "turn failed"

    path = Path.join(System.tmp_dir!(), "codex-session-render-#{System.unique_integer([:positive])}.ndjson")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)

    assert capture_io(fn ->
             assert :ok = CodexSessionLogRenderer.render_file(path)
           end) =~ "turn failed"
  end

  test "returns file read errors" do
    missing = Path.join(System.tmp_dir!(), "missing-codex-session-#{System.unique_integer([:positive])}.ndjson")

    assert {:error, :enoent} = CodexSessionLogRenderer.render_file(missing, use_color: false)
  end

  # The Claude Code backend normalizes (Option A) `agent_message_chunk` to
  # `item/agentMessage/delta` with the text at `params.delta` and *no* item id —
  # there is no following `item/completed` to flush a buffered message. The
  # renderer must append these directly, like id-less reasoning deltas.
  test "renders Option-A normalized agent and reasoning chunks that carry no item id" do
    log =
      [
        %{"at" => "2026-04-23T12:00:00Z", "event" => "session_started", "session_id" => "sess-acp"},
        %{
          "at" => "2026-04-23T12:00:01Z",
          "event" => "notification",
          "payload" => %{
            "method" => "item/reasoning/textDelta",
            "params" => %{"textDelta" => "Considering the request", "threadId" => "sess-acp"}
          }
        },
        %{
          "at" => "2026-04-23T12:00:02Z",
          "event" => "notification",
          "payload" => %{
            "method" => "item/agentMessage/delta",
            "params" => %{"delta" => "Hello from the ACP agent", "threadId" => "sess-acp"}
          }
        }
      ]
      |> Enum.map_join("\n", &Jason.encode!/1)

    output = CodexSessionLogRenderer.render_string(log, use_color: false)

    assert output =~ "REASONING"
    assert output =~ "Considering the request"
    assert output =~ "AGENT"
    assert output =~ "Hello from the ACP agent"
  end

  # Native ACP rendering (Option B): the ACP backend forwards `session/update`
  # verbatim and the renderer dispatches on `update.sessionUpdate`, surfacing the
  # ACP tool `kind` and `plan` updates that Option-A flattening would have lost.
  test "renders native ACP session/update notifications (chunks, tool kinds, plans)" do
    log =
      [
        %{"at" => "2026-04-23T12:00:00Z", "event" => "session_started", "session_id" => "sess-acp"},
        acp_update("2026-04-23T12:00:01Z", %{
          "sessionUpdate" => "agent_thought_chunk",
          "content" => %{"type" => "text", "text" => "Considering the request"}
        }),
        acp_update("2026-04-23T12:00:02Z", %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "Hello from the ACP agent"}
        }),
        acp_update("2026-04-23T12:00:03Z", %{
          "sessionUpdate" => "tool_call",
          "toolCallId" => "tc-1",
          "title" => "Update README",
          "kind" => "edit",
          "rawInput" => %{"path" => "README.md"}
        }),
        acp_update("2026-04-23T12:00:04Z", %{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => "tc-1",
          "content" => [%{"type" => "content", "content" => %{"type" => "text", "text" => "patched 1 file"}}]
        }),
        acp_update("2026-04-23T12:00:05Z", %{
          "sessionUpdate" => "plan",
          "entries" => [
            %{"content" => "write tests", "status" => "completed"},
            %{"content" => "ship it", "status" => "pending"}
          ]
        })
      ]
      |> Enum.map_join("\n", &Jason.encode!/1)

    output = CodexSessionLogRenderer.render_string(log, use_color: false)

    assert output =~ "REASONING"
    assert output =~ "Considering the request"
    assert output =~ "AGENT"
    assert output =~ "Hello from the ACP agent"
    assert output =~ "TOOL edit: Update README"
    assert output =~ "OUT"
    assert output =~ "patched 1 file"
    assert output =~ "PLAN"
    assert output =~ "- [x] write tests"
    assert output =~ "- [ ] ship it"
  end

  # ACP sends the initial `tool_call` with an empty `rawInput`; the arguments and
  # the cumulative output stream in via `tool_call_update`. Keyed on `toolCallId`,
  # the renderer fills the arguments into the one TOOL entry and shows the latest
  # output once instead of concatenating each cumulative resend.
  test "merges ACP tool_call_update arguments and de-duplicates cumulative output" do
    log =
      [
        %{"at" => "2026-04-23T12:00:00Z", "event" => "session_started", "session_id" => "sess-acp"},
        acp_update("2026-04-23T12:00:01Z", %{
          "sessionUpdate" => "tool_call",
          "toolCallId" => "read_0",
          "kind" => "read",
          "title" => "read",
          "rawInput" => %{}
        }),
        acp_update("2026-04-23T12:00:02Z", %{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => "read_0",
          "rawInput" => %{"filePath" => "lib/foo.ex"}
        }),
        acp_update("2026-04-23T12:00:03Z", %{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => "read_0",
          "content" => %{"type" => "text", "text" => "alpha\n"}
        }),
        acp_update("2026-04-23T12:00:04Z", %{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => "read_0",
          "content" => %{"type" => "text", "text" => "alpha\nbeta\n"}
        })
      ]
      |> Enum.map_join("\n", &Jason.encode!/1)

    output = CodexSessionLogRenderer.render_string(log, use_color: false)

    assert output =~ "TOOL read: read"
    assert output =~ "lib/foo.ex"
    assert output =~ "beta"
    # One TOOL entry, one OUT entry — and the cumulative output appears once.
    assert length(String.split(output, "] TOOL ")) == 2
    assert length(String.split(output, "] OUT")) == 2
    assert length(String.split(output, "alpha")) == 2
  end

  defp acp_update(at, update) do
    %{
      "at" => at,
      "event" => "notification",
      "payload" => %{
        "method" => "session/update",
        "params" => %{"sessionId" => "sess-acp", "update" => update}
      }
    }
  end
end
