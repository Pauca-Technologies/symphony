defmodule SymphonyElixir.BareClone do
  @moduledoc """
  Lazy bare-clone + worktree machinery for the multi-repo Symphony driver
  (audit §9.4, implementation plan T27).

  Architecture: one bare clone per configured repo, lazy-created on first
  dispatch, fetched fresh on every issue, and used as the base for
  per-issue `git worktree add`. Eliminates per-issue full clones and gives
  Symphony control of the cloning step instead of delegating to the
  consumer's `after_create` hook.

  Layout:

      <workspace_root>/
        _bare/
          <repo_id>.git/        (one shared bare clone per configured repo)
        <safe-issue-identifier>/  (per-issue worktree)

  All filesystem operations are guarded with file locks so concurrent
  agent runs against the same repo don't race on the bare clone.
  """

  require Logger

  @lock_dir_relative "_bare/.locks"
  @bare_dir_relative "_bare"

  @typedoc "Subset of RepoConfig.repo_entry the worktree pipeline needs."
  @type routed_repo :: %{
          id: String.t(),
          repo_url: String.t() | nil,
          base_branch: String.t()
        }

  @doc """
  Ensure a bare clone exists for the given routed repo, then fetch.
  Returns `{:ok, bare_path}` on success.
  """
  @spec ensure_and_fetch(String.t(), routed_repo()) ::
          {:ok, Path.t()} | {:error, term()}
  def ensure_and_fetch(workspace_root, %{repo_url: nil}) when is_binary(workspace_root) do
    {:error, :missing_repo_url}
  end

  def ensure_and_fetch(workspace_root, %{id: repo_id, repo_url: repo_url} = _routed)
      when is_binary(workspace_root) and is_binary(repo_id) and is_binary(repo_url) do
    bare_path = bare_path(workspace_root, repo_id)
    File.mkdir_p!(Path.dirname(bare_path))

    with_repo_lock(workspace_root, repo_id, fn ->
      with :ok <- ensure_clone(bare_path, repo_url),
           :ok <- fetch(bare_path) do
        {:ok, bare_path}
      end
    end)
  end

  @doc """
  Create a worktree at `worktree_path` rooted at `origin/<base_branch>`
  on a branch named `branch_name`. If the branch already exists in the
  bare clone (a previous run on the same issue), the worktree is created
  pointing at the existing branch rather than re-forking. The caller
  must remove an existing dir at `worktree_path` first if present.
  """
  @spec create_worktree(Path.t(), Path.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def create_worktree(bare_path, worktree_path, branch_name, base_branch)
      when is_binary(bare_path) and is_binary(worktree_path) and is_binary(branch_name) and
             is_binary(base_branch) do
    File.mkdir_p!(Path.dirname(worktree_path))

    args = [
      "-C",
      bare_path,
      "worktree",
      "add",
      # `-B` creates or resets the branch — safe for retries on the same issue.
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
  def remove_worktree(bare_path, worktree_path)
      when is_binary(bare_path) and is_binary(worktree_path) do
    if File.exists?(worktree_path) do
      args = ["-C", bare_path, "worktree", "remove", "--force", worktree_path]

      case System.cmd("git", args, stderr_to_stdout: true) do
        {_output, 0} ->
          :ok

        {output, status} ->
          Logger.warning(
            "git worktree remove failed (status=#{status}, falling back to rm -rf): #{String.trim(IO.iodata_to_binary(output))}"
          )

          _ = File.rm_rf(worktree_path)
          # Best-effort prune any dangling refs in the bare clone.
          _ = System.cmd("git", ["-C", bare_path, "worktree", "prune"], stderr_to_stdout: true)
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  Compute the bare-clone path for a given workspace root + repo id.
  Public for tests + the Workspace module.
  """
  @spec bare_path(String.t(), String.t()) :: Path.t()
  def bare_path(workspace_root, repo_id) when is_binary(workspace_root) and is_binary(repo_id) do
    Path.join([workspace_root, @bare_dir_relative, "#{repo_id}.git"])
  end

  defp ensure_clone(bare_path, repo_url) do
    if bare_clone_present?(bare_path) do
      :ok
    else
      # Clean any half-cloned remnants so `git clone --bare` doesn't fail
      # on a pre-existing partial dir from a crashed earlier attempt.
      _ = File.rm_rf(bare_path)

      case System.cmd("git", ["clone", "--bare", repo_url, bare_path], stderr_to_stdout: true) do
        {_output, 0} ->
          :ok

        {output, status} ->
          {:error, {:bare_clone_failed, status, String.trim(IO.iodata_to_binary(output))}}
      end
    end
  end

  defp bare_clone_present?(bare_path) do
    # A populated bare clone has a `HEAD` file and an `objects/` dir.
    File.regular?(Path.join(bare_path, "HEAD")) and File.dir?(Path.join(bare_path, "objects"))
  end

  defp fetch(bare_path) do
    case System.cmd("git", ["-C", bare_path, "fetch", "--prune", "origin"], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        # A fetch failure isn't fatal — the existing pack might still cover the
        # required base_branch. Log it and keep going.
        Logger.warning(
          "git fetch on bare clone #{bare_path} failed (status=#{status}); reusing existing pack: #{String.trim(IO.iodata_to_binary(output))}"
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
        {:error, {:bare_clone_lock_failed, reason}}
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
