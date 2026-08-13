defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{BareClone, Config, GitHubAuth, OSProcess, PathSafety, SSH, TestWorkerBudget}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"

  @type worker_host :: String.t() | nil

  @spec create_for_issue(map() | String.t() | nil, worker_host(), keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil, opts \\ []) do
    issue_context = issue_context(issue_or_identifier)
    routed_repo = Keyword.get(opts, :routed_repo)
    after_create_override = Keyword.get(opts, :after_create_command)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <-
             ensure_workspace(workspace, worker_host, routed_repo, issue_or_identifier),
           {:ok, _issue_context_file} <-
             prepare_issue_context(workspace, issue_or_identifier, worker_host),
           :ok <-
             maybe_run_host_after_create_hook(
               routed_repo,
               workspace,
               issue_context,
               created?,
               worker_host,
               after_create_override
             ) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  @doc """
  Write the current issue snapshot outside the agent-writable workspace.

  The returned path is safe to expose to repository hooks and agent processes;
  it contains task context, never Symphony's Linear credentials.
  """
  @spec prepare_issue_context(Path.t(), map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def prepare_issue_context(workspace, issue_or_identifier, worker_host \\ nil)
      when is_binary(workspace) do
    with :ok <- validate_workspace_path(workspace, worker_host),
         {:ok, payload} <- encode_issue_context(issue_or_identifier),
         :ok <- write_issue_context(workspace, payload, worker_host) do
      {:ok, issue_context_path(workspace)}
    end
  end

  @doc "Return the trusted issue-context file path associated with a workspace."
  @spec issue_context_path(Path.t()) :: Path.t()
  def issue_context_path(workspace) when is_binary(workspace) do
    Path.join([Path.dirname(workspace), ".symphony-context", Path.basename(workspace) <> ".json"])
  end

  @doc "Return the trusted durable pending-handoff file associated with a workspace."
  @spec handoff_gate_state_path(Path.t()) :: Path.t()
  def handoff_gate_state_path(workspace) when is_binary(workspace) do
    issue_context_path(workspace) <> ".handoff-gate.json"
  end

  @doc "Atomically persist pending asynchronous handoff state outside the agent workspace."
  @spec persist_handoff_gate_state(Path.t(), map(), worker_host()) :: :ok | {:error, term()}
  def persist_handoff_gate_state(workspace, state, worker_host \\ nil)
      when is_binary(workspace) and is_map(state) do
    with :ok <- validate_workspace_path(workspace, worker_host),
         {:ok, payload} <-
           Jason.encode(%{
             "protocolVersion" => 1,
             "capturedAt" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
             "request" => state
           }) do
      write_handoff_gate_state(workspace, payload, worker_host)
    end
  end

  @doc "Load a durable pending asynchronous handoff request, if one exists."
  @spec load_handoff_gate_state(Path.t(), worker_host()) :: {:ok, map() | nil} | {:error, term()}
  def load_handoff_gate_state(workspace, worker_host \\ nil) when is_binary(workspace) do
    with :ok <- validate_workspace_path(workspace, worker_host),
         {:ok, payload} <- read_handoff_gate_state(workspace, worker_host) do
      decode_handoff_gate_state(payload)
    end
  end

  @doc "Remove the durable pending asynchronous handoff request for a workspace."
  @spec clear_handoff_gate_state(Path.t(), worker_host()) :: :ok | {:error, term()}
  def clear_handoff_gate_state(workspace, worker_host \\ nil) when is_binary(workspace) do
    with :ok <- validate_workspace_path(workspace, worker_host) do
      remove_handoff_gate_state(workspace, worker_host)
    end
  end

  @doc """
  Run `after_create` against a workspace that's already populated.
  Public because `AgentRunner` calls this with the per-repo workflow's
  `after_create` command once the worktree exists and the consumer's
  WORKFLOW.md has been loaded (T27 multi-repo dispatch).
  """
  @spec run_after_create_hook(Path.t(), map() | String.t() | nil, worker_host(), keyword()) ::
          :ok | {:error, term()}
  def run_after_create_hook(workspace, issue_or_identifier, worker_host \\ nil, opts \\ [])
      when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    command = resolve_hook_command(:after_create, Keyword.get(opts, :hook_command))

    case command do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_create", worker_host, github_auth: Keyword.get(opts, :github_auth, true))
    end
  end

  # When the issue is routed to a configured repo (T24/T27), Symphony owns
  # the cloning step: it lazy-creates a bare clone per repo and uses
  # `git worktree add` per issue. Local path only — SSH/remote worktree
  # support is a future task. When no routed_repo is given (legacy single-
  # repo mode), fall through to the pre-T27 mkdir + after_create-hook
  # clone behavior.
  defp ensure_workspace(workspace, nil, %{repo_url: url} = routed_repo, issue_or_identifier)
       when is_binary(url) do
    workspace_root = Config.settings!().workspace.root
    branch_name = resolve_worktree_branch_name(issue_or_identifier)
    base_branch = Map.get(routed_repo, :base_branch, "main")

    # If a prior dispatch left non-worktree debris at this path, clear it so
    # the worktree machinery has a clean slate. A valid worktree is left in
    # place for `ensure_worktree` to reuse (preserving gitignored artifacts).
    if File.exists?(workspace) and not git_worktree_dir?(workspace) do
      File.rm_rf!(workspace)
    end

    with {:ok, bare_path} <- BareClone.ensure_and_fetch(workspace_root, routed_repo, branch_name),
         {:ok, %{start_point: start_point, reused: reused?}} <-
           BareClone.ensure_worktree(bare_path, workspace, branch_name, base_branch) do
      Logger.info("Workspace ready via worktree repo=#{routed_repo.id} bare=#{bare_path} workspace=#{workspace} branch=#{branch_name} base=#{base_branch} start=#{start_point} reused=#{reused?}")

      {:ok, workspace, true}
    end
  end

  defp ensure_workspace(workspace, nil, _routed_repo, _issue) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host, _routed_repo, _issue) when is_binary(worker_host) do
    ensure_workspace_remote(workspace, worker_host)
  end

  # A populated worktree always has a `.git` file (NOT a directory) that
  # points back to the bare clone. We use that to distinguish "worktree
  # we created last time" from "random debris left in this path."
  defp git_worktree_dir?(workspace) when is_binary(workspace) do
    git_marker = Path.join(workspace, ".git")
    File.regular?(git_marker)
  end

  defp resolve_worktree_branch_name(%{branch_name: bn}) when is_binary(bn) and bn != "", do: bn

  defp resolve_worktree_branch_name(%{identifier: id}) when is_binary(id) do
    safe_identifier(id)
  end

  defp resolve_worktree_branch_name(id) when is_binary(id), do: safe_identifier(id)
  defp resolve_worktree_branch_name(_), do: "symphony-worktree"

  defp ensure_workspace_remote(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil) do
          :ok ->
            maybe_run_before_remove_hook(workspace, nil)
            result = File.rm_rf(workspace)
            remove_handoff_gate_state(workspace, nil)
            remove_issue_context(workspace)
            result

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        result = File.rm_rf(workspace)
        remove_handoff_gate_state(workspace, nil)
        remove_issue_context(workspace)
        result
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    maybe_run_before_remove_hook(workspace, worker_host)

    script =
      [
        remote_shell_assign("workspace", workspace),
        remote_shell_assign("context_file", issue_context_path(workspace)),
        remote_shell_assign("handoff_file", handoff_gate_state_path(workspace)),
        "rm -rf \"$workspace\"",
        "rm -f \"$context_file\"",
        "rm -f \"$handoff_file\"",
        "rmdir \"$(dirname \"$context_file\")\" 2>/dev/null || true"
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    safe_id = safe_identifier(identifier)

    case workspace_path_for_issue(safe_id, worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)

    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(safe_id, nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host) do
    :ok
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host(), keyword()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil, opts \\ [])
      when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    command = resolve_hook_command(:before_run, Keyword.get(opts, :hook_command))

    case command do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host)
    end
  end

  @spec run_session_start_hook(Path.t(), map() | String.t() | nil, worker_host(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def run_session_start_hook(workspace, issue_or_identifier, worker_host \\ nil, opts \\ [])
      when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    command = resolve_hook_command(:session_start, Keyword.get(opts, :hook_command))

    case command do
      nil ->
        {:ok, ""}

      command ->
        run_hook(command, workspace, issue_context, "session_start", worker_host, capture_output: true)
    end
  end

  @spec run_before_handoff_hook(Path.t(), map() | String.t() | nil, worker_host(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def run_before_handoff_hook(workspace, issue_or_identifier, worker_host \\ nil, opts \\ [])
      when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    command = resolve_hook_command(:before_handoff, Keyword.get(opts, :hook_command))

    with {:ok, _issue_context_file} <-
           prepare_issue_context(workspace, issue_or_identifier, worker_host) do
      case command do
        nil ->
          {:ok, ""}

        command ->
          run_hook(command, workspace, issue_context, "before_handoff", worker_host,
            capture_output: true,
            timeout_ms: Keyword.get(opts, :timeout_ms),
            env: handoff_hook_env(opts)
          )
      end
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host(), keyword()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil, opts \\ [])
      when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    command = resolve_hook_command(:after_run, Keyword.get(opts, :hook_command))

    case command do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.settings!().workspace.root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  @doc """
  Compute the local workspace path Symphony would use for a given issue
  identifier. Public so `SymphonyElixir.WorkspaceGc` (T28) can locate a
  worktree from a Linear issue identifier without duplicating the
  `safe_identifier` + workspace-root logic. Returns nil when the
  identifier is empty or non-binary.
  """
  @spec workspace_path_for_identifier(term()) :: Path.t() | nil
  def workspace_path_for_identifier(identifier) when is_binary(identifier) and identifier != "" do
    safe_id = safe_identifier(identifier)
    Path.join(Config.settings!().workspace.root, safe_id)
  end

  def workspace_path_for_identifier(_identifier), do: nil

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  # When a routed_repo is in play (multi-repo dispatch, T27), the caller
  # (AgentRunner) is responsible for running after_create itself with the
  # consumer repo's own WORKFLOW.md hook (which can only be read after the
  # worktree exists), so we skip it here. In the legacy single-repo path we
  # still run after_create from the host-level Config so existing setups
  # don't change.
  defp maybe_run_host_after_create_hook(routed_repo, _workspace, _issue_context, _created?, _worker_host, _override)
       when not is_nil(routed_repo),
       do: :ok

  defp maybe_run_host_after_create_hook(_routed_repo, workspace, issue_context, created?, worker_host, override) do
    maybe_run_after_create_hook(workspace, issue_context, created?, worker_host, override)
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host, override) do
    command = resolve_hook_command(:after_create, override)

    case {created?, command} do
      {true, command} when is_binary(command) ->
        # In legacy single-repo mode this hook is responsible for cloning the
        # repository, so GitHub auth cannot derive a repository until it exits.
        run_hook(command, workspace, issue_context, "after_create", worker_host, github_auth: false)

      _ ->
        :ok
    end
  end

  # Pick the hook command at call time: an explicit per-call override
  # (used by AgentRunner to thread the per-repo workflow's hooks once the
  # worktree is loaded) takes precedence over the host-level Config
  # settings. `:not_set` means "no override; fall back to global".
  defp resolve_hook_command(hook_name, override) do
    case override do
      nil ->
        Map.get(Config.settings!().hooks, hook_name)

      :not_set ->
        Map.get(Config.settings!().hooks, hook_name)

      command when is_binary(command) ->
        command

      _ ->
        Map.get(Config.settings!().hooks, hook_name)
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              false
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, worker_host, opts \\ [])

  defp run_hook(command, workspace, issue_context, hook_name, nil, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms) || Config.settings!().hooks.timeout_ms
    capture_output? = Keyword.get(opts, :capture_output, false)

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    with {:ok, github_env} <- github_hook_env(workspace, nil, opts) do
      env = port_hook_env(workspace, merge_env(github_env, Keyword.get(opts, :env, [])))
      {port, root_identity} = start_local_hook_port(command, workspace, env)

      case collect_local_hook_port(port, timeout_ms) do
        {:ok, cmd_result} ->
          handle_hook_command_result(cmd_result, workspace, issue_context, hook_name, capture_output?)

        :timeout ->
          terminate_local_hook_port(port, root_identity, issue_context, hook_name)

          Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

          {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
      end
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host, opts)
       when is_binary(worker_host) do
    timeout_ms = Keyword.get(opts, :timeout_ms) || Config.settings!().hooks.timeout_ms
    capture_output? = Keyword.get(opts, :capture_output, false)

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    with {:ok, github_env} <- github_hook_env(workspace, worker_host, opts) do
      exports = remote_hook_exports(workspace, merge_env(github_env, Keyword.get(opts, :env, [])))

      case run_remote_command(
             worker_host,
             "cd #{shell_escape(workspace)} && #{exports} #{command}",
             timeout_ms
           ) do
        {:ok, cmd_result} ->
          handle_hook_command_result(cmd_result, workspace, issue_context, hook_name, capture_output?)

        {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
          {:error, reason}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp start_local_hook_port(command, workspace, env) do
    executable = System.find_executable("sh") || raise "sh executable not found"

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [~c"-lc", String.to_charlist(command)],
          cd: String.to_charlist(workspace),
          env: env
        ]
      )

    {port, local_hook_root_identity(port)}
  end

  defp collect_local_hook_port(port, timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    collect_local_hook_port(port, deadline_ms, [])
  end

  defp collect_local_hook_port(port, deadline_ms, output) do
    timeout_ms = max(0, deadline_ms - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, data}} ->
        collect_local_hook_port(port, deadline_ms, [output, data])

      {^port, {:exit_status, status}} ->
        {:ok, {IO.iodata_to_binary(output), status}}
    after
      timeout_ms -> :timeout
    end
  end

  defp local_hook_root_identity(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) ->
        os_pid
        |> OSProcess.snapshot_tree()
        |> Enum.find(&(&1.pid == os_pid))

      _port_info ->
        nil
    end
  end

  defp terminate_local_hook_port(port, root_identity, issue_context, hook_name) do
    identities = local_hook_process_tree(root_identity)
    close_hook_port(port)

    case OSProcess.terminate_identities(identities) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Workspace hook process cleanup failed hook=#{hook_name} #{issue_log_context(issue_context)} reason=#{inspect(reason)}")

        :ok
    end
  end

  defp local_hook_process_tree(%{pid: os_pid, start_time: start_time} = root_identity) do
    if OSProcess.alive?(root_identity) do
      tree = OSProcess.snapshot_tree(os_pid)

      if Enum.any?(tree, &(&1.pid == os_pid and &1.start_time == start_time)),
        do: tree,
        else: []
    else
      []
    end
  end

  defp local_hook_process_tree(_root_identity), do: []

  defp close_hook_port(port) do
    if :erlang.port_info(port) != :undefined, do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name, false) do
    :ok
  end

  defp handle_hook_command_result({output, 0}, _workspace, _issue_id, _hook_name, true) do
    {:ok, IO.iodata_to_binary(output)}
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name, _capture_output?) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp hook_env(workspace, extra_env) do
    [
      {"SYMPHONY_RUN", "1"},
      {"SYMPHONY_ISSUE_CONTEXT_FILE", issue_context_path(workspace)}
    ] ++ extra_env
  end

  # SYMPHONY_RUN=1 marks this as a Symphony-spawned outer hook so consumer
  # repositories can distinguish it from an inner coding-agent process.
  defp port_hook_env(workspace, extra_env) do
    workspace
    |> hook_env(extra_env)
    |> Enum.map(fn
      {name, false} -> {String.to_charlist(name), false}
      {name, value} -> {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  defp github_hook_env(workspace, worker_host, opts) when is_binary(workspace) do
    case Keyword.get(opts, :github_auth, true) do
      false ->
        {:ok, []}

      true ->
        with {:ok, %{env: env}} <- GitHubAuth.prepare(workspace, worker_host: worker_host) do
          {:ok, env}
        end
    end
  end

  defp merge_env(base, overrides) do
    base
    |> Map.new()
    |> Map.merge(Map.new(overrides))
    |> Map.to_list()
  end

  defp handoff_hook_env(opts) do
    [
      {"SYMPHONY_TEST_WORKER_LIMIT", Integer.to_string(TestWorkerBudget.limit())},
      {
        "SYMPHONY_HEAVY_VALIDATION_LIMIT",
        Integer.to_string(TestWorkerBudget.heavy_validation_limit())
      }
    ]
    |> maybe_put_hook_env("SYMPHONY_HANDOFF_GATE_PROTOCOL", Keyword.get(opts, :gate_protocol))
    |> maybe_put_hook_env("SYMPHONY_HANDOFF_GATE_JOB_ID", Keyword.get(opts, :gate_job_id))
  end

  defp maybe_put_hook_env(env, _name, nil), do: env
  defp maybe_put_hook_env(env, name, value), do: env ++ [{name, to_string(value)}]

  defp remote_hook_exports(workspace, extra_env) do
    ([
       {"SYMPHONY_RUN", "1"},
       {"SYMPHONY_ISSUE_CONTEXT_FILE", issue_context_path(workspace)}
     ] ++ extra_env)
    |> Enum.map_join(" ", fn
      {name, false} -> "unset #{name} &&"
      {name, value} -> "export #{name}=#{shell_escape(value)} &&"
    end)
  end

  defp encode_issue_context(issue_or_identifier) do
    Jason.encode(%{
      "version" => 2,
      "capturedAt" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "issue" => issue_snapshot(issue_or_identifier)
    })
  end

  defp issue_snapshot(issue) when is_map(issue) do
    %{
      "id" => issue_value(issue, :id),
      "identifier" => issue_value(issue, :identifier),
      "title" => issue_value(issue, :title),
      "description" => issue_value(issue, :description),
      "url" => issue_value(issue, :url),
      "state" => issue_value(issue, :state),
      "labels" => issue_value(issue, :labels) || [],
      "comments" => Enum.map(issue_value(issue, :comments) || [], &comment_snapshot/1),
      "commentsTruncated" => issue_value(issue, :comments_truncated) == true,
      "updatedAt" => encode_datetime(issue_value(issue, :updated_at))
    }
  end

  defp issue_snapshot(identifier) when is_binary(identifier) do
    %{
      "id" => nil,
      "identifier" => identifier,
      "title" => nil,
      "description" => nil,
      "url" => nil,
      "state" => nil,
      "labels" => [],
      "comments" => [],
      "commentsTruncated" => false,
      "updatedAt" => nil
    }
  end

  defp issue_snapshot(_issue), do: issue_snapshot("issue")

  defp comment_snapshot(comment) when is_map(comment) do
    %{
      "id" => issue_value(comment, :id),
      "body" => issue_value(comment, :body) || "",
      "author" => %{
        "id" => issue_value(comment, :author_id),
        "name" => issue_value(comment, :author_name)
      },
      "createdAt" => encode_datetime(issue_value(comment, :created_at)),
      "updatedAt" => encode_datetime(issue_value(comment, :updated_at))
    }
  end

  defp issue_value(issue, key) do
    Map.get(issue, key) || Map.get(issue, Atom.to_string(key))
  end

  defp encode_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_datetime(value) when is_binary(value), do: value
  defp encode_datetime(_value), do: nil

  defp write_issue_context(workspace, payload, nil) do
    context_file = issue_context_path(workspace)
    context_dir = Path.dirname(context_file)
    temporary_file = context_file <> ".tmp.#{System.unique_integer([:positive])}"

    result =
      with :ok <- File.mkdir_p(context_dir),
           :ok <- File.write(temporary_file, payload, [:binary]),
           :ok <- File.chmod(temporary_file, 0o600),
           do: File.rename(temporary_file, context_file)

    if result != :ok, do: File.rm(temporary_file)
    result
  end

  defp write_issue_context(workspace, payload, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("context_file", issue_context_path(workspace)),
        "context_dir=$(dirname \"$context_file\")",
        "mkdir -p \"$context_dir\"",
        "temporary_file=\"$context_file.tmp.$$\"",
        "trap 'rm -f \"$temporary_file\"' EXIT",
        "umask 077",
        "printf '%s' #{shell_escape(payload)} > \"$temporary_file\"",
        "chmod 600 \"$temporary_file\"",
        "mv \"$temporary_file\" \"$context_file\"",
        "trap - EXIT"
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, status}} ->
        {:error, {:issue_context_write_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_handoff_gate_state(workspace, payload, nil) do
    state_file = handoff_gate_state_path(workspace)
    state_dir = Path.dirname(state_file)
    temporary_file = state_file <> ".tmp.#{System.unique_integer([:positive])}"

    result =
      with :ok <- File.mkdir_p(state_dir),
           :ok <- File.write(temporary_file, payload, [:binary]),
           :ok <- File.chmod(temporary_file, 0o600),
           do: File.rename(temporary_file, state_file)

    if result != :ok, do: File.rm(temporary_file)
    result
  end

  defp write_handoff_gate_state(workspace, payload, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("state_file", handoff_gate_state_path(workspace)),
        "state_dir=$(dirname \"$state_file\")",
        "mkdir -p \"$state_dir\"",
        "temporary_file=\"$state_file.tmp.$$\"",
        "trap 'rm -f \"$temporary_file\"' EXIT",
        "umask 077",
        "printf '%s' #{shell_escape(payload)} > \"$temporary_file\"",
        "chmod 600 \"$temporary_file\"",
        "mv \"$temporary_file\" \"$state_file\"",
        "trap - EXIT"
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:handoff_gate_state_write_failed, worker_host, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_handoff_gate_state(workspace, nil) do
    case File.read(handoff_gate_state_path(workspace)) do
      {:ok, payload} -> {:ok, payload}
      {:error, :enoent} -> {:ok, nil}
      {:error, reason} -> {:error, {:handoff_gate_state_read_failed, reason}}
    end
  end

  defp read_handoff_gate_state(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        remote_shell_assign("state_file", handoff_gate_state_path(workspace)),
        "if [ -f \"$state_file\" ]; then cat \"$state_file\"; else exit 3; fi"
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {payload, 0}} -> {:ok, payload}
      {:ok, {_output, 3}} -> {:ok, nil}
      {:ok, {output, status}} -> {:error, {:handoff_gate_state_read_failed, worker_host, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_handoff_gate_state(nil), do: {:ok, nil}

  defp decode_handoff_gate_state(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{"protocolVersion" => 1, "request" => request}} when is_map(request) ->
        {:ok, request}

      {:ok, decoded} ->
        {:error, {:invalid_handoff_gate_state, decoded}}

      {:error, reason} ->
        {:error, {:invalid_handoff_gate_state, reason}}
    end
  end

  defp remove_handoff_gate_state(workspace, nil) do
    case File.rm(handoff_gate_state_path(workspace)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:handoff_gate_state_remove_failed, reason}}
    end
  end

  defp remove_handoff_gate_state(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        remote_shell_assign("state_file", handoff_gate_state_path(workspace)),
        "rm -f \"$state_file\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:handoff_gate_state_remove_failed, worker_host, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Remove the trusted issue-context snapshot associated with a local workspace."
  @spec remove_issue_context(Path.t()) :: :ok
  def remove_issue_context(workspace) when is_binary(workspace) do
    if validate_workspace_path(workspace, nil) == :ok do
      context_file = issue_context_path(workspace)
      File.rm(context_file)
      File.rmdir(Path.dirname(context_file))
    end

    :ok
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue"
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue"
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
