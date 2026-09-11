defmodule SymphonyElixir.WorkflowPolicyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.WorkflowPolicy

  @base String.duplicate("b", 40)
  @ancestor String.duplicate("a", 40)

  test "distinguishes stale base policy from intentional branch changes and divergence" do
    old = workflow("shadow")
    new = workflow("enforce")
    review = %{config: %{}, prompt_template: "Review"}

    for {current, base, ancestor, expected} <- [{new, new, old, "current"}, {old, new, old, "stale"}, {new, old, old, "candidate_change"}, {%{old | prompt_template: "local"}, new, old, "diverged"}] do
      assert {:ok, ^current, diagnostic} = WorkflowPolicy.resolve("/unused", current, review, base_drift_ref: "develop", git_runner: runner(base, ancestor))
      assert diagnostic["status"] == expected
      assert diagnostic["efficiency_source"] == "worktree"
      assert diagnostic["base_sha"] == @base
      refute inspect(diagnostic) =~ "secret hook"
    end
  end

  test "base opt-in overlays only efficiency and preserves branch routing, hooks, and prompts" do
    current = workflow("shadow")
    assert {:ok, effective, diagnostic} = WorkflowPolicy.resolve("/unused", current, nil, base_drift_ref: "develop", efficiency_policy_source: "base", git_runner: runner(workflow("enforce"), current))
    assert effective.config["agent"]["efficiency"]["mode"] == "enforce"
    assert effective.config["agent"]["routing"] == current.config["agent"]["routing"]
    assert effective.config["hooks"] == current.config["hooks"]
    assert effective.prompt_template == current.prompt_template
    assert diagnostic["efficiency_source"] == "base"
    base = %{current | config: %{}}
    assert {:ok, effective, _} = WorkflowPolicy.resolve("/unused", current, nil, base_drift_ref: "develop", efficiency_policy_source: "base", git_runner: runner(base, current))
    refute Map.has_key?(effective.config["agent"], "efficiency")
    assert {:error, _} = WorkflowPolicy.resolve("/unused", current, nil, base_drift_ref: "develop", efficiency_policy_source: "base", git_runner: runner(workflow("invalid"), current))
  end

  test "missing and malformed base policies remain diagnostic unless base policy is required" do
    assert {:ok, nil, %{"status" => "not_applicable"}} = WorkflowPolicy.resolve("/unused", nil, nil)
    assert {:error, {:workflow_policy_unavailable, :base_workflow_unavailable}} = WorkflowPolicy.resolve("/unused", workflow("shadow"), nil, efficiency_policy_source: "base")
    assert {:ok, nil, %{"status" => "unavailable"}} = WorkflowPolicy.resolve("/unused", nil, nil, base_drift_ref: "develop")

    for path <- [nil, "", "../WORKFLOW.md", "/WORKFLOW.md", "a//b", "a\\b", "-flag"] do
      assert {:ok, _, %{"status" => "unavailable"}} = WorkflowPolicy.resolve("/unused", workflow("shadow"), nil, base_drift_ref: "develop", workflow_path: path)
    end

    for failure <- [fn _, _ -> {"", 1} end, fn _, _ -> {"invalid", 0} end, fn _, _ -> raise "unavailable" end] do
      assert {:ok, _, %{"status" => "unavailable"}} = WorkflowPolicy.resolve("/unused", workflow("shadow"), nil, base_drift_ref: "develop", git_runner: failure)
      assert {:error, {:workflow_policy_unavailable, _}} = WorkflowPolicy.resolve("/unused", workflow("shadow"), nil, base_drift_ref: "develop", efficiency_policy_source: "base", git_runner: failure)
    end

    for {command, output} <- [{"merge-base", "invalid"}, {"cat-file", "262145"}, {"cat-file", "invalid"}, {"show", String.duplicate("x", 262_145)}, {"show", "---\n- invalid\n---"}] do
      delegate = runner(workflow("shadow"), workflow("shadow"))
      failing = fn args, cwd -> if hd(args) == command, do: {output, 0}, else: delegate.(args, cwd) end
      assert {:ok, _, %{"status" => "unavailable"}} = WorkflowPolicy.resolve("/unused", workflow("shadow"), nil, base_drift_ref: "develop", git_runner: failing)
    end

    delegate = runner(workflow("shadow"), workflow("shadow"))
    read_failure = fn args, cwd -> if hd(args) == "show", do: {"failed", 1}, else: delegate.(args, cwd) end

    assert {:ok, _, %{"status" => "unavailable", "reason" => "workflow_git_read_failed"}} =
             WorkflowPolicy.resolve("/unused", workflow("shadow"), nil, base_drift_ref: "develop", git_runner: read_failure)

    missing = fn args, cwd -> if hd(args) == "--literal-pathspecs", do: {"", 0}, else: delegate.(args, cwd) end

    assert {:error, {:workflow_policy_unavailable, :base_workflow_unavailable}} =
             WorkflowPolicy.resolve("/unused", workflow("shadow"), nil, base_drift_ref: "develop", efficiency_policy_source: "base", git_runner: missing)
  end

  test "remote reads escape arguments and fail safely" do
    ssh = fn "worker", command, _ ->
      assert command =~ "cd '/workspace/it'\"'\"'s' && git"
      {:ok, {"", 1}}
    end

    assert {:ok, _, %{"status" => "unavailable"}} = WorkflowPolicy.resolve("/workspace/it's", workflow("shadow"), nil, worker_host: "worker", ssh_runner: ssh, base_drift_ref: "develop")

    assert {:ok, _, %{"status" => "unavailable"}} =
             WorkflowPolicy.resolve("/unused", workflow("shadow"), nil, worker_host: "worker", ssh_runner: fn _, _, _ -> {:error, :offline} end, base_drift_ref: "develop")
  end

  test "real git comparison preserves a dirty issue branch and reads each shared revision once" do
    root = Path.join(Path.dirname(Workflow.workflow_file_path()), "repo")
    File.mkdir_p!(root)

    git = fn args ->
      {output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
      String.trim(output)
    end

    git.(["init", "-b", "develop"])
    git.(["config", "user.email", "test@example.com"])
    git.(["config", "user.name", "Test"])
    File.write!(Path.join(root, "WORKFLOW.md"), content(workflow("shadow")))
    git.(["add", "."])
    git.(["commit", "-m", "base"])
    sha = git.(["rev-parse", "HEAD"])
    git.(["update-ref", "refs/remotes/origin/develop", sha])
    git.(["switch", "-c", "issue"])
    File.write!(Path.join(root, "WORKFLOW.md"), content(workflow("enforce")))
    assert {:ok, loaded} = Workflow.load(Path.join(root, "WORKFLOW.md"))
    before = git.(["status", "--porcelain"])
    assert {:ok, ^loaded, %{"status" => "candidate_change"}} = WorkflowPolicy.resolve(root, loaded, nil, base_drift_ref: "develop")
    assert git.(["status", "--porcelain"]) == before
    assert git.(["rev-parse", "HEAD"]) == sha
  end

  defp workflow(mode),
    do: %{config: %{"agent" => %{"efficiency" => %{"mode" => mode}, "routing" => %{"enabled" => false}}, "hooks" => %{"after_create" => "secret hook"}}, prompt_template: "Implement"}

  defp content(workflow), do: "---\n" <> Jason.encode!(workflow.config) <> "\n---\n" <> workflow.prompt_template

  defp runner(base, ancestor) do
    fn
      ["rev-parse" | _], _ ->
        {@base, 0}

      ["merge-base" | _], _ ->
        {@ancestor, 0}

      ["--literal-pathspecs", "ls-tree", _, "--", _], _ ->
        {"blob", 0}

      ["cat-file", "-s", _], _ ->
        {"100", 0}

      ["show", object], _ ->
        workflow = if String.starts_with?(object, @base), do: base, else: ancestor
        if String.ends_with?(object, "WORKFLOW_REVIEW.md"), do: {"Review", 0}, else: {content(workflow), 0}
    end
  end
end
