defmodule SymphonyElixir.BaseDriftTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.BaseDrift
  alias SymphonyElixir.Linear.Issue

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-base-drift-#{System.unique_integer([:positive])}")
    origin = Path.join(root, "origin.git")
    seed = Path.join(root, "seed")
    workspace = Path.join(root, "workspace")
    upstream = Path.join(root, "upstream")
    File.mkdir_p!(root)

    git!(root, ["init", "--bare", origin])
    git!(root, ["clone", origin, seed])
    configure!(seed)
    File.mkdir_p!(Path.join(seed, "lib"))
    File.mkdir_p!(Path.join(seed, "docs"))
    File.write!(Path.join(seed, "lib/account.ex"), "account = :initial\n")
    File.write!(Path.join(seed, "docs/readme.md"), "initial\n")
    git!(seed, ["add", "."])
    git!(seed, ["commit", "-m", "initial"])
    git!(seed, ["branch", "-M", "main"])
    git!(seed, ["push", "-u", "origin", "main"])
    git!(origin, ["symbolic-ref", "HEAD", "refs/heads/main"])

    git!(root, ["clone", origin, workspace])
    configure!(workspace)
    git!(workspace, ["checkout", "-b", "candidate"])

    git!(root, ["clone", origin, upstream])
    configure!(upstream)

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, workspace: workspace, upstream: upstream}
  end

  test "a disjoint base advance blocks review until the candidate is current", context do
    commit_file!(context.workspace, "lib/candidate.ex", "candidate\n", "candidate")
    commit_file!(context.upstream, "docs/readme.md", "upstream docs\n", "docs advance")
    git!(context.upstream, ["push", "origin", "main"])

    issue = issue()

    assert {:defer, remediation, decision} = BaseDrift.assess(context.workspace, issue, "main")
    assert decision.action == "defer_stale_base"
    assert decision.base_advanced
    assert decision.overlap_paths == []
    assert decision.candidate_paths == ["lib/candidate.ex"]
    assert decision.upstream_paths == ["docs/readme.md"]
    assert decision.gates_avoided == 1
    assert remediation =~ "does not contain the current origin/main base"
    assert remediation =~ "upstream paths do not directly overlap"
  end

  test "a changed handoff runtime blocks a disjoint candidate until it refreshes", context do
    commit_file!(context.workspace, "lib/candidate.ex", "candidate\n", "candidate")

    commit_file!(
      context.upstream,
      "scripts/hooks/before-handoff.sh",
      "#!/usr/bin/env bash\nexit 0\n",
      "fix handoff hook"
    )

    git!(context.upstream, ["push", "origin", "main"])

    assert {:defer, remediation, decision} =
             BaseDrift.assess(context.workspace, issue(), "main", hook_command: "scripts/hooks/before-handoff.sh")

    assert decision.candidate_paths == ["lib/candidate.ex"]

    assert decision.critical_paths == [
             "WORKFLOW.md",
             "WORKFLOW_REVIEW.md",
             "scripts/hooks/before-handoff.sh"
           ]

    assert decision.critical_overlap_paths == ["scripts/hooks/before-handoff.sh"]
    assert decision.overlap_paths == ["scripts/hooks/before-handoff.sh"]
    assert remediation =~ "paths required by the configured handoff runtime"
  end

  test "extracts only normalized repository paths from a handoff command" do
    command = """
    if [ -x ./scripts/hooks/before-handoff.sh ]; then
      bash ./scripts/hooks/before-handoff.sh --base origin/develop
    fi
    """

    assert BaseDrift.handoff_runtime_paths(command) == [
             "WORKFLOW.md",
             "WORKFLOW_REVIEW.md",
             "scripts/hooks/before-handoff.sh"
           ]
  end

  test "overlapping base advance avoids stale gates and preserves dirty work", context do
    commit_file!(context.workspace, "lib/account.ex", "account = :candidate\n", "candidate account")
    commit_file!(context.upstream, "lib/account.ex", "account = :upstream\n", "upstream account")
    git!(context.upstream, ["push", "origin", "main"])
    File.write!(Path.join(context.workspace, "scratch.txt"), "do not discard\n")

    head_before = git!(context.workspace, ["rev-parse", "HEAD"])
    status_before = git!(context.workspace, ["status", "--porcelain"])

    assert {:defer, remediation, decision} =
             BaseDrift.assess(context.workspace, issue(), "main")

    assert decision.action == "defer_overlapping_drift"
    assert decision.overlap_paths == ["lib/account.ex"]
    assert decision.dirty
    assert decision.gates_avoided == 1
    assert remediation =~ "do not run an automatic rebase, reset, or stash"
    assert remediation =~ "Expensive gates were intentionally not run"
    assert git!(context.workspace, ["rev-parse", "HEAD"]) == head_before
    assert git!(context.workspace, ["status", "--porcelain"]) == status_before
    assert File.read!(Path.join(context.workspace, "scratch.txt")) == "do not discard\n"
  end

  test "a refreshed branch clears stale reservation risk", context do
    commit_file!(context.workspace, "lib/candidate.ex", "candidate\n", "candidate")
    commit_file!(context.upstream, "docs/readme.md", "upstream docs\n", "docs advance")
    git!(context.upstream, ["push", "origin", "main"])

    git!(context.workspace, ["fetch", "origin", "main"])
    git!(context.workspace, ["rebase", "origin/main"])

    assert {:ok, decision} = BaseDrift.assess(context.workspace, issue(), "main")
    assert decision.action == "allow_fresh_base"
    refute decision.base_advanced
    assert decision.candidate_base_sha == decision.current_base_sha
  end

  test "a later handoff attempt refetches instead of trusting stale process state", context do
    commit_file!(context.workspace, "lib/account.ex", "account = :candidate\n", "candidate")

    assert {:ok, %{action: "allow_fresh_base"}} =
             BaseDrift.assess(context.workspace, issue(), "main")

    commit_file!(context.upstream, "lib/account.ex", "account = :upstream\n", "upstream")
    git!(context.upstream, ["push", "origin", "main"])

    assert {:defer, _prompt, %{action: "defer_overlapping_drift"}} =
             BaseDrift.assess(context.workspace, issue(), "main")
  end

  test "required manifest command failures fail safe", context do
    commit_file!(context.workspace, "lib/candidate.ex", "candidate\n", "candidate")

    runner = fn
      ["diff", "--name-only", _range], _workspace -> {"manifest unavailable", 17}
      args, workspace -> System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    end

    assert {:error, {:git_manifest_failed, ["diff", "--name-only", _range], 17, _message}} =
             BaseDrift.assess(context.workspace, issue(), "main", git_runner: runner)
  end

  test "remote assessment runs every git command on the selected worker with escaped arguments" do
    {:ok, calls} = Agent.start_link(fn -> [] end)
    workspace = "/srv/remote work/'candidate"
    base_ref = "release/'safe"

    ssh_runner = fn host, command, opts ->
      Agent.update(calls, &[{host, command, opts} | &1])

      output =
        cond do
          String.contains?(command, "'rev-parse' 'HEAD'") -> "candidate-head\n"
          String.contains?(command, "'rev-parse' 'refs/remotes/origin/release/") -> "current-base\n"
          String.contains?(command, "'merge-base'") -> "current-base\n"
          String.contains?(command, "'diff' '--name-only' 'current-base..HEAD'") -> "lib/candidate.ex\n"
          true -> ""
        end

      {:ok, {output, 0}}
    end

    assert {:ok, decision} =
             BaseDrift.assess(workspace, issue(), base_ref,
               worker_host: "builder-a",
               ssh_runner: ssh_runner
             )

    assert decision.action == "allow_fresh_base"
    assert decision.candidate_paths == ["lib/candidate.ex"]

    remote_calls = Agent.get(calls, &Enum.reverse/1)
    assert length(remote_calls) == 9
    assert Enum.all?(remote_calls, fn {host, _command, opts} -> host == "builder-a" and opts == [stderr_to_stdout: true] end)

    assert Enum.all?(remote_calls, fn {_host, command, _opts} ->
             String.starts_with?(command, "cd '/srv/remote work/'\"'\"'candidate' && git ")
           end)

    assert Enum.any?(remote_calls, fn {_host, command, _opts} ->
             command =~ "'fetch' '--quiet' 'origin' 'release/'\"'\"'safe'"
           end)
  end

  defp issue do
    %Issue{
      id: "issue-drift",
      identifier: "UDPE-7163",
      title: "Protect stale gates",
      state: "In Progress",
      labels: ["repo:symphony"]
    }
  end

  defp commit_file!(repo, relative, content, message) do
    path = Path.join(repo, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    git!(repo, ["add", relative])
    git!(repo, ["commit", "-m", message])
  end

  defp configure!(repo) do
    git!(repo, ["config", "user.name", "Symphony Test"])
    git!(repo, ["config", "user.email", "symphony@example.test"])
  end

  defp git!(directory, args) do
    case System.cmd("git", args, cd: directory, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end
end
