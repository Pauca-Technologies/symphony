defmodule SymphonyElixir.GitHubAuth.Local do
  @moduledoc false
  @behaviour SymphonyElixir.GitHubAuth

  @artifact_subdir ".artifacts/github-app-auth"
  @cache_filename "installation-token.json"
  @lock_dirname "token.lock"
  @session_filename "session.env"
  @refresh_skew_seconds 5 * 60
  @lock_timeout_ms 15_000
  @lock_poll_ms 150
  @stale_lock_seconds 60
  @github_api_version "2022-11-28"

  @type context :: %{
          workspace: Path.t(),
          host: String.t(),
          repo: String.t(),
          app_id: String.t(),
          private_key: term(),
          installation_id: pos_integer() | nil,
          env: map(),
          auth_root: Path.t(),
          gh_config_dir: Path.t(),
          shim_dir: Path.t(),
          cache_path: Path.t(),
          lock_dir: Path.t()
        }

  @impl true
  @spec prepare(Path.t(), keyword()) ::
          {:ok, SymphonyElixir.GitHubAuth.session()} | {:error, term()}
  def prepare(workspace, opts \\ []) when is_binary(workspace) and is_list(opts) do
    with :ok <- ensure_local(Keyword.get(opts, :worker_host)),
         {:ok, context} <- build_context(workspace, opts),
         :ok <- ensure_auth_directories(context),
         {:ok, token} <- resolve_token(context, opts),
         {:ok, real_gh} <- resolve_real_gh(context, opts),
         {:ok, cli_path} <- resolve_cli_path(opts),
         env <- session_env(context, real_gh),
         :ok <- write_gh_shim(context, cli_path),
         :ok <- write_compatibility_env(context, env),
         :ok <- exclude_auth_artifacts(context.workspace) do
      {:ok,
       %{
         env: Map.to_list(env),
         repo: context.repo,
         host: context.host,
         auth_root: context.auth_root,
         expires_at: token.expires_at
       }}
    end
  end

  @impl true
  @spec token(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def token(workspace, opts \\ []) when is_binary(workspace) and is_list(opts) do
    with :ok <- ensure_local(Keyword.get(opts, :worker_host)),
         {:ok, context} <- build_context(workspace, opts),
         :ok <- ensure_auth_directories(context) do
      resolve_token(context, opts)
    end
  end

  @doc false
  @spec parse_repository(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def parse_repository(url, host \\ "github.com") when is_binary(url) and is_binary(host) do
    escaped_host = Regex.escape(host)

    patterns = [
      ~r/^git@#{escaped_host}:(?<repo>[^\s]+?)\/?(?:\.git)?$/i,
      ~r{^https?://#{escaped_host}/(?<repo>[^\s]+?)/?(?:\.git)?$}i,
      ~r{^ssh://(?:git@)?#{escaped_host}/(?<repo>[^\s]+?)/?(?:\.git)?$}i
    ]

    case Enum.find_value(patterns, &repository_capture(&1, String.trim(url))) do
      nil -> {:error, {:unsupported_github_remote, redact_remote(url)}}
      repo -> validate_repository(repo)
    end
  end

  defp repository_capture(pattern, url) do
    case Regex.named_captures(pattern, url) do
      %{"repo" => repo} -> String.trim_trailing(repo, ".git")
      _ -> nil
    end
  end

  defp validate_repository(repo) do
    case String.split(repo, "/", trim: true) do
      [owner, name] when owner != "" and name != "" -> {:ok, owner <> "/" <> name}
      _ -> {:error, {:invalid_github_repository, repo}}
    end
  end

  defp redact_remote(url) do
    case URI.parse(url) do
      %URI{userinfo: userinfo} = uri when is_binary(userinfo) ->
        %{uri | userinfo: "[redacted]"} |> URI.to_string()

      _ ->
        url
    end
  end

  defp ensure_local(nil), do: :ok
  defp ensure_local(worker_host), do: {:error, {:github_auth_remote_worker_unsupported, worker_host}}

  defp build_context(workspace, opts) do
    env = Keyword.get(opts, :env, System.get_env())
    host = option_or_env(opts, :host, env, ["GH_HOST", "GITHUB_HOST"], "github.com")
    command = Keyword.get(opts, :command, &System.cmd/3)

    with {:ok, workspace_root} <- resolve_workspace_root(workspace, command),
         {:ok, repo} <- resolve_repository(workspace_root, host, env, opts),
         {:ok, app_id} <- required_env(env, "GITHUB_APP_ID"),
         {:ok, private_key} <- read_private_key(workspace_root, env),
         {:ok, installation_id} <- optional_positive_integer(env["GITHUB_APP_INSTALLATION_ID"]) do
      auth_root = Path.join(workspace_root, @artifact_subdir)

      {:ok,
       %{
         workspace: workspace_root,
         host: host,
         repo: repo,
         app_id: app_id,
         private_key: private_key,
         installation_id: installation_id,
         env: env,
         auth_root: auth_root,
         gh_config_dir: Path.join(auth_root, "gh-config"),
         shim_dir: Path.join(auth_root, "shims"),
         cache_path: Path.join(auth_root, @cache_filename),
         lock_dir: Path.join(auth_root, @lock_dirname)
       }}
    end
  end

  defp option_or_env(opts, option, env, names, default) do
    Keyword.get(opts, option) || Enum.find_value(names, &non_blank(env[&1])) || default
  end

  defp resolve_workspace_root(workspace, command) do
    case command.("git", ["-C", workspace, "rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {root, 0} -> {:ok, root |> String.trim() |> Path.expand()}
      {_output, status} -> {:error, {:github_repository_root_unresolved, status}}
    end
  rescue
    error in ErlangError -> {:error, {:github_repository_root_unresolved, error.original}}
  end

  defp resolve_repository(workspace, host, env, opts) do
    cond do
      repo = non_blank(Keyword.get(opts, :repo)) -> validate_repository(repo)
      repo = non_blank(env["SYMPHONY_GITHUB_REPOSITORY"]) -> validate_repository(repo)
      repo = non_blank(env["GITHUB_REPOSITORY"]) -> validate_repository(repo)
      url = non_blank(Keyword.get(opts, :repo_url)) -> parse_repository(url, host)
      true -> repository_from_remote(workspace, host, Keyword.get(opts, :command, &System.cmd/3))
    end
  end

  defp repository_from_remote(workspace, host, command) do
    case command.("git", ["-C", workspace, "remote", "get-url", "origin"], stderr_to_stdout: true) do
      {url, 0} -> parse_repository(String.trim(url), host)
      {_output, status} -> {:error, {:github_repository_unresolved, status}}
    end
  rescue
    error in ErlangError -> {:error, {:github_repository_unresolved, error.original}}
  end

  defp required_env(env, name) do
    case non_blank(env[name]) do
      nil -> {:error, {:missing_github_app_credential, name}}
      value -> {:ok, value}
    end
  end

  defp read_private_key(workspace, env) do
    cond do
      value = non_blank(env["GITHUB_APP_PRIVATE_KEY"]) -> decode_private_key(value)
      path = non_blank(env["GITHUB_APP_PRIVATE_KEY_FILE"]) -> read_private_key_file(workspace, path)
      true -> {:error, {:missing_github_app_credential, "GITHUB_APP_PRIVATE_KEY_FILE or GITHUB_APP_PRIVATE_KEY"}}
    end
  end

  defp read_private_key_file(workspace, path) do
    expanded = Path.expand(path, workspace)

    case File.read(expanded) do
      {:ok, pem} -> decode_private_key(pem)
      {:error, reason} -> {:error, {:github_app_private_key_unreadable, expanded, reason}}
    end
  end

  defp decode_private_key(pem) do
    normalized_pem = String.replace(pem, "\\n", "\n")

    case :public_key.pem_decode(normalized_pem) do
      [entry | _rest] -> {:ok, :public_key.pem_entry_decode(entry)}
      [] -> {:error, :github_app_private_key_invalid}
    end
  rescue
    _error -> {:error, :github_app_private_key_invalid}
  end

  defp optional_positive_integer(nil), do: {:ok, nil}
  defp optional_positive_integer(""), do: {:ok, nil}

  defp optional_positive_integer(value) do
    case Integer.parse(to_string(value)) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, {:invalid_github_app_installation_id, "must be a positive integer"}}
    end
  end

  defp ensure_auth_directories(context) do
    with :ok <- File.mkdir_p(context.gh_config_dir),
         :ok <- File.mkdir_p(context.shim_dir),
         :ok <- File.chmod(context.auth_root, 0o700),
         :ok <- File.chmod(context.gh_config_dir, 0o700),
         :ok <- File.chmod(context.shim_dir, 0o700) do
      :ok
    else
      {:error, reason} -> {:error, {:github_auth_artifact_failed, reason}}
    end
  end

  defp resolve_token(context, opts) do
    now = now(opts)

    if Keyword.get(opts, :force_refresh, false) do
      refresh_token_under_lock(context, opts, true)
    else
      case read_cached_token(context.cache_path, context, now) do
        {:ok, token} -> {:ok, token}
        :miss -> refresh_token_under_lock(context, opts, false)
      end
    end
  end

  defp refresh_token_under_lock(context, opts, force_refresh?) do
    with :ok <- acquire_lock(context.lock_dir, opts) do
      try do
        if force_refresh? do
          mint_and_cache_token(context, opts)
        else
          case read_cached_token(context.cache_path, context, now(opts)) do
            {:ok, token} -> {:ok, token}
            :miss -> mint_and_cache_token(context, opts)
          end
        end
      after
        _ = File.rm_rf(context.lock_dir)
      end
    end
  end

  defp acquire_lock(lock_dir, opts) do
    monotonic_ms = Keyword.get(opts, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end)
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    deadline = monotonic_ms.() + @lock_timeout_ms
    do_acquire_lock(lock_dir, deadline, monotonic_ms, sleep)
  end

  defp do_acquire_lock(lock_dir, deadline, monotonic_ms, sleep) do
    case File.mkdir(lock_dir) do
      :ok ->
        :ok

      {:error, :eexist} ->
        maybe_remove_stale_lock(lock_dir)

        if monotonic_ms.() < deadline do
          sleep.(@lock_poll_ms)
          do_acquire_lock(lock_dir, deadline, monotonic_ms, sleep)
        else
          {:error, {:github_auth_token_lock_timeout, lock_dir}}
        end

      {:error, reason} ->
        {:error, {:github_auth_token_lock_failed, reason}}
    end
  end

  defp maybe_remove_stale_lock(lock_dir) do
    case File.stat(lock_dir, time: :posix) do
      {:ok, %{mtime: mtime}} when is_integer(mtime) ->
        if System.os_time(:second) - mtime > @stale_lock_seconds, do: File.rm_rf(lock_dir)

      _ ->
        :ok
    end
  end

  defp read_cached_token(path, context, now) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, token} <- normalize_token(decoded),
         true <- token.host == context.host,
         true <- token.repo == context.repo,
         true <- DateTime.diff(token.expires_at, now, :second) > @refresh_skew_seconds do
      {:ok, token}
    else
      _ -> :miss
    end
  end

  defp normalize_token(%{
         "token" => token,
         "expiresAt" => expires_at,
         "host" => host,
         "repo" => repo,
         "installationId" => installation_id
       })
       when is_binary(token) and is_binary(expires_at) and is_binary(host) and is_binary(repo) and
              is_integer(installation_id) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, datetime, _offset} ->
        {:ok,
         %{
           token: token,
           expires_at: datetime,
           host: host,
           repo: repo,
           installation_id: installation_id
         }}

      _ ->
        {:error, :invalid_expiration}
    end
  end

  defp normalize_token(_value), do: {:error, :invalid_cache}

  defp mint_and_cache_token(context, opts) do
    with {:ok, jwt} <- create_app_jwt(context, now(opts)),
         {:ok, installation_id} <- resolve_installation_id(context, jwt, opts),
         {:ok, token} <- request_installation_token(context, jwt, installation_id, opts),
         :ok <- write_token_cache(context.cache_path, token) do
      {:ok, token}
    end
  end

  defp create_app_jwt(context, now) do
    issued_at = DateTime.to_unix(now) - 60

    header = base64url(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT"}))
    payload = base64url(Jason.encode!(%{"exp" => issued_at + 9 * 60, "iat" => issued_at, "iss" => context.app_id}))
    signing_input = header <> "." <> payload

    signature = :public_key.sign(signing_input, :sha256, context.private_key)
    {:ok, signing_input <> "." <> base64url(signature)}
  rescue
    _error -> {:error, :github_app_jwt_signing_failed}
  end

  defp base64url(value), do: Base.url_encode64(value, padding: false)

  defp resolve_installation_id(%{installation_id: id}, _jwt, _opts) when is_integer(id), do: {:ok, id}

  defp resolve_installation_id(context, jwt, opts) do
    url = api_base_url(context.host) <> "/repos/" <> encode_repo(context.repo) <> "/installation"

    with {:ok, body} <- github_request(:get, url, jwt, nil, :resolve_installation, opts),
         id when is_integer(id) and id > 0 <- body_value(body, "id") do
      {:ok, id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_installation_lookup_missing_id}
    end
  end

  defp request_installation_token(context, jwt, installation_id, opts) do
    url = api_base_url(context.host) <> "/app/installations/#{installation_id}/access_tokens"

    with {:ok, body} <- github_request(:post, url, jwt, %{}, :mint_installation_token, opts),
         token when is_binary(token) and token != "" <- body_value(body, "token"),
         expires_at when is_binary(expires_at) <- body_value(body, "expires_at"),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(expires_at) do
      {:ok,
       %{
         token: token,
         expires_at: datetime,
         host: context.host,
         repo: context.repo,
         installation_id: installation_id
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_installation_token_invalid_response}
    end
  end

  defp github_request(method, url, jwt, json, operation, opts) do
    request = Keyword.get(opts, :request, &default_request/1)

    request_opts = %{
      method: method,
      url: url,
      headers: [
        {"accept", "application/vnd.github+json"},
        {"authorization", "Bearer " <> jwt},
        {"user-agent", "symphony-github-app-auth"},
        {"x-github-api-version", @github_api_version}
      ],
      json: json
    }

    case request.(request_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:github_api_error, operation, status, api_message(body)}}
      {:error, reason} -> {:error, {:github_api_unavailable, operation, reason}}
    end
  end

  defp default_request(%{method: method, url: url, headers: headers, json: json}) do
    options = [method: method, url: url, headers: headers, receive_timeout: 30_000]
    options = if is_nil(json), do: options, else: Keyword.put(options, :json, json)
    Req.request(options)
  end

  defp api_message(body) when is_map(body) do
    body_value(body, "message") |> to_string() |> String.slice(0, 500)
  end

  defp api_message(_body), do: "GitHub API request failed"

  defp body_value(body, key) when is_map(body), do: Map.get(body, key) || Map.get(body, String.to_atom(key))

  defp api_base_url("github.com"), do: "https://api.github.com"
  defp api_base_url(host), do: "https://#{host}/api/v3"

  defp encode_repo(repo) do
    repo
    |> String.split("/", parts: 2)
    |> Enum.map_join("/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)
  end

  defp write_token_cache(path, token) do
    payload = %{
      "token" => token.token,
      "expiresAt" => DateTime.to_iso8601(token.expires_at),
      "host" => token.host,
      "repo" => token.repo,
      "installationId" => token.installation_id
    }

    write_private_file(path, Jason.encode!(payload, pretty: true) <> "\n", overwrite: true)
  end

  defp resolve_real_gh(context, opts) do
    candidates = [Keyword.get(opts, :real_gh), System.get_env("SYMPHONY_REAL_GH")]

    case Enum.find(candidates, &executable_file?/1) || find_real_gh(context.shim_dir) do
      nil -> {:error, :github_cli_not_found}
      path -> {:ok, Path.expand(path)}
    end
  end

  defp find_real_gh(shim_dir) do
    System.get_env("PATH", "")
    |> String.split(path_separator(), trim: true)
    |> Enum.map(&Path.join(&1, "gh"))
    |> Enum.reject(fn path ->
      Path.expand(Path.dirname(path)) == Path.expand(shim_dir) or
        String.contains?(path, ["/scripts/github/shims/", "/.artifacts/github-app-auth/shims/"])
    end)
    |> Enum.find(&executable_file?/1)
  end

  defp executable_file?(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp executable_file?(_path), do: false

  defp resolve_cli_path(opts) do
    explicit = Keyword.get(opts, :cli_path) || System.get_env("SYMPHONY_GITHUB_AUTH_CLI")
    escript = :escript.script_name() |> to_string() |> non_blank()
    path = explicit || escript || System.find_executable("symphony")

    if executable_file?(path) do
      {:ok, Path.expand(path)}
    else
      {:error, :symphony_github_auth_cli_not_found}
    end
  end

  defp session_env(context, real_gh) do
    env = context.env
    shim_path = context.shim_dir <> path_separator() <> (env["PATH"] || "")

    %{
      "GH_CONFIG_DIR" => context.gh_config_dir,
      "GH_HOST" => context.host,
      "GH_PROMPT_DISABLED" => "1",
      "GH_TOKEN" => false,
      "GITHUB_ENTERPRISE_TOKEN" => false,
      "GITHUB_TOKEN" => false,
      "GH_ENTERPRISE_TOKEN" => false,
      "PATH" => shim_path,
      "SYMPHONY_GITHUB_AUTH" => "1",
      "SYMPHONY_GITHUB_AUTH_ROOT" => context.auth_root,
      "SYMPHONY_GITHUB_REPOSITORY" => context.repo,
      "SYMPHONY_REAL_GH" => real_gh,
      # Transitional compatibility for the existing UDP repositories. New
      # consumers should use the provider-neutral SYMPHONY_GITHUB_AUTH marker.
      "UDP_BOT_MODE" => "1"
    }
    |> maybe_put_commit_identity(env)
  end

  defp maybe_put_commit_identity(session_env, env) do
    name = non_blank(env["UDP_AGENT_COMMIT_NAME"])
    email = non_blank(env["UDP_AGENT_COMMIT_EMAIL"])

    if name && email do
      Map.merge(session_env, %{
        "GIT_AUTHOR_NAME" => name,
        "GIT_AUTHOR_EMAIL" => email,
        "GIT_COMMITTER_NAME" => name,
        "GIT_COMMITTER_EMAIL" => email
      })
    else
      session_env
    end
  end

  defp write_gh_shim(context, cli_path) do
    path = Path.join(context.shim_dir, "gh")
    body = "#!/bin/sh\nexec #{shell_quote(cli_path)} github-auth gh \"$@\"\n"

    case write_private_file(path, body, overwrite: true) do
      :ok -> File.chmod(path, 0o700)
      {:error, _reason} = error -> error
    end
  end

  # Existing deployments may still have `agent.pre_command` source this file.
  # Create it only when absent so a repository's own transitional before_run
  # hook can replace/extend it (for example with browser-runtime variables).
  defp write_compatibility_env(context, env) do
    path = Path.join(context.auth_root, @session_filename)
    write_private_file(path, render_shell_exports(env), overwrite: false)
  end

  defp write_private_file(path, contents, opts) do
    overwrite? = Keyword.fetch!(opts, :overwrite)

    if not overwrite? and File.regular?(path) do
      File.chmod(path, 0o600)
    else
      temporary = path <> ".tmp.#{System.unique_integer([:positive])}"

      with :ok <- File.write(temporary, contents),
           :ok <- File.chmod(temporary, 0o600),
           :ok <- File.rename(temporary, path) do
        :ok
      else
        {:error, reason} ->
          _ = File.rm(temporary)
          {:error, {:github_auth_artifact_failed, path, reason}}
      end
    end
  end

  defp render_shell_exports(env) do
    env
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join("\n", fn
      {name, false} -> "unset #{name}"
      {name, value} -> "export #{name}=#{shell_quote(value)}"
    end)
    |> Kernel.<>("\n")
  end

  defp shell_quote(value), do: "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"

  defp exclude_auth_artifacts(workspace) do
    case System.cmd("git", ["-C", workspace, "rev-parse", "--git-path", "info/exclude"], stderr_to_stdout: true) do
      {path, 0} -> ensure_exclude_rule(workspace, String.trim(path))
      {_output, _status} -> :ok
    end
  end

  defp ensure_exclude_rule(workspace, path) do
    expanded = if Path.type(path) == :absolute, do: path, else: Path.expand(path, workspace)
    rule = "/.artifacts/"

    existing =
      case File.read(expanded) do
        {:ok, body} -> body
        _ -> ""
      end

    if existing |> String.split("\n") |> Enum.any?(&(String.trim(&1) == rule)) do
      :ok
    else
      with :ok <- File.mkdir_p(Path.dirname(expanded)),
           :ok <- File.write(expanded, existing <> exclude_separator(existing) <> rule <> "\n") do
        :ok
      else
        {:error, reason} -> {:error, {:github_auth_git_exclude_failed, reason}}
      end
    end
  end

  defp exclude_separator(""), do: ""
  defp exclude_separator(existing), do: if(String.ends_with?(existing, "\n"), do: "", else: "\n")

  defp now(opts) do
    opts
    |> Keyword.get(:now, &DateTime.utc_now/0)
    |> then(fn clock -> clock.() |> DateTime.truncate(:second) end)
  end

  defp path_separator do
    case :os.type() do
      {:win32, _name} -> ";"
      _ -> ":"
    end
  end

  defp non_blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp non_blank(_value), do: nil
end
