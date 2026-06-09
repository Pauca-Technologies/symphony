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

  # Stub `gh` runner: pretends a PR exists and accepts edits, so the verdict
  # tests exercise the gate (and PR-section write) without shelling real gh.
  # When given a test pid, it forwards the edited PR body for assertions.
  defp pr_runner(test_pid \\ nil) do
    fn
      ["pr", "view" | _], _cwd ->
        {Jason.encode!(%{"id" => "PR_7", "number" => 7, "body" => "Existing PR body."}), 0}

      ["api", "graphql" | _] = args, _cwd ->
        if test_pid, do: send(test_pid, {:pr_edit, graphql_body_arg(args)})
        {"", 0}
    end
  end

  defp graphql_body_arg(args) do
    args
    |> Enum.find(&String.starts_with?(&1, "body="))
    |> String.replace_prefix("body=", "")
  end

  test "approve verdict allows the handoff", %{workspace: workspace} do
    runner = verdict_runner(%{"verdict" => "approve", "summary" => "looks good", "comments" => []})

    assert :ok =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               pr_runner: pr_runner()
             )
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
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               pr_runner: pr_runner()
             )

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

    opts = [session_runner: runner, comment_fn: capture_comments(test_pid), pr_runner: pr_runner()]

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

    runner = fn ctx ->
      attempt = Process.get(:review_attempt, 0) + 1
      Process.put(:review_attempt, attempt)
      send(test_pid, {:review_attempt, attempt, ctx.prompt})
      {:error, :boom}
    end

    assert :ok =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               comment_fn: capture_comments(test_pid),
               pr_runner: pr_runner()
             )

    assert_received {:review_attempt, 1, first_prompt}
    assert first_prompt =~ "Review UDPE-1"
    assert first_prompt =~ "Symphony automated-review runtime guard"
    assert first_prompt =~ "you may"
    assert first_prompt =~ "sub-agents"
    refute first_prompt =~ "Do not spawn sub-agents"
    assert_received {:review_attempt, 2, retry_prompt}
    assert retry_prompt =~ "Symphony retry guard"
    assert retry_prompt =~ "review_session_failed"
    assert_received {:review_comment, "issue-1", body}
    assert body =~ "symphony:review-skipped"
    assert body =~ "review_session_failed"
  end

  test "retries once when the reviewer session fails before producing a verdict", %{workspace: workspace} do
    test_pid = self()

    runner = fn ctx ->
      attempt = Process.get(:review_session_attempt, 0) + 1
      Process.put(:review_session_attempt, attempt)
      send(test_pid, {:review_session_attempt, attempt, ctx.prompt})

      if attempt == 1 do
        {:error, {:turn_aborted, %{"reason" => "interrupted", "turn_id" => "turn-1"}}}
      else
        File.mkdir_p!(Path.dirname(ctx.verdict_path))

        File.write!(
          ctx.verdict_path,
          Jason.encode!(%{
            "verdict" => "approve",
            "review_effort" => "focused",
            "human_review" => "Session retry completed the review.",
            "comments" => []
          })
        )

        {:ok, %{}}
      end
    end

    assert :ok =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               comment_fn: capture_comments(test_pid),
               pr_runner: pr_runner(test_pid)
             )

    assert_received {:review_session_attempt, 1, _first_prompt}
    assert_received {:review_session_attempt, 2, retry_prompt}
    assert retry_prompt =~ "Symphony retry guard"
    assert retry_prompt =~ "turn_aborted"
    assert_received {:pr_edit, body}
    assert body =~ "Session retry completed the review."
    refute_received {:review_comment, _, _}
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
               comment_fn: capture_comments(test_pid),
               pr_runner: pr_runner()
             )

    assert_received {:review_comment, "issue-1", body}
    assert body =~ "symphony:review-skipped"
    refute File.exists?(verdict_path)
  end

  test "retries once when the reviewer completes without a verdict", %{workspace: workspace} do
    test_pid = self()

    runner = fn ctx ->
      attempt = Process.get(:review_attempt, 0) + 1
      Process.put(:review_attempt, attempt)
      send(test_pid, {:review_attempt, attempt, ctx.prompt})

      if attempt == 2 do
        File.mkdir_p!(Path.dirname(ctx.verdict_path))

        File.write!(
          ctx.verdict_path,
          Jason.encode!(%{
            "verdict" => "approve",
            "review_effort" => "focused",
            "human_review" => "Retry produced the review guidance.",
            "comments" => []
          })
        )
      end

      {:ok, %{}}
    end

    assert :ok =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               comment_fn: capture_comments(test_pid),
               pr_runner: pr_runner(test_pid)
             )

    assert_received {:review_attempt, 1, first_prompt}
    assert first_prompt =~ "Review UDPE-1"
    assert first_prompt =~ "Symphony automated-review runtime guard"
    assert first_prompt =~ "you may"
    assert first_prompt =~ "sub-agents"
    refute first_prompt =~ "Do not spawn sub-agents"
    assert first_prompt =~ "Do not run package-manager validation commands"
    assert first_prompt =~ "Symphony review tool-output guard"
    assert first_prompt =~ "Symphony verdict reliability guard"
    assert first_prompt =~ "write a valid interim verdict"
    assert first_prompt =~ ~s("symphony_interim": true)
    assert first_prompt =~ "Before starting any long-running command or broad validation check"
    assert first_prompt =~ "Do not run broad searches in `node_modules`"
    assert first_prompt =~ "--glob '!node_modules/**'"
    assert_received {:review_attempt, 2, retry_prompt}
    assert retry_prompt =~ "Symphony review tool-output guard"
    assert retry_prompt =~ "Symphony verdict reliability guard"
    assert retry_prompt =~ "Symphony retry guard"
    assert retry_prompt =~ "ended without a readable verdict file"
    assert_received {:pr_edit, body}
    assert body =~ "Retry produced the review guidance."
    refute_received {:review_comment, _, _}
  end

  test "does not treat an interim verdict placeholder as final reviewer output", %{workspace: workspace} do
    test_pid = self()

    runner = fn ctx ->
      attempt = Process.get(:review_interim_attempt, 0) + 1
      Process.put(:review_interim_attempt, attempt)
      send(test_pid, {:review_interim_attempt, attempt, ctx.prompt})
      File.mkdir_p!(Path.dirname(ctx.verdict_path))

      verdict =
        if attempt == 1 do
          %{
            "verdict" => "request_changes",
            "summary" => "Interim verdict while review is in progress.",
            "review_effort" => "thorough",
            "human_review" => "Interim guidance: review is still in progress.",
            "comments" => [
              %{
                "severity" => "major",
                "file" => ".artifacts/symphony-review/verdict.json",
                "body" => "Interim placeholder: final review has not completed yet."
              }
            ]
          }
        else
          %{
            "verdict" => "approve",
            "review_effort" => "skim",
            "human_review" => "Retry completed a real review.",
            "comments" => []
          }
        end

      File.write!(ctx.verdict_path, Jason.encode!(verdict))
      {:ok, %{}}
    end

    assert :ok =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               comment_fn: capture_comments(test_pid),
               pr_runner: pr_runner(test_pid)
             )

    assert_received {:review_interim_attempt, 1, _first_prompt}
    assert_received {:review_interim_attempt, 2, retry_prompt}
    assert retry_prompt =~ "interim_verdict"
    assert_received {:pr_edit, body}
    assert body =~ "Retry completed a real review."
    refute_received {:review_comment, _, _}
  end

  test "fails open on an unparseable verdict", %{workspace: workspace} do
    runner = fn ctx ->
      File.mkdir_p!(Path.dirname(ctx.verdict_path))
      File.write!(ctx.verdict_path, "not json{")
      {:ok, %{}}
    end

    assert :ok =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               pr_runner: pr_runner()
             )
  end

  test "honors a custom max_iterations", %{workspace: workspace} do
    runner =
      verdict_runner(%{"verdict" => "request_changes", "comments" => [%{"body" => "x"}]})

    wf = review_workflow(%{"max_iterations" => 1})
    opts = [session_runner: runner, pr_runner: pr_runner()]

    assert {:blocked, prompt, _} = ReviewGate.run(workspace, issue(), nil, wf, opts)
    assert prompt =~ "pass 1 of 1"
    assert :ok = ReviewGate.run(workspace, issue(), nil, wf, opts)
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
               pr_runner: pr_runner(),
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

  test "writes the human-review section to the PR on approve", %{workspace: workspace} do
    test_pid = self()

    runner =
      verdict_runner(%{
        "verdict" => "approve",
        "review_effort" => "skim",
        "human_review" => "Mostly skimmable; focus on `lib/foo.ex`.",
        "comments" => []
      })

    assert :ok =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               pr_runner: pr_runner(test_pid)
             )

    assert_received {:pr_edit, body}
    assert body =~ "<!-- symphony:review:start -->"
    assert body =~ "## 🤖 How to review this PR"
    assert body =~ "🔵 **Skim**"
    assert body =~ "Mostly skimmable; focus on `lib/foo.ex`."
  end

  test "resolves the PR from the Linear attachment before requiring branch inference", %{workspace: workspace} do
    test_pid = self()

    issue = %{issue() | attachment_urls: ["https://github.com/Pauca-Technologies/udp-dashboard-v2/pull/1358"]}

    runner =
      verdict_runner(%{
        "verdict" => "approve",
        "review_effort" => "focused",
        "human_review" => "Check the handoff review path.",
        "comments" => []
      })

    pr_runner = fn
      [
        "pr",
        "view",
        "https://github.com/Pauca-Technologies/udp-dashboard-v2/pull/1358",
        "--json",
        "id,number,body"
      ],
      _cwd ->
        {Jason.encode!(%{"id" => "PR_1358", "number" => 1358, "body" => "Existing PR body."}), 0}

      ["pr", "view", "--json", "id,number,body"], _cwd ->
        flunk("must not rely on current branch PR detection when Linear has a PR attachment")

      ["api", "graphql" | _] = args, _cwd ->
        send(test_pid, {:pr_edit, graphql_body_arg(args)})
        {"", 0}
    end

    assert :ok =
             ReviewGate.run(workspace, issue, nil, review_workflow(),
               session_runner: runner,
               pr_runner: pr_runner
             )

    assert_received {:pr_edit, body}
    assert body =~ "<!-- symphony:review:start -->"
    assert body =~ "Check the handoff review path."
  end

  test "skips the reviewer entirely when no PR is present (require_pr)", %{workspace: workspace} do
    test_pid = self()
    runner = fn _ctx -> flunk("the reviewer session must not run without a PR") end

    no_pr = fn ["pr", "view" | _], _cwd -> {"no pull requests found", 1} end

    assert :ok =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               pr_runner: no_pr,
               comment_fn: capture_comments(test_pid)
             )

    assert_received {:review_comment, "issue-1", body}
    assert body =~ "symphony:review-skipped"
    refute_received {:pr_edit, _}
  end

  test "reviews on the diff but skips the annotation when require_pr is false", %{workspace: workspace} do
    runner = verdict_runner(%{"verdict" => "approve", "review_effort" => "none", "comments" => []})

    pr_runner = fn
      ["pr", "view" | _], _cwd -> {"no pull requests found", 1}
      ["api", "graphql" | _], _cwd -> flunk("must not edit a PR that does not exist")
    end

    wf = review_workflow(%{"require_pr" => false})

    assert :ok =
             ReviewGate.run(workspace, issue(), nil, wf, session_runner: runner, pr_runner: pr_runner)
  end

  test "budget exhaustion refreshes the section to elevated risk", %{workspace: workspace} do
    test_pid = self()

    runner =
      verdict_runner(%{
        "verdict" => "request_changes",
        "review_effort" => "focused",
        "human_review" => "needs another pass",
        "comments" => [%{"body" => "fix"}]
      })

    wf = review_workflow(%{"max_iterations" => 1})
    opts = [session_runner: runner, pr_runner: pr_runner(test_pid), comment_fn: capture_comments(test_pid)]

    # Pass 1: request_changes -> section reflects the reviewer's medium tier.
    assert {:blocked, _, _} = ReviewGate.run(workspace, issue(), nil, wf, opts)
    assert_received {:pr_edit, first_body}
    assert first_body =~ "🟠 **Focused**"

    # Pass 2: budget spent -> section is overwritten to high / did-not-converge.
    assert :ok = ReviewGate.run(workspace, issue(), nil, wf, opts)
    assert_received {:pr_edit, second_body}
    assert second_body =~ "🔴 **Thorough**"
    assert second_body =~ "without converging"
  end

  test "returns :ok for issues without an id (fail open)", %{workspace: workspace} do
    runner = fn _ctx -> flunk("session should not run without an issue id") end

    assert :ok =
             ReviewGate.run(workspace, %Issue{identifier: "UDPE-9"}, nil, review_workflow(), session_runner: runner)
  end
end
