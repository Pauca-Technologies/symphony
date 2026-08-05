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
      write_verdict(ctx, verdict)
      {:ok, %{}}
    end
  end

  defp write_verdict(ctx, verdict) do
    complete =
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
    File.write!(ctx.verdict_path, Jason.encode!(complete))
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
        {Jason.encode!(%{
           "id" => "PR_7",
           "number" => 7,
           "body" => "Existing PR body.",
           "headRefOid" => "head-7"
         }), 0}

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

    assert {:approved, outcome} =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               pr_runner: pr_runner()
             )

    assert outcome.outcome == :approved
    assert outcome.authoritative
    assert outcome.reviewed_sha == "head-7"
  end

  test "review packet builder can be injected without changing approval semantics", %{
    workspace: workspace
  } do
    test_pid = self()

    packet_builder = fn workspace, issue, pr, reviewed_sha, prior_outcome, settings, opts ->
      send(test_pid, {:review_packet_builder, issue.identifier, reviewed_sha})

      SymphonyElixir.ReviewPacket.build(
        workspace,
        issue,
        pr,
        reviewed_sha,
        prior_outcome,
        settings,
        opts
      )
    end

    assert {:approved, %{authoritative: true}} =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               review_packet_builder: packet_builder,
               session_runner: verdict_runner(%{"verdict" => "approve", "summary" => "packet seam"}),
               pr_runner: pr_runner()
             )

    assert_received {:review_packet_builder, "UDPE-1", "head-7"}
  end

  test "review reuses the exact pre-hook base decision instead of fetching again", %{
    workspace: workspace
  } do
    runner = verdict_runner(%{"verdict" => "approve", "summary" => "fresh", "comments" => []})

    assert {:approved, outcome} =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               pr_runner: pr_runner(),
               base_drift_ref: "missing-base-that-would-fail",
               base_drift_decision: %{
                 action: "allow_fresh_base",
                 overlap_paths: [],
                 overlap_paths_omitted: 0
               }
             )

    assert outcome.authoritative
  end

  test "review does not trust a remote-worker bypass marker", %{workspace: workspace} do
    session_runner = fn _context -> flunk("review must not run without required base evidence") end

    assert {:automation_inconclusive, outcome} =
             ReviewGate.run(workspace, issue(), "builder-a", review_workflow(),
               session_runner: session_runner,
               pr_runner: pr_runner(),
               base_drift_ref: "main",
               base_drift_decision: %{action: "remote_worker_unavailable"},
               base_drift_ssh_runner: fn _host, _command, _opts ->
                 {:error, :worker_unreachable}
               end
             )

    assert outcome.failure_reason == {:base_drift_check_unavailable, {:git_failed, ["rev-parse", "HEAD"], 255, "remote git unavailable: :worker_unreachable"}}
  end

  test "direct review assessment reads base drift on the selected remote worker", %{
    workspace: workspace
  } do
    test_pid = self()

    ssh_runner = fn host, command, opts ->
      send(test_pid, {:remote_base_git, host, command, opts})

      output =
        cond do
          String.contains?(command, "'rev-parse' 'HEAD'") -> "head-7\n"
          String.contains?(command, "'rev-parse' 'refs/remotes/origin/main'") -> "base-7\n"
          String.contains?(command, "'merge-base'") -> "base-7\n"
          true -> ""
        end

      {:ok, {output, 0}}
    end

    assert {:approved, outcome} =
             ReviewGate.run(workspace, issue(), "builder-a", review_workflow(),
               session_runner: verdict_runner(%{"verdict" => "approve", "summary" => "remote base is fresh", "comments" => []}),
               pr_runner: pr_runner(),
               base_drift_ref: "main",
               base_drift_ssh_runner: ssh_runner
             )

    assert outcome.authoritative

    assert_received {:remote_base_git, "builder-a", command, [stderr_to_stdout: true]}
    assert command =~ "cd '#{workspace}' && git"
    assert_received {:remote_base_git, "builder-a", _command, [stderr_to_stdout: true]}
  end

  test "fresh reviewer receives a bounded exact-head packet without implementor transcript", %{
    workspace: workspace
  } do
    test_pid = self()
    issue = %{issue() | comments: [%{body: "IMPLEMENTOR-TRANSCRIPT-MUST-NOT-LEAK"}]}

    runner = fn ctx ->
      send(test_pid, {:review_context, ctx})

      write_verdict(ctx, %{
        "verdict" => "approve",
        "inspected" => ["git diff --find-renames base...head-7", "lib/"],
        "attestations" => %{"reused" => ["mix test"], "rerun" => ["mix test test/unit"]}
      })

      {:ok, %{}}
    end

    workflow =
      review_workflow(%{
        "packet_max_bytes" => 12_000,
        "context_budget_tokens" => 3_000,
        "turn_budget" => 99,
        "tool_output_max_bytes" => 2_000
      })

    assert {:approved, outcome} =
             ReviewGate.run(workspace, issue, nil, workflow,
               session_runner: runner,
               pr_runner: pr_runner()
             )

    assert_received {:review_context, ctx}
    assert ctx.packet.schema_version == 1
    assert ctx.packet.candidate.head_sha == "head-7"
    assert byte_size(Jason.encode!(ctx.packet)) <= 12_000
    assert ctx.review_settings.turn_budget == 1
    assert ctx.prompt =~ "This is a fresh reviewer thread"
    assert ctx.prompt =~ "fork_turns: \"none\""
    assert ctx.prompt =~ "authoritative full-diff commands"
    refute ctx.prompt =~ "IMPLEMENTOR-TRANSCRIPT-MUST-NOT-LEAK"
    assert outcome.packet_id == ctx.packet.packet_id
    assert outcome.inspected == ["git diff --find-renames base...head-7", "lib/"]
    assert outcome.attestation_report == %{reused: ["mix test"], rerun: ["mix test test/unit"]}
  end

  test "changed or missing verdict head is inconclusive and retried, never approved", %{
    workspace: workspace
  } do
    test_pid = self()

    runner = fn ctx ->
      send(test_pid, :mismatched_review_attempt)

      write_verdict(ctx, %{
        "verdict" => "approve",
        "reviewed_sha" => "older-head",
        "inspected" => ["complete diff"]
      })

      {:ok, %{}}
    end

    assert {:automation_inconclusive, outcome} =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               pr_runner: pr_runner()
             )

    assert_received :mismatched_review_attempt
    assert_received :mismatched_review_attempt

    assert {:verdict_unreadable, {:verdict_head_mismatch, %{expected: "head-7", reported: "older-head"}}} =
             outcome.failure_reason

    refute outcome.authoritative
  end

  test "high-risk follow-up cannot approve without a final full-diff attestation", %{
    workspace: workspace
  } do
    runner = fn ctx ->
      write_verdict(ctx, %{
        "verdict" => "approve",
        "full_diff_inspected" => false
      })

      {:ok, %{}}
    end

    assert {:automation_inconclusive, outcome} =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               pr_runner: pr_runner(),
               risk: :high
             )

    assert outcome.failure_reason ==
             {:verdict_unreadable, :verdict_missing_high_risk_full_diff_attestation}

    refute outcome.authoritative
  end

  test "resolved PR without head SHA does not borrow workspace HEAD authority", %{
    workspace: workspace
  } do
    {_, 0} = System.cmd("git", ["-C", workspace, "init", "--quiet"])
    File.write!(Path.join(workspace, "README.md"), "candidate\n")
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
        "candidate"
      ])

    {workspace_head, 0} = System.cmd("git", ["-C", workspace, "rev-parse", "HEAD"])
    assert String.trim(workspace_head) != ""

    unpinned_pr_runner = fn
      ["pr", "view" | _], _cwd ->
        {Jason.encode!(%{"id" => "PR_unpinned", "number" => 8, "body" => "Body."}), 0}

      ["api", "graphql" | _], _cwd ->
        {"", 0}
    end

    assert {:approved, outcome} =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: verdict_runner(%{"verdict" => "approve"}),
               pr_runner: unpinned_pr_runner
             )

    assert outcome.reviewed_sha == nil
    refute outcome.authoritative
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

    assert {:request_changes, remediation, outcome} =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               pr_runner: pr_runner()
             )

    assert [comment] = outcome.findings

    assert remediation =~ "requested changes (review pass 1 of 3)"
    assert remediation =~ "needs work"
    assert remediation =~ "app/foo.ts:12"
    assert remediation =~ "guard the nil case"
    assert %{severity: "blocker", file: "app/foo.ts", line: 12, body: "guard the nil case"} = comment
    assert outcome.severity_counts == %{"blocker" => 1}
  end

  test "budget exhaustion preserves findings, never approves, and does not spawn more reviewers", %{workspace: workspace} do
    test_pid = self()
    Process.put(:budget_review_runs, 0)

    runner = fn ctx ->
      Process.put(:budget_review_runs, Process.get(:budget_review_runs, 0) + 1)

      verdict = %{
        "verdict" => "request_changes",
        "summary" => "still not there",
        "comments" => [%{"severity" => "major", "body" => "fix it"}]
      }

      File.mkdir_p!(Path.dirname(ctx.verdict_path))
      write_verdict(ctx, verdict)
      {:ok, %{}}
    end

    opts = [session_runner: runner, comment_fn: capture_comments(test_pid), pr_runner: pr_runner()]

    # The first two change-request passes return remediation.
    assert {:request_changes, p1, _} = ReviewGate.run(workspace, issue(), nil, review_workflow(), opts)
    assert p1 =~ "pass 1 of 3"
    assert {:request_changes, p2, _} = ReviewGate.run(workspace, issue(), nil, review_workflow(), opts)
    assert p2 =~ "pass 2 of 3"

    refute_received {:review_comment, _, _}

    # The third verdict consumes the budget and escalates immediately.
    assert {:budget_exhausted_with_findings, outcome} =
             ReviewGate.run(workspace, issue(), nil, review_workflow(), opts)

    refute outcome.authoritative
    assert outcome.findings == [%{severity: "major", file: nil, line: nil, body: "fix it"}]
    assert outcome.severity_counts == %{"major" => 1}
    assert Process.get(:budget_review_runs) == 3
    assert_received {:review_comment, "issue-1", body}
    assert body =~ "symphony:review-budget-exhausted"
    assert body =~ "budget_exhausted_with_findings"
    assert body =~ "[major] fix it"
    assert body =~ "start a fresh orchestration run"

    assert {:budget_exhausted_with_findings, repeated} =
             ReviewGate.run(workspace, issue(), nil, review_workflow(), opts)

    assert repeated.findings == outcome.findings
    assert Process.get(:budget_review_runs) == 3
    refute_received {:review_comment, _, _}
  end

  test "reviewer crash is infrastructure_unavailable, latched, and never approves", %{workspace: workspace} do
    test_pid = self()

    runner = fn ctx ->
      attempt = Process.get(:review_attempt, 0) + 1
      Process.put(:review_attempt, attempt)
      send(test_pid, {:review_attempt, attempt, ctx.prompt})
      raise "reviewer crashed"
    end

    assert {:infrastructure_unavailable, outcome} =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               comment_fn: capture_comments(test_pid),
               pr_runner: pr_runner()
             )

    assert outcome.outcome == :infrastructure_unavailable
    assert outcome.failure_reason.class == :agent_protocol_failure
    refute outcome.authoritative

    assert_received {:review_attempt, 1, first_prompt}
    assert first_prompt =~ "Review UDPE-1"
    assert first_prompt =~ "Symphony automated-review runtime guard"
    assert first_prompt =~ "vitest --maxWorkers=2"
    assert first_prompt =~ "playwright test --workers=2"
    assert first_prompt =~ "you may"
    assert first_prompt =~ "sub-agents"
    refute first_prompt =~ "Do not spawn sub-agents"
    assert_received {:review_attempt, 2, retry_prompt}
    assert retry_prompt =~ "Symphony retry guard"
    assert retry_prompt =~ "review_session_failed"
    assert_received {:review_comment, "issue-1", body}
    assert body =~ "symphony:review-skipped"
    assert body =~ "review_session_failed"

    assert {:infrastructure_unavailable, repeated} =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               comment_fn: capture_comments(test_pid),
               pr_runner: pr_runner()
             )

    assert repeated == outcome
    assert Process.get(:review_attempt) == 2
    refute_received {:review_comment, _, _}
  end

  for {label, reason, expected_class} <- [
        {"timeout", {:turn_timeout, 60_000}, :response_timeout_or_stall},
        {"tool failure", {:tool_error, :unavailable}, :agent_protocol_failure},
        {"authentication failure", :unauthorized, :authentication_configuration}
      ] do
    test "#{label} is an explicit infrastructure_unavailable outcome", %{workspace: workspace} do
      issue = %{issue() | id: "issue-#{unquote(label)}"}
      runner = fn _ctx -> {:error, unquote(Macro.escape(reason))} end

      assert {:infrastructure_unavailable, outcome} =
               ReviewGate.run(workspace, issue, nil, review_workflow(),
                 session_runner: runner,
                 pr_runner: pr_runner(),
                 comment_fn: fn _issue_id, _body -> :ok end
               )

      assert outcome.failure_reason.class == unquote(expected_class)
      refute outcome.authoritative
    end
  end

  test "a later request_changes verdict replaces approval evidence", %{workspace: workspace} do
    runner = fn ctx ->
      verdict =
        case Process.get(:stale_approval_pass, 0) do
          0 ->
            %{"verdict" => "approve", "summary" => "first pass approved"}

          _ ->
            %{
              "verdict" => "request_changes",
              "summary" => "new blocker",
              "comments" => [%{"severity" => "blocker", "body" => "do not hand off"}]
            }
        end

      Process.put(:stale_approval_pass, Process.get(:stale_approval_pass, 0) + 1)
      File.mkdir_p!(Path.dirname(ctx.verdict_path))
      write_verdict(ctx, verdict)
      {:ok, %{}}
    end

    opts = [session_runner: runner, pr_runner: pr_runner()]

    assert {:approved, approved} =
             ReviewGate.run(workspace, issue(), nil, review_workflow(), opts)

    assert approved.authoritative

    assert {:request_changes, _prompt, changes} =
             ReviewGate.run(workspace, issue(), nil, review_workflow(), opts)

    refute changes.authoritative
    assert changes.summary == "new blocker"
    assert changes.severity_counts == %{"blocker" => 1}
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
        write_verdict(
          ctx,
          %{
            "verdict" => "approve",
            "review_effort" => "focused",
            "human_review" => "Session retry completed the review.",
            "comments" => []
          }
        )

        {:ok, %{}}
      end
    end

    assert {:approved, outcome} =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               comment_fn: capture_comments(test_pid),
               pr_runner: pr_runner(test_pid)
             )

    assert outcome.attempts == 2

    assert_received {:review_session_attempt, 1, _first_prompt}
    assert_received {:review_session_attempt, 2, retry_prompt}
    assert retry_prompt =~ "Symphony retry guard"
    assert retry_prompt =~ "turn_aborted"
    assert_received {:pr_edit, body}
    assert body =~ "Session retry completed the review."
    refute_received {:review_comment, _, _}
  end

  test "missing verdict is automation_inconclusive and clears stale approval", %{workspace: workspace} do
    test_pid = self()

    # Stale verdict from a previous run must not be trusted.
    verdict_path = Path.join(workspace, ".artifacts/symphony-review/verdict.json")
    File.mkdir_p!(Path.dirname(verdict_path))
    File.write!(verdict_path, Jason.encode!(%{"verdict" => "approve"}))

    runner = fn _ctx -> {:ok, %{}} end

    assert {:automation_inconclusive, outcome} =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               comment_fn: capture_comments(test_pid),
               pr_runner: pr_runner()
             )

    assert outcome.failure_reason == {:verdict_unreadable, :enoent}
    refute outcome.authoritative

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

        write_verdict(
          ctx,
          %{
            "verdict" => "approve",
            "review_effort" => "focused",
            "human_review" => "Retry produced the review guidance.",
            "comments" => []
          }
        )
      end

      {:ok, %{}}
    end

    assert {:approved, outcome} =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               comment_fn: capture_comments(test_pid),
               pr_runner: pr_runner(test_pid)
             )

    assert outcome.attempts == 2

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

      write_verdict(ctx, verdict)
      {:ok, %{}}
    end

    assert {:approved, outcome} =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               comment_fn: capture_comments(test_pid),
               pr_runner: pr_runner(test_pid)
             )

    assert outcome.attempts == 2

    assert_received {:review_interim_attempt, 1, _first_prompt}
    assert_received {:review_interim_attempt, 2, retry_prompt}
    assert retry_prompt =~ "interim_verdict"
    assert_received {:pr_edit, body}
    assert body =~ "Retry completed a real review."
    refute_received {:review_comment, _, _}
  end

  test "malformed verdict is automation_inconclusive", %{workspace: workspace} do
    runner = fn ctx ->
      File.mkdir_p!(Path.dirname(ctx.verdict_path))
      File.write!(ctx.verdict_path, "not json{")
      {:ok, %{}}
    end

    assert {:automation_inconclusive, outcome} =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               pr_runner: pr_runner()
             )

    assert match?({:verdict_unreadable, %Jason.DecodeError{}}, outcome.failure_reason)
    refute outcome.authoritative
  end

  test "passes reviewer events to the lifecycle heartbeat callback", %{workspace: workspace} do
    test_pid = self()

    runner = fn ctx ->
      ctx.on_message.(%{event: :notification, timestamp: DateTime.utc_now()})
      File.mkdir_p!(Path.dirname(ctx.verdict_path))
      write_verdict(ctx, %{"verdict" => "approve"})
      {:ok, %{}}
    end

    assert {:approved, _outcome} =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               pr_runner: pr_runner(),
               on_message: fn update -> send(test_pid, {:review_heartbeat, update}) end
             )

    assert_received {:review_heartbeat, %{event: :notification}}
  end

  test "max_iterations one escalates on the first request_changes verdict", %{workspace: workspace} do
    runner =
      verdict_runner(%{"verdict" => "request_changes", "comments" => [%{"body" => "x"}]})

    wf = review_workflow(%{"max_iterations" => 1})
    opts = [session_runner: runner, pr_runner: pr_runner()]

    assert {:budget_exhausted_with_findings, outcome} =
             ReviewGate.run(workspace, issue(), nil, wf, opts)

    assert outcome.findings == [%{severity: "comment", file: nil, line: nil, body: "x"}]
    assert outcome.iteration == 1
  end

  test "the reviewer tool executor is read-only and gate-free", %{workspace: workspace} do
    test_pid = self()

    runner = fn ctx ->
      send(test_pid, {:tool_executor, ctx.tool_executor})
      File.mkdir_p!(Path.dirname(ctx.verdict_path))
      write_verdict(ctx, %{"verdict" => "approve"})
      {:ok, %{}}
    end

    assert {:approved, _outcome} =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               pr_runner: pr_runner(),
               linear_client: fn query, variables, _opts ->
                 send(test_pid, {:linear_called, query, variables})

                 {:ok, %{"data" => %{"viewer" => %{"id" => "u1"}}}}
               end
             )

    assert_received {:tool_executor, tool_executor}

    # A read query is forwarded to the (test) Linear client.
    read = tool_executor.("linear_graphql", %{"query" => "query Viewer { viewer { id } }"})
    assert read["success"] == true
    assert_received {:linear_called, "query Viewer { viewer { id } }", %{}}

    # A mutation is rejected before it can reach Linear.
    mutation =
      tool_executor.("linear_graphql", %{
        "query" => "mutation Move { issueUpdate(id: \"issue-1\", input: {stateId: \"s\"}) { success } }"
      })

    assert mutation["success"] == false
    refute_received {:linear_called, _, _}
  end

  test "successful reviewer tool output is compacted to the configured hard bound", %{
    workspace: workspace
  } do
    test_pid = self()

    runner = fn ctx ->
      response =
        ctx.tool_executor.("linear_graphql", %{
          "query" => "query Large { viewer { id } }"
        })

      failure =
        ctx.tool_executor.("linear_graphql", %{
          "query" => "query LargeFailure { viewer { id } }"
        })

      send(test_pid, {:bounded_tool_response, response, failure})
      write_verdict(ctx, %{"verdict" => "approve"})
      {:ok, %{}}
    end

    workflow = review_workflow(%{"tool_output_max_bytes" => 512})

    assert {:approved, _outcome} =
             ReviewGate.run(workspace, issue(), nil, workflow,
               session_runner: runner,
               pr_runner: pr_runner(),
               linear_client: fn query, _variables, _opts ->
                 if query =~ "LargeFailure" do
                   {:ok, %{"errors" => [%{"message" => String.duplicate("failure detail", 200)}]}}
                 else
                   {:ok, %{"data" => %{"rows" => String.duplicate("évidence", 2_000)}}}
                 end
               end
             )

    assert_received {:bounded_tool_response, response, failure}
    assert response["success"]
    assert byte_size(response["output"]) <= 512
    assert [%{"text" => text}] = response["contentItems"]
    assert text == response["output"]

    assert %{
             "compacted" => true,
             "original_bytes" => original_bytes,
             "max_bytes" => 512,
             "recovery" => recovery,
             "preview" => _preview
           } = Jason.decode!(response["output"])

    assert original_bytes > 512
    assert recovery =~ "narrower query"
    refute failure["success"]
    assert byte_size(failure["output"]) > 512
    assert [%{"text" => failure_text}] = failure["contentItems"]
    assert failure_text == failure["output"]
    assert %{"errors" => [%{"message" => message}]} = Jason.decode!(failure["output"])
    assert message =~ "failure detail"
  end

  test "oversized review workflow fails closed at the final context ceiling", %{
    workspace: workspace
  } do
    runner = fn _ctx -> flunk("review session must not start over the context ceiling") end
    huge_prompt = "Review {{ issue.identifier }}\n" <> String.duplicate("workflow evidence ", 20_000)

    workflow = %{
      config: %{"review" => %{"context_budget_tokens" => 6_144}},
      prompt: huge_prompt,
      prompt_template: huge_prompt
    }

    assert {:automation_inconclusive, outcome} =
             ReviewGate.run(workspace, issue(), nil, workflow,
               session_runner: runner,
               pr_runner: pr_runner()
             )

    assert {:review_prompt_unavailable, {:review_context_budget_exceeded, actual_bytes, max_bytes}} = outcome.failure_reason

    assert actual_bytes > max_bytes
    assert max_bytes == 6_144 * 3
  end

  test "minimum context budget admits a normal packet without truncating the candidate", %{
    workspace: workspace
  } do
    test_pid = self()

    runner = fn ctx ->
      send(test_pid, {:minimum_context_prompt, byte_size(ctx.prompt), ctx.packet})
      write_verdict(ctx, %{"verdict" => "approve"})
      {:ok, %{}}
    end

    workflow = review_workflow(%{"context_budget_tokens" => 6_144, "packet_max_bytes" => 8_192})

    assert {:approved, _outcome} =
             ReviewGate.run(workspace, issue(), nil, workflow,
               session_runner: runner,
               pr_runner: pr_runner()
             )

    assert_received {:minimum_context_prompt, prompt_bytes, packet}
    assert prompt_bytes <= 6_144 * 3
    assert packet.budgets.candidate_reduction_allowed == false
    assert packet.candidate.head_sha == "head-7"
    assert packet.diff.authoritative_full_diff.pull_request_command == "gh pr diff 7"
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

    assert {:approved, outcome} =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               pr_runner: pr_runner(test_pid)
             )

    assert outcome.authoritative

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
        "id,number,body,url,headRefOid,baseRefOid,baseRefName,changedFiles,headRepository"
      ],
      _cwd ->
        {Jason.encode!(%{
           "id" => "PR_1358",
           "number" => 1358,
           "body" => "Existing PR body.",
           "headRefOid" => "head-1358"
         }), 0}

      [
        "pr",
        "view",
        "--json",
        "id,number,body,url,headRefOid,baseRefOid,baseRefName,changedFiles,headRepository"
      ],
      _cwd ->
        flunk("must not rely on current branch PR detection when Linear has a PR attachment")

      ["api", "graphql" | _] = args, _cwd ->
        send(test_pid, {:pr_edit, graphql_body_arg(args)})
        {"", 0}
    end

    assert {:approved, outcome} =
             ReviewGate.run(workspace, issue, nil, review_workflow(),
               session_runner: runner,
               pr_runner: pr_runner
             )

    assert outcome.reviewed_sha == "head-1358"

    assert_received {:pr_edit, body}
    assert body =~ "<!-- symphony:review:start -->"
    assert body =~ "Check the handoff review path."
  end

  test "missing required PR is automation_inconclusive", %{workspace: workspace} do
    test_pid = self()
    runner = fn _ctx -> flunk("the reviewer session must not run without a PR") end

    no_pr = fn ["pr", "view" | _], _cwd -> {"no pull requests found", 1} end

    assert {:automation_inconclusive, outcome} =
             ReviewGate.run(workspace, issue(), nil, review_workflow(),
               session_runner: runner,
               pr_runner: no_pr,
               comment_fn: capture_comments(test_pid)
             )

    assert outcome.failure_reason == {:no_pr, :no_pr}
    refute outcome.authoritative

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

    assert {:approved, outcome} =
             ReviewGate.run(workspace, issue(), nil, wf, session_runner: runner, pr_runner: pr_runner)

    refute outcome.authoritative
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

    wf = review_workflow(%{"max_iterations" => 2})
    opts = [session_runner: runner, pr_runner: pr_runner(test_pid), comment_fn: capture_comments(test_pid)]

    # Pass 1: request_changes -> section reflects the reviewer's medium tier.
    assert {:request_changes, _, _} = ReviewGate.run(workspace, issue(), nil, wf, opts)
    assert_received {:pr_edit, first_body}
    assert first_body =~ "🟠 **Focused**"

    # Pass 2 consumes the budget -> section is overwritten immediately to high / did-not-converge.
    assert {:budget_exhausted_with_findings, outcome} =
             ReviewGate.run(workspace, issue(), nil, wf, opts)

    assert outcome.outcome == :budget_exhausted_with_findings
    assert_received {:pr_edit, second_body}
    assert second_body =~ "🔴 **Thorough**"
    assert second_body =~ "without converging"
    assert second_body =~ "handoff was **withheld"
    assert second_body =~ "remains unapproved by automation"
    refute second_body =~ "allowed through"
  end

  test "invalid review context is automation_inconclusive", %{workspace: workspace} do
    runner = fn _ctx -> flunk("session should not run without an issue id") end

    assert {:automation_inconclusive, outcome} =
             ReviewGate.run(workspace, %Issue{identifier: "UDPE-9"}, nil, review_workflow(), session_runner: runner)

    assert outcome.failure_reason == :invalid_review_context
  end
end
