defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  # Stub `gh` so ReviewGate's PR resolution finds a PR (and accepts the
  # human-review section edit) without shelling real gh.
  defp stub_pr_runner do
    fn
      ["pr", "view" | _], _cwd -> {Jason.encode!(%{"number" => 7, "body" => "Body."}), 0}
      ["pr", "edit" | _], _cwd -> {"", 0}
    end
  end

  test "tool_specs advertises the linear_graphql input contract" do
    assert [
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{
                   "query" => _,
                   "variables" => _
                 },
                 "required" => ["query"],
                 "type" => "object"
               },
               "name" => "linear_graphql"
             }
           ] = DynamicTool.tool_specs()

    assert description =~ "Linear"
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_graphql"]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]
  end

  test "linear_graphql blocks In Progress to In Review issueUpdate when before_handoff hook fails" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-before-handoff-tool-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(workspace),
      hook_before_handoff: """
      printf '%s' '{"checks":[{"name":"landable-check","status":"failed","summary":"CI is not green","remediation":"wait for CI"}]}'
      exit 2
      """
    )

    handler_id = "before-handoff-tool-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      SymphonyElixir.HandoffGate.telemetry_event(),
      fn event, measurements, metadata, recipient ->
        send(recipient, {:before_handoff_telemetry, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      File.rm_rf(workspace)
    end)

    issue = %Issue{
      id: "issue-gate",
      identifier: "UDPE-1",
      title: "Gate handoff",
      state: "In Progress"
    }

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "mutation Move($issueId: String!, $stateId: String!) { issueUpdate(id: $issueId, input: {stateId: $stateId}) { success } }",
          "variables" => %{"issueId" => "issue-gate", "stateId" => "state-review"}
        },
        handoff_gate_context: %{issue: issue, workspace: workspace, worker_host: nil},
        linear_client: fn
          query, %{"issueId" => "issue-gate"}, [] ->
            assert query =~ "SymphonyResolveIssueTransition"

            {:ok,
             %{
               "data" => %{
                 "issue" => %{
                   "state" => %{"name" => "In Progress"},
                   "team" => %{
                     "states" => %{
                       "nodes" => [
                         %{"id" => "state-review", "name" => "In Review"}
                       ]
                     }
                   }
                 }
               }
             }}

          _query, _variables, [] ->
            flunk("blocked handoff mutation should not be sent to Linear")
        end
      )

    assert response["success"] == false

    output = Jason.decode!(response["output"])
    assert get_in(output, ["error", "message"]) =~ "before_handoff hook blocked"
    assert get_in(output, ["error", "remediation"]) =~ "the following gates failed:"
    assert get_in(output, ["error", "remediation"]) =~ "landable-check: CI is not green"

    telemetry_event = [:symphony_elixir, :gate, :before_handoff]

    assert_receive {:before_handoff_telemetry, ^telemetry_event, %{count: 1}, telemetry}
    assert %{event: "gate.before_handoff", outcome: :failed, gates: gates} = telemetry

    assert [%{name: "landable-check", passed: false}] = gates
  end

  test "linear_graphql runs the reviewer gate after before_handoff and blocks on request_changes" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-gate-tool-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    review_workflow = %{
      config: %{"review" => %{"max_iterations" => 3}},
      prompt: "Review {{ issue.identifier }}",
      prompt_template: "Review {{ issue.identifier }}"
    }

    # Stand-in reviewer session: writes a request_changes verdict to the
    # gate-provided path instead of launching Codex.
    session_runner = fn ctx ->
      File.mkdir_p!(Path.dirname(ctx.verdict_path))

      File.write!(
        ctx.verdict_path,
        Jason.encode!(%{
          "verdict" => "request_changes",
          "summary" => "missing test",
          "comments" => [%{"severity" => "major", "file" => "app/x.ts", "body" => "add a test"}]
        })
      )

      {:ok, %{}}
    end

    issue = %Issue{id: "issue-review", identifier: "UDPE-2", title: "Review me", state: "In Progress"}

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "mutation Move($issueId: String!, $stateId: String!) { issueUpdate(id: $issueId, input: {stateId: $stateId}) { success } }",
          "variables" => %{"issueId" => "issue-review", "stateId" => "state-review"}
        },
        handoff_gate_context: %{
          issue: issue,
          workspace: workspace,
          worker_host: nil,
          review_workflow: review_workflow,
          review_opts: [session_runner: session_runner, pr_runner: stub_pr_runner()]
        },
        linear_client: fn
          _query, %{"issueId" => "issue-review"}, [] ->
            {:ok,
             %{
               "data" => %{
                 "issue" => %{
                   "state" => %{"name" => "In Progress"},
                   "team" => %{
                     "states" => %{"nodes" => [%{"id" => "state-review", "name" => "In Review"}]}
                   }
                 }
               }
             }}

          _query, _variables, [] ->
            flunk("the issue transition mutation must not reach Linear when the reviewer blocks")
        end
      )

    assert response["success"] == false

    output = Jason.decode!(response["output"])
    assert get_in(output, ["error", "message"]) =~ "Automated reviewer requested changes"
    assert get_in(output, ["error", "remediation"]) =~ "requested changes (review pass 1 of 3)"
    assert get_in(output, ["error", "remediation"]) =~ "app/x.ts"
    assert [%{"severity" => "major"}] = get_in(output, ["error", "findings"])
  end

  test "linear_graphql lets the transition through when the reviewer approves" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-gate-approve-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    review_workflow = %{
      config: %{"review" => %{}},
      prompt: "Review {{ issue.identifier }}",
      prompt_template: "Review {{ issue.identifier }}"
    }

    session_runner = fn ctx ->
      File.mkdir_p!(Path.dirname(ctx.verdict_path))
      File.write!(ctx.verdict_path, Jason.encode!(%{"verdict" => "approve", "comments" => []}))
      {:ok, %{}}
    end

    issue = %Issue{id: "issue-ok", identifier: "UDPE-3", title: "Ship it", state: "In Progress"}
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "mutation Move($issueId: String!, $stateId: String!) { issueUpdate(id: $issueId, input: {stateId: $stateId}) { success } }",
          "variables" => %{"issueId" => "issue-ok", "stateId" => "state-review"}
        },
        handoff_gate_context: %{
          issue: issue,
          workspace: workspace,
          worker_host: nil,
          review_workflow: review_workflow,
          review_opts: [session_runner: session_runner, pr_runner: stub_pr_runner()]
        },
        linear_client: fn
          query, %{"issueId" => "issue-ok"}, [] ->
            if query =~ "SymphonyResolveIssueTransition" do
              {:ok,
               %{
                 "data" => %{
                   "issue" => %{
                     "state" => %{"name" => "In Progress"},
                     "team" => %{
                       "states" => %{"nodes" => [%{"id" => "state-review", "name" => "In Review"}]}
                     }
                   }
                 }
               }}
            else
              send(test_pid, :mutation_sent)
              {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
            end
        end
      )

    assert response["success"] == true
    assert_received :mutation_sent
  end

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:linear_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ")

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert Jason.decode!(missing_token["output"]) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
      )

    assert Jason.decode!(status_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_request, :timeout}} end
      )

    assert Jason.decode!(request_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "linear_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true
    assert response["output"] == ":ok"
  end
end
