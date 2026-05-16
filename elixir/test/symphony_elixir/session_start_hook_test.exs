defmodule SymphonyElixir.SessionStartHookTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.SessionStartHook

  test "skips when no session_start hook is configured" do
    workspace = temp_workspace!("session-start-skip")
    issue = issue("MT-SKIP")

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.dirname(workspace))

    assert SessionStartHook.telemetry_event() == [:symphony_elixir, :gate, :session_start]

    assert %{outcome: :skipped, prompt: "", output: "", workpad_files: [], script_timings: []} =
             SessionStartHook.run(workspace, issue)
  end

  test "passes without advisory prompt when no workpad files are found" do
    workspace = temp_workspace!("session-start-empty")
    issue = issue("MT-EMPTY")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(workspace),
      hook_session_start: "printf '%s\\n' plain-output"
    )

    assert %{outcome: :passed, prompt: "", output: "plain-output\n", workpad_files: [], script_timings: []} =
             SessionStartHook.run(workspace, issue)
  end

  test "discovers local issue branch workpad files" do
    workspace = temp_workspace!("session-start-local-branch")
    issue = issue("MT-BRANCH", branch_name: "feature/session-start")
    fake_git = Path.join(Path.dirname(workspace), "git")
    previous_path = System.get_env("PATH")

    on_exit(fn -> restore_env("PATH", previous_path) end)

    File.write!(fake_git, """
    #!/bin/sh
    printf '%s\\n' 'feature/session-start'
    """)

    File.chmod!(fake_git, 0o755)
    System.put_env("PATH", Path.dirname(workspace) <> ":" <> (previous_path || ""))

    File.mkdir_p!(Path.join(workspace, "docs/agent-workpad/feature/session-start"))
    File.mkdir_p!(Path.join(workspace, "docs/agent-workpad/feature_session-start"))
    File.write!(Path.join(workspace, "docs/agent-workpad/feature/session-start/local.md"), "local\n")
    File.write!(Path.join(workspace, "docs/agent-workpad/feature_session-start/sanitized.md"), "sanitized\n")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(workspace),
      hook_session_start: "printf '%s\\n' '{\"timings\":{\"session:check-base\":2.6}}'"
    )

    result = SessionStartHook.run(workspace, issue)

    assert result.outcome == :passed

    assert result.workpad_files == [
             "docs/agent-workpad/feature/session-start/local.md",
             "docs/agent-workpad/feature_session-start/sanitized.md"
           ]

    assert result.prompt =~ "docs/agent-workpad/feature/session-start/local.md"
    assert result.script_timings == [%{name: "session:check-base", duration_ms: 3, status: nil}]
  end

  test "extracts supported timing report variants" do
    workspace = temp_workspace!("session-start-timings")
    issue = issue("MT-TIMINGS")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(workspace),
      hook_session_start: "printf '%s\\n' 'prefix {\"checks\":[{\"check\":123,\"elapsedMs\":\"9\",\"result\":true},\"bad\"]} suffix'"
    )

    assert %{script_timings: [%{name: "123", duration_ms: 9, status: "true"}]} =
             SessionStartHook.run(workspace, issue)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(workspace),
      hook_session_start: "printf '%s\\n' '{\"gates\":[{\"gate\":\"reuse\",\"time_ms\":\"bad\"}]}'"
    )

    assert %{script_timings: []} = SessionStartHook.run(workspace, issue)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(workspace),
      hook_session_start: "printf '%s\\n' '[]'"
    )

    assert %{script_timings: []} = SessionStartHook.run(workspace, issue)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(workspace),
      hook_session_start: "printf '%s\\n' '{bad-json}'"
    )

    assert %{script_timings: []} = SessionStartHook.run(workspace, issue)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(workspace),
      hook_session_start: "printf '%s\\n' '{\"scripts\":[{\"script\":\"digest\",\"durationMs\":4}]}'"
    )

    assert %{script_timings: [%{name: "digest", duration_ms: 4, status: nil}]} =
             SessionStartHook.run(workspace, issue)
  end

  test "discovers remote workpad files" do
    test_root = temp_dir!("session-start-remote")
    fake_ssh = Path.join(test_root, "ssh")
    previous_path = System.get_env("PATH")

    on_exit(fn -> restore_env("PATH", previous_path) end)

    File.write!(fake_ssh, """
    #!/bin/sh
    case "$*" in
      *"git branch --show-current"*)
        printf '%s\\n' 'feature/remote'
        ;;
      *"find"*)
        printf '%s\\n' 'docs/agent-workpad/feature/remote/one.md'
        printf '%s\\n' 'docs/agent-workpad/feature_remote/two.md'
        printf '%s\\n' 'docs/agent-workpad/feature/remote/one.md'
        ;;
      *)
        printf '%s\\n' '{"timings":{"remote":5}}'
        ;;
    esac
    """)

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: "/remote/workspaces",
      hook_session_start: "scripts/hooks/session-start.sh"
    )

    result = SessionStartHook.run("/remote/workspaces/MT-REMOTE", issue("MT-REMOTE"), "worker-1")

    assert result.outcome == :passed

    assert result.workpad_files == [
             "docs/agent-workpad/feature/remote/one.md",
             "docs/agent-workpad/feature_remote/two.md"
           ]

    assert result.script_timings == [%{name: "remote", duration_ms: 5, status: nil}]
  end

  test "times out remote workpad discovery" do
    test_root = temp_dir!("session-start-remote-discovery-timeout")
    fake_ssh = Path.join(test_root, "ssh")
    previous_path = System.get_env("PATH")

    on_exit(fn -> restore_env("PATH", previous_path) end)

    File.write!(fake_ssh, """
    #!/bin/sh
    case "$*" in
      *"scripts/hooks/session-start.sh"*)
        printf '%s\\n' '{"timings":{"remote":5}}'
        ;;
      *)
        sleep 1
        ;;
    esac
    """)

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: "/remote/workspaces",
      hook_session_start: "scripts/hooks/session-start.sh",
      hook_timeout_ms: 100
    )

    started_at = System.monotonic_time()
    result = SessionStartHook.run("/remote/workspaces/MT-REMOTE-TIMEOUT", issue("MT-REMOTE-TIMEOUT"), "worker-1")
    elapsed_ms = System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

    assert result.outcome == :passed
    assert result.workpad_files == []
    assert result.script_timings == [%{name: "remote", duration_ms: 5, status: nil}]
    assert elapsed_ms < 1_000
  end

  test "handles remote branch discovery failures" do
    test_root = temp_dir!("session-start-remote-branch-fail")
    fake_ssh = Path.join(test_root, "ssh")
    previous_path = System.get_env("PATH")

    on_exit(fn -> restore_env("PATH", previous_path) end)

    File.write!(fake_ssh, """
    #!/bin/sh
    case "$*" in
      *"git branch --show-current"*)
        printf '\\n'
        ;;
      *"find"*)
        exit 4
        ;;
      *)
        printf '%s\\n' '{"scripts":[{"script":"remote","durationMs":1}]}'
        ;;
    esac
    """)

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: "/remote/workspaces",
      hook_session_start: "scripts/hooks/session-start.sh"
    )

    result = SessionStartHook.run("/remote/workspaces/MT-REMOTE-BRANCH", issue("MT-REMOTE-BRANCH"), "worker-1")

    assert result.outcome == :passed
    assert result.workpad_files == []
    assert result.prompt == ""
  end

  test "remote session_start failures remain informational" do
    test_root = temp_dir!("session-start-remote-fail")
    fake_ssh = Path.join(test_root, "ssh")
    previous_path = System.get_env("PATH")

    on_exit(fn -> restore_env("PATH", previous_path) end)

    File.write!(fake_ssh, """
    #!/bin/sh
    case "$*" in
      *"git branch --show-current"*)
        exit 3
        ;;
      *"find"*)
        exit 4
        ;;
      *)
        printf '%s\\n' 'remote hook failed'
        exit 17
        ;;
    esac
    """)

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: "/remote/workspaces",
      hook_session_start: "scripts/hooks/session-start.sh"
    )

    result = SessionStartHook.run("/remote/workspaces/MT-REMOTE-FAIL", issue("MT-REMOTE-FAIL"), "worker-1")

    assert result.outcome == :failed
    assert result.workpad_files == []
    assert result.prompt =~ "No session_start workpad files were found."
  end

  test "non-hook-command failures remain informational" do
    workspace = temp_workspace!("session-start-timeout")
    issue = issue("MT-TIMEOUT")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(workspace),
      hook_session_start: "sleep 1",
      hook_timeout_ms: 1
    )

    result = SessionStartHook.run(workspace, issue)

    assert result.outcome == :failed
    assert result.output =~ "workspace_hook_timeout"
  end

  defp temp_workspace!(name) do
    root = temp_dir!(name)
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    workspace
  end

  defp temp_dir!(name) do
    path = Path.join(System.tmp_dir!(), "symphony-elixir-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp issue(identifier, attrs \\ []) do
    struct!(
      Issue,
      Keyword.merge(
        [
          id: "issue-#{identifier}",
          identifier: identifier,
          title: "Session start",
          state: "In Progress"
        ],
        attrs
      )
    )
  end
end
