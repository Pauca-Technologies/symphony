defmodule SymphonyElixir.GitHubAuth.External do
  @moduledoc false
  @behaviour SymphonyElixir.GitHubAuth

  @contract_version 1
  @environment_name ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @impl true
  @spec prepare(Path.t(), keyword()) ::
          {:ok, SymphonyElixir.GitHubAuth.session()} | {:error, term()}
  def prepare(workspace, opts \\ []) when is_binary(workspace) and is_list(opts) do
    with :ok <- ensure_local(Keyword.get(opts, :worker_host)),
         {:ok, executable} <- resolve_executable(opts),
         {:ok, output} <- execute_prepare(executable, workspace, opts) do
      decode_session(output)
    end
  end

  defp ensure_local(nil), do: :ok
  defp ensure_local(worker_host), do: {:error, {:github_auth_remote_worker_unsupported, worker_host}}

  defp resolve_executable(opts) do
    explicit = Keyword.get(opts, :executable)
    configured = Application.get_env(:symphony_elixir, :udp_gh_cli)

    cond do
      is_binary(explicit) ->
        executable_result(explicit)

      is_binary(configured) ->
        executable_result(configured)

      true ->
        candidates = [
          System.find_executable("udp-gh"),
          sibling_executable(),
          Path.expand("bin/udp-gh", File.cwd!())
        ]

        case Enum.find(candidates, &executable_file?/1) do
          nil -> {:error, :udp_gh_cli_not_found}
          executable -> {:ok, Path.expand(executable)}
        end
    end
  end

  defp executable_result(executable) do
    if executable_file?(executable) do
      {:ok, Path.expand(executable)}
    else
      {:error, :udp_gh_cli_not_found}
    end
  end

  defp sibling_executable do
    script = :escript.script_name() |> to_string() |> String.trim()
    Path.join(Path.dirname(Path.expand(script)), "udp-gh")
  end

  defp executable_file?(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp executable_file?(_path), do: false

  defp execute_prepare(executable, workspace, opts) do
    command = Keyword.get(opts, :command, &System.cmd/3)

    case command.(executable, ["prepare", "--cwd", workspace], stderr_to_stdout: true) do
      {output, 0} -> {:ok, IO.iodata_to_binary(output)}
      {output, status} -> {:error, {:udp_gh_prepare_failed, status, bounded_output(output)}}
    end
  rescue
    error in ErlangError -> {:error, {:udp_gh_prepare_failed, error.original}}
  end

  defp decode_session(output) do
    with {:ok, decoded} <- Jason.decode(output),
         :ok <- validate_contract_version(decoded),
         {:ok, set} <- validate_set(decoded["set"]),
         {:ok, unset} <- validate_unset(decoded["unset"]),
         :ok <- validate_disjoint_environment(set, unset),
         {:ok, expires_at} <- parse_expiration(decoded["expiresAt"]),
         {:ok, repository} <- required_string(decoded, "repository"),
         {:ok, host} <- required_string(decoded, "host"),
         {:ok, auth_root} <- required_string(decoded, "authRoot") do
      symphony_set =
        set
        |> Map.put("SYMPHONY_GITHUB_AUTH", "1")
        |> Map.put("SYMPHONY_GITHUB_AUTH_ROOT", auth_root)
        |> Map.put("SYMPHONY_GITHUB_REPOSITORY", repository)
        |> maybe_put_real_gh()

      env =
        symphony_set
        |> Map.to_list()
        |> Kernel.++(Enum.map(unset, &{&1, false}))
        |> Enum.sort_by(&elem(&1, 0))

      {:ok,
       %{
         env: env,
         repo: repository,
         host: host,
         auth_root: auth_root,
         expires_at: expires_at
       }}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:udp_gh_invalid_contract, Exception.message(error)}}

      {:error, reason} ->
        {:error, {:udp_gh_invalid_contract, reason}}
    end
  end

  defp validate_contract_version(%{"version" => @contract_version}), do: :ok
  defp validate_contract_version(%{"version" => version}), do: {:error, {:unsupported_version, version}}
  defp validate_contract_version(_decoded), do: {:error, :missing_version}

  defp validate_set(set) when is_map(set) do
    if Enum.all?(set, fn {name, value} -> valid_environment_name?(name) and is_binary(value) end) do
      {:ok, set}
    else
      {:error, :invalid_set_environment}
    end
  end

  defp validate_set(_set), do: {:error, :invalid_set_environment}

  defp validate_unset(unset) when is_list(unset) do
    if Enum.all?(unset, &valid_environment_name?/1) and length(Enum.uniq(unset)) == length(unset) do
      {:ok, unset}
    else
      {:error, :invalid_unset_environment}
    end
  end

  defp validate_unset(_unset), do: {:error, :invalid_unset_environment}

  defp valid_environment_name?(name) when is_binary(name), do: Regex.match?(@environment_name, name)
  defp valid_environment_name?(_name), do: false

  defp validate_disjoint_environment(set, unset) do
    case Enum.find(unset, &Map.has_key?(set, &1)) do
      nil -> :ok
      name -> {:error, {:conflicting_environment_variable, name}}
    end
  end

  defp parse_expiration(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, expires_at, _offset} -> {:ok, expires_at}
      _ -> {:error, :invalid_expiration}
    end
  end

  defp parse_expiration(_value), do: {:error, :invalid_expiration}

  defp required_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp maybe_put_real_gh(set) do
    case Map.get(set, "UDP_GH_REAL_GH") do
      value when is_binary(value) and value != "" -> Map.put(set, "SYMPHONY_REAL_GH", value)
      _ -> set
    end
  end

  defp bounded_output(output, max_bytes \\ 2_048) do
    binary = IO.iodata_to_binary(output)

    if byte_size(binary) <= max_bytes do
      binary
    else
      binary_part(binary, 0, max_bytes) <> "... (truncated)"
    end
  end
end
