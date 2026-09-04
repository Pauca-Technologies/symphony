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
  @worktree_fingerprint_max_paths 200
  @worktree_fingerprint_batch_size 50
  @diff_count_max_paths 50
  @diff_count_scope "bounded_tracked_git_diff_numstat_v1"
  @command_path_regex ~r{(?:^|[\s`'"(])((?:\.?/?[A-Za-z0-9_.-]+/)+[A-Za-z0-9_.-]+)}m

  @doc "Assess base freshness, returning compact remediation for a stale candidate base."
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
    head_sha = resolved_git_value(runner, workspace, ["rev-parse", "HEAD"])
    current_base = resolved_base_value(runner, workspace, base_ref)
    candidate_base = resolved_candidate_base(runner, workspace, current_base)

    {actual_paths, untracked_paths, path_errors} =
      best_effort_candidate_path_details(runner, workspace, candidate_base)

    worktree = best_effort_worktree_state(runner, workspace, actual_paths)

    {diff_counts, diff_errors} =
      if path_errors == [] do
        best_effort_diff_counts(runner, workspace, candidate_base, actual_paths, untracked_paths)
      else
        {nil, ["repository.diff_counts_unavailable"]}
      end

    errors =
      []
      |> maybe_error(is_nil(head_sha), "repository.head_unavailable")
      |> maybe_error(is_binary(base_ref) and is_nil(current_base), "repository.base_unavailable")
      |> Kernel.++(path_errors)
      |> maybe_error(is_nil(worktree.status_fingerprint), "repository.worktree_status_unavailable")
      |> Kernel.++(diff_errors)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      head_sha: head_sha,
      base_sha: current_base,
      base_age_seconds: commit_age_seconds(runner, workspace, current_base),
      candidate_base_sha: candidate_base,
      actual_paths: actual_paths,
      diff_counts: diff_counts,
      errors: errors,
      dirty: worktree.dirty,
      worktree_fingerprint: worktree.fingerprint,
      worktree_status_fingerprint: worktree.status_fingerprint,
      worktree_content_fingerprint: worktree.content_fingerprint,
      worktree_fingerprint_complete: worktree.complete,
      worktree_fingerprint_path_count: worktree.path_count
    }
  end

  defp resolved_base_value(_runner, _workspace, base_ref) when not is_binary(base_ref), do: nil

  defp resolved_base_value(runner, workspace, base_ref),
    do: resolved_git_value(runner, workspace, ["rev-parse", "refs/remotes/origin/#{base_ref}"])

  defp resolved_candidate_base(_runner, _workspace, current_base) when not is_binary(current_base), do: nil

  defp resolved_candidate_base(runner, workspace, current_base),
    do: resolved_git_value(runner, workspace, ["merge-base", "HEAD", current_base])

  defp resolved_git_value(runner, workspace, args) do
    case value(runner, workspace, args) do
      {:ok, sha} -> sha
      _missing -> nil
    end
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
      defer? = advanced?

      action =
        cond do
          not advanced? -> "allow_fresh_base"
          overlap_paths == [] -> "defer_stale_base"
          true -> "defer_overlapping_drift"
        end

      decision = %{
        action: action,
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
    with {:ok, %{paths: paths}} <- candidate_path_details(runner, workspace, candidate_base) do
      {:ok, paths}
    end
  end

  defp candidate_path_details(runner, workspace, candidate_base) do
    committed_result =
      if is_binary(candidate_base),
        do: changed_paths(runner, workspace, candidate_base, "HEAD"),
        else: {:ok, []}

    with {:ok, committed} <- committed_result,
         {:ok, working} <- name_only(runner, workspace, ["diff", "--name-only", "HEAD"]),
         {:ok, staged} <- name_only(runner, workspace, ["diff", "--name-only", "--cached"]),
         {:ok, untracked} <- name_only(runner, workspace, ["ls-files", "--others", "--exclude-standard"]) do
      {:ok,
       %{
         paths: RepositoryScheduler.normalize_paths(committed ++ working ++ staged ++ untracked),
         untracked_paths: RepositoryScheduler.normalize_paths(untracked)
       }}
    end
  end

  defp best_effort_candidate_path_details(runner, workspace, candidate_base) do
    case candidate_path_details(runner, workspace, candidate_base) do
      {:ok, %{paths: paths, untracked_paths: untracked_paths}} -> {paths, untracked_paths, []}
      {:error, _reason} -> {[], [], ["repository.changed_paths_unavailable"]}
    end
  end

  defp best_effort_diff_counts(_runner, _workspace, _candidate_base, [], _untracked_paths) do
    {%{
       files: 0,
       additions: 0,
       deletions: 0,
       binary_files: 0,
       paths_considered: 0,
       paths_omitted: 0,
       scope: @diff_count_scope
     }, []}
  end

  defp best_effort_diff_counts(runner, workspace, candidate_base, paths, untracked_paths) do
    untracked_paths = MapSet.new(untracked_paths)

    selected_paths =
      paths
      |> Enum.take(@diff_count_max_paths)
      |> Enum.reject(&MapSet.member?(untracked_paths, &1))

    paths_omitted = max(length(paths) - length(selected_paths), 0)
    from = candidate_base || "HEAD"

    partial_errors =
      []
      |> maybe_error(paths_omitted > 0, "repository.diff_counts_partial")
      |> maybe_error(MapSet.size(untracked_paths) > 0, "repository.diff_counts_partial_untracked")

    if selected_paths == [] do
      {%{
         files: 0,
         additions: 0,
         deletions: 0,
         binary_files: 0,
         paths_considered: 0,
         paths_omitted: paths_omitted,
         scope: @diff_count_scope
       }, partial_errors}
    else
      case runner.(["diff", "--numstat", from, "--" | selected_paths], workspace) do
        {output, 0} ->
          {counts, parse_errors} =
            parse_numstat(output, length(selected_paths), paths_omitted)

          {counts, Enum.uniq(partial_errors ++ parse_errors)}

        {_output, _status} ->
          {nil, ["repository.diff_counts_unavailable"]}
      end
    end
  rescue
    _error -> {nil, ["repository.diff_counts_unavailable"]}
  end

  defp parse_numstat(output, paths_considered, paths_omitted) do
    rows = String.split(output, "\n", trim: true)

    {files, additions, deletions, binary_files, malformed_rows} =
      Enum.reduce(rows, {0, 0, 0, 0, 0}, &accumulate_numstat_row/2)

    counts = %{
      files: files,
      additions: additions,
      deletions: deletions,
      binary_files: binary_files,
      paths_considered: paths_considered,
      paths_omitted: paths_omitted,
      scope: @diff_count_scope
    }

    errors = if malformed_rows > 0, do: ["repository.diff_numstat_malformed"], else: []
    {counts, errors}
  end

  defp accumulate_numstat_row(row, counts) do
    case String.split(row, "\t", parts: 3) do
      ["-", "-", path] when path != "" -> increment_binary_file(counts)
      [added, deleted, path] when path != "" -> accumulate_text_numstat(added, deleted, counts)
      _malformed -> increment_malformed_row(counts)
    end
  end

  defp accumulate_text_numstat(added, deleted, {files, additions, deletions, binary_files, malformed_rows} = counts) do
    case {parse_count(added), parse_count(deleted)} do
      {{:ok, added}, {:ok, deleted}} ->
        {files + 1, additions + added, deletions + deleted, binary_files, malformed_rows}

      _invalid ->
        increment_malformed_row(counts)
    end
  end

  defp increment_binary_file({files, additions, deletions, binary_files, malformed_rows}),
    do: {files + 1, additions, deletions, binary_files + 1, malformed_rows}

  defp increment_malformed_row({files, additions, deletions, binary_files, malformed_rows}),
    do: {files, additions, deletions, binary_files, malformed_rows + 1}

  defp parse_count(value) do
    case Integer.parse(value) do
      {count, ""} when count >= 0 -> {:ok, count}
      _invalid -> :error
    end
  end

  defp maybe_error(errors, true, code), do: [code | errors]
  defp maybe_error(errors, false, _code), do: errors

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

  defp best_effort_worktree_state(runner, workspace, paths) do
    case runner.(["status", "--porcelain", "--untracked-files=normal"], workspace) do
      {output, 0} ->
        selected_paths = Enum.take(paths, @worktree_fingerprint_max_paths)
        status_fingerprint = sha256(output)
        content_fingerprint = content_fingerprint(runner, workspace, selected_paths, length(paths))

        %{
          dirty: String.trim(output) != "",
          fingerprint: combined_fingerprint(status_fingerprint, content_fingerprint),
          status_fingerprint: status_fingerprint,
          content_fingerprint: content_fingerprint,
          complete:
            is_binary(content_fingerprint) and
              length(paths) <= @worktree_fingerprint_max_paths,
          path_count: length(paths)
        }

      {_output, _status} ->
        unknown_worktree_state()
    end
  rescue
    _error -> unknown_worktree_state()
  end

  defp content_fingerprint(runner, workspace, paths, path_count) do
    paths
    |> Enum.chunk_every(@worktree_fingerprint_batch_size)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, digests} ->
      case runner.(["hash-object", "--no-filters", "--" | batch], workspace) do
        {output, 0} -> {:cont, {:ok, [sha256(output) | digests]}}
        {_output, _status} -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, digests} ->
        sha256([
          "worktree-content/v1\0",
          sha256(Enum.join(paths, "\0")),
          "\0",
          Integer.to_string(path_count),
          "\0",
          digests |> Enum.reverse() |> Enum.join("\0")
        ])

      :error ->
        nil
    end
  rescue
    _error -> nil
  end

  defp combined_fingerprint(status_fingerprint, content_fingerprint)
       when is_binary(status_fingerprint) and is_binary(content_fingerprint),
       do: sha256(["worktree/v2\0", status_fingerprint, "\0", content_fingerprint])

  defp combined_fingerprint(_status_fingerprint, _content_fingerprint), do: nil

  defp unknown_worktree_state,
    do: %{
      dirty: true,
      fingerprint: nil,
      status_fingerprint: nil,
      content_fingerprint: nil,
      complete: false,
      path_count: 0
    }

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

    Symphony deferred final validation and automated review because #{drift_description(decision)}.

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

  defp drift_description(%{critical_overlap_paths: [_path | _paths]} = decision) do
    "origin/#{decision.base_ref} advanced on paths required by the configured handoff runtime: #{format_overlap(decision)}"
  end

  defp drift_description(%{overlap_paths: [_path | _paths]} = decision) do
    "origin/#{decision.base_ref} advanced on paths that overlap this candidate: #{format_overlap(decision)}"
  end

  defp drift_description(decision) do
    "the candidate does not contain the current origin/#{decision.base_ref} base, even though the upstream paths do not directly overlap its changes"
  end

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

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
