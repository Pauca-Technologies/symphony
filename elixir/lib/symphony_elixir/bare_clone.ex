defmodule SymphonyElixir.BareClone do
  @moduledoc """
  Lazy repo-clone + worktree machinery for the multi-repo Symphony
  driver (audit §9.4, implementation plan T27).

  *(Module name is historical — it manages a regular clone now, not a
  bare clone. The simpler model: one full clone per configured repo,
  refreshed from origin before every dispatch; per-issue work happens
  in `git worktree add` siblings of that clone.)*

  Layout:

      <workspace_root>/
        _repos/
          <repo_id>/             (one shared regular clone per repo)
            .git/
            … working tree (unused; we never modify it directly) …
        <safe-issue-identifier>/  (per-issue worktree)

  Operations are guarded by a file lock so concurrent agent runs
  against the same repo don't race each other on the canonical clone.
  """

  require Logger

  @lock_dir_relative "_repos/.locks"
  @repos_dir_relative "_repos"
  @rescue_branch_prefix "symphony/rescue"
  @rescue_stash_message "symphony: rescue uncommitted work before worktree reset"
  @interrupted_operations [
    {:rebase, ["rebase-merge", "rebase-apply"], ["rebase", "--quit"]},
    {:cherry_pick, ["CHERRY_PICK_HEAD"], ["cherry-pick", "--quit"]},
    {:revert, ["REVERT_HEAD"], ["revert", "--quit"]},
    {:merge, ["MERGE_HEAD"], ["merge", "--quit"]}
  ]

  @typedoc "Subset of RepoConfig.repo_entry the worktree pipeline needs."
  @type routed_repo :: %{
          id: String.t(),
          repo_url: String.t() | nil,
          base_branch: String.t()
        }

  @doc """
  Ensure the canonical clone exists, then fetch from origin so
  `origin/<base_branch>` reflects upstream's latest. Returns
  `{:ok, clone_path}` on success.

  When `issue_branch` is given, its remote-tracking ref is refreshed too
  (best-effort) so that an open PR's head — `origin/<issue_branch>` — is
  available as a worktree start point. The branch may not exist on origin
  yet (issue has no PR); that's not an error.
  """
  @spec ensure_and_fetch(String.t(), routed_repo(), String.t() | nil) ::
          {:ok, Path.t()} | {:error, term()}
  def ensure_and_fetch(workspace_root, routed, issue_branch \\ nil)

  def ensure_and_fetch(workspace_root, %{repo_url: nil}, _issue_branch)
      when is_binary(workspace_root) do
    {:error, :missing_repo_url}
  end

  def ensure_and_fetch(workspace_root, %{id: repo_id, repo_url: repo_url} = routed, issue_branch)
      when is_binary(workspace_root) and is_binary(repo_id) and is_binary(repo_url) do
    clone_path = clone_path(workspace_root, repo_id)
    File.mkdir_p!(Path.dirname(clone_path))

    with_repo_lock(workspace_root, repo_id, fn ->
      with :ok <- ensure_clone(clone_path, repo_url),
           :ok <- fetch(clone_path, Map.get(routed, :base_branch, "main")) do
        maybe_fetch_issue_branch(clone_path, issue_branch)
        {:ok, clone_path}
      end
    end)
  end

  @doc """
  Ensure a worktree exists at `worktree_path` on branch `branch_name`,
  synced to the latest appropriate start point:

    * If `origin/<branch_name>` exists — the issue already has an open PR
      whose head is this branch — the worktree continues that branch from
      its latest pushed state, **not** a fresh fork from base. This is what
      makes a re-dispatch pick up the existing PR instead of starting over.
    * Otherwise the worktree starts from `origin/<base_branch>`.

  When a worktree dir is already present for this issue (a prior dispatch),
  it is reused in place: its tracked files are reset to the start point via
  `git checkout --force`, which leaves untracked and gitignored files
  alone. That preserves expensive build artifacts (node_modules, compiled
  assets, …) across dispatches instead of recloning from scratch.

  Before that reset, any uncommitted *tracked* changes an interrupted prior
  run left behind are snapshotted onto a `#{@rescue_branch_prefix}/…` branch
  so `git checkout --force` never silently discards real work (untracked and
  gitignored files survive the reset untouched and need no rescue). If the
  snapshot can't be captured, the reset is refused rather than risk losing
  the changes. Unmerged files from an interrupted Git operation are captured
  with a temporary index, after which the stale operation is quit before the
  worktree is reset.

  The canonical clone is a normal (non-bare) clone and worktrees share its
  object store + `refs/remotes/origin/*`, so the `origin/<branch>` form
  resolves both in the clone and inside the worktree.

  Returns `{:ok, %{start_point: ref, reused: boolean}}`.
  """
  @spec ensure_worktree(Path.t(), Path.t(), String.t(), String.t()) ::
          {:ok, %{start_point: String.t(), reused: boolean()}} | {:error, term()}
  def ensure_worktree(clone_path, worktree_path, branch_name, base_branch)
      when is_binary(clone_path) and is_binary(worktree_path) and is_binary(branch_name) and
             is_binary(base_branch) do
    start_point = worktree_start_point(clone_path, branch_name, base_branch)

    if reusable_worktree?(clone_path, worktree_path) do
      case refresh_worktree(worktree_path, branch_name, start_point) do
        :ok ->
          {:ok, %{start_point: start_point, reused: true}}

        {:error, {:rescue_failed, _detail} = reason} ->
          # The worktree carries uncommitted tracked changes we could NOT
          # snapshot. Resetting (or recreating, which also wipes the dir)
          # would discard them, so refuse and surface the failure. The
          # worktree is left exactly as-is for a human to recover from.
          Logger.error("Refusing to reset reused worktree with unpreserved local changes: #{worktree_path} (#{inspect(reason)})")

          {:error, reason}

        {:error, {:interrupted_operation_quit_failed, _operation, _status, _output} = reason} ->
          Logger.error("Refusing to reset reused worktree after interrupted operation cleanup failed: #{worktree_path} (#{inspect(reason)})")

          {:error, reason}

        {:error, reason} ->
          Logger.warning("Worktree refresh failed (#{inspect(reason)}); recreating from scratch: #{worktree_path}")

          recreate_worktree(clone_path, worktree_path, branch_name, start_point)
      end
    else
      recreate_worktree(clone_path, worktree_path, branch_name, start_point)
    end
  end

  # Prefer an existing remote branch matching the issue branch (an open
  # PR's head) so we continue it; otherwise fork from the base branch.
  defp worktree_start_point(clone_path, branch_name, base_branch) do
    if remote_ref_exists?(clone_path, branch_name) do
      "origin/#{branch_name}"
    else
      "origin/#{base_branch}"
    end
  end

  defp remote_ref_exists?(clone_path, branch_name) do
    case System.cmd(
           "git",
           ["-C", clone_path, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/#{branch_name}"],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> true
      _ -> false
    end
  end

  # A dir is reusable only when it's a worktree this very clone registered.
  # `worktree list` is authoritative: a re-routed issue (now a different
  # clone) or stale debris won't be listed, so we recreate instead.
  defp reusable_worktree?(clone_path, worktree_path) do
    File.regular?(Path.join(worktree_path, ".git")) and
      registered_worktree?(clone_path, worktree_path)
  end

  defp registered_worktree?(clone_path, worktree_path) do
    target = Path.expand(worktree_path)

    case System.cmd("git", ["-C", clone_path, "worktree", "list", "--porcelain"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> IO.iodata_to_binary()
        |> String.split("\n", trim: true)
        |> Enum.any?(&(worktree_line_path(&1) == target))

      _ ->
        false
    end
  end

  # Extract the absolute path from a `worktree <path>` porcelain line, or
  # nil for any other line (HEAD/branch/bare markers, blanks).
  defp worktree_line_path(line) do
    case String.split(line, " ", parts: 2) do
      ["worktree", path] -> Path.expand(String.trim(path))
      _ -> nil
    end
  end

  # Reset an existing worktree's tracked files to `start_point` without
  # disturbing untracked / gitignored build artifacts. `--force` discards
  # local tracked edits left over from an aborted prior run; `-B` (re)points
  # the branch at the start point. origin/* is already current (the shared
  # clone was just fetched), so this is the "pull latest" step.
  #
  # Because `--force` would otherwise silently drop an interrupted run's
  # uncommitted tracked changes, snapshot them onto a rescue branch first (see
  # `preserve_uncommitted_changes/2`). If that snapshot can't be captured we
  # return `{:error, {:rescue_failed, _}}` and the caller refuses to reset.
  defp refresh_worktree(worktree_path, branch_name, start_point) do
    with :ok <- preserve_uncommitted_changes(worktree_path, branch_name),
         :ok <- quit_interrupted_operation(worktree_path) do
      force_reset_worktree(worktree_path, branch_name, start_point)
    end
  end

  defp force_reset_worktree(worktree_path, branch_name, start_point) do
    args = ["-C", worktree_path, "checkout", "--force", "-B", branch_name, start_point]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        {:error, {:worktree_checkout_failed, status, String.trim(IO.iodata_to_binary(output))}}
    end
  end

  # Untracked and gitignored files survive `git checkout --force`, so only
  # uncommitted *tracked* changes are at risk. When present, capture them onto
  # a `symphony/rescue/...` branch before the reset so nothing is silently lost.
  defp preserve_uncommitted_changes(worktree_path, branch_name) do
    if worktree_has_tracked_changes?(worktree_path) do
      rescue_uncommitted_changes(worktree_path, branch_name)
    else
      :ok
    end
  end

  defp worktree_has_tracked_changes?(worktree_path) do
    case System.cmd(
           "git",
           ["-C", worktree_path, "status", "--porcelain", "--untracked-files=no"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(IO.iodata_to_binary(output)) != ""
      # Can't determine cleanliness (unusual) — treat as clean and let the
      # checkout itself surface any real error; matches prior behavior.
      _ -> false
    end
  end

  # `git stash create` builds a commit object capturing the current tracked
  # WIP WITHOUT touching the working tree or the stash ref, and prints its
  # SHA. We point a rescue branch at that commit so a human can recover the
  # work (`git checkout <rescue-branch>`), then let the caller reset.
  defp rescue_uncommitted_changes(worktree_path, branch_name) do
    case System.cmd(
           "git",
           ["-C", worktree_path, "stash", "create", @rescue_stash_message],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case String.trim(IO.iodata_to_binary(output)) do
          "" ->
            rescue_empty_snapshot(worktree_path, branch_name)

          sha ->
            create_rescue_branch(worktree_path, branch_name, sha)
        end

      {output, status} ->
        rescue_failed_stash(worktree_path, branch_name, status, output)
    end
  end

  defp rescue_empty_snapshot(worktree_path, branch_name) do
    if worktree_has_unmerged_entries?(worktree_path) do
      rescue_unmerged_changes(worktree_path, branch_name)
    else
      # Dirty per `status` but nothing to snapshot: refuse rather than risk
      # discarding whatever `status` saw.
      {:error, {:rescue_failed, :empty_snapshot}}
    end
  end

  defp rescue_failed_stash(worktree_path, branch_name, status, output) do
    if worktree_has_unmerged_entries?(worktree_path) do
      rescue_unmerged_changes(worktree_path, branch_name)
    else
      {:error, {:rescue_failed, {:stash_create_failed, status, String.trim(IO.iodata_to_binary(output))}}}
    end
  end

  # `git stash create` refuses an index with unmerged entries. Build a clean,
  # temporary index from HEAD and update it from the working tree instead. The
  # resulting single-parent commit records the exact tracked file contents,
  # including conflict markers, without mutating the real index or worktree.
  defp rescue_unmerged_changes(worktree_path, branch_name) do
    index_file =
      Path.join(
        System.tmp_dir!(),
        "symphony-rescue-index-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    try do
      with {:ok, _output} <- run_rescue_git(worktree_path, index_file, ["read-tree", "HEAD"], :read_tree_failed),
           {:ok, _output} <- run_rescue_git(worktree_path, index_file, ["add", "-u", "--", "."], :add_tracked_failed),
           {:ok, tree} <- run_rescue_git(worktree_path, index_file, ["write-tree"], :write_tree_failed),
           {:ok, sha} <- create_rescue_commit(worktree_path, index_file, tree) do
        create_rescue_branch(worktree_path, branch_name, sha)
      else
        {:error, detail} -> {:error, {:rescue_failed, detail}}
      end
    after
      _ = File.rm(index_file)
      _ = File.rm(index_file <> ".lock")
    end
  end

  defp run_rescue_git(worktree_path, index_file, args, error_tag) do
    case System.cmd("git", ["-C", worktree_path | args],
           env: [{"GIT_INDEX_FILE", index_file}],
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(IO.iodata_to_binary(output))}
      {output, status} -> {:error, {error_tag, status, String.trim(IO.iodata_to_binary(output))}}
    end
  end

  defp create_rescue_commit(worktree_path, index_file, tree) do
    env = [
      {"GIT_INDEX_FILE", index_file},
      {"GIT_AUTHOR_NAME", "Symphony"},
      {"GIT_AUTHOR_EMAIL", "symphony@localhost"},
      {"GIT_COMMITTER_NAME", "Symphony"},
      {"GIT_COMMITTER_EMAIL", "symphony@localhost"}
    ]

    case System.cmd(
           "git",
           ["-C", worktree_path, "commit-tree", tree, "-p", "HEAD", "-m", @rescue_stash_message],
           env: env,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(IO.iodata_to_binary(output))}
      {output, status} -> {:error, {:commit_tree_failed, status, String.trim(IO.iodata_to_binary(output))}}
    end
  end

  defp worktree_has_unmerged_entries?(worktree_path) do
    case System.cmd(
           "git",
           ["-C", worktree_path, "diff", "--name-only", "--diff-filter=U"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(IO.iodata_to_binary(output)) != ""
      _ -> false
    end
  end

  # Once the tracked state is safely referenced, forget stale operation
  # metadata so `checkout --force` can return the worktree to its issue branch.
  # `--quit` intentionally leaves files untouched; the following checkout owns
  # the reset.
  defp quit_interrupted_operation(worktree_path) do
    case Enum.find(@interrupted_operations, fn {_operation, git_paths, _args} ->
           Enum.any?(git_paths, &git_internal_path_exists?(worktree_path, &1))
         end) do
      nil ->
        :ok

      {operation, _git_paths, args} ->
        case System.cmd("git", ["-C", worktree_path | args], stderr_to_stdout: true) do
          {_output, 0} ->
            Logger.warning("Quit interrupted Git operation before resetting reused worktree operation=#{operation} workspace=#{worktree_path}")

            :ok

          {output, status} ->
            {:error, {:interrupted_operation_quit_failed, operation, status, String.trim(IO.iodata_to_binary(output))}}
        end
    end
  end

  defp git_internal_path_exists?(worktree_path, git_path) do
    case System.cmd(
           "git",
           ["-C", worktree_path, "rev-parse", "--git-path", git_path],
           stderr_to_stdout: true
         ) do
      {output, 0} -> output |> IO.iodata_to_binary() |> String.trim() |> File.exists?()
      _ -> false
    end
  end

  defp create_rescue_branch(worktree_path, branch_name, sha) do
    rescue_branch = rescue_branch_name(branch_name, sha)

    case System.cmd(
           "git",
           ["-C", worktree_path, "branch", "--force", rescue_branch, sha],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        Logger.warning("Preserved uncommitted tracked changes in reused worktree #{worktree_path} on rescue branch '#{rescue_branch}' before resetting to the start point")

        :ok

      {output, status} ->
        {:error, {:rescue_failed, {:branch_create_failed, status, String.trim(IO.iodata_to_binary(output))}}}
    end
  end

  # `symphony/rescue/<sanitized-branch>-<short-sha>`. The branch name is
  # sanitized (slashes → dashes) so the rescue ref can never collide with a
  # real branch ref path, and the short SHA makes repeated rescues of distinct
  # dirty states land on distinct branches (identical states dedupe).
  defp rescue_branch_name(branch_name, sha) do
    sanitized = String.replace(branch_name, "/", "-")
    short = String.slice(sha, 0, 12)
    "#{@rescue_branch_prefix}/#{sanitized}-#{short}"
  end

  defp recreate_worktree(clone_path, worktree_path, branch_name, start_point) do
    File.mkdir_p!(Path.dirname(worktree_path))
    # Clear a present dir, then prune any stale registration so
    # `worktree add` doesn't trip on "already exists / registered".
    _ = remove_worktree(clone_path, worktree_path)
    _ = System.cmd("git", ["-C", clone_path, "worktree", "prune"], stderr_to_stdout: true)

    args = ["-C", clone_path, "worktree", "add", "-B", branch_name, worktree_path, start_point]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {_output, 0} ->
        {:ok, %{start_point: start_point, reused: false}}

      {output, status} ->
        {:error, {:worktree_add_failed, status, String.trim(IO.iodata_to_binary(output))}}
    end
  end

  @doc """
  Remove a worktree using `git worktree remove`. Falls back to `rm -rf`
  on any git error so terminal-state cleanup is never blocked by a stale
  worktree state.
  """
  @spec remove_worktree(Path.t(), Path.t()) :: :ok
  def remove_worktree(clone_path, worktree_path)
      when is_binary(clone_path) and is_binary(worktree_path) do
    if File.exists?(worktree_path) do
      args = ["-C", clone_path, "worktree", "remove", "--force", worktree_path]

      case System.cmd("git", args, stderr_to_stdout: true) do
        {_output, 0} ->
          :ok

        {output, status} ->
          Logger.warning("git worktree remove failed (status=#{status}, falling back to rm -rf): #{String.trim(IO.iodata_to_binary(output))}")

          _ = File.rm_rf(worktree_path)
          # Best-effort prune any dangling refs in the canonical clone.
          _ = System.cmd("git", ["-C", clone_path, "worktree", "prune"], stderr_to_stdout: true)
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  Plain (non-forcing) `git worktree remove`. Returns `:ok` on success,
  `{:error, reason}` otherwise.

  Unlike `remove_worktree/2`, this NEVER falls back to `rm -rf`: if the
  worktree has uncommitted changes a human added, the call fails and the
  caller (WorkspaceGc, T28) preserves the work for human inspection.
  Resolves the parent clone via the worktree's own `.git` file linkage,
  so callers don't have to know which configured repo a worktree belongs
  to.

  Failure reasons surfaced:
    * `:worktree_missing` — the path doesn't exist on disk.
    * `:not_a_worktree` — the path exists but isn't a git worktree
      (e.g. a legacy plain-mkdir workspace, or random debris).
    * `{:worktree_remove_failed, status, message}` — git's own refusal
      (typically a dirty worktree or unmerged changes).
  """
  @spec remove_worktree_safe(Path.t()) :: :ok | {:error, term()}
  def remove_worktree_safe(worktree_path) when is_binary(worktree_path) do
    cond do
      not File.exists?(worktree_path) ->
        {:error, :worktree_missing}

      # A populated worktree always has a `.git` file (NOT a directory)
      # that points back to its parent clone. Mirrors the discriminator
      # `Workspace.git_worktree_dir?/1` uses for dispatch.
      not File.regular?(Path.join(worktree_path, ".git")) ->
        {:error, :not_a_worktree}

      true ->
        args = ["-C", worktree_path, "worktree", "remove", worktree_path]

        case System.cmd("git", args, stderr_to_stdout: true) do
          {_output, 0} ->
            :ok

          {output, status} ->
            {:error, {:worktree_remove_failed, status, String.trim(IO.iodata_to_binary(output))}}
        end
    end
  end

  @doc """
  Compute the canonical-clone path for a given workspace root + repo
  id. Public for tests + the Workspace module.
  """
  @spec bare_path(String.t(), String.t()) :: Path.t()
  def bare_path(workspace_root, repo_id), do: clone_path(workspace_root, repo_id)

  @doc false
  @spec clone_path(String.t(), String.t()) :: Path.t()
  def clone_path(workspace_root, repo_id) when is_binary(workspace_root) and is_binary(repo_id) do
    Path.join([workspace_root, @repos_dir_relative, repo_id])
  end

  defp ensure_clone(clone_path, repo_url) do
    if clone_present?(clone_path) do
      :ok
    else
      # Clean any half-cloned remnants so `git clone` doesn't fail on a
      # pre-existing partial dir from a crashed earlier attempt.
      _ = File.rm_rf(clone_path)

      case System.cmd("git", ["clone", repo_url, clone_path], stderr_to_stdout: true) do
        {_output, 0} ->
          :ok

        {output, status} ->
          {:error, {:repo_clone_failed, status, String.trim(IO.iodata_to_binary(output))}}
      end
    end
  end

  defp clone_present?(clone_path) do
    # A populated clone has a `.git` entry (dir or, less common, file)
    # and an objects directory under it. Either form resolves.
    git_path = Path.join(clone_path, ".git")
    File.dir?(git_path) or File.regular?(git_path)
  end

  # Best-effort fetch of the issue branch (an open PR's head). Absence is
  # the common case (no PR yet), so a failure is logged at debug, not warn.
  defp maybe_fetch_issue_branch(_clone_path, branch) when branch in [nil, ""], do: :ok

  defp maybe_fetch_issue_branch(clone_path, branch) when is_binary(branch) do
    case System.cmd("git", ["-C", clone_path, "fetch", "origin", branch], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        Logger.debug("git fetch of issue branch #{branch} on clone #{clone_path} failed (status=#{status}); no open PR head to continue: #{String.trim(IO.iodata_to_binary(output))}")

        :ok
    end
  end

  defp fetch(clone_path, base_branch) do
    # Fetch updates remote-tracking refs (refs/remotes/origin/*). We
    # don't touch the canonical clone's working tree — per-issue work
    # happens in worktrees that take `origin/<base_branch>` directly
    # as their starting point, so the canonical clone's checked-out
    # branch never matters.
    case System.cmd("git", ["-C", clone_path, "fetch", "origin", base_branch], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        # A fetch failure isn't fatal — the existing pack might still cover the
        # required base_branch (the initial clone fetched everything). Log it
        # and keep going.
        Logger.warning("git fetch on clone #{clone_path} failed (status=#{status}); reusing existing refs: #{String.trim(IO.iodata_to_binary(output))}")

        :ok
    end
  end

  defp with_repo_lock(workspace_root, repo_id, fun) when is_function(fun, 0) do
    lock_dir = Path.join(workspace_root, @lock_dir_relative)
    File.mkdir_p!(lock_dir)
    lock_path = Path.join(lock_dir, "#{repo_id}.lock")

    case acquire_lock(lock_path) do
      :ok ->
        try do
          fun.()
        after
          _ = File.rm(lock_path)
        end

      {:error, reason} ->
        {:error, {:repo_clone_lock_failed, reason}}
    end
  end

  defp acquire_lock(lock_path, retries \\ 60) do
    case File.open(lock_path, [:write, :exclusive]) do
      {:ok, file} ->
        File.close(file)
        :ok

      {:error, :eexist} when retries > 0 ->
        Process.sleep(500)
        acquire_lock(lock_path, retries - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
