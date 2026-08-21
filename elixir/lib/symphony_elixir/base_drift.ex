defmodule SymphonyElixir.BaseDrift do
  @moduledoc """
  Revalidates a candidate against its configured remote base before expensive
  handoff gates. The check is read-only: it fetches and inspects, but never
  rebases, resets, stashes, or otherwise mutates candidate work.
  """

  alias SymphonyElixir.{Linear.Issue, RepositoryScheduler, SSH, Telemetry}

  @type decision :: %{
          action: String.t(),
          base_ref: String.t(),
          candidate_base_sha: String.t() | nil,
          current_base_sha: String.t() | nil,
          base_advanced: boolean(),
          dirty: boolean(),
          candidate_paths: [String.t()],
          critical_paths: [String.t()],
          upstream_paths: [String.t()],
          overlap_paths: [String.t()],
          critical_overlap_paths: [String.t()],
          overlap_paths_omitted: non_neg_integer(),
          gates_avoided: non_neg_integer()
        }

  @workflow_runtime_paths ["WORKFLOW.md", "WORKFLOW_REVIEW.md"]
  @command_path_regex ~r{(?:^|[\s`'"(])((?:\.?/?[A-Za-z0-9_.-]+/)+[A-Za-z0-9_.-]+)}m

  @doc "Assess base freshness, returning compact remediation for overlapping drift."
  @spec assess(Path.t(), Issue.t(), String.t() | nil, keyword()) ::
          {:ok, decision()} | {:defer, String.t(), decision()} | {:error, term()}
  def assess(workspace, issue, base_ref, opts \\ [])

  def assess(_workspace, _issue, nil, _opts), do: {:ok, disabled_decision()}

  def assess(workspace, %Issue{} = issue, base_ref, opts)
      when is_binary(workspace) and is_binary(base_ref) do
    runner = git_runner(opts)
    critical_paths = handoff_runtime_paths(Keyword.get(opts, :hook_command))

    with {:ok, head_sha} <- value(runner, workspace, ["rev-parse", "HEAD"]),
         {:ok, current_base_sha} <- fetch_base(runner, workspace, base_ref) do
      compute(runner, workspace, issue, base_ref, head_sha, current_base_sha, critical_paths)
    end
  end

  @doc "Return repository paths whose base version defines the configured handoff runtime."
  @spec handoff_runtime_paths(String.t() | nil) :: [String.t()]
  def handoff_runtime_paths(command) when is_binary(command) do
    command_paths =
      @command_path_regex
      |> Regex.scan(command, capture: :all_but_first)
      |> List.flatten()
      |> Enum.filter(&handoff_runtime_path?/1)

    RepositoryScheduler.normalize_paths(@workflow_runtime_paths ++ command_paths)
  end

  def handoff_runtime_paths(_command), do: []

  defp handoff_runtime_path?(path) do
    String.starts_with?(path, ["./", "scripts/", "bin/", ".github/", ".codex/", ".claude/"]) or
      Path.extname(path) != ""
  end

  @doc "Capture the strongest actual changed-file manifest available during a run."
  @spec manifest(Path.t(), String.t() | nil, keyword()) :: map()
  def manifest(workspace, base_ref, opts \\ []) when is_binary(workspace) do
    runner = git_runner(opts)

    current_base =
      case base_ref && value(runner, workspace, ["rev-parse", "refs/remotes/origin/#{base_ref}"]) do
        {:ok, sha} -> sha
        _missing -> nil
      end

    candidate_base =
      case current_base && value(runner, workspace, ["merge-base", "HEAD", current_base]) do
        {:ok, sha} -> sha
        _missing -> nil
      end

    %{
      base_sha: current_base,
      base_age_seconds: commit_age_seconds(runner, workspace, current_base),
      candidate_base_sha: candidate_base,
      actual_paths: best_effort_candidate_paths(runner, workspace, candidate_base),
      dirty: best_effort_dirty?(runner, workspace)
    }
  end

  defp compute(runner, workspace, issue, base_ref, head_sha, current_base_sha, critical_paths) do
    with {:ok, candidate_base_sha} <- value(runner, workspace, ["merge-base", head_sha, current_base_sha]),
         {:ok, candidate_paths} <- candidate_paths(runner, workspace, candidate_base_sha),
         {:ok, upstream_paths} <- changed_paths(runner, workspace, candidate_base_sha, current_base_sha),
         {:ok, dirty} <- dirty?(runner, workspace) do
      candidate_overlap = RepositoryScheduler.overlap(candidate_paths, upstream_paths)
      critical_overlap = RepositoryScheduler.overlap(critical_paths, upstream_paths)
      overlap_paths = Enum.uniq(candidate_overlap.paths ++ critical_overlap.paths) |> Enum.sort()
      overlap_omitted = max(length(overlap_paths) - 20, 0)
      advanced? = candidate_base_sha != current_base_sha
      defer? = advanced? and overlap_paths != []

      decision = %{
        action: if(defer?, do: "defer_overlapping_drift", else: if(advanced?, do: "allow_irrelevant_drift", else: "allow_fresh_base")),
        base_ref: base_ref,
        candidate_base_sha: candidate_base_sha,
        current_base_sha: current_base_sha,
        base_advanced: advanced?,
        dirty: dirty,
        candidate_paths: candidate_paths,
        critical_paths: critical_paths,
        upstream_paths: upstream_paths,
        overlap_paths: Enum.take(overlap_paths, 20),
        critical_overlap_paths: critical_overlap.paths,
        overlap_paths_omitted: overlap_omitted,
        gates_avoided: if(defer?, do: 1, else: 0)
      }

      emit(issue, decision)

      if defer? do
        {:defer, remediation(decision), decision}
      else
        {:ok, decision}
      end
    end
  end

  defp fetch_base(runner, workspace, base_ref) do
    case runner.(["fetch", "--quiet", "origin", base_ref], workspace) do
      {_output, 0} -> value(runner, workspace, ["rev-parse", "refs/remotes/origin/#{base_ref}"])
      {output, status} -> {:error, {:base_fetch_failed, status, compact(output)}}
    end
  rescue
    error -> {:error, {:base_fetch_failed, error.__struct__, Exception.message(error)}}
  end

  defp candidate_paths(runner, workspace, candidate_base) do
    committed_result =
      if is_binary(candidate_base),
        do: changed_paths(runner, workspace, candidate_base, "HEAD"),
        else: {:ok, []}

    with {:ok, committed} <- committed_result,
         {:ok, working} <- name_only(runner, workspace, ["diff", "--name-only", "HEAD"]),
         {:ok, staged} <- name_only(runner, workspace, ["diff", "--name-only", "--cached"]),
         {:ok, untracked} <- name_only(runner, workspace, ["ls-files", "--others", "--exclude-standard"]) do
      {:ok, RepositoryScheduler.normalize_paths(committed ++ working ++ staged ++ untracked)}
    end
  end

  defp best_effort_candidate_paths(runner, workspace, candidate_base) do
    case candidate_paths(runner, workspace, candidate_base) do
      {:ok, paths} -> paths
      {:error, _reason} -> []
    end
  end

  defp changed_paths(_runner, _workspace, from, to) when from == to, do: {:ok, []}

  defp changed_paths(runner, workspace, from, to) do
    name_only(runner, workspace, ["diff", "--name-only", "#{from}..#{to}"])
  end

  defp name_only(runner, workspace, args) do
    case runner.(args, workspace) do
      {output, 0} ->
        {:ok, output |> String.split("\n", trim: true) |> RepositoryScheduler.normalize_paths()}

      {output, status} ->
        {:error, {:git_manifest_failed, args, status, compact(output)}}
    end
  rescue
    error -> {:error, {:git_manifest_failed, args, error.__struct__, Exception.message(error)}}
  end

  defp dirty?(runner, workspace) do
    case runner.(["status", "--porcelain", "--untracked-files=normal"], workspace) do
      {output, 0} -> {:ok, String.trim(output) != ""}
      {output, status} -> {:error, {:git_status_failed, status, compact(output)}}
    end
  rescue
    error -> {:error, {:git_status_failed, error.__struct__, Exception.message(error)}}
  end

  defp best_effort_dirty?(runner, workspace) do
    case dirty?(runner, workspace) do
      {:ok, dirty} -> dirty
      {:error, _reason} -> true
    end
  end

  defp commit_age_seconds(_runner, _workspace, nil), do: nil

  defp commit_age_seconds(runner, workspace, sha) do
    case value(runner, workspace, ["show", "-s", "--format=%ct", sha]) do
      {:ok, timestamp} -> max(System.system_time(:second) - String.to_integer(timestamp), 0)
      _failure -> nil
    end
  rescue
    _error -> nil
  end

  defp value(runner, workspace, args) do
    case runner.(args, workspace) do
      {output, 0} ->
        case String.trim(output) do
          "" -> {:error, {:git_value_missing, args}}
          value -> {:ok, value}
        end

      {output, status} ->
        {:error, {:git_failed, args, status, compact(output)}}
    end
  rescue
    error -> {:error, {:git_failed, args, error.__struct__, Exception.message(error)}}
  end

  defp remediation(decision) do
    dirty_guidance =
      if decision.dirty do
        "The worktree is dirty. Preserve those changes; do not run an automatic rebase, reset, or stash. Inspect and commit or otherwise reconcile them deliberately before refreshing the branch."
      else
        "Refresh the branch against origin/#{decision.base_ref}, resolving conflicts with agent judgment; Symphony will not rebase automatically."
      end

    """
    System message:

    Symphony deferred final validation and automated review because origin/#{decision.base_ref} advanced on #{overlap_description(decision)}: #{format_overlap(decision)}.

    #{dirty_guidance}

    After the candidate contains the current base, re-attempt the handoff. Expensive gates were intentionally not run on the stale head.
    """
    |> String.trim()
  end

  defp emit(issue, decision) do
    Telemetry.emit(:base_drift, %{
      action: decision.action,
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      repository: repository(issue.labels),
      base_ref: decision.base_ref,
      candidate_base_sha: decision.candidate_base_sha,
      current_base_sha: decision.current_base_sha,
      dirty: decision.dirty,
      candidate_path_count: length(decision.candidate_paths),
      upstream_path_count: length(decision.upstream_paths),
      overlap_paths: decision.overlap_paths,
      critical_overlap_paths: decision.critical_overlap_paths,
      overlap_paths_omitted: decision.overlap_paths_omitted,
      gates_avoided: decision.gates_avoided
    })
  end

  defp repository(labels) do
    Enum.find_value(labels || [], "default", fn
      "repo:" <> value -> value
      _label -> nil
    end)
  end

  defp disabled_decision do
    %{
      action: "disabled",
      base_ref: "",
      candidate_base_sha: nil,
      current_base_sha: nil,
      base_advanced: false,
      dirty: false,
      candidate_paths: [],
      critical_paths: [],
      upstream_paths: [],
      overlap_paths: [],
      critical_overlap_paths: [],
      overlap_paths_omitted: 0,
      gates_avoided: 0
    }
  end

  defp compact(value), do: value |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 500)
  defp overlap_description(%{critical_overlap_paths: [_path | _paths]}), do: "paths required by the configured handoff runtime"
  defp overlap_description(_decision), do: "paths that overlap this candidate"
  defp format_overlap(%{overlap_paths: paths, overlap_paths_omitted: 0}), do: Enum.join(paths, ", ")
  defp format_overlap(%{overlap_paths: paths, overlap_paths_omitted: omitted}), do: Enum.join(paths, ", ") <> " (+#{omitted} omitted)"

  defp git_runner(opts) do
    case Keyword.get(opts, :git_runner) do
      runner when is_function(runner, 2) ->
        runner

      _missing ->
        worker_git_runner(Keyword.get(opts, :worker_host), opts)
    end
  end

  defp worker_git_runner(worker_host, opts)
       when is_binary(worker_host) and worker_host != "" do
    ssh_runner = Keyword.get(opts, :ssh_runner, &SSH.run/3)
    fn args, workspace -> remote_git(ssh_runner, worker_host, args, workspace) end
  end

  defp worker_git_runner(_local, _opts), do: &git/2

  defp remote_git(ssh_runner, worker_host, args, workspace)
       when is_function(ssh_runner, 3) and is_list(args) do
    command =
      ["cd", shell_escape(workspace), "&&", "git" | Enum.map(args, &shell_escape/1)]
      |> Enum.join(" ")

    case ssh_runner.(worker_host, command, stderr_to_stdout: true) do
      {:ok, {output, status}} when is_binary(output) and is_integer(status) ->
        {output, status}

      {:error, reason} ->
        {"remote git unavailable: #{inspect(reason)}", 255}

      other ->
        {"invalid remote git response: #{inspect(other)}", 255}
    end
  end

  defp shell_escape(value) do
    value = to_string(value)
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp git(args, workspace), do: System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
end
