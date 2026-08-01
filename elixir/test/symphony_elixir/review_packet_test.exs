defmodule SymphonyElixir.ReviewPacketTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{Config, Linear.Issue, ReviewOutcome, ReviewPacket}

  setup do
    workspace = Path.join(System.tmp_dir!(), "review-packet-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    git!(workspace, ["init", "--quiet"])
    git!(workspace, ["config", "user.name", "Symphony Test"])
    git!(workspace, ["config", "user.email", "symphony@example.test"])
    File.write!(Path.join(workspace, "AGENTS.md"), "Security: preserve tenant authorization and never expose secrets.\n")
    File.write!(Path.join(workspace, "lib.ex"), "defmodule First do\nend\n")
    git!(workspace, ["add", "."])
    git!(workspace, ["commit", "--quiet", "-m", "base"])
    base_sha = git!(workspace, ["rev-parse", "HEAD"])

    File.write!(Path.join(workspace, "lib.ex"), "defmodule First do\n  def value, do: :ok\nend\n")
    git!(workspace, ["add", "."])
    git!(workspace, ["commit", "--quiet", "-m", "candidate"])
    head_sha = git!(workspace, ["rev-parse", "HEAD"])

    on_exit(fn -> File.rm_rf(workspace) end)
    {:ok, workspace: workspace, base_sha: base_sha, head_sha: head_sha}
  end

  test "first review packet is exact, complete, persisted, and bounded", context do
    settings = settings(%{"packet_max_bytes" => 24_000, "context_budget_tokens" => 6_000})
    issue = issue("Small implementation summary")

    assert {:ok, result} =
             ReviewPacket.build(
               context.workspace,
               issue,
               pr(context),
               context.head_sha,
               nil,
               settings,
               attestations: [attestation(context.head_sha)]
             )

    assert byte_size(result.encoded) <= 24_000
    assert result.packet.schema_version == 1
    assert result.packet.packet_id =~ "review-packet-v1-"
    assert result.packet.candidate.base_sha == context.base_sha
    assert result.packet.candidate.head_sha == context.head_sha
    assert result.packet.follow_up.kind == "first_review"
    assert result.packet.diff.mode == "first_full_diff"
    assert result.packet.diff.authoritative_full_diff.local_command =~ context.head_sha
    assert result.packet.issue.acceptance_criteria =~ "packet is bounded"
    assert [%{command: "mix test", head_sha: head_sha}] = result.packet.validation_attestations
    assert head_sha == context.head_sha
    assert Enum.any?(result.packet.repository_rules, & &1.security_relevant)
    assert result.packet.implementation.summary =~ "1 changed files"
    assert result.packet.implementation.known_risks == [result.packet.risk.rationale]
    assert issue.url in result.packet.implementation.evidence_links
    assert pr(context).url in result.packet.implementation.evidence_links
    assert result.packet.evidence_status.raw_evidence_artifact in result.packet.implementation.evidence_links
    assert File.regular?(result.path)
    assert File.regular?(result.archive_path)
    assert File.regular?(result.evidence_path)
    assert result.packet.evidence_status.raw_evidence_artifact =~ "/evidence/"

    assert %{"validation_attestations" => [%{"command" => "mix test"}]} =
             result.evidence_path |> File.read!() |> Jason.decode!()
  end

  test "oversized issue prose compacts deterministically without reducing candidate access", context do
    huge = String.duplicate("accept every edge case and preserve tenant isolation ", 5_000)
    settings = settings(%{"packet_max_bytes" => 8_192, "context_budget_tokens" => 2_048})
    issue = issue(huge)

    assert {:ok, first} =
             ReviewPacket.build(context.workspace, issue, pr(context), context.head_sha, nil, settings, attestations: [attestation(context.head_sha)])

    assert {:ok, second} =
             ReviewPacket.build(context.workspace, issue, pr(context), context.head_sha, nil, settings, attestations: [attestation(context.head_sha)])

    assert byte_size(first.encoded) <= 8_192
    assert first.packet.packet_id == second.packet.packet_id

    assert first.packet.diff.authoritative_full_diff.local_command ==
             second.packet.diff.authoritative_full_diff.local_command

    assert "issue_prose" in first.packet.compaction.compacted_fields
    assert first.packet.budgets.candidate_reduction_allowed == false
    assert Enum.any?(first.packet.repository_rules, &(&1.path == "AGENTS.md"))
  end

  test "follow-up carries originating findings and a bounded delta; high risk forces a final full diff", context do
    prior = %ReviewOutcome{
      outcome: :request_changes,
      iteration: 1,
      max_iterations: 3,
      reviewed_sha: context.head_sha,
      findings: [%{severity: "major", file: "lib.ex", line: 2, body: "Handle :error."}],
      resume_condition: "Fix it"
    }

    File.write!(Path.join(context.workspace, "auth.ex"), "defmodule Auth do\n  def check, do: :ok\nend\n")
    git!(context.workspace, ["add", "."])
    git!(context.workspace, ["commit", "--quiet", "-m", "follow-up"])
    new_head = git!(context.workspace, ["rev-parse", "HEAD"])
    pr = %{pr(context) | head_oid: new_head}
    delta_range = "#{context.head_sha}..#{new_head}"

    huge_delta_runner = fn
      ["diff", "--stat", "--find-renames", range], _workspace
      when range == delta_range ->
        {String.duplicate("large delta stat\n", 2_000), 0}

      args, workspace ->
        System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    end

    assert {:ok, result} =
             ReviewPacket.build(
               context.workspace,
               issue("Follow up"),
               pr,
               new_head,
               prior,
               settings(),
               attestations: [attestation(new_head)],
               git_runner: huge_delta_runner
             )

    assert result.packet.follow_up.kind == "changed_head_delta"
    assert result.packet.follow_up.prior_reviewed_sha == context.head_sha
    assert result.packet.follow_up.command == "git diff --find-renames #{context.head_sha}..#{new_head}"
    assert byte_size(result.packet.follow_up.stat) <= 2_000
    assert result.packet.follow_up.stat =~ "[compacted]"
    assert [%{originating_sha: originating_sha}] = result.packet.unresolved_findings
    assert originating_sha == context.head_sha
    assert result.packet.risk.level == "high"
    assert result.packet.diff.mode == "high_risk_final_full_diff"
  end

  test "missing diff and validation artifacts are explicit, not silently accepted", context do
    missing_runner = fn _args, _workspace -> {"not available", 1} end
    head = String.duplicate("a", 40)

    assert {:ok, result} =
             ReviewPacket.build(
               context.workspace,
               issue("Missing evidence"),
               %{number: 9, head_oid: head, base_oid: String.duplicate("b", 40)},
               head,
               nil,
               settings(),
               git_runner: missing_runner
             )

    assert "local_git_diff_manifest" in result.packet.evidence_status.missing_artifacts
    assert "exact_head_validation_attestations" in result.packet.evidence_status.missing_artifacts
    assert result.packet.diff.authoritative_full_diff.pull_request_command == "gh pr diff 9"
    assert "exact_head_validation_attestations" in result.packet.implementation.skipped_proof
    assert result.packet.risk.rationale in result.packet.implementation.known_risks
    assert result.packet.evidence_status.raw_evidence_artifact in result.packet.implementation.evidence_links
  end

  test "repository packet paths cannot escape the issue workspace", context do
    unsafe = settings(%{"packet_path" => "../../outside-review-packet.json"})

    assert {:error, {:packet_path_outside_workspace, "../../outside-review-packet.json"}} =
             ReviewPacket.build(
               context.workspace,
               issue("unsafe path"),
               pr(context),
               context.head_sha,
               nil,
               unsafe,
               attestations: [attestation(context.head_sha)]
             )
  end

  test "caller-provided implementation evidence overrides deterministic defaults", context do
    assert {:ok, result} =
             ReviewPacket.build(
               context.workspace,
               issue("overrides"),
               pr(context),
               context.head_sha,
               nil,
               settings(),
               attestations: [attestation(context.head_sha)],
               implementation_summary: "Caller summary",
               known_risks: ["Caller risk"],
               skipped_proof: ["Caller skipped proof"],
               evidence_links: ["https://evidence.example/artifact"]
             )

    assert result.packet.implementation.summary == "Caller summary"
    assert result.packet.implementation.known_risks == ["Caller risk"]
    assert result.packet.implementation.skipped_proof == ["Caller skipped proof"]
    assert "https://evidence.example/artifact" in result.packet.implementation.evidence_links
    assert result.packet.evidence_status.raw_evidence_artifact in result.packet.implementation.evidence_links
  end

  defp settings(overrides \\ %{}) do
    Config.review_settings(%{config: %{"review" => overrides}, prompt: "", prompt_template: ""})
  end

  defp issue(extra) do
    %Issue{
      id: "issue-packet",
      identifier: "UDPE-7158",
      title: "Bound review packets",
      url: "https://linear.example/UDPE-7158",
      description: """
      ## Required change
      Build an exact-head review packet. #{extra}

      ## Acceptance criteria
      The packet is bounded and the full diff remains accessible.

      ## Non-goals
      Do not include the implementor transcript.
      """
    }
  end

  defp pr(context) do
    %{
      id: "PR_18",
      number: 18,
      url: "https://github.example/org/repo/pull/18",
      repository: "org/repo",
      base_ref: "main",
      base_oid: context.base_sha,
      head_oid: context.head_sha
    }
  end

  defp attestation(head_sha) do
    %{
      command: "mix test",
      head_sha: head_sha,
      status: "passed",
      duration_ms: 123,
      environment: "test",
      harness_version: "symphony-test",
      artifact_refs: ["test.log"]
    }
  end

  defp git!(workspace, args) do
    case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end
end
