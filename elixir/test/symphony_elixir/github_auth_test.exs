defmodule SymphonyElixir.GitHubAuthTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHubAuth
  alias SymphonyElixir.GitHubAuth.External

  defmodule ControlledProvider do
    @behaviour SymphonyElixir.GitHubAuth

    @impl true
    def prepare(_workspace, _opts), do: Process.get(:github_auth_prepare_result)
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-external-github-auth-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)

    %{root: root, workspace: workspace}
  end

  test "decodes udp-gh's typed machine contract", context do
    executable = fake_udp_gh!(context.root, valid_contract(context.workspace))

    assert {:ok, session} = External.prepare(context.workspace, executable: executable)
    assert session.repo == "Acme/widgets"
    assert session.host == "github.com"
    assert session.auth_root == Path.join(context.workspace, ".artifacts/udp-gh")
    assert session.expires_at == ~U[2099-01-01 00:00:00Z]

    env = Map.new(session.env)
    assert env["UDP_GH_AUTH"] == "1"
    assert env["SYMPHONY_GITHUB_AUTH"] == "1"
    assert env["SYMPHONY_GITHUB_REPOSITORY"] == "Acme/widgets"
    assert env["SYMPHONY_REAL_GH"] == "/usr/bin/gh"
    assert env["GH_TOKEN"] == false
    assert env["GITHUB_TOKEN"] == false
  end

  test "passes workspace as an argument without shell interpolation", context do
    workspace = Path.join(context.root, "workspace with spaces; untouched")
    File.mkdir_p!(workspace)
    contract = valid_contract(workspace)

    command = fn executable, args, opts ->
      send(self(), {:udp_gh_command, executable, args, opts})
      {Jason.encode!(contract), 0}
    end

    assert {:ok, _session} =
             External.prepare(workspace,
               executable: fake_udp_gh!(context.root, contract),
               command: command
             )

    assert_received {:udp_gh_command, _executable, ["prepare", "--cwd", ^workspace], [stderr_to_stdout: true]}
  end

  test "discovers a configured or PATH-installed udp-gh executable", context do
    executable = fake_udp_gh!(context.root, valid_contract(context.workspace), "udp-gh")
    previous_cli = Application.get_env(:symphony_elixir, :udp_gh_cli)
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_application_env(:udp_gh_cli, previous_cli)
      restore_system_env("PATH", previous_path)
    end)

    Application.put_env(:symphony_elixir, :udp_gh_cli, executable)
    assert {:ok, %{repo: "Acme/widgets"}} = External.prepare(context.workspace)

    Application.delete_env(:symphony_elixir, :udp_gh_cli)
    System.put_env("PATH", context.root <> ":" <> (previous_path || ""))
    assert {:ok, %{repo: "Acme/widgets"}} = External.prepare(context.workspace)
  end

  test "reports failure when default executable discovery finds no udp-gh", context do
    previous_cli = Application.get_env(:symphony_elixir, :udp_gh_cli)
    previous_path = System.get_env("PATH")
    original_cwd = File.cwd!()

    on_exit(fn ->
      File.cd!(original_cwd)
      restore_application_env(:udp_gh_cli, previous_cli)
      restore_system_env("PATH", previous_path)
    end)

    Application.delete_env(:symphony_elixir, :udp_gh_cli)
    System.put_env("PATH", context.root)
    File.cd!(context.root)

    assert {:error, :udp_gh_cli_not_found} = External.prepare(context.workspace)
  end

  test "rejects malformed, conflicting, and unsupported contracts", context do
    base = valid_contract(context.workspace)

    cases = [
      %{},
      Map.put(base, "version", 2),
      Map.put(base, "set", nil),
      Map.put(base, "set", %{"BAD-NAME" => "value"}),
      Map.put(base, "set", %{"VALID_NAME" => 123}),
      Map.put(base, "unset", nil),
      Map.put(base, "unset", [123]),
      Map.put(base, "unset", ["GH_TOKEN", "GH_TOKEN"]),
      base |> Map.put("set", %{"GH_TOKEN" => "secret"}) |> Map.put("unset", ["GH_TOKEN"]),
      Map.put(base, "expiresAt", "not-a-date"),
      Map.put(base, "expiresAt", nil),
      Map.put(base, "repository", "")
    ]

    Enum.each(cases, fn contract ->
      executable = fake_udp_gh!(context.root, contract)

      assert {:error, {:udp_gh_invalid_contract, _reason}} =
               External.prepare(context.workspace, executable: executable)
    end)

    executable = fake_udp_gh!(context.root, base)

    assert {:error, {:udp_gh_invalid_contract, _reason}} =
             External.prepare(context.workspace,
               executable: executable,
               command: fn _executable, _args, _opts -> {"not json", 0} end
             )
  end

  test "accepts a contract without an optional real-gh path", context do
    contract = update_in(valid_contract(context.workspace), ["set"], &Map.delete(&1, "UDP_GH_REAL_GH"))
    executable = fake_udp_gh!(context.root, contract)

    assert {:ok, session} = External.prepare(context.workspace, executable: executable)
    refute Map.has_key?(Map.new(session.env), "SYMPHONY_REAL_GH")
  end

  test "preserves typed command and discovery failures", context do
    executable = fake_udp_gh!(context.root, valid_contract(context.workspace))

    assert {:error, {:udp_gh_prepare_failed, 7, "preflight failed\n"}} =
             External.prepare(context.workspace,
               executable: executable,
               command: fn _executable, _args, _opts -> {"preflight failed\n", 7} end
             )

    assert {:error, {:udp_gh_prepare_failed, 9, output}} =
             External.prepare(context.workspace,
               executable: executable,
               command: fn _executable, _args, _opts -> {String.duplicate("x", 3_000), 9} end
             )

    assert byte_size(output) < 2_100
    assert String.ends_with?(output, "... (truncated)")

    assert {:error, {:udp_gh_prepare_failed, :enoent}} =
             External.prepare(context.workspace,
               executable: executable,
               command: fn _executable, _args, _opts -> raise ErlangError, original: :enoent end
             )

    assert {:error, :udp_gh_cli_not_found} =
             External.prepare(context.workspace, executable: Path.join(context.root, "missing"))

    assert {:error, {:github_auth_remote_worker_unsupported, "worker-01"}} =
             External.prepare(context.workspace,
               executable: executable,
               worker_host: "worker-01"
             )
  end

  test "provider facade normalizes environments and failures", context do
    Application.put_env(:symphony_elixir, :github_auth_provider, ControlledProvider)

    Process.put(
      :github_auth_prepare_result,
      {:ok,
       %{
         env: [{"GH_TOKEN", false}, {"PATH", "/tmp/shims:/usr/bin"}],
         repo: "Acme/widgets",
         host: "github.com",
         auth_root: "/tmp/auth",
         expires_at: ~U[2099-01-01 00:00:00Z]
       }}
    )

    assert {:ok, %{repo: "Acme/widgets"}} = GitHubAuth.prepare(context.workspace)

    assert {:ok, [{~c"GH_TOKEN", false}, {~c"PATH", ~c"/tmp/shims:/usr/bin"}]} =
             GitHubAuth.port_env(context.workspace)

    Process.put(:github_auth_prepare_result, {:error, :untyped_prepare})
    assert {:error, {:github_auth_failed, :untyped_prepare}} = GitHubAuth.prepare(context.workspace)

    Process.put(:github_auth_prepare_result, {:error, {:github_auth_failed, :already_typed}})
    assert {:error, {:github_auth_failed, :already_typed}} = GitHubAuth.prepare(context.workspace)
  end

  defp valid_contract(workspace) do
    %{
      "version" => 1,
      "repository" => "Acme/widgets",
      "host" => "github.com",
      "authRoot" => Path.join(workspace, ".artifacts/udp-gh"),
      "expiresAt" => "2099-01-01T00:00:00Z",
      "installationId" => 987,
      "set" => %{
        "GH_CONFIG_DIR" => Path.join(workspace, ".artifacts/udp-gh/gh-config"),
        "PATH" => Path.join(workspace, ".artifacts/udp-gh/shims") <> ":/usr/bin",
        "UDP_GH_AUTH" => "1",
        "UDP_GH_REAL_GH" => "/usr/bin/gh"
      },
      "unset" => ["GH_TOKEN", "GITHUB_TOKEN"]
    }
  end

  defp fake_udp_gh!(root, contract, filename \\ nil) do
    path = Path.join(root, filename || "udp-gh-#{System.unique_integer([:positive])}")
    payload = Jason.encode!(contract)
    quoted_payload = "'" <> String.replace(payload, "'", "'\"'\"'") <> "'"
    File.write!(path, "#!/bin/sh\nprintf '%s\\n' #{quoted_payload}\n")
    File.chmod!(path, 0o700)
    path
  end

  defp restore_application_env(name, nil), do: Application.delete_env(:symphony_elixir, name)
  defp restore_application_env(name, value), do: Application.put_env(:symphony_elixir, name, value)

  defp restore_system_env(name, nil), do: System.delete_env(name)
  defp restore_system_env(name, value), do: System.put_env(name, value)
end
