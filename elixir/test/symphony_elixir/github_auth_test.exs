defmodule SymphonyElixir.GitHubAuthTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureIO

  alias SymphonyElixir.GitHubAuth
  alias SymphonyElixir.GitHubAuth.CLI
  alias SymphonyElixir.GitHubAuth.Local

  defmodule ControlledProvider do
    @behaviour SymphonyElixir.GitHubAuth

    @impl true
    def prepare(_workspace, _opts), do: Process.get(:github_auth_prepare_result)

    @impl true
    def token(_workspace, _opts), do: Process.get(:github_auth_token_result)
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-github-auth-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    System.cmd("git", ["-C", workspace, "init", "--quiet"])
    System.cmd("git", ["-C", workspace, "remote", "add", "origin", "git@github.com:Acme/widgets.git"])

    cli_path = executable!(root, "symphony", "#!/bin/sh\nexit 0\n")
    real_gh = executable!(root, "gh", "#!/bin/sh\nexit 0\n")

    private_key = :public_key.generate_key({:rsa, 1024, 65_537})
    pem_entry = :public_key.pem_entry_encode(:RSAPrivateKey, private_key)
    pem = :public_key.pem_encode([pem_entry])

    env = %{
      "GITHUB_APP_ID" => "12345",
      "GITHUB_APP_PRIVATE_KEY" => pem,
      "PATH" => System.get_env("PATH", "")
    }

    on_exit(fn -> File.rm_rf(root) end)

    %{workspace: workspace, cli_path: cli_path, real_gh: real_gh, env: env}
  end

  test "parses supported GitHub remote forms" do
    assert {:ok, "Acme/widgets"} =
             Local.parse_repository("git@github.com:Acme/widgets.git")

    assert {:ok, "Acme/widgets"} =
             Local.parse_repository("https://github.com/Acme/widgets.git")

    assert {:ok, "Acme/widgets"} =
             Local.parse_repository("ssh://git@github.com/Acme/widgets.git")

    assert {:error, {:unsupported_github_remote, _url}} =
             Local.parse_repository("git@gitlab.com:Acme/widgets.git")
  end

  test "preflights auth, writes a token-free session, and reuses the cache", context do
    test_pid = self()

    request = fn request ->
      send(test_pid, {:github_request, request})

      case request.method do
        :get -> {:ok, %{status: 200, body: %{"id" => 987}}}
        :post -> {:ok, %{status: 201, body: token_response()}}
      end
    end

    opts = auth_opts(context, request)

    assert {:ok, session} = Local.prepare(context.workspace, opts)
    assert session.repo == "Acme/widgets"
    assert session.host == "github.com"

    env = Map.new(session.env)
    assert env["SYMPHONY_GITHUB_AUTH"] == "1"
    assert env["SYMPHONY_GITHUB_REPOSITORY"] == "Acme/widgets"
    assert env["SYMPHONY_REAL_GH"] == context.real_gh
    assert env["GH_TOKEN"] == false
    assert env["GITHUB_TOKEN"] == false

    assert_received {:github_request, %{method: :get, headers: headers}}
    assert_received {:github_request, %{method: :post}}
    assert jwt_payload(headers)["iss"] == "12345"

    auth_root = Path.join(context.workspace, ".artifacts/github-app-auth")
    session_path = Path.join(auth_root, "session.env")
    cache_path = Path.join(auth_root, "installation-token.json")
    shim_path = Path.join([auth_root, "shims", "gh"])

    session_contents = File.read!(session_path)
    refute session_contents =~ "secret-installation-token"
    assert session_contents =~ "unset GH_TOKEN"
    assert session_contents =~ "unset GITHUB_TOKEN"
    assert session_contents =~ "SYMPHONY_GITHUB_AUTH"
    assert File.read!(shim_path) =~ context.cli_path
    assert private_mode(session_path) == 0o600
    assert private_mode(cache_path) == 0o600
    assert private_mode(shim_path) == 0o700

    {ignored, 0} =
      System.cmd("git", ["-C", context.workspace, "check-ignore", ".artifacts/github-app-auth/session.env"])

    assert String.trim(ignored) == ".artifacts/github-app-auth/session.env"

    assert {:ok, _cached_session} =
             Local.prepare(
               context.workspace,
               Keyword.put(opts, :request, fn _request -> flunk("valid token cache should be reused") end)
             )
  end

  test "anchors interactive auth artifacts at the Git toplevel", context do
    nested = Path.join(context.workspace, "elixir")
    File.mkdir_p!(nested)

    request = fn
      %{method: :get} -> {:ok, %{status: 200, body: %{"id" => 987}}}
      %{method: :post} -> {:ok, %{status: 201, body: token_response()}}
    end

    assert {:ok, session} = Local.prepare(nested, auth_opts(context, request))

    assert session.auth_root ==
             Path.join(context.workspace, ".artifacts/github-app-auth")

    refute File.exists?(Path.join(nested, ".artifacts"))
  end

  test "force refresh replaces a still-valid cached installation token", context do
    counter = start_supervised!({Agent, fn -> 0 end})

    request = fn request ->
      Agent.update(counter, &(&1 + 1))

      case request.method do
        :get -> {:ok, %{status: 200, body: %{"id" => 987}}}
        :post -> {:ok, %{status: 201, body: token_response()}}
      end
    end

    opts = auth_opts(context, request)
    assert {:ok, _token} = Local.token(context.workspace, opts)
    assert Agent.get(counter, & &1) == 2

    assert {:ok, _token} =
             Local.token(context.workspace, Keyword.put(opts, :force_refresh, true))

    assert Agent.get(counter, & &1) == 4
  end

  test "missing App credentials fail with a typed configuration error", context do
    assert {:error, {:missing_github_app_credential, "GITHUB_APP_ID"}} =
             Local.prepare(
               context.workspace,
               cli_path: context.cli_path,
               real_gh: context.real_gh,
               env: %{}
             )
  end

  test "remote workers fail before reading local credentials", context do
    assert {:error, {:github_auth_remote_worker_unsupported, "builder.example"}} =
             Local.prepare(context.workspace, worker_host: "builder.example")

    assert {:error, {:github_auth_remote_worker_unsupported, "builder.example"}} =
             Local.token(context.workspace, worker_host: "builder.example")
  end

  test "private-key files and pinned installation ids avoid the installation lookup", context do
    key_path = Path.join(context.workspace, "app-key.pem")
    File.write!(key_path, context.env["GITHUB_APP_PRIVATE_KEY"])

    env = %{
      "GITHUB_APP_ID" => "12345",
      "GITHUB_APP_PRIVATE_KEY_FILE" => "app-key.pem",
      "GITHUB_APP_INSTALLATION_ID" => "987",
      "UDP_AGENT_COMMIT_NAME" => "Automation Bot",
      "UDP_AGENT_COMMIT_EMAIL" => "bot@example.com",
      "PATH" => System.get_env("PATH", "")
    }

    request = fn
      %{method: :post} -> {:ok, %{status: 201, body: token_response()}}
      %{method: :get} -> flunk("pinned installation id should skip lookup")
    end

    assert {:ok, session} =
             Local.prepare(
               context.workspace,
               env: env,
               request: request,
               now: fn -> ~U[2026-08-12 16:00:00Z] end,
               cli_path: context.cli_path,
               real_gh: context.real_gh
             )

    prepared_env = Map.new(session.env)
    assert prepared_env["GIT_AUTHOR_NAME"] == "Automation Bot"
    assert prepared_env["GIT_COMMITTER_EMAIL"] == "bot@example.com"
  end

  test "invalid keys and installation ids fail before an API request", context do
    base_opts = [cli_path: context.cli_path, real_gh: context.real_gh]

    assert {:error, :github_app_private_key_invalid} =
             Local.prepare(
               context.workspace,
               Keyword.put(base_opts, :env, %{
                 "GITHUB_APP_ID" => "12345",
                 "GITHUB_APP_PRIVATE_KEY" => "not a PEM"
               })
             )

    assert {:error, {:invalid_github_app_installation_id, _message}} =
             Local.prepare(
               context.workspace,
               Keyword.put(base_opts, :env, Map.put(context.env, "GITHUB_APP_INSTALLATION_ID", "zero"))
             )
  end

  test "GitHub API failures retain their operation and status", context do
    opts =
      auth_opts(context, fn _request ->
        {:ok, %{status: 403, body: %{"message" => "App is not installed"}}}
      end)

    assert {:error, {:github_api_error, :resolve_installation, 403, "App is not installed"}} =
             Local.prepare(context.workspace, opts)
  end

  test "interactive off restores every managed value without reading credentials" do
    output = capture_io(fn -> assert CLI.run(["off"]) == 0 end)

    assert output =~ "SYMPHONY_GITHUB_PREV_PATH"
    assert output =~ ~S(if [ "${SYMPHONY_GITHUB_PREV_PATH+x}" = x ])
    assert output =~ "unset SYMPHONY_GITHUB_AUTH"
    assert output =~ "unset UDP_BOT_MODE"
  end

  test "provider facade normalizes environments and preserves typed failures", context do
    Application.put_env(:symphony_elixir, :github_auth_provider, ControlledProvider)

    Process.put(
      :github_auth_prepare_result,
      session(context.workspace, [{"PATH", "/auth/bin"}, {"GH_TOKEN", false}])
    )

    Process.put(:github_auth_token_result, {:ok, token()})

    assert {:ok, %{repo: "Acme/widgets"}} = GitHubAuth.prepare(context.workspace)

    assert {:ok, [{~c"PATH", ~c"/auth/bin"}, {~c"GH_TOKEN", false}]} =
             GitHubAuth.port_env(context.workspace)

    assert {:ok, %{token: "test-installation-token"}} = GitHubAuth.token(context.workspace)

    Process.put(:github_auth_prepare_result, {:error, {:github_auth_failed, :already_typed}})
    assert {:error, {:github_auth_failed, :already_typed}} = GitHubAuth.prepare(context.workspace, [])

    Process.put(:github_auth_prepare_result, {:error, :untyped_prepare})
    assert {:error, {:github_auth_failed, :untyped_prepare}} = GitHubAuth.prepare(context.workspace, [])

    Process.put(:github_auth_token_result, {:error, {:github_auth_failed, :already_typed}})
    assert {:error, {:github_auth_failed, :already_typed}} = GitHubAuth.token(context.workspace, [])

    Process.put(:github_auth_token_result, {:error, :untyped_token})
    assert {:error, {:github_auth_failed, :untyped_token}} = GitHubAuth.token(context.workspace, [])
  end

  test "interactive activation and check reuse the configured provider", context do
    Application.put_env(:symphony_elixir, :github_auth_provider, ControlledProvider)

    Process.put(
      :github_auth_prepare_result,
      session(context.workspace, [
        {"PATH", "/auth/bin"},
        {"GH_TOKEN", false},
        {"GITHUB_TOKEN", false},
        {"SYMPHONY_GITHUB_AUTH", "1"},
        {"SYMPHONY_GITHUB_REPOSITORY", "Acme/widgets"}
      ])
    )

    on_output = capture_io(fn -> assert CLI.run(["on"], workspace: context.workspace) == 0 end)
    assert on_output =~ "export PATH='/auth/bin'"
    assert on_output =~ "unset GH_TOKEN"
    assert on_output =~ "unset GITHUB_TOKEN"
    assert on_output =~ "export SYMPHONY_GITHUB_AUTH='1'"
    assert on_output =~ "SYMPHONY_GITHUB_PREV_PATH"

    check_output = capture_io(fn -> assert CLI.run(["check"], workspace: context.workspace) == 0 end)
    assert check_output =~ "GitHub App authentication ready for Acme/widgets"
    refute check_output =~ "test-installation-token"
  end

  test "interactive gh refreshes once after an authentication failure", context do
    Application.put_env(:symphony_elixir, :github_auth_provider, ControlledProvider)
    Process.put(:github_auth_token_result, {:ok, token()})

    counter = Path.join(Path.dirname(context.real_gh), "gh-invoked")

    real_gh =
      executable!(
        Path.dirname(context.real_gh),
        "retry-gh",
        "#!/bin/sh\nif [ ! -f '#{counter}' ]; then touch '#{counter}'; echo 'Bad credentials'; exit 1; fi\necho \"refreshed: $*\"\n"
      )

    previous_real_gh = System.get_env("SYMPHONY_REAL_GH")
    System.put_env("SYMPHONY_REAL_GH", real_gh)
    on_exit(fn -> restore_env("SYMPHONY_REAL_GH", previous_real_gh) end)

    output =
      capture_io(fn ->
        assert CLI.run(["gh", "auth", "status"], workspace: context.workspace) == 0
      end)

    assert output =~ "Bad credentials"
    assert output =~ "refreshed: auth status"
  end

  test "interactive commands report provider, executable, and usage errors", context do
    Application.put_env(:symphony_elixir, :github_auth_provider, ControlledProvider)
    Process.put(:github_auth_prepare_result, {:error, :credential_error})
    Process.put(:github_auth_token_result, {:ok, token()})

    assert capture_io(:stderr, fn ->
             assert CLI.run(["on"], workspace: context.workspace) == 1
           end) =~ "credential_error"

    assert capture_io(:stderr, fn ->
             assert CLI.run(["check"], workspace: context.workspace) == 1
           end) =~ "credential_error"

    previous_real_gh = System.get_env("SYMPHONY_REAL_GH")
    System.delete_env("SYMPHONY_REAL_GH")
    on_exit(fn -> restore_env("SYMPHONY_REAL_GH", previous_real_gh) end)

    assert capture_io(:stderr, fn ->
             assert CLI.run(["gh", "auth", "status"], workspace: context.workspace) == 1
           end) =~ "symphony_real_gh_missing"

    assert capture_io(:stderr, fn -> assert CLI.run(["unknown"]) == 2 end) =~
             "Usage: symphony github-auth"
  end

  defp auth_opts(context, request) do
    [
      cli_path: context.cli_path,
      real_gh: context.real_gh,
      env: context.env,
      request: request,
      now: fn -> ~U[2026-08-12 16:00:00Z] end
    ]
  end

  defp token_response do
    %{
      "token" => "secret-installation-token",
      "expires_at" => "2026-08-12T18:00:00Z"
    }
  end

  defp session(workspace, env) do
    {:ok,
     %{
       env: env,
       repo: "Acme/widgets",
       host: "github.com",
       auth_root: Path.join(workspace, ".artifacts/github-app-auth"),
       expires_at: ~U[2026-08-12 18:00:00Z]
     }}
  end

  defp token do
    %{
      token: "test-installation-token",
      repo: "Acme/widgets",
      host: "github.com",
      installation_id: 987,
      expires_at: ~U[2026-08-12 18:00:00Z]
    }
  end

  defp jwt_payload(headers) do
    {"authorization", "Bearer " <> jwt} =
      Enum.find(headers, fn {name, _value} -> name == "authorization" end)

    [_header, payload, _signature] = String.split(jwt, ".")
    {:ok, decoded} = Base.url_decode64(payload, padding: false)
    Jason.decode!(decoded)
  end

  defp private_mode(path) do
    {:ok, %{mode: mode}} = File.stat(path)
    Bitwise.band(mode, 0o777)
  end

  defp executable!(root, name, body) do
    path = Path.join(root, name)
    File.write!(path, body)
    File.chmod!(path, 0o700)
    path
  end
end
