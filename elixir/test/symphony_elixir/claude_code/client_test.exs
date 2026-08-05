defmodule SymphonyElixir.ClaudeCode.ClientTest do
  @moduledoc """
  Drives `SymphonyElixir.ClaudeCode.Client` against a fake `claude` shell script
  (mirrors `app_server_test.exs` / `acp/client_test.exs`): the script records
  argv + env, reads the stream-json user message from stdin, emits canned
  `system` / `assistant` / `tool_result` stream-json lines, then a terminal
  `result` with a chosen stop reason.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ClaudeCode.Client, as: ClaudeCode

  @issue %SymphonyElixir.Linear.Issue{
    id: "issue-cc",
    identifier: "CC-10",
    title: "Drive Claude Code turn",
    description: "Claude Code backend e2e",
    state: "In Progress",
    url: "https://example.org/issues/CC-10",
    labels: ["backend"]
  }

  test "completes a happy turn and returns the session id" do
    with_cc_env(fn workspace, _trace ->
      write_fake_agent!(workspace.agent_path, events: [system_init("cc-1"), assistant_text("Working on it")])

      assert {:ok, %{session_id: "cc-1", stop_reason: "end_turn"}} =
               run(workspace, on_message: collector())

      # The model Claude reports in `system/init` rides on :session_started so the
      # dashboard can show the actual model.
      assert_received {:cc_message, %{event: :session_started, session_id: "cc-1", model: "claude-haiku"}}
      assert_received {:cc_message, %{event: :turn_completed, stop_reason: "end_turn"}}
    end)
  end

  test "builds the stream-json command and wires the gated MCP server with --strict-mcp-config" do
    with_cc_env(fn workspace, trace ->
      write_fake_agent!(workspace.agent_path, events: [system_init()])

      assert {:ok, _} = run(workspace, on_message: collector())

      argv = trace_argv(trace)
      assert argv =~ "--output-format stream-json"
      assert argv =~ "--input-format stream-json"
      assert argv =~ "--permission-mode bypassPermissions"
      assert argv =~ "--strict-mcp-config"
      assert argv =~ ~s|"mcpServers":{"symphony-linear":{"type":"http"|
      assert argv =~ "127.0.0.1"
    end)
  end

  test "normalizes assistant text, thinking, tool_use and tool_result into the transcript shape" do
    with_cc_env(fn workspace, _trace ->
      write_fake_agent!(workspace.agent_path,
        events: [
          system_init(),
          assistant_thinking("planning the change"),
          assistant_tool_use("Read", %{"file_path" => "/ws/a.ex"}),
          user_tool_result("1\thello"),
          assistant_text("Done.")
        ]
      )

      assert {:ok, _} = run(workspace, on_message: collector())

      assert_received {:cc_message, %{event: :notification, payload: %{"method" => "item/reasoning/textDelta", "params" => %{"textDelta" => "planning the change"}}}}

      assert_received {:cc_message, %{event: :notification, payload: %{"method" => "item/tool/call", "params" => %{"name" => "Read"}}}}

      assert_received {:cc_message, %{event: :notification, payload: %{"method" => "item/commandExecution/outputDelta", "params" => %{"output" => "1\thello"}}}}

      assert_received {:cc_message, %{event: :notification, payload: %{"method" => "item/agentMessage/delta", "params" => %{"delta" => "Done."}}}}
    end)
  end

  test "renders a TodoWrite tool call as a native plan checklist" do
    alias SymphonyElixir.CodexSessionLogRenderer, as: Renderer

    with_cc_env(fn workspace, _trace ->
      write_fake_agent!(workspace.agent_path,
        events: [
          system_init(),
          assistant_tool_use("TodoWrite", %{
            "todos" => [
              %{"content" => "write tests", "status" => "completed", "activeForm" => "writing tests"},
              %{"content" => "ship it", "status" => "pending", "activeForm" => "shipping it"}
            ]
          })
        ]
      )

      assert {:ok, _} = run(workspace, on_message: collector())

      # A TodoWrite call normalizes to the canonical `session/update`/plan block
      # (shared with ACP), not a raw `item/tool/call` args dump.
      assert_received {:cc_message,
                       %{
                         event: :notification,
                         payload: %{"method" => "session/update", "params" => %{"update" => %{"sessionUpdate" => "plan"} = update}}
                       }}

      assert update["entries"] == [
               %{"content" => "write tests", "status" => "completed"},
               %{"content" => "ship it", "status" => "pending"}
             ]

      # And it renders as a checklist through the session-log renderer.
      log =
        Jason.encode!(%{
          "at" => "2026-06-17T00:00:00Z",
          "payload" => %{
            "method" => "session/update",
            "params" => %{"sessionId" => "cc-1", "update" => %{"sessionUpdate" => "plan", "entries" => update["entries"]}}
          }
        })

      output = Renderer.render_string(log, use_color: false)
      assert output =~ "PLAN"
      assert output =~ "- [x] write tests"
      assert output =~ "- [ ] ship it"
    end)
  end

  test "marks a failed tool_result as an error in the transcript" do
    with_cc_env(fn workspace, _trace ->
      write_fake_agent!(workspace.agent_path,
        events: [system_init(), user_tool_result_error("permission denied")]
      )

      assert {:ok, _} = run(workspace, on_message: collector())

      assert_received {:cc_message,
                       %{
                         event: :notification,
                         payload: %{"method" => "item/commandExecution/outputDelta", "params" => %{"output" => "[tool error] permission denied"}}
                       }}
    end)
  end

  test "maps an error result to an abnormal completion" do
    with_cc_env(fn workspace, _trace ->
      write_fake_agent!(workspace.agent_path,
        events: [system_init()],
        result: result_line("error_during_execution", is_error: true)
      )

      assert {:error, {:turn_completed_abnormally, %{stop_reason: _}}} =
               run(workspace, on_message: collector())

      assert_received {:cc_message, %{event: :turn_completed_abnormally}}
    end)
  end

  test "treats max_tokens as a completed turn with a note" do
    with_cc_env(fn workspace, _trace ->
      write_fake_agent!(workspace.agent_path,
        events: [system_init()],
        result: result_line("max_tokens")
      )

      assert {:ok, %{stop_reason: "max_tokens"}} = run(workspace, on_message: collector())
      assert_received {:cc_message, %{event: :turn_completed, note: "max_tokens"}}
    end)
  end

  test "times out a turn when the agent stops responding" do
    with_cc_env([claude_code_prompt_timeout_ms: 300, claude_code_stall_timeout_ms: 300], fn workspace, _trace ->
      write_fake_agent!(workspace.agent_path, silent: true)

      assert {:error, reason} = run(workspace, on_message: collector())
      assert reason in [:turn_timeout, :turn_stalled]
    end)
  end

  test "withholds Linear credentials from the agent process env" do
    previous = System.get_env("LINEAR_API_KEY")
    System.put_env("LINEAR_API_KEY", "super-secret-token")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous) end)

    with_cc_env(fn workspace, trace ->
      write_fake_agent!(workspace.agent_path, events: [system_init()])
      issue_context_file = Path.join(workspace.root, "issue-context.json")

      assert {:ok, _} =
               run(workspace,
                 on_message: collector(),
                 issue_context_file: issue_context_file
               )

      env_lines = trace |> File.read!() |> String.split("\n", trim: true)
      assert "ENV:LINEAR_API_KEY=[]" in env_lines
      assert "ENV:SYMPHONY_ISSUE_CONTEXT_FILE=[#{issue_context_file}]" in env_lines
      assert "ENV:SYMPHONY_TEST_WORKER_LIMIT=[2]" in env_lines
    end)
  end

  test "passes the configured model as a --model flag" do
    with_cc_env([claude_code_model: "opus"], fn workspace, trace ->
      write_fake_agent!(workspace.agent_path, events: [system_init()])

      assert {:ok, _} = run(workspace, on_message: collector())
      assert trace_argv(trace) =~ "--model opus"
    end)
  end

  test "a per-task model override takes effect even when no model is configured" do
    with_cc_env(fn workspace, trace ->
      write_fake_agent!(workspace.agent_path, events: [system_init()])

      assert {:ok, _} = run(workspace, on_message: collector(), overrides: %{model: "opus"})
      assert trace_argv(trace) =~ "--model opus"
    end)
  end

  test "agent.pre_command runs in the launch shell so its env reaches the agent" do
    with_cc_env([agent_pre_command: "export CC_PRECMD=propagated"], fn workspace, trace ->
      write_fake_agent!(workspace.agent_path, events: [system_init()])

      assert {:ok, _} = run(workspace, on_message: collector())

      env_line =
        trace |> File.read!() |> String.split("\n", trim: true) |> Enum.find(&String.starts_with?(&1, "ENV:CC_PRECMD="))

      assert env_line == "ENV:CC_PRECMD=[propagated]"
    end)
  end

  test "rejects a workspace outside the configured workspace root" do
    with_cc_env(fn workspace, _trace ->
      outside = Path.join(workspace.root, "../outside-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.expand(outside))

      assert {:error, {:invalid_workspace_cwd, _kind, _path, _root}} =
               ClaudeCode.run(Path.expand(outside), "do work", @issue)
    end)
  end

  # ── harness ────────────────────────────────────────────────────────────────

  defp run(workspace, opts) do
    ClaudeCode.run(workspace.binary, "do the work", @issue, opts)
  end

  defp collector do
    test_pid = self()
    fn message -> send(test_pid, {:cc_message, message}) end
  end

  defp with_cc_env(extra_overrides \\ [], fun) do
    root = Path.join(System.tmp_dir!(), "symphony-cc-#{System.unique_integer([:positive])}")
    workspace_dir = Path.join(root, "CC-10")
    agent_path = Path.join(root, "fake-claude.sh")
    trace = Path.join(root, "claude.trace")
    File.mkdir_p!(workspace_dir)

    overrides =
      [
        workspace_root: root,
        agent_backend: "claude_code",
        claude_code_command: "CC_TRACE=#{trace} sh #{agent_path}"
      ] ++ extra_overrides

    write_workflow_file!(Workflow.workflow_file_path(), overrides)
    on_exit(fn -> File.rm_rf(root) end)

    workspace = %{binary: workspace_dir, root: root, agent_path: agent_path}
    fun.(workspace, trace)
  end

  defp trace_argv(trace) do
    trace
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.find(&String.starts_with?(&1, "ARGV:"))
    |> to_string()
    |> String.trim_leading("ARGV:")
  end

  # ── stream-json line builders ────────────────────────────────────────────────

  defp system_init(session_id \\ "cc-1") do
    Jason.encode!(%{"type" => "system", "subtype" => "init", "session_id" => session_id, "model" => "claude-haiku"})
  end

  defp assistant_text(text) do
    assistant_message([%{"type" => "text", "text" => text}])
  end

  defp assistant_thinking(text) do
    assistant_message([%{"type" => "thinking", "thinking" => text, "signature" => "sig"}])
  end

  defp assistant_tool_use(name, input) do
    assistant_message([%{"type" => "tool_use", "id" => "toolu_1", "name" => name, "input" => input}])
  end

  defp assistant_message(content) do
    Jason.encode!(%{
      "type" => "assistant",
      "message" => %{"role" => "assistant", "content" => content, "usage" => %{"output_tokens" => 3}},
      "session_id" => "cc-1"
    })
  end

  defp user_tool_result(content) do
    Jason.encode!(%{
      "type" => "user",
      "message" => %{"role" => "user", "content" => [%{"type" => "tool_result", "tool_use_id" => "toolu_1", "content" => content}]},
      "session_id" => "cc-1"
    })
  end

  defp user_tool_result_error(content) do
    Jason.encode!(%{
      "type" => "user",
      "message" => %{
        "role" => "user",
        "content" => [%{"type" => "tool_result", "tool_use_id" => "toolu_1", "content" => content, "is_error" => true}]
      },
      "session_id" => "cc-1"
    })
  end

  defp result_line(stop_reason, opts \\ []) do
    is_error = Keyword.get(opts, :is_error, false)
    subtype = if is_error, do: "error_during_execution", else: "success"

    Jason.encode!(%{
      "type" => "result",
      "subtype" => subtype,
      "is_error" => is_error,
      "stop_reason" => stop_reason,
      "result" => "ok",
      "session_id" => "cc-1"
    })
  end

  # Builds a POSIX-sh fake `claude`. `opts`:
  #   :events — list of raw stream-json lines streamed before the result
  #   :result — the terminal result line (default success/end_turn)
  #   :silent — never answer (drives the timeout path)
  defp write_fake_agent!(agent_path, opts) do
    File.write!(agent_path, fake_agent_script(opts))
    File.chmod!(agent_path, 0o755)
    :ok
  end

  defp fake_agent_script(opts) do
    """
    #!/bin/sh
    trace="${CC_TRACE}"
    emit() { printf '%s\\n' "$1"; }
    if [ -n "$trace" ]; then
      printf 'ARGV:%s\\n' "$*" >> "$trace"
      printf 'ENV:LINEAR_API_KEY=[%s]\\n' "$LINEAR_API_KEY" >> "$trace"
      printf 'ENV:SYMPHONY_ISSUE_CONTEXT_FILE=[%s]\\n' "$SYMPHONY_ISSUE_CONTEXT_FILE" >> "$trace"
      printf 'ENV:SYMPHONY_TEST_WORKER_LIMIT=[%s]\\n' "$SYMPHONY_TEST_WORKER_LIMIT" >> "$trace"
      printf 'ENV:CC_PRECMD=[%s]\\n' "$CC_PRECMD" >> "$trace"
    fi
    IFS= read -r line
    [ -n "$trace" ] && printf 'JSON:%s\\n' "$line" >> "$trace"
    #{prompt_body(opts)}
    """
  end

  defp prompt_body(opts) do
    if Keyword.get(opts, :silent, false) do
      "while IFS= read -r _l; do : ; done"
    else
      events = Keyword.get(opts, :events, [system_init()])
      result = Keyword.get(opts, :result, result_line("end_turn"))

      emits = Enum.map(events ++ [result], fn line -> "    emit '#{line}'" end)

      (emits ++ ["    exit 0"])
      |> Enum.join("\n")
    end
  end
end
