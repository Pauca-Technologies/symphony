defmodule SymphonyElixir.ReviewGateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ReviewGate

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-gate-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    {:ok, workspace: workspace}
  end

  defp review_workflow(overrides \\ %{}) do
    %{
      config: %{"review" => Map.merge(%{"max_iterations" => 3}, overrides)},
      prompt: "Review {{ issue.identifier }}",
      prompt_template: "Review {{ issue.identifier }}"
    }
  end

  defp issue do
    %Issue{id: "issue-1", identifier: "UDPE-1", title: "Thing", state: "In Progress"}
  end

  # A session runner that writes `verdict` to the gate-provided path, then
  # returns success — mimicking a reviewer agent that produced a verdict file.
  defp verdict_runner(verdict) do
    fn ctx ->
      File.mkdir_p!(Path.dirname(ctx.verdict_path))
      File.write!(ctx.verdict_path, Jason.encode!(verdict))
      {:ok, %{}}
    end
  end

  defp capture_comments(test_pid) do
    fn issue_id, body ->
      send(test_pid, {:review_comment, issue_id, body})
      :ok
    end
  end

  test "approve verdict allows the handoff", %{workspace: workspace} do
    runner = verdict_runner(%{"verdict" => "approve", "summary" => "looks good", "comments" => []})

    assert :ok =
             ReviewGate.run(workspace, issue(), nil, review_workflow(), session_runner: runner)
  end

  test "request_changes blocks with the reviewer comments as remediation", %{workspace: workspace} do
    runner =
      verdict_runner(%{
        "verdict" => "request_changes",
        "summary" => "needs work",
        "comments" => [
          %{"severity" => "blocker", "file" => "app/foo.ts", "line" => 12, "body" => "guard the nil case"}
        ]
      })

    assert {:blocked, remediation, [comment]} =
             ReviewGate.run(workspace, issue(), nil, review_workflow(), session_runner: runner)

    assert remediation =~ "requested changes (review pass 1 of 3)"
    assert remediation =~ "needs work"
    assert remediation =~ "app/foo.ts:12"
    assert remediation =~ "guard the nil case"
    assert %{severity: "blocker", file: "app/foo.ts", line: 12, body: "guard the nil case"} = comment
  end

  test "loops up to max_iterations then allows the handoff with a one-time note", %{workspace: workspace} do
    test_pid = self()

    runner =
      verdict_runner(%{
        "verdict" => "request_changes",
        "summary" => "still not there",
        "comments" => [%{"severity" => "major", "body" => "fix it"}]
      })

    opts = [session_runner: runner, comment_fn: capture_comments(test_pid)]

    # Three change-request passes, numbered 1..3.
    assert {:blocked, p1, _} = ReviewGate.run(workspace, issue(), nil, review_workflow(), opts)
    assert p1 =~ "pass 1 of 3"
    assert {:blocked, p2, _} = ReviewGate.run(workspace, issue(), nil, review_workflow(), opts)
    assert p2 =~ "pass 2 of 3"
    assert {:blocked, p3, _} = ReviewGate.run(workspace, issue(), nil, review_workflow(), opts)
    assert p3 =~ "pass 3 of 3"

    refute_received {:review_comment, _, _}

    # Budget spent: the next attempt is allowed and posts exactly one note.
    assert :ok = ReviewGate.run(workspace, issue(), nil, review_workflow(), opts)
    assert_received {:review_comment, "issue-1", body}
    assert body =~ "symphony:review-budget-exhausted"

    # A further attempt still allows, without re-posting the note.
    assert :ok = ReviewGate.run(workspace, issue(), nil, review_workflow(), opts)
    refute_received {:review_comment, _, _}
  end

  test "fails open and notes when the reviewer session errors", %{workspace: workspace} do
    test_pid = self()
    runner = fn _ctx -> {:error, :boom} end

    assert :ok =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               comment_fn: capture_comments(test_pid)
             )

    assert_received {:review_comment, "issue-1", body}
    assert body =~ "symphony:review-skipped"
    assert body =~ "review_session_failed"
  end

  test "fails open when no verdict file is written (clears stale verdicts first)", %{workspace: workspace} do
    test_pid = self()

    # Stale verdict from a previous run must not be trusted.
    verdict_path = Path.join(workspace, ".artifacts/symphony-review/verdict.json")
    File.mkdir_p!(Path.dirname(verdict_path))
    File.write!(verdict_path, Jason.encode!(%{"verdict" => "approve"}))

    runner = fn _ctx -> {:ok, %{}} end

    assert :ok =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               comment_fn: capture_comments(test_pid)
             )

    assert_received {:review_comment, "issue-1", body}
    assert body =~ "symphony:review-skipped"
    refute File.exists?(verdict_path)
  end

  test "fails open on an unparseable verdict", %{workspace: workspace} do
    runner = fn ctx ->
      File.mkdir_p!(Path.dirname(ctx.verdict_path))
      File.write!(ctx.verdict_path, "not json{")
      {:ok, %{}}
    end

    assert :ok = ReviewGate.run(workspace, issue(), nil, review_workflow(), session_runner: runner)
  end

  test "honors a custom max_iterations", %{workspace: workspace} do
    runner =
      verdict_runner(%{"verdict" => "request_changes", "comments" => [%{"body" => "x"}]})

    wf = review_workflow(%{"max_iterations" => 1})

    assert {:blocked, prompt, _} = ReviewGate.run(workspace, issue(), nil, wf, session_runner: runner)
    assert prompt =~ "pass 1 of 1"
    assert :ok = ReviewGate.run(workspace, issue(), nil, wf, session_runner: runner)
  end

  test "the reviewer tool executor is read-only and gate-free", %{workspace: workspace} do
    test_pid = self()

    runner = fn ctx ->
      send(test_pid, {:tool_executor, ctx.tool_executor})
      File.mkdir_p!(Path.dirname(ctx.verdict_path))
      File.write!(ctx.verdict_path, Jason.encode!(%{"verdict" => "approve"}))
      {:ok, %{}}
    end

    assert :ok =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               linear_client: fn query, _vars, _opts ->
                 send(test_pid, {:linear_called, query})
                 {:ok, %{"data" => %{"viewer" => %{"id" => "u1"}}}}
               end
             )

    assert_received {:tool_executor, tool_executor}

    # A read query is forwarded to the (test) Linear client.
    read = tool_executor.("linear_graphql", %{"query" => "query Viewer { viewer { id } }"})
    assert read["success"] == true
    assert_received {:linear_called, "query Viewer { viewer { id } }"}

    # A mutation is rejected before it can reach Linear.
    mutation =
      tool_executor.("linear_graphql", %{
        "query" => "mutation Move { issueUpdate(id: \"issue-1\", input: {stateId: \"s\"}) { success } }"
      })

    assert mutation["success"] == false
    refute_received {:linear_called, _}
  end

  test "returns :ok for issues without an id (fail open)", %{workspace: workspace} do
    runner = fn _ctx -> flunk("session should not run without an issue id") end

    assert :ok =
             ReviewGate.run(workspace, %Issue{identifier: "UDPE-9"}, nil, review_workflow(), session_runner: runner)
  end
end
