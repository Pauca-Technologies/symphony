defmodule SymphonyElixir.GitHubAuth.CLI do
  @moduledoc false

  alias SymphonyElixir.GitHubAuth

  @managed_keys [
    "GH_CONFIG_DIR",
    "GH_ENTERPRISE_TOKEN",
    "GH_HOST",
    "GH_PROMPT_DISABLED",
    "GH_TOKEN",
    "GIT_AUTHOR_EMAIL",
    "GIT_AUTHOR_NAME",
    "GIT_COMMITTER_EMAIL",
    "GIT_COMMITTER_NAME",
    "GITHUB_ENTERPRISE_TOKEN",
    "GITHUB_TOKEN",
    "PATH",
    "SYMPHONY_GITHUB_AUTH",
    "SYMPHONY_GITHUB_AUTH_ROOT",
    "SYMPHONY_GITHUB_REPOSITORY",
    "SYMPHONY_REAL_GH",
    "UDP_BOT_MODE"
  ]
  @stash_prefix "SYMPHONY_GITHUB_PREV_"
  @unset_sentinel "__SYMPHONY_UNSET__"
  @empty_sentinel "__SYMPHONY_EMPTY__"

  @doc "Run an interactive GitHub-auth CLI command and return its exit status."
  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(args, opts \\ []) when is_list(args) and is_list(opts) do
    if args == ["off"] do
      emit_off()
    else
      with {:ok, _req_apps} <- Application.ensure_all_started(:req),
           {:ok, _public_key_apps} <- Application.ensure_all_started(:public_key) do
        dispatch(args, opts)
      else
        {:error, reason} -> print_error({:github_auth_runtime_unavailable, reason})
      end
    end
  end

  defp dispatch(args, opts) do
    case args do
      ["on"] -> emit_on(opts)
      ["check"] -> check(opts)
      ["gh" | gh_args] -> run_gh(gh_args, opts)
      _ -> usage()
    end
  end

  defp emit_on(opts) do
    workspace = Keyword.get(opts, :workspace, File.cwd!())

    case GitHubAuth.prepare(workspace, Keyword.get(opts, :auth_opts, [])) do
      {:ok, %{env: env}} ->
        current = System.get_env()
        prepared = Map.new(env)

        @managed_keys
        |> Enum.flat_map(fn key ->
          [stash_export(key, current), live_export(key, prepared)]
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")
        |> IO.puts()

        0

      {:error, reason} ->
        print_error(reason)
    end
  end

  defp emit_off do
    @managed_keys
    |> Enum.map_join("\n", &restore_statement/1)
    |> IO.puts()

    0
  end

  defp check(opts) do
    workspace = Keyword.get(opts, :workspace, File.cwd!())

    case GitHubAuth.prepare(workspace, Keyword.get(opts, :auth_opts, [])) do
      {:ok, session} ->
        IO.puts("GitHub App authentication ready for #{session.repo} until #{DateTime.to_iso8601(session.expires_at)}")
        0

      {:error, reason} ->
        print_error(reason)
    end
  end

  defp run_gh(args, opts) do
    workspace = Keyword.get(opts, :workspace, File.cwd!())
    auth_opts = Keyword.get(opts, :auth_opts, [])

    with {:ok, token} <- GitHubAuth.token(workspace, auth_opts),
         {:ok, real_gh} <- real_gh() do
      {output, status} = execute_gh(real_gh, args, token.token)
      IO.binwrite(output)

      if status != 0 and auth_failure?(output) do
        retry_gh(real_gh, args, workspace, auth_opts)
      else
        status
      end
    else
      {:error, reason} -> print_error(reason)
    end
  end

  defp retry_gh(real_gh, args, workspace, auth_opts) do
    case GitHubAuth.token(workspace, Keyword.put(auth_opts, :force_refresh, true)) do
      {:ok, refreshed} ->
        {retry_output, retry_status} = execute_gh(real_gh, args, refreshed.token)
        IO.binwrite(retry_output)
        retry_status

      {:error, reason} ->
        print_error(reason)
    end
  end

  defp real_gh do
    case System.get_env("SYMPHONY_REAL_GH") do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, :symphony_real_gh_missing}
    end
  end

  defp execute_gh(real_gh, args, token) do
    env = [
      {"GH_TOKEN", token},
      {"GITHUB_TOKEN", token}
    ]

    System.cmd(real_gh, args, cd: File.cwd!(), env: env, stderr_to_stdout: true)
  rescue
    error in ErlangError -> {"Failed to execute gh: #{inspect(error.original)}\n", 1}
  end

  defp auth_failure?(output) do
    normalized = String.downcase(output)

    Enum.any?(
      ["bad credentials", "http 401", "requires authentication", "token has expired", "authentication failed"],
      &String.contains?(normalized, &1)
    )
  end

  defp stash_export(key, current) do
    stash = stash_key(key)

    value =
      cond do
        Map.has_key?(current, stash) -> current[stash]
        not Map.has_key?(current, key) -> @unset_sentinel
        current[key] == "" -> @empty_sentinel
        true -> current[key]
      end

    "export #{stash}=#{shell_quote(value)}"
  end

  defp live_export(key, prepared) do
    case Map.fetch(prepared, key) do
      {:ok, false} -> "unset #{key}"
      {:ok, value} -> "export #{key}=#{shell_quote(value)}"
      :error -> "unset #{key}"
    end
  end

  defp restore_statement(key) do
    stash = stash_key(key)

    "if [ \"${#{stash}+x}\" = x ]; then " <>
      "case \"${#{stash}}\" in " <>
      "#{@unset_sentinel}) unset #{key} ;; " <>
      "#{@empty_sentinel}) export #{key}=\"\" ;; " <>
      "*) export #{key}=\"${#{stash}}\" ;; esac; unset #{stash}; fi"
  end

  defp stash_key(key), do: @stash_prefix <> key

  defp shell_quote(value), do: "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"

  defp print_error(reason) do
    IO.puts(:stderr, "GitHub App authentication failed: #{inspect(reason)}")
    1
  end

  defp usage do
    IO.puts(:stderr, "Usage: symphony github-auth <on|off|check|gh [arguments...]>")
    2
  end
end
