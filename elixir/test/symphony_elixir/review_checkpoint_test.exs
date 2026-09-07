defmodule SymphonyElixir.ReviewCheckpointTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{BehavioralEvidence, Github.PrReviewSection, ReviewCheckpoint}

  setup do
    workspace = Path.join(System.tmp_dir!(), "review-checkpoint-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    System.cmd("git", ["init", "--quiet"], cd: workspace)
    File.write!(Path.join(workspace, "AGENTS.md"), "Review all affected entry points.")
    System.cmd("git", ["add", "."], cd: workspace)
    System.cmd("git", ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--quiet", "-m", "initial"], cd: workspace)
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace)
    sha = String.trim(head)
    connection = %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}

    snapshot = %{
      "state" => "OPEN",
      "headRefOid" => sha,
      "baseRefOid" => sha,
      "body" => "User scope",
      "reviewDecision" => nil,
      "comments" => connection,
      "reviews" => connection,
      "reviewThreads" => %{connection | "nodes" => [%{"id" => "thread", "comments" => connection}]}
    }

    context = %{
      workspace: workspace,
      worker_host: nil,
      reviewed_sha: sha,
      pr: %{id: "PR_1", base_oid: sha},
      settings: %{},
      review_workflow: %{},
      packet_result: %{packet: %{candidate: %{base_sha: sha}, repository_rules: [%{path: "AGENTS.md"}]}},
      opts: [review_checkpoint_writer: fn _ -> :ok end, pr_runner: runner(snapshot)]
    }

    on_exit(fn -> File.rm_rf(workspace) end)
    %{context: context, snapshot: snapshot}
  end

  defp runner(snapshot), do: fn _, _ -> {Jason.encode!(%{"data" => %{"node" => snapshot}}), 0} end

  test "pins policy, full rules, packet and complete feedback; own section does not invalidate", %{context: context, snapshot: snapshot} do
    assert {:ok, identity} = ReviewCheckpoint.identity(context)
    assert Map.keys(identity) |> Enum.sort() == ~w(feedback packet policy rules)
    {:changed, managed_body} = PrReviewSection.apply_to_body("User scope", PrReviewSection.render(:focused, "Review text"))
    managed = %{context | opts: Keyword.put(context.opts, :pr_runner, runner(%{snapshot | "body" => managed_body}))}
    assert {:ok, ^identity} = ReviewCheckpoint.identity(managed)

    for changed <- [
          %{context | review_workflow: %{prompt: "new policy"}},
          %{context | packet_result: %{packet: Map.put(context.packet_result.packet, :evidence, "new proof")}},
          %{context | opts: Keyword.put(context.opts, :pr_runner, runner(%{snapshot | "body" => "Changed scope"}))}
        ] do
      assert {:ok, other} = ReviewCheckpoint.identity(changed)
      refute other == identity
    end
  end

  test "uncertain snapshots, pagination, missing rules, dirty work and remote workers disable reuse", %{context: context, snapshot: snapshot} do
    paginated = put_in(snapshot, ["comments", "pageInfo", "hasNextPage"], true)

    for changed <- [
          %{context | opts: []},
          %{context | worker_host: "remote"},
          %{context | reviewed_sha: "not-a-sha"},
          %{context | pr: nil},
          %{context | packet_result: %{packet: %{candidate: %{base_sha: context.reviewed_sha}, repository_rules: [%{path: "missing"}]}}},
          %{context | opts: Keyword.put(context.opts, :pr_runner, runner(paginated))},
          %{context | opts: Keyword.put(context.opts, :pr_runner, runner(%{snapshot | "reviews" => nil}))},
          %{context | opts: Keyword.put(context.opts, :pr_runner, fn _, _ -> raise "unavailable" end)}
        ] do
      assert {:error, :evidence_unavailable} = ReviewCheckpoint.identity(changed)
    end

    File.write!(Path.join(context.workspace, "untracked"), "changed")
    assert {:error, :evidence_unavailable} = ReviewCheckpoint.identity(context)
  end

  test "CLI unavailability fails closed", %{context: context} do
    cli_dir = Path.join(context.workspace, ".git/test-bin")
    File.mkdir_p!(cli_dir)
    File.write!(Path.join(cli_dir, "gh"), "#!/bin/sh\nexit 1\n")
    File.chmod!(Path.join(cli_dir, "gh"), 0o700)
    path = System.fetch_env!("PATH")
    System.put_env("PATH", cli_dir <> ":" <> path)
    on_exit(fn -> System.put_env("PATH", path) end)
    assert {:error, :evidence_unavailable} = ReviewCheckpoint.identity(%{context | opts: Keyword.delete(context.opts, :pr_runner)})
  end

  test "only bounded, unexpired approvals with identical inputs can resume" do
    identity = %{"packet" => "p", "policy" => "policy", "feedback" => "f", "rules" => "r"}
    verdict = %{"verdict" => "approve"}
    assert {:ok, saved} = ReviewCheckpoint.build(identity, verdict)
    assert {:ok, ^verdict} = ReviewCheckpoint.lookup(saved, identity)
    assert {:error, {:changed_inputs, ["feedback"]}} = ReviewCheckpoint.lookup(saved, %{identity | "feedback" => "new"})
    assert {:error, :checkpoint_expired} = ReviewCheckpoint.lookup(%{saved | "capturedAt" => 0}, identity)
    assert {:error, :not_approved} = ReviewCheckpoint.lookup(%{saved | "verdict" => %{"verdict" => "request_changes"}}, identity)
    large = %{"verdict" => "approve", "summary" => String.duplicate("x", 262_144)}
    assert {:error, :checkpoint_too_large} = ReviewCheckpoint.build(identity, large)
    assert {:error, :checkpoint_too_large} = ReviewCheckpoint.lookup(%{saved | "verdict" => large}, identity)
    assert {:error, :not_approved} = ReviewCheckpoint.build(identity, %{})
    assert {:error, :checkpoint_missing} = ReviewCheckpoint.lookup(nil, identity)
  end

  test "behavioral guidance maps task families to observable proof" do
    assert BehavioralEvidence.prompt_section(%{task_type: "concurrency_liveness"}).content =~ "bootstrap"
    assert BehavioralEvidence.prompt_section(%{task_type: "ui"}).content =~ "reduced motion"
    assert BehavioralEvidence.prompt_section(nil).content =~ "production-shaped boundary"
    assert BehavioralEvidence.review_guidance() =~ "acceptance criterion"
  end
end
