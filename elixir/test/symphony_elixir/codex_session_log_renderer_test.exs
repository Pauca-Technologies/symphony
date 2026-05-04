defmodule SymphonyElixir.CodexSessionLogRendererTest do
  use ExUnit.Case, async: true

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
    assert output =~ "TOOL FAILED linear_graphql"
    assert output =~ "… [400 chars]"
  end
end
