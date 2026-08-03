defmodule SymphonyElixir.AgentTransport do
  @moduledoc """
  Backend-agnostic process/transport plumbing shared by the coding-agent
  backends.

  This collects the cwd validation, sourced-`.env` sanitization, local
  `Port.open` / remote `SSH.start_port` launch, line-framed stdio, and port
  teardown that `SymphonyElixir.Codex.AppServer` originally implemented inline.
  The ACP backend (`SymphonyElixir.Acp.Client`) is the first consumer; it calls
  these with its own configured command and environment.

  The Codex app-server still carries its own private copies for now so its
  behavior stays byte-for-byte unchanged (see `docs/acp-support-plan.md` §5.3 —
  "keep the functions in AppServer initially and have Acp.Client call them,
  then extract in a follow-up once green"). A later refactor will have
  `AppServer` delegate here.

  The `env` parameter is an Erlang port env list (`[{charlist, charlist}]`).
  A value of `false` *unsets* the variable in the child — that is how the ACP
  backend withholds Linear credentials from the agent process.
  """

  require Logger

  alias SymphonyElixir.{Config, PathSafety, SSH}

  @port_line_bytes 1_048_576
  @source_env_pattern ~r/(?:^|[\s;&|('"])(?:\.|source)\s+(?:"([^"]+)"|'([^']+)'|([^\s;&|]+))/

  @type port_env :: [{charlist(), charlist() | false}]

  @doc "Maximum bytes per line for the line-framed port (matches the Codex path)."
  @spec port_line_bytes() :: pos_integer()
  def port_line_bytes, do: @port_line_bytes

  @doc """
  The configured global `agent.pre_command` shell snippet, or `nil` when unset
  or blank. Backend-agnostic: every backend runs this in the launch shell
  before its agent process (see `with_pre_command/2`).
  """
  @spec pre_command() :: String.t() | nil
  def pre_command do
    case Config.settings!().agent.pre_command do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  @doc """
  Prepend the global `agent.pre_command` (if any) to a launch-shell fragment,
  joined with `&&`, so it runs in the same shell — and workspace cwd — before
  `fragment`. Returns `fragment` unchanged when no pre-command is configured, so
  the default launch path stays byte-for-byte identical.

  Used for both the local fragment (the bare command) and the remote fragment
  (`exec <command>`), so the snippet runs before exec on either path.
  """
  @spec with_pre_command(String.t()) :: String.t()
  def with_pre_command(fragment) when is_binary(fragment),
    do: with_pre_command(fragment, pre_command())

  @spec with_pre_command(String.t(), String.t() | nil) :: String.t()
  def with_pre_command(fragment, nil) when is_binary(fragment), do: fragment

  def with_pre_command(fragment, pre) when is_binary(fragment) and is_binary(pre),
    do: pre <> " && " <> fragment

  @doc """
  Validate that `workspace` is a safe agent cwd: a real directory strictly
  under the configured workspace root, with no symlink escape. Remote
  workspaces (when `worker_host` is set) are only sanity-checked for shell
  safety since the path lives on another host.
  """
  @spec validate_workspace_cwd(Path.t(), String.t() | nil) ::
          {:ok, Path.t()} | {:error, term()}
  def validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  def validate_workspace_cwd(workspace, worker_host)
      when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  @doc """
  Strip non-assignment noise from any workspace-local `.env` files that the
  launch command sources, so a generated env file with stray log lines can be
  `source`d without aborting the shell. No-op for remote launches.
  """
  @spec prepare_sourced_env_files(Path.t(), String.t() | nil, String.t()) :: :ok
  def prepare_sourced_env_files(workspace, nil, command)
      when is_binary(workspace) and is_binary(command) do
    # Scan both the backend command and the global `agent.pre_command` — either
    # may `source` a generated workspace `.env` (e.g. a GitHub-session file).
    [command, pre_command()]
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&sourced_env_files(&1, workspace))
    |> Enum.uniq()
    |> Enum.each(&sanitize_sourced_env_file(&1, workspace))

    :ok
  end

  def prepare_sourced_env_files(_workspace, worker_host, _command) when is_binary(worker_host),
    do: :ok

  @doc """
  Launch `command` in `workspace` with `env`, returning a line-framed port.
  Local launches go through `bash -lc`; remote launches use `SSH.start_port/3`
  with the env inlined into the remote shell command.
  """
  @spec start_port(Path.t(), String.t() | nil, String.t(), port_env()) ::
          {:ok, port()} | {:error, term()}
  def start_port(workspace, nil, command, env)
      when is_binary(workspace) and is_binary(command) and is_list(env) do
    case System.find_executable("bash") do
      nil ->
        {:error, :bash_not_found}

      executable ->
        port =
          Port.open(
            {:spawn_executable, String.to_charlist(executable)},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: [~c"-lc", String.to_charlist(with_pre_command(command))],
              cd: String.to_charlist(workspace),
              line: @port_line_bytes,
              env: env
            ]
          )

        {:ok, port}
    end
  end

  def start_port(workspace, worker_host, command, env)
      when is_binary(workspace) and is_binary(worker_host) and is_binary(command) and is_list(env) do
    remote_command = remote_launch_command(workspace, command, env)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  @doc "Best-effort close of a launched port."
  @spec stop_port(port()) :: :ok
  def stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end

  def stop_port(_port), do: :ok

  @doc "Send a JSON-RPC message as a single newline-terminated line."
  @spec send_message(port(), map()) :: true
  def send_message(port, message) when is_port(port) and is_map(message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  @doc "Metadata describing the launched port (os pid, worker host)."
  @spec port_metadata(port(), String.t() | nil) :: map()
  def port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} -> %{agent_os_pid: to_string(os_pid)}
        _ -> %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp remote_launch_command(workspace, command, env)
       when is_binary(workspace) and is_binary(command) and is_list(env) do
    # SSH does not forward our local env, so set/unset each variable inline in
    # the remote shell command.
    env_lines =
      Enum.map(env, fn
        {name, false} -> "unset #{to_string(name)}"
        {name, value} -> "export #{to_string(name)}=#{shell_escape(to_string(value))}"
      end)

    (["cd #{shell_escape(workspace)}"] ++ env_lines ++ [with_pre_command("exec #{command}")])
    |> Enum.join(" && ")
  end

  defp sourced_env_files(command, workspace) when is_binary(command) and is_binary(workspace) do
    @source_env_pattern
    |> Regex.scan(command)
    |> Enum.map(fn [_match | captures] -> Enum.find(captures, &(&1 != "")) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&String.ends_with?(&1, ".env"))
    |> Enum.map(&Path.expand(&1, workspace))
    |> Enum.uniq()
    |> Enum.filter(&workspace_file?(&1, workspace))
  end

  defp sanitize_sourced_env_file(path, workspace) do
    with true <- File.regular?(path),
         {:ok, content} <- File.read(path),
         {:ok, sanitized_content, removed_count} <- sanitize_shell_env_content(content),
         true <- sanitized_content != content,
         :ok <- File.write(path, sanitized_content) do
      Logger.warning("Sanitized sourced env file before agent startup workspace=#{workspace} path=#{path} removed_lines=#{removed_count}")
    else
      _ -> :ok
    end
  end

  defp sanitize_shell_env_content(content) when is_binary(content) do
    lines = String.split(content, "\n", trim: false)

    {sanitized_lines, removed_count, assignment_count} =
      Enum.reduce(lines, {[], 0, 0}, fn line, {kept, removed, assignments} ->
        cond do
          shell_env_assignment_line?(line) ->
            {[line | kept], removed, assignments + 1}

          shell_env_ignored_line?(line) ->
            {[line | kept], removed, assignments}

          true ->
            {kept, removed + 1, assignments}
        end
      end)

    if removed_count > 0 and assignment_count > 0 do
      {:ok, sanitized_lines |> Enum.reverse() |> Enum.join("\n"), removed_count}
    else
      :skip
    end
  end

  defp shell_env_assignment_line?(line) when is_binary(line) do
    String.match?(line, ~r/^\s*(?:export\s+)?[A-Za-z_][A-Za-z0-9_]*=/)
  end

  defp shell_env_ignored_line?(line) when is_binary(line) do
    trimmed = String.trim_leading(line)
    trimmed == "" or String.starts_with?(trimmed, "#")
  end

  defp workspace_file?(path, workspace) do
    with {:ok, canonical_path} <- PathSafety.canonicalize(path),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace) do
      String.starts_with?(canonical_path <> "/", canonical_workspace <> "/")
    else
      _ -> false
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
