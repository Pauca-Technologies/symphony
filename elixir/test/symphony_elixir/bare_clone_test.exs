defmodule SymphonyElixir.BareCloneTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.BareClone

  # --- git test scaffolding ---------------------------------------------

  defp git!(dir, args) do
    {out, status} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")} failed in #{dir}:\n#{out}"
    String.trim(out)
  end

  defp write!(dir, rel, contents) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  defp tmp!(label) do
    path = Path.join(System.tmp_dir!(), "bareclone-#{label}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  # An "origin" repo with `develop` (base) plus, optionally, a feature
  # branch standing in for an open PR head.
  defp make_origin(opts \\ []) do
    origin = tmp!("origin")
    git!(origin, ["init", "--initial-branch=develop", "--quiet"])
    git!(origin, ["config", "user.email", "t@t.test"])
    git!(origin, ["config", "user.name", "Tester"])
    write!(origin, "base.txt", "base\n")
    git!(origin, ["add", "."])
    git!(origin, ["commit", "--quiet", "-m", "base on develop"])

    if branch = opts[:feature_branch] do
      git!(origin, ["checkout", "--quiet", "-b", branch])
      write!(origin, "feature.txt", "pr work\n")
      git!(origin, ["add", "."])
      git!(origin, ["commit", "--quiet", "-m", "pr commit"])
      git!(origin, ["checkout", "--quiet", "develop"])
    end

    origin
  end

  defp routed(origin), do: %{id: "repo-#{System.unique_integer([:positive])}", repo_url: origin, base_branch: "develop"}

  # ----------------------------------------------------------------------

  test "forks from base branch when the issue has no PR branch on origin" do
    origin = make_origin()
    root = tmp!("root")
    repo = routed(origin)
    wt = Path.join(root, "UDPE-1")

    assert {:ok, clone} = BareClone.ensure_and_fetch(root, repo, "udpe-1-no-pr")

    assert {:ok, %{start_point: "origin/develop", reused: false}} =
             BareClone.ensure_worktree(clone, wt, "udpe-1-no-pr", "develop")

    # Worktree is on a fresh branch off develop; the PR-only file is absent.
    assert File.exists?(Path.join(wt, "base.txt"))
    refute File.exists?(Path.join(wt, "feature.txt"))
  end

  test "continues the existing PR branch instead of forking from develop" do
    branch = "udpe-2-feature"
    origin = make_origin(feature_branch: branch)
    root = tmp!("root")
    repo = routed(origin)
    wt = Path.join(root, "UDPE-2")

    assert {:ok, clone} = BareClone.ensure_and_fetch(root, repo, branch)

    assert {:ok, %{start_point: start, reused: false}} =
             BareClone.ensure_worktree(clone, wt, branch, "develop")

    assert start == "origin/#{branch}"
    # The PR's commit is present — we did NOT start from develop.
    assert File.read!(Path.join(wt, "feature.txt")) == "pr work\n"
  end

  test "reuses an existing worktree, pulls latest, and keeps gitignored artifacts" do
    branch = "udpe-3-feature"
    origin = make_origin(feature_branch: branch)
    root = tmp!("root")
    repo = routed(origin)
    wt = Path.join(root, "UDPE-3")

    assert {:ok, clone} = BareClone.ensure_and_fetch(root, repo, branch)
    assert {:ok, %{reused: false}} = BareClone.ensure_worktree(clone, wt, branch, "develop")

    # Simulate a gitignored build artifact produced by after_create (e.g.
    # node_modules) and a local tracked edit from an aborted run.
    artifact = write!(wt, "node_modules/dep.js", "cached\n")
    File.write!(Path.join(wt, "feature.txt"), "local scratch\n")

    # Someone advances the PR branch on origin.
    git!(origin, ["checkout", "--quiet", branch])
    write!(origin, "feature.txt", "pr work v2\n")
    git!(origin, ["commit", "--quiet", "-am", "pr commit 2"])
    git!(origin, ["checkout", "--quiet", "develop"])

    # Re-dispatch: reuse the worktree in place.
    assert {:ok, ^clone} = BareClone.ensure_and_fetch(root, repo, branch)

    assert {:ok, %{start_point: start, reused: true}} =
             BareClone.ensure_worktree(clone, wt, branch, "develop")

    assert start == "origin/#{branch}"
    # Tracked file reset to latest pushed PR state (local scratch discarded).
    assert File.read!(Path.join(wt, "feature.txt")) == "pr work v2\n"
    # Gitignored artifact survived the reuse.
    assert File.read!(artifact) == "cached\n"
  end
end
