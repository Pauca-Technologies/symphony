defmodule SymphonyElixir.WorkflowPolicy do
  @moduledoc "Compares loaded workflow policy with the fetched base without modifying the worktree."

  alias SymphonyElixir.{Config, RunManifest, SSH, Workflow}

  @max_workflow_bytes 262_144

  @doc "Resolve the explicitly selected efficiency policy and report branch/base drift."
  @spec resolve(Path.t(), map() | nil, map() | nil, keyword()) ::
          {:ok, map() | nil, map()} | {:error, term()}
  def resolve(workspace, workflow, review, opts \\ []) do
    source = Keyword.get(opts, :efficiency_policy_source, "worktree")
    base_ref = Keyword.get(opts, :base_drift_ref)

    case compare(workspace, workflow, review, base_ref, opts) do
      {:ok, base_workflow, diagnostic} ->
        select_efficiency(workflow, base_workflow, source, diagnostic)

      {:error, reason} when source == "base" ->
        {:error, {:workflow_policy_unavailable, reason}}

      {:error, reason} ->
        {:ok, workflow, %{"status" => "unavailable", "reason" => diagnostic_reason(reason), "efficiency_source" => source}}
    end
  end

  defp diagnostic_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp diagnostic_reason({category, _detail}) when is_atom(category), do: Atom.to_string(category)

  defp compare(_workspace, _workflow, _review, nil, _opts),
    do: {:ok, nil, %{"status" => "not_applicable", "differing_sections" => []}}

  defp compare(workspace, workflow, review, base_ref, opts) do
    runner = Keyword.get(opts, :git_runner, git_runner(Keyword.get(opts, :worker_host), Keyword.get(opts, :ssh_runner, &SSH.run/3)))
    paths = {Keyword.get(opts, :workflow_path, "WORKFLOW.md"), Keyword.get(opts, :review_workflow_path, "WORKFLOW_REVIEW.md")}

    with true <- is_map(workflow) or {:error, :worktree_workflow_unavailable},
         true <- (valid_path?(elem(paths, 0)) and valid_path?(elem(paths, 1))) or {:error, :invalid_workflow_path},
         {:ok, base_sha} <- git_value(runner, workspace, ["rev-parse", "--verify", "--end-of-options", "refs/remotes/origin/#{base_ref}^{commit}"]),
         true <- valid_sha?(base_sha) or {:error, :base_sha_unavailable},
         {:ok, ancestor_sha} <- git_value(runner, workspace, ["merge-base", "HEAD", base_sha]),
         true <- valid_sha?(ancestor_sha) or {:error, :merge_base_unavailable},
         {:ok, base_workflow, base_review} <- workflows_at(runner, workspace, base_sha, paths),
         {:ok, ancestor_workflow, ancestor_review} <- ancestor_workflows(runner, workspace, ancestor_sha, base_sha, paths, base_workflow, base_review) do
      {:ok, base_workflow,
       comparison(workflow, review, base_workflow, base_review, ancestor_workflow, ancestor_review)
       |> Map.merge(%{"base_ref" => base_ref, "base_sha" => base_sha, "ancestor_sha" => ancestor_sha})}
    end
  rescue
    error -> {:error, {:workflow_comparison_failed, error.__struct__}}
  end

  defp comparison(workflow, review, base_workflow, base_review, ancestor_workflow, ancestor_review) do
    current = sections(workflow, review)
    base = sections(base_workflow, base_review)
    ancestor = sections(ancestor_workflow, ancestor_review)
    differences = current |> Map.keys() |> Enum.filter(&(current[&1] != base[&1])) |> Enum.sort()

    status =
      cond do
        differences == [] -> "current"
        base == ancestor -> "candidate_change"
        current == ancestor -> "stale"
        true -> "diverged"
      end

    %{
      "status" => status,
      "differing_sections" => differences,
      "worktree_digest" => RunManifest.config_digest(current),
      "base_digest" => RunManifest.config_digest(base),
      "worktree_efficiency_mode" => efficiency_mode(workflow),
      "base_efficiency_mode" => efficiency_mode(base_workflow),
      "remediation" =>
        "Compare workflow changes with the fetched base; update the issue branch through its normal sync/review process. " <>
          "A new attempt reloads policy. Operators may select repos[].efficiency_policy_source: base to use base efficiency settings without changing the branch."
    }
  end

  defp sections(workflow, review) do
    config = workflow_config(workflow)
    agent = Map.get(config, "agent") || %{}

    %{
      "agent.efficiency" => Map.get(agent, "efficiency"),
      "agent.routing" => Map.get(agent, "routing"),
      "agent.other" => Map.drop(agent, ["efficiency", "routing"]),
      "hooks" => Map.get(config, "hooks"),
      "workflow.other" => Map.drop(config, ["agent", "hooks"]),
      "prompt" => workflow_prompt(workflow),
      "review.config" => workflow_config(review),
      "review.prompt" => workflow_prompt(review)
    }
  end

  defp workflow_config(%{config: config}) when is_map(config), do: config
  defp workflow_config(_workflow), do: %{}
  defp workflow_prompt(%{prompt_template: prompt}), do: prompt
  defp workflow_prompt(_workflow), do: nil

  defp efficiency_mode(workflow) do
    case Config.agent_efficiency_settings(workflow) do
      {:ok, settings} -> settings.mode
      _ -> "invalid"
    end
  end

  defp select_efficiency(workflow, _base, "worktree", diagnostic),
    do: {:ok, workflow, Map.put(diagnostic, "efficiency_source", "worktree")}

  defp select_efficiency(%{config: config} = workflow, %{config: base_config} = base, "base", diagnostic) do
    with {:ok, _settings} <- Config.agent_efficiency_settings(base) do
      agent = Map.get(config, "agent") || %{}
      base_efficiency = get_in(base_config, ["agent", "efficiency"])
      agent = if is_nil(base_efficiency), do: Map.delete(agent, "efficiency"), else: Map.put(agent, "efficiency", base_efficiency)
      effective = %{workflow | config: Map.put(config, "agent", agent)}
      {:ok, effective, Map.put(diagnostic, "efficiency_source", "base")}
    end
  end

  defp select_efficiency(_workflow, _base, _source, _diagnostic),
    do: {:error, {:workflow_policy_unavailable, :base_workflow_unavailable}}

  defp ancestor_workflows(_runner, _workspace, sha, sha, _paths, workflow, review), do: {:ok, workflow, review}
  defp ancestor_workflows(runner, workspace, sha, _base_sha, paths, _workflow, _review), do: workflows_at(runner, workspace, sha, paths)

  defp workflows_at(runner, workspace, sha, {workflow_path, review_path}) do
    with {:ok, workflow} <- workflow_at(runner, workspace, sha, workflow_path),
         {:ok, review} <- workflow_at(runner, workspace, sha, review_path) do
      {:ok, workflow, review}
    end
  end

  defp workflow_at(runner, workspace, sha, path) do
    with {:ok, entry} <- git_value(runner, workspace, ["--literal-pathspecs", "ls-tree", sha, "--", path]) do
      if entry == "", do: {:ok, nil}, else: read_workflow(runner, workspace, "#{sha}:#{path}")
    end
  end

  defp read_workflow(runner, workspace, object) do
    with {:ok, size} <- git_value(runner, workspace, ["cat-file", "-s", object]),
         {bytes, ""} when bytes in 1..@max_workflow_bytes <- Integer.parse(size),
         {:ok, content} <- git_value(runner, workspace, ["show", object]),
         true <- byte_size(content) <= @max_workflow_bytes do
      Workflow.from_string(content)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :workflow_size_invalid}
    end
  end

  defp git_value(runner, workspace, args) do
    case runner.(args, workspace) do
      {output, 0} when is_binary(output) -> {:ok, String.trim(output)}
      _ -> {:error, :workflow_git_read_failed}
    end
  end

  defp git_runner(worker_host, ssh_runner) when is_binary(worker_host) and worker_host != "" do
    fn args, workspace ->
      command = "cd #{shell_escape(workspace)} && git " <> Enum.map_join(args, " ", &shell_escape/1)

      case ssh_runner.(worker_host, command, stderr_to_stdout: true) do
        {:ok, result} -> result
        _ -> {"", 1}
      end
    end
  end

  defp git_runner(_worker_host, _ssh_runner), do: &System.cmd("git", &1, cd: &2, stderr_to_stdout: true)
  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  defp valid_sha?(value), do: Regex.match?(~r/\A[0-9a-f]{40,64}\z/, value)

  defp valid_path?(path) when is_binary(path) and byte_size(path) in 1..320 do
    not String.starts_with?(path, ["/", ":", "-"]) and
      not Regex.match?(~r/[\x00-\x1f\x7f\\]/, path) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  defp valid_path?(_path), do: false
end
