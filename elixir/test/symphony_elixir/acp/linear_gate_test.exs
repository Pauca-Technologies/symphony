defmodule SymphonyElixir.Acp.LinearGateTest do
  @moduledoc """
  In-VM MCP gate endpoint + ACP handoff-gate parity (`docs/acp-support-plan.md`
  §5.5). Proves that a `linear_graphql` call hitting the HTTP endpoint is
  dispatched into the owning session process and runs the same before_handoff +
  reviewer gates the Codex path does — blocking an In Progress -> In Review
  handoff with the same remediation.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Acp.LinearGate
  alias SymphonyElixir.Codex.DynamicTool

  @handoff_mutation "mutation Move($issueId: String!, $stateId: String!) { issueUpdate(id: $issueId, input: {stateId: $stateId}) { success } }"

  describe "MCP handshake" do
    test "initialize and tools/list expose the gated linear_graphql tool" do
      %{url: url} = start_gate(fn _tool, _args -> %{"success" => true, "output" => "ok"} end)

      init = mcp(url, %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{"protocolVersion" => "2025-06-18"}})

      assert init.status == 200
      assert get_in(init.body, ["result", "protocolVersion"]) == "2025-06-18"
      assert get_in(init.body, ["result", "serverInfo", "name"]) == "symphony-linear-gate"
      assert get_in(init.body, ["result", "capabilities", "tools"])

      list = mcp(url, %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})
      tools = get_in(list.body, ["result", "tools"])
      assert Enum.any?(tools, &(&1["name"] == "linear_graphql"))
    end

    test "an initialized notification gets a 202 with no body" do
      %{url: url} = start_gate(fn _tool, _args -> %{"success" => true, "output" => "ok"} end)

      resp = mcp(url, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
      assert resp.status == 202
    end

    test "a bad path token is rejected" do
      %{port: port} = start_gate(fn _tool, _args -> %{"success" => true, "output" => "ok"} end)

      resp = mcp("http://127.0.0.1:#{port}/mcp/wrong-token", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
      assert resp.status == 404
    end
  end

  describe "tools/call routing" do
    test "dispatches into the session process and returns the tool result" do
      executor = fn "linear_graphql", _args ->
        DynamicTool.execute("linear_graphql", %{"query" => "query { viewer { id } }"}, linear_client: fn _q, _v, _o -> {:ok, %{"data" => %{"viewer" => %{"id" => "usr_1"}}}} end)
      end

      %{url: url} = start_gate(executor)

      resp =
        mcp(url, %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "tools/call",
          "params" => %{"name" => "linear_graphql", "arguments" => %{"query" => "query { viewer { id } }"}}
        })

      assert resp.status == 200
      assert get_in(resp.body, ["result", "isError"]) == false
      text = resp.body |> get_in(["result", "content"]) |> List.first() |> Map.get("text")
      assert text =~ "usr_1"
    end
  end

  describe "handoff gate parity (ship blocker)" do
    test "before_handoff failure blocks the In Progress -> In Review handoff" do
      workspace = make_workspace("before-handoff")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: Path.dirname(workspace),
        hook_before_handoff: """
        printf '%s' '{"checks":[{"name":"landable-check","status":"failed","summary":"CI is not green"}]}'
        exit 2
        """
      )

      issue = %Issue{id: "issue-acp-gate", identifier: "ACP-1", title: "Gate handoff", state: "In Progress"}

      executor =
        handoff_executor(issue, workspace,
          linear_client: fn
            _query, %{"issueId" => "issue-acp-gate"}, [] -> {:ok, transition_response("In Progress")}
            _query, _variables, [] -> flunk("blocked handoff mutation must not reach Linear")
          end
        )

      %{url: url} = start_gate(executor)

      resp = tools_call(url, issue.id)

      assert get_in(resp.body, ["result", "isError"]) == true
      output = tool_call_output(resp)
      assert get_in(output, ["error", "message"]) =~ "before_handoff hook blocked"
      assert get_in(output, ["error", "remediation"]) =~ "landable-check: CI is not green"
    end

    test "reviewer request_changes blocks the In Progress -> In Review handoff" do
      workspace = make_workspace("review-gate")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.dirname(workspace))

      review_workflow = %{
        config: %{"review" => %{"max_iterations" => 3}},
        prompt: "Review {{ issue.identifier }}",
        prompt_template: "Review {{ issue.identifier }}"
      }

      test_pid = self()

      session_runner = fn ctx ->
        send(test_pid, {:review_issue_state, ctx.issue.state})
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

      issue = %Issue{id: "issue-acp-review", identifier: "ACP-2", title: "Review me", state: "Todo"}

      executor =
        handoff_executor(issue, workspace,
          review_workflow: review_workflow,
          review_opts: [session_runner: session_runner, pr_runner: stub_pr_runner()],
          linear_client: fn
            _query, %{"issueId" => "issue-acp-review"}, [] -> {:ok, transition_response("In Progress")}
            _query, _variables, [] -> flunk("the transition mutation must not reach Linear when the reviewer blocks")
          end
        )

      %{url: url} = start_gate(executor)

      resp = tools_call(url, issue.id)

      assert get_in(resp.body, ["result", "isError"]) == true
      assert_received {:review_issue_state, "In Progress"}

      output = tool_call_output(resp)
      assert get_in(output, ["error", "message"]) =~ "Automated reviewer requested changes"
      assert get_in(output, ["error", "remediation"]) =~ "app/x.ts"
    end

    test "accepted deferred review returns a successful structured result" do
      workspace = make_workspace("deferred-review")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.dirname(workspace))

      review_workflow = %{
        config: %{"review" => %{}},
        prompt: "Review {{ issue.identifier }}",
        prompt_template: "Review {{ issue.identifier }}"
      }

      issue = %Issue{id: "issue-acp-deferred", identifier: "ACP-3", title: "Review later", state: "In Progress"}
      test_pid = self()

      executor =
        handoff_executor(issue, workspace,
          review_workflow: review_workflow,
          deferred_review_callback: fn request -> send(test_pid, {:deferred_review, request}) end,
          linear_client: fn
            _query, %{"issueId" => "issue-acp-deferred"}, [] -> {:ok, transition_response("In Progress")}
            _query, _variables, [] -> flunk("deferred handoff mutation must not reach Linear before review")
          end
        )

      %{url: url} = start_gate(executor)

      resp = tools_call(url, issue.id)

      assert get_in(resp.body, ["result", "isError"]) == false

      assert %{
               "success" => true,
               "status" => "deferred_review_started",
               "issueIdentifier" => "ACP-3",
               "review" => %{"deferred" => true},
               "instructions" => instructions
             } = tool_call_output(resp)

      assert instructions =~ "End the turn now"
      assert instructions =~ "Do not retry the Linear handoff mutation"
      assert_received {:deferred_review, %{issue: ^issue}}
    end

    test "the gate runs in the session process (process-dictionary state is honored)" do
      # Deferred-review/iteration counters live in the session process's
      # dictionary; prove the tool actually executes there, not in the HTTP
      # handler, by stashing a marker from the executor and reading it back.
      workspace = make_workspace("in-process")
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.dirname(workspace))

      parent = self()

      executor = fn "linear_graphql", _args ->
        send(parent, {:executed_in, self()})
        %{"success" => true, "output" => "ok"}
      end

      %{url: url, session_pid: session_pid} = start_gate(executor)

      _resp =
        mcp(url, %{
          "jsonrpc" => "2.0",
          "id" => 9,
          "method" => "tools/call",
          "params" => %{"name" => "linear_graphql", "arguments" => %{"query" => "query { viewer { id } }"}}
        })

      assert_receive {:executed_in, ^session_pid}
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp start_gate(executor) when is_function(executor, 2) do
    test_pid = self()

    session_pid =
      spawn_link(fn ->
        session_loop(executor)
      end)

    {:ok, gate} = LinearGate.start(session_pid: session_pid)
    on_exit(fn -> LinearGate.stop(gate) end)

    _ = test_pid
    Map.put(gate, :session_pid, session_pid)
  end

  defp session_loop(executor) do
    receive do
      {:acp_tool_call, ref, from, tool, args} ->
        result = executor.(tool, args)
        send(from, {:acp_tool_result, ref, result})
        session_loop(executor)

      :stop ->
        :ok
    end
  end

  defp handoff_executor(issue, workspace, opts) do
    linear_client = Keyword.fetch!(opts, :linear_client)

    context =
      %{issue: issue, workspace: workspace, worker_host: nil}
      |> maybe_put(:review_workflow, Keyword.get(opts, :review_workflow))
      |> maybe_put(:review_opts, Keyword.get(opts, :review_opts))
      |> maybe_put(:deferred_review_callback, Keyword.get(opts, :deferred_review_callback))

    fn "linear_graphql", args ->
      DynamicTool.execute("linear_graphql", args, linear_client: linear_client, handoff_gate_context: context)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp tools_call(url, issue_id) do
    mcp(url, %{
      "jsonrpc" => "2.0",
      "id" => 4,
      "method" => "tools/call",
      "params" => %{
        "name" => "linear_graphql",
        "arguments" => %{
          "query" => @handoff_mutation,
          "variables" => %{"issueId" => issue_id, "stateId" => "state-review"}
        }
      }
    })
  end

  defp tool_call_output(resp) do
    resp.body
    |> get_in(["result", "content"])
    |> List.first()
    |> Map.get("text")
    |> Jason.decode!()
  end

  defp transition_response(current_state) do
    %{
      "data" => %{
        "issue" => %{
          "state" => %{"name" => current_state},
          "team" => %{"states" => %{"nodes" => [%{"id" => "state-review", "name" => "In Review"}]}}
        }
      }
    }
  end

  defp mcp(url, body) do
    Req.post!(url, json: body, retry: false)
  end

  defp make_workspace(label) do
    workspace =
      Path.join(System.tmp_dir!(), "symphony-elixir-acp-gate-#{label}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    workspace
  end

  defp stub_pr_runner do
    fn
      ["pr", "view" | _], _cwd -> {Jason.encode!(%{"id" => "PR_7", "number" => 7, "body" => "Body."}), 0}
      ["api", "graphql" | _], _cwd -> {"", 0}
    end
  end
end
