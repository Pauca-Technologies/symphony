defmodule SymphonyElixir.AppServerTest do
  use SymphonyElixir.TestSupport

  test "app server rejects the workspace root and paths outside workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-guard",
        identifier: "MT-999",
        title: "Validate workspace guard",
        description: "Ensure app-server refuses invalid cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-999",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
               AppServer.run(workspace_root, "guard", issue)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
               AppServer.run(outside_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects symlink escape cwd paths under the workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-symlink-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")
      symlink_workspace = Path.join(workspace_root, "MT-1000")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)
      File.ln_s!(outside_workspace, symlink_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-symlink-guard",
        identifier: "MT-1000",
        title: "Validate symlink workspace guard",
        description: "Ensure app-server refuses symlink escape cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-1000",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :symlink_escape, ^symlink_workspace, _root}} =
               AppServer.run(symlink_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "turn timeout is an absolute wall-clock deadline even while events keep streaming" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-wall-clock-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-1000-TIMEOUT")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1) printf '%s\n' '{"id":1,"result":{}}' ;;
          2) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-timeout"}}}' ;;
          3)
            printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-timeout"}}}'
            i=0
            while [ "$i" -lt 20 ]; do
              printf '%s\n' '{"method":"turn/progress","params":{"turn":{"id":"turn-timeout"}}}'
              sleep 0.03
              i=$((i + 1))
            done
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-wall-clock-timeout",
        identifier: "MT-1000-TIMEOUT",
        title: "Bound a busy turn",
        state: "In Progress"
      }

      opts = [
        turn_timeout_ms: 120,
        issue_context_file: Path.join(test_root, "issue-context.json")
      ]

      assert {:ok, session} = AppServer.start_session(workspace, opts)

      try do
        started = System.monotonic_time(:millisecond)
        assert {:error, :turn_timeout} = AppServer.run_turn(session, "Keep streaming", issue, opts)
        elapsed = System.monotonic_time(:millisecond) - started
        assert elapsed < 300
      after
        AppServer.stop_session(session)
      end
    after
      File.rm_rf(test_root)
    end
  end

  test "app server applies model/effort overrides and passes explicit turn policies through unchanged" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-supported-turn-policies-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-1001")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-supported-turn-policies.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-supported-turn-policies.trace}"
      printf 'ISSUE_CONTEXT:%s\n' "$SYMPHONY_ISSUE_CONTEXT_FILE" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1001"},"model":"gpt-5.6-sol","reasoningEffort":"medium"}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1001"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      issue = %Issue{
        id: "issue-supported-turn-policies",
        identifier: "MT-1001",
        title: "Validate explicit turn sandbox policy passthrough",
        description: "Ensure runtime startup forwards configured turn sandbox policies unchanged",
        state: "In Progress",
        url: "https://example.org/issues/MT-1001",
        labels: ["backend"]
      }

      policy_cases = [
        %{"type" => "dangerFullAccess"},
        %{"type" => "externalSandbox", "profile" => "remote-ci"},
        %{"type" => "workspaceWrite", "writableRoots" => ["relative/path"], "networkAccess" => true},
        %{"type" => "futureSandbox", "nested" => %{"flag" => true}}
      ]

      issue_context_file = Path.join(test_root, "issue-context.json")

      output_schema = %{
        "type" => "object",
        "required" => ["profile"],
        "properties" => %{"profile" => %{"type" => "string"}}
      }

      Enum.each(policy_cases, fn configured_policy ->
        File.rm(trace_file)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_command: "#{codex_binary} app-server",
          codex_turn_sandbox_policy: configured_policy
        )

        test_pid = self()
        on_message = fn message -> send(test_pid, {:codex_message, message}) end

        assert {:ok, _result} =
                 AppServer.run(workspace, "Validate supported turn policy", issue,
                   on_message: on_message,
                   issue_context_file: issue_context_file,
                   overrides: %{model: "gpt-5.6-sol", reasoning_effort: "xhigh"},
                   thread_config: %{"project_doc_max_bytes" => 0},
                   output_schema: output_schema
                 )

        assert_receive {:codex_message,
                        %{
                          event: :session_started,
                          session_id: "thread-1001-turn-1001",
                          model: "gpt-5.6-sol",
                          reasoning_effort: "xhigh"
                        }}

        trace = File.read!(trace_file)
        lines = String.split(trace, "\n", trim: true)
        assert "ISSUE_CONTEXT:#{issue_context_file}" in lines

        assert Enum.any?(lines, fn line ->
                 if String.starts_with?(line, "JSON:") do
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()
                   |> then(fn payload ->
                     payload["method"] == "thread/start" &&
                       get_in(payload, ["params", "model"]) == "gpt-5.6-sol" &&
                       get_in(payload, ["params", "config", "project_doc_max_bytes"]) == 0
                   end)
                 else
                   false
                 end
               end)

        assert Enum.any?(lines, fn line ->
                 if String.starts_with?(line, "JSON:") do
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()
                   |> then(fn payload ->
                     payload["method"] == "turn/start" &&
                       get_in(payload, ["params", "sandboxPolicy"]) == configured_policy &&
                       get_in(payload, ["params", "effort"]) == "xhigh" &&
                       get_in(payload, ["params", "outputSchema"]) == output_schema
                   end)
                 else
                   false
                 end
               end)
      end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server marks request-for-input events as a hard failure" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-input-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-input.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-input.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-88\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-88\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/input_required\",\"id\":\"resp-1\",\"params\":{\"requiresInput\":true,\"reason\":\"blocked\"}}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-input",
        identifier: "MT-88",
        title: "Input needed",
        description: "Cannot satisfy codex input",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Needs input", issue)

      assert payload["method"] == "turn/input_required"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server sanitizes noise from sourced env files before startup" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-sourced-env-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-87")
      env_dir = Path.join(workspace, ".artifacts/github-app-auth")
      env_file = Path.join(env_dir, "session.env")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-sourced-env.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEX_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEX_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEX_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)
      File.mkdir_p!(env_dir)

      File.write!(env_file, """
      WARN Unsupported engine: wanted: {"node":">=24.0.0"} (current: {"node":"v22.22.2"})

      > app@ github:bootstrap #{workspace}
      export SYMPHONY_TEST_SOURCED_ENV='available'
      """)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/codex-sourced-env.trace}"
      printf 'ENV:%s\\n' "$SYMPHONY_TEST_SOURCED_ENV" >> "$trace_file"

      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-87"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-87"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "sh -lc '. .artifacts/github-app-auth/session.env && exec #{codex_binary} app-server'"
      )

      issue = %Issue{
        id: "issue-sourced-env",
        identifier: "MT-87",
        title: "Sourced env contains command noise",
        description: "Ensure generated env files can be sourced by the app-server command",
        state: "In Progress",
        url: "https://example.org/issues/MT-87",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Use sanitized env", issue)
      assert File.read!(trace_file) =~ "ENV:available"

      sanitized_env = File.read!(env_file)
      refute sanitized_env =~ "Unsupported engine"
      refute sanitized_env =~ "github:bootstrap"
      assert sanitized_env =~ "export SYMPHONY_TEST_SOURCED_ENV='available'"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server applies the global agent.pre_command and sanitizes the env files it sources" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-pre-command-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90")
      env_dir = Path.join(workspace, ".artifacts/github-app-auth")
      env_file = Path.join(env_dir, "session.env")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-pre-command.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEX_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEX_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEX_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)
      File.mkdir_p!(env_dir)

      File.write!(env_file, """
      WARN Unsupported engine: wanted: {"node":">=24.0.0"} (current: {"node":"v22.22.2"})

      > app@ github:bootstrap #{workspace}
      export SYMPHONY_TEST_SOURCED_ENV='available'
      """)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/codex-pre-command.trace}"
      printf 'ENV:%s\\n' "$SYMPHONY_TEST_SOURCED_ENV" >> "$trace_file"

      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-90"}}}' ;;
          3) printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-90"}}}' ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *) exit 0 ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      # The codex command is now bare — the env-sourcing lives in the
      # backend-agnostic agent.pre_command instead.
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_pre_command: ". .artifacts/github-app-auth/session.env",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-pre-command",
        identifier: "MT-90",
        title: "Pre-command sources the GitHub session env",
        description: "Ensure the global pre_command runs before the codex backend launches",
        state: "In Progress",
        url: "https://example.org/issues/MT-90",
        labels: ["backend"]
      }

      assert {:ok, _result} =
               AppServer.run(workspace, "Use pre-command env", issue,
                 thread_config: %{
                   "features.shell_snapshot" => true,
                   "project_doc_max_bytes" => 12_345
                 }
               )

      assert File.read!(trace_file) =~ "ENV:available"

      thread_config =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.find_value(fn line ->
          if String.starts_with?(line, "JSON:") do
            payload = line |> String.trim_leading("JSON:") |> Jason.decode!()

            if payload["method"] == "thread/start" do
              get_in(payload, ["params", "config"])
            end
          end
        end)

      assert thread_config["features.shell_snapshot"] == false
      assert thread_config["mcp_servers.linear.enabled"] == false
      assert thread_config["project_doc_max_bytes"] == 12_345

      sanitized_env = File.read!(env_file)
      refute sanitized_env =~ "Unsupported engine"
      assert sanitized_env =~ "export SYMPHONY_TEST_SOURCED_ENV='available'"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server fails when command execution approval is required under safer defaults" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-approval-required-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-89")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-89"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-89"}}}'
            printf '%s\\n' '{"id":99,"method":"item/commandExecution/requestApproval","params":{"command":"gh pr view","cwd":"/tmp","reason":"need approval"}}'
            ;;
          *)
            sleep 1
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-approval-required",
        identifier: "MT-89",
        title: "Approval required",
        description: "Ensure safer defaults do not auto approve requests",
        state: "In Progress",
        url: "https://example.org/issues/MT-89",
        labels: ["backend"]
      }

      assert {:error, {:approval_required, payload}} =
               AppServer.run(workspace, "Handle approval request", issue)

      assert payload["method"] == "item/commandExecution/requestApproval"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server auto-approves command execution approval requests when approval policy is never" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-auto-approve-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-89")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-auto-approve.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-auto-approve.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-89\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-89\"}}}'
            printf '%s\\n' '{\"id\":99,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"command\":\"gh pr view\",\"cwd\":\"/tmp\",\"reason\":\"need approval\"}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-auto-approve",
        identifier: "MT-89",
        title: "Auto approve request",
        description: "Ensure app-server approval requests are handled automatically",
        state: "In Progress",
        url: "https://example.org/issues/MT-89",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Handle approval request", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 1 and
                   get_in(payload, ["params", "capabilities", "experimentalApi"]) == true
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 tools = get_in(payload, ["params", "dynamicTools"])

                 payload["id"] == 2 and is_list(tools) and
                   Enum.any?(tools, fn
                     %{
                       "description" => description,
                       "inputSchema" => %{"required" => ["query"]},
                       "name" => "linear_graphql"
                     } ->
                       description =~ "Linear"

                     _ ->
                       false
                   end) and length(tools) == 3
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 99 and get_in(payload, ["result", "decision"]) == "acceptForSession"
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server auto-approves generic MCP tool approval prompts when approval policy is never" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-auto-approve-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-717")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-user-input-auto-approve.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-user-input-auto-approve.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-717\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-717\"}}}'
            printf '%s\\n' '{\"id\":110,\"method\":\"item/tool/requestUserInput\",\"params\":{\"itemId\":\"call-717\",\"questions\":[{\"header\":\"Approve app tool call?\",\"id\":\"mcp_tool_call_approval_call-717\",\"isOther\":false,\"isSecret\":false,\"options\":[{\"description\":\"Run the tool and continue.\",\"label\":\"Approve Once\"},{\"description\":\"Run the tool and remember this choice for this session.\",\"label\":\"Approve this Session\"},{\"description\":\"Decline this tool call and continue.\",\"label\":\"Deny\"},{\"description\":\"Cancel this tool call\",\"label\":\"Cancel\"}],\"question\":\"The linear MCP server wants to run the tool \\\"Save comment\\\", which may modify or delete data. Allow this action?\"}],\"threadId\":\"thread-717\",\"turnId\":\"turn-717\"}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-tool-user-input-auto-approve",
        identifier: "MT-717",
        title: "Auto approve MCP tool request user input",
        description: "Ensure app tool approval prompts continue automatically",
        state: "In Progress",
        url: "https://example.org/issues/MT-717",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Handle tool approval prompt", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 110 and
                   get_in(payload, ["result", "answers", "mcp_tool_call_approval_call-717", "answers"]) ==
                     ["Approve this Session"]
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server denies native Linear save_issue approval prompts when approval policy is never" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-linear-save-issue-deny-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-719")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-linear-save-issue-deny.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-linear-save-issue-deny.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-719"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-719"}}}'
            printf '%s\\n' '{"id":110,"method":"item/tool/requestUserInput","params":{"itemId":"call-719","questions":[{"header":"Approve app tool call?","id":"mcp_tool_call_approval_call-719","isOther":false,"isSecret":false,"options":[{"description":"Run the tool and continue.","label":"Approve Once"},{"description":"Run the tool and remember this choice for this session.","label":"Approve this Session"},{"description":"Decline this tool call and continue.","label":"Deny"},{"description":"Cancel this tool call","label":"Cancel"}],"question":"The linear MCP server wants to run the tool \\"Save issue\\", which may modify or delete data. Allow this action?"}],"threadId":"thread-719","turnId":"turn-719"}}'
            ;;
          5)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-linear-save-issue-deny",
        identifier: "MT-719",
        title: "Deny native save_issue",
        description: "Ensure native Linear save_issue cannot bypass handoff gates",
        state: "In Progress",
        url: "https://example.org/issues/MT-719",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Handle tool approval prompt", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 110 and
                   get_in(payload, ["result", "answers", "mcp_tool_call_approval_call-719", "answers"]) ==
                     ["Deny"]
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server sends a generic non-interactive answer for freeform tool input prompts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-required-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-718")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-718"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-718"}}}'
            printf '%s\\n' '{"id":111,"method":"item/tool/requestUserInput","params":{"itemId":"call-718","questions":[{"header":"Provide context","id":"freeform-718","isOther":false,"isSecret":false,"options":null,"question":"What comment should I post back to the issue?"}],"threadId":"thread-718","turnId":"turn-718"}}'
            ;;
          5)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-tool-user-input-required",
        identifier: "MT-718",
        title: "Non interactive tool input answer",
        description: "Ensure arbitrary tool prompts receive a generic answer",
        state: "In Progress",
        url: "https://example.org/issues/MT-718",
        labels: ["backend"]
      }

      on_message = fn message -> send(self(), {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle generic tool input", issue, on_message: on_message)

      assert_received {:app_server_message,
                       %{
                         event: :tool_input_auto_answered,
                         answer: "This is a non-interactive session. Operator input is unavailable."
                       }}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server sends a generic non-interactive answer for option-based tool input prompts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-options-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-719")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-user-input-options.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-user-input-options.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-719\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-719\"}}}'
            printf '%s\\n' '{\"id\":112,\"method\":\"item/tool/requestUserInput\",\"params\":{\"itemId\":\"call-719\",\"questions\":[{\"header\":\"Choose an action\",\"id\":\"options-719\",\"isOther\":false,\"isSecret\":false,\"options\":[{\"description\":\"Use the default behavior.\",\"label\":\"Use default\"},{\"description\":\"Skip this step.\",\"label\":\"Skip\"}],\"question\":\"How should I proceed?\"}],\"threadId\":\"thread-719\",\"turnId\":\"turn-719\"}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-tool-user-input-options",
        identifier: "MT-719",
        title: "Option based tool input answer",
        description: "Ensure option prompts receive a generic non-interactive answer",
        state: "In Progress",
        url: "https://example.org/issues/MT-719",
        labels: ["backend"]
      }

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle option based tool input", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 112 and
                   get_in(payload, ["result", "answers", "options-719", "answers"]) == [
                     "This is a non-interactive session. Operator input is unavailable."
                   ]
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects unsupported dynamic tool calls without stalling" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-call-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-call.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-call.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90\"}}}'
            printf '%s\\n' '{\"id\":101,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"some_tool\",\"callId\":\"call-90\",\"threadId\":\"thread-90\",\"turnId\":\"turn-90\",\"arguments\":{}}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-tool-call",
        identifier: "MT-90",
        title: "Unsupported tool call",
        description: "Ensure unsupported tool calls do not stall a turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-90",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Reject unsupported tool calls", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 101 and
                   get_in(payload, ["result", "success"]) == false and
                   String.contains?(
                     get_in(payload, ["result", "output"]),
                     "Unsupported dynamic tool"
                   )
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server executes supported dynamic tool calls and returns the tool result" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-supported-tool-call-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90A")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-supported-tool-call.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-supported-tool-call.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90a\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90a\"}}}'
            printf '%s\\n' '{\"id\":102,\"method\":\"item/tool/call\",\"params\":{\"name\":\"linear_graphql\",\"callId\":\"call-90a\",\"threadId\":\"thread-90a\",\"turnId\":\"turn-90a\",\"arguments\":{\"query\":\"query Viewer { viewer { id } }\",\"variables\":{\"includeTeams\":false}}}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-supported-tool-call",
        identifier: "MT-90A",
        title: "Supported tool call",
        description: "Ensure supported tool calls return tool output",
        state: "In Progress",
        url: "https://example.org/issues/MT-90A",
        labels: ["backend"]
      }

      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:tool_called, tool, arguments})

        %{
          "success" => true,
          "contentItems" => [
            %{
              "type" => "inputText",
              "text" => ~s({"data":{"viewer":{"id":"usr_123"}}})
            }
          ]
        }
      end

      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle supported tool calls", issue,
                 on_message: on_message,
                 tool_executor: tool_executor
               )

      assert_received {:tool_called, "linear_graphql",
                       %{
                         "query" => "query Viewer { viewer { id } }",
                         "variables" => %{"includeTeams" => false}
                       }}

      assert_received {:app_server_message,
                       %{
                         event: :tool_call_completed,
                         details: %{
                           result: %{
                             "success" => true,
                             "output" => %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
                           }
                         }
                       }}

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 102 and
                   get_in(payload, ["result", "success"]) == true and
                   get_in(payload, ["result", "output"]) ==
                     ~s({"data":{"viewer":{"id":"usr_123"}}})
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server emits tool_call_failed for supported tool failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-call-failed-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90B")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-call-failed.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-call-failed.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90b\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90b\"}}}'
            printf '%s\\n' '{\"id\":103,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"linear_graphql\",\"callId\":\"call-90b\",\"threadId\":\"thread-90b\",\"turnId\":\"turn-90b\",\"arguments\":{\"query\":\"query Viewer { viewer { id } }\"}}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-tool-call-failed",
        identifier: "MT-90B",
        title: "Tool call failed",
        description: "Ensure supported tool failures emit a distinct event",
        state: "In Progress",
        url: "https://example.org/issues/MT-90B",
        labels: ["backend"]
      }

      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:tool_called, tool, arguments})

        %{
          "success" => false,
          "contentItems" => [
            %{
              "type" => "inputText",
              "text" => ~s({"error":{"message":"boom"}})
            }
          ]
        }
      end

      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle failed tool calls", issue,
                 on_message: on_message,
                 tool_executor: tool_executor
               )

      assert_received {:tool_called, "linear_graphql", %{"query" => "query Viewer { viewer { id } }"}}

      assert_received {:app_server_message,
                       %{
                         event: :tool_call_failed,
                         payload: %{"params" => %{"tool" => "linear_graphql"}},
                         details: %{
                           result: %{
                             "success" => false,
                             "output" => %{"error" => %{"message" => "boom"}}
                           }
                         }
                       }}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server buffers partial JSON lines until newline terminator" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-partial-line-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-91")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            padding=$(printf '%*s' 1100000 '' | tr ' ' a)
            printf '{"id":1,"result":{},"padding":"%s"}\\n' "$padding"
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-91"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-91"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-partial-line",
        identifier: "MT-91",
        title: "Partial line decode",
        description: "Ensure JSON parsing waits for newline-delimited messages",
        state: "In Progress",
        url: "https://example.org/issues/MT-91",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Validate newline-delimited buffering", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server captures codex side output and logs it through Logger" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-stderr-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-92")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-92"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-92"}}}'
            ;;
          4)
            printf '%s\\n' 'warning: this is stderr noise' >&2
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-stderr",
        identifier: "MT-92",
        title: "Capture stderr",
        description: "Ensure codex stderr is captured and logged",
        state: "In Progress",
        url: "https://example.org/issues/MT-92",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      log =
        capture_log(fn ->
          assert {:ok, _result} =
                   AppServer.run(workspace, "Capture stderr log", issue, on_message: on_message)
        end)

      assert_received {:app_server_message, %{event: :turn_completed}}
      refute_received {:app_server_message, %{event: :malformed}}
      assert log =~ "Codex turn stream output: warning: this is stderr noise"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server treats aborted command item output as a turn error" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-interruption-signal-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-94")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-94"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-94"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"item/completed","params":{"item":{"type":"function_call_output","output":"aborted by user after 10.0s"},"threadId":"thread-94","turnId":"turn-94"}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-interruption-signal",
        identifier: "MT-94",
        title: "Capture interruption signal",
        description: "Ensure aborted command output is surfaced to the orchestrator",
        state: "In Progress",
        url: "https://example.org/issues/MT-94",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      log =
        capture_log(fn ->
          assert {:error, {:turn_interruption_signal, %{summary: error_summary}}} =
                   AppServer.run(workspace, "Capture interruption signal", issue, on_message: on_message)

          assert error_summary =~ "aborted by user after 10.0s"
        end)

      assert_received {:app_server_message,
                       %{
                         event: :turn_interruption_signal,
                         summary: summary,
                         payload: %{"method" => "item/completed"}
                       }}

      assert summary =~ "item/completed"
      assert summary =~ "aborted by user after 10.0s"
      refute_received {:app_server_message, %{event: :turn_completed}}
      assert log =~ "Codex interruption signal method=\"item/completed\""
    after
      File.rm_rf(test_root)
    end
  end

  test "app server ignores cancelled MCP startup and benign marker text" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-benign-cancelled-status-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-941")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-941"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-941"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"mcpServer/startupStatus/updated","params":{"server":"sentry","status":"cancelled","failureReason":"example mentions turn/interrupted"}}'
            printf '%s\\n' '{"method":"item/agentMessage/delta","params":{"delta":"Document <turn_aborted> and aborted by user","threadId":"thread-941","turnId":"turn-941"}}'
            printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-941","status":{"type":"completed"}}}}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-benign-cancelled-status",
        identifier: "MT-941",
        title: "Ignore unrelated cancelled status",
        description: "Keep MCP startup status separate from turn control",
        state: "In Progress",
        url: "https://example.org/issues/MT-941",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Ignore benign status", issue, on_message: on_message)

      assert_received {:app_server_message,
                       %{
                         event: :notification,
                         payload: %{"method" => "mcpServer/startupStatus/updated"}
                       }}

      assert_received {:app_server_message,
                       %{
                         event: :notification,
                         payload: %{"method" => "item/agentMessage/delta"}
                       }}

      assert_received {:app_server_message, %{event: :turn_completed}}
      refute_received {:app_server_message, %{event: :turn_interruption_signal}}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server preserves explicit aborted and interrupted terminal events" do
    for {method, suffix} <- [{"turn/aborted", "aborted"}, {"turn/interrupted", "interrupted"}] do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-app-server-terminal-#{suffix}-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "MT-942-#{suffix}")
        codex_binary = Path.join(test_root, "fake-codex")
        File.mkdir_p!(workspace)

        File.write!(codex_binary, """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))

          case "$count" in
            1)
              printf '%s\\n' '{"id":1,"result":{}}'
              ;;
            2)
              printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-942-#{suffix}"}}}'
              ;;
            3)
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-942-#{suffix}"}}}'
              ;;
            4)
              printf '%s\\n' '{"method":"#{method}","params":{"turn":{"id":"turn-942-#{suffix}"}}}'
              exit 0
              ;;
            *)
              exit 0
              ;;
          esac
        done
        """)

        File.chmod!(codex_binary, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_command: "#{codex_binary} app-server"
        )

        issue = %Issue{
          id: "issue-terminal-#{suffix}",
          identifier: "MT-942-#{suffix}",
          title: "Classify terminal #{suffix} event",
          description: "Preserve explicit terminal turn diagnostics",
          state: "In Progress",
          url: "https://example.org/issues/MT-942-#{suffix}",
          labels: ["backend"]
        }

        test_pid = self()
        on_message = fn message -> send(test_pid, {:app_server_message, message}) end

        assert {:error,
                {:turn_interruption_signal,
                 %{
                   method: ^method,
                   classification: %{kind: :terminal_method, method: ^method}
                 }}} = AppServer.run(workspace, "Classify terminal event", issue, on_message: on_message)

        assert_received {:app_server_message,
                         %{
                           event: :turn_interruption_signal,
                           classification: %{kind: :terminal_method, method: ^method},
                           payload: %{"method" => ^method}
                         }}

        refute_received {:app_server_message, %{event: :turn_completed}}
      after
        File.rm_rf(test_root)
      end
    end
  end

  test "app server treats interrupted turn completed payloads as errors" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-interrupted-completion-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-95")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-95"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-95"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-95","status":{"type":"interrupted","reason":"user_interrupted"}}}}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-interrupted-completion",
        identifier: "MT-95",
        title: "Classify interrupted completion",
        description: "Ensure interrupted terminal payloads are not treated as successful turns",
        state: "In Progress",
        url: "https://example.org/issues/MT-95",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:error, {:turn_completed_abnormally, %{status_type: "interrupted"}}} =
               AppServer.run(workspace, "Classify interrupted completion", issue, on_message: on_message)

      assert_received {:app_server_message,
                       %{
                         event: :turn_interruption_signal,
                         payload: %{"method" => "turn/completed"}
                       }}

      assert_received {:app_server_message,
                       %{
                         event: :turn_completed_abnormally,
                         details: %{status_type: "interrupted"}
                       }}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server treats JSONL turn_aborted after completed stream as an error" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-jsonl-turn-aborted-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-96")
      codex_binary = Path.join(test_root, "fake-codex")
      session_log = Path.join(test_root, "sessions/thread-96.jsonl")
      previous_session_log = System.get_env("SYMP_TEST_CODEX_SESSION_LOG")

      on_exit(fn ->
        if is_binary(previous_session_log) do
          System.put_env("SYMP_TEST_CODEX_SESSION_LOG", previous_session_log)
        else
          System.delete_env("SYMP_TEST_CODEX_SESSION_LOG")
        end
      end)

      System.put_env("SYMP_TEST_CODEX_SESSION_LOG", session_log)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      session_log="${SYMP_TEST_CODEX_SESSION_LOG}"

      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '{"id":2,"result":{"thread":{"id":"thread-96","path":"%s"}}}\\n' "$session_log"
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-96"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            sleep 0.35
            mkdir -p "$(dirname "$session_log")"
            printf '%s\\n' '{"timestamp":"2026-06-08T22:38:32.961Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-96","reason":"interrupted","duration_ms":128425}}' > "$session_log"
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-jsonl-turn-aborted",
        identifier: "MT-96",
        title: "Classify JSONL turn abort",
        description: "Ensure JSONL-only turn_aborted events are not treated as successful turns",
        state: "In Progress",
        url: "https://example.org/issues/MT-96",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:error, {:turn_aborted, %{"reason" => "interrupted", "turn_id" => "turn-96"}}} =
               AppServer.run(workspace, "Classify JSONL turn abort", issue, on_message: on_message)

      assert_received {:app_server_message,
                       %{
                         event: :turn_ended_with_error,
                         reason: {:turn_aborted, %{"reason" => "interrupted", "turn_id" => "turn-96"}}
                       }}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server emits malformed events for JSON-like protocol lines that fail to decode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-malformed-protocol-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-93")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-93"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-93"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-malformed-protocol",
        identifier: "MT-93",
        title: "Malformed protocol frame",
        description: "Ensure malformed JSON-like frames are surfaced to the orchestrator",
        state: "In Progress",
        url: "https://example.org/issues/MT-93",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Capture malformed protocol line", issue, on_message: on_message)

      assert_received {:app_server_message, %{event: :malformed, payload: "{\"method\":\"turn/completed\""}}
      assert_received {:app_server_message, %{event: :turn_completed}}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server launches over ssh for remote workers" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-remote-ssh-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      remote_workspace = "/remote/workspaces/MT-REMOTE"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      count=0
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-remote"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-remote"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "/remote/workspaces",
        codex_command: "fake-remote-codex app-server"
      )

      issue = %Issue{
        id: "issue-remote",
        identifier: "MT-REMOTE",
        title: "Run remote app server",
        description: "Validate ssh-backed codex startup",
        state: "In Progress",
        url: "https://example.org/issues/MT-REMOTE",
        labels: ["backend"]
      }

      assert {:ok, _result} =
               AppServer.run(
                 remote_workspace,
                 "Run remote worker",
                 issue,
                 worker_host: "worker-01:2200"
               )

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, &String.starts_with?(&1, "ARGV:"))
      assert argv_line =~ "-T -p 2200 worker-01 bash -lc"
      assert argv_line =~ "cd "
      assert argv_line =~ remote_workspace
      assert argv_line =~ "exec "
      assert argv_line =~ "fake-remote-codex app-server"
      assert argv_line =~ "export SYMPHONY_TEST_WORKER_LIMIT=2"

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [remote_workspace],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "cwd"]) == remote_workspace
                 end)
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == remote_workspace &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "subagent turn/completed on the shared connection does not end the parent turn" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-subagent-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-77")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-subagent.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEX_SUBAGENT_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEX_SUBAGENT_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEX_SUBAGENT_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEX_SUBAGENT_TRACE", trace_file)
      File.mkdir_p!(workspace)

      # A reviewer-style session that spawns subagents. The subagents run as
      # child threads multiplexed onto the same app-server connection, so the
      # first subagent's `turn/completed` (turn-subagent) arrives on this
      # connection *before* the parent's own completion (turn-parent). The fake
      # emits both, subagent first; the parent turn must win.
      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEX_SUBAGENT_TRACE:-/tmp/codex-subagent.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-parent"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-parent"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-subagent","status":{"type":"completed"}}}}'
            printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-parent","status":{"type":"completed"}}}}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-subagent-turn",
        identifier: "MT-77",
        title: "Subagent completion must not end the parent turn",
        description: "Reviewer-style session that spawns subagents on the shared connection",
        state: "In Progress",
        url: "https://example.org/issues/MT-77",
        labels: ["backend"]
      }

      {:ok, collector} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(collector), do: Agent.stop(collector) end)
      on_message = fn message -> Agent.update(collector, &[message | &1]) end

      assert {:ok, result} =
               AppServer.run(workspace, "review the diff", issue, on_message: on_message)

      # The turn that completed the run is the parent's, not the subagent's.
      assert result.turn_id == "turn-parent"

      events = collector |> Agent.get(& &1) |> Enum.reverse()

      # The subagent's terminal event is surfaced as a foreign-turn event and the
      # receive loop keeps waiting. Pre-fix, this first `turn/completed` was
      # mistaken for the parent and ended the session before turn-parent ever
      # completed.
      assert [%{turn_id: "turn-subagent", method: "turn/completed"}] =
               Enum.filter(events, &(&1[:event] == :subagent_turn_event))

      # The run still terminates on the parent turn's completion.
      assert Enum.any?(events, &(&1[:event] == :turn_completed))

      # ...and only after the subagent event was observed.
      assert Enum.find_index(events, &(&1[:event] == :subagent_turn_event)) <
               Enum.find_index(events, &(&1[:event] == :turn_completed))
    after
      File.rm_rf(test_root)
    end
  end

  test "withholds Linear credentials from the Codex agent process env" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-withhold-linear-#{System.unique_integer([:positive])}"
      )

    secret = "lin_test_secret_value_#{System.unique_integer([:positive])}"
    previous_linear = System.get_env("LINEAR_API_KEY")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-95")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-withhold-linear.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEX_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEX_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEX_TRACE")
        end

        if is_binary(previous_linear) do
          System.put_env("LINEAR_API_KEY", previous_linear)
        else
          System.delete_env("LINEAR_API_KEY")
        end
      end)

      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)
      System.put_env("LINEAR_API_KEY", secret)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/codex-withhold-linear.trace}"
      printf 'ENV:LINEAR_API_KEY=[%s]\\n' "$LINEAR_API_KEY" >> "$trace_file"
      printf 'ENV:SYMPHONY_TEST_WORKER_LIMIT=[%s]\\n' "$SYMPHONY_TEST_WORKER_LIMIT" >> "$trace_file"

      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-95"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-95"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      # Default config: codex.withhold_linear_credentials defaults to true.
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-withhold-linear",
        identifier: "MT-95",
        title: "Withhold Linear credentials",
        description: "Ensure the Codex agent process cannot inherit Linear credentials",
        state: "In Progress",
        url: "https://example.org/issues/MT-95",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Withhold Linear credentials", issue)

      trace = File.read!(trace_file)
      assert trace =~ "ENV:LINEAR_API_KEY=[]"
      assert trace =~ "ENV:SYMPHONY_TEST_WORKER_LIMIT=[2]"
      refute trace =~ secret
    after
      File.rm_rf(test_root)
    end
  end

  test "leaves Linear credentials in the Codex env when withholding is disabled" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-withhold-linear-off-#{System.unique_integer([:positive])}"
      )

    secret = "lin_test_secret_value_#{System.unique_integer([:positive])}"
    previous_linear = System.get_env("LINEAR_API_KEY")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-96")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-withhold-linear-off.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEX_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEX_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEX_TRACE")
        end

        if is_binary(previous_linear) do
          System.put_env("LINEAR_API_KEY", previous_linear)
        else
          System.delete_env("LINEAR_API_KEY")
        end
      end)

      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)
      System.put_env("LINEAR_API_KEY", secret)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/codex-withhold-linear-off.trace}"
      printf 'ENV:LINEAR_API_KEY=[%s]\\n' "$LINEAR_API_KEY" >> "$trace_file"

      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-96"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-96"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_withhold_linear_credentials: false
      )

      issue = %Issue{
        id: "issue-withhold-linear-off",
        identifier: "MT-96",
        title: "Leave Linear credentials in place",
        description: "Ensure disabling the flag leaves Linear credentials in the agent env",
        state: "In Progress",
        url: "https://example.org/issues/MT-96",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Leave Linear credentials in place", issue)

      trace = File.read!(trace_file)
      assert trace =~ "ENV:LINEAR_API_KEY=[#{secret}]"
    after
      File.rm_rf(test_root)
    end
  end
end
