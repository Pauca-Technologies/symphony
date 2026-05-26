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
  """
  @spec ensure_and_fetch(String.t(), routed_repo()) ::
          {:ok, Path.t()} | {:error, term()}
  def ensure_and_fetch(workspace_root, %{repo_url: nil}) when is_binary(workspace_root) do
    {:error, :missing_repo_url}
  end

  def ensure_and_fetch(workspace_root, %{id: repo_id, repo_url: repo_url} = routed)
      when is_binary(workspace_root) and is_binary(repo_id) and is_binary(repo_url) do
    clone_path = clone_path(workspace_root, repo_id)
    File.mkdir_p!(Path.dirname(clone_path))

    with_repo_lock(workspace_root, repo_id, fn ->
      with :ok <- ensure_clone(clone_path, repo_url),
           :ok <- fetch(clone_path, Map.get(routed, :base_branch, "main")) do
        {:ok, clone_path}
      end
    end)
  end

  @doc """
  Create a worktree at `worktree_path` rooted at `origin/<base_branch>`
  on a branch named `branch_name`. The canonical clone is a normal
  (non-bare) clone, so remote-tracking refs at
  `refs/remotes/origin/*` exist and the `origin/<branch>` form
  resolves directly. `-B` creates or resets the per-issue branch so
  retries on the same issue are idempotent. Caller must clean up any
  existing dir at `worktree_path` first.
  """
  @spec create_worktree(Path.t(), Path.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def create_worktree(clone_path, worktree_path, branch_name, base_branch)
      when is_binary(clone_path) and is_binary(worktree_path) and is_binary(branch_name) and
             is_binary(base_branch) do
    File.mkdir_p!(Path.dirname(worktree_path))

    args = [
      "-C",
      clone_path,
      "worktree",
      "add",
      "-B",
      branch_name,
      worktree_path,
      "origin/#{base_branch}"
    ]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

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
          Logger.warning(
            "git worktree remove failed (status=#{status}, falling back to rm -rf): #{String.trim(IO.iodata_to_binary(output))}"
          )

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
            {:error,
             {:worktree_remove_failed, status, String.trim(IO.iodata_to_binary(output))}}
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
        Logger.warning(
          "git fetch on clone #{clone_path} failed (status=#{status}); reusing existing refs: #{String.trim(IO.iodata_to_binary(output))}"
        )

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
