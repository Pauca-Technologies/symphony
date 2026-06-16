defmodule SymphonyElixir.Acp.ClientTest do
  @moduledoc """
  Drives `SymphonyElixir.Acp.Client` against a fake `acp` agent shell script
  (mirrors `app_server_test.exs`): the script answers `initialize`,
  `session/new`, streams `session/update` notifications and optional
  `session/request_permission` requests, then returns a `session/prompt`
  response with a chosen `stopReason`.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Acp.Client, as: AcpClient

  @issue %SymphonyElixir.Linear.Issue{
    id: "issue-acp",
    identifier: "ACP-10",
    title: "Drive ACP turn",
    description: "ACP backend e2e",
    state: "In Progress",
    url: "https://example.org/issues/ACP-10",
    labels: ["backend"]
  }

  test "completes a happy turn and returns the session id" do
    with_acp_env(fn workspace, trace ->
      write_fake_agent!(workspace.agent_path, updates: [agent_chunk("Working on it")])

      assert {:ok, %{session_id: "sess-1", stop_reason: "end_turn"}} =
               run(workspace, on_message: collector())

      assert_received {:acp_message, %{event: :session_started, session_id: "sess-1"}}
      assert_received {:acp_message, %{event: :turn_completed, stop_reason: "end_turn"}}

      # session/new advertised the gated MCP server with no inline credentials.
      session_new = trace_message(trace, "session/new")
      [server] = get_in(session_new, ["params", "mcpServers"])
      assert server["type"] == "http"
      assert server["name"] == "symphony-linear"
      assert server["url"] =~ "127.0.0.1"
      assert server["headers"] == []
    end)
  end

  test "normalizes agent and reasoning chunks into the existing transcript shape" do
    with_acp_env(fn workspace, _trace ->
      write_fake_agent!(workspace.agent_path,
        updates: [agent_chunk("Hello there"), thought_chunk("thinking hard")]
      )

      assert {:ok, _} = run(workspace, on_message: collector())

      assert_received {:acp_message,
                       %{
                         event: :notification,
                         payload: %{"method" => "item/agentMessage/delta", "params" => %{"delta" => "Hello there"}}
                       }}

      assert_received {:acp_message,
                       %{
                         event: :notification,
                         payload: %{"method" => "item/reasoning/textDelta", "params" => %{"textDelta" => "thinking hard"}}
                       }}
    end)
  end

  test "auto-approves a session/request_permission by selecting an allow option" do
    with_acp_env(fn workspace, trace ->
      write_fake_agent!(workspace.agent_path, permission: permission_request())

      assert {:ok, %{stop_reason: "end_turn"}} = run(workspace, on_message: collector())

      assert_received {:acp_message, %{event: :approval_auto_approved, decision: "approved"}}

      permission_response = trace_message(trace, "client-permission-response")
      assert get_in(permission_response, ["result", "outcome", "optionId"]) == "opt-allow-always"
    end)
  end

  test "blocks the turn when auto_approve is false" do
    with_acp_env([acp_auto_approve: false], fn workspace, _trace ->
      write_fake_agent!(workspace.agent_path, permission: permission_request())

      assert {:error, {:approval_required, _payload}} = run(workspace, on_message: collector())
      assert_received {:acp_message, %{event: :approval_required}}
    end)
  end

  test "maps a refusal stopReason to an abnormal completion" do
    with_acp_env(fn workspace, _trace ->
      write_fake_agent!(workspace.agent_path, stop_reason: "refusal")

      assert {:error, {:turn_completed_abnormally, %{stop_reason: "refusal"}}} =
               run(workspace, on_message: collector())

      assert_received {:acp_message, %{event: :turn_completed_abnormally}}
    end)
  end

  test "maps a cancelled stopReason to an interruption + abnormal completion" do
    with_acp_env(fn workspace, _trace ->
      write_fake_agent!(workspace.agent_path, stop_reason: "cancelled")

      assert {:error, {:turn_completed_abnormally, %{stop_reason: "cancelled"}}} =
               run(workspace, on_message: collector())

      assert_received {:acp_message, %{event: :turn_interruption_signal}}
      assert_received {:acp_message, %{event: :turn_completed_abnormally}}
    end)
  end

  test "treats max_tokens as a completed turn" do
    with_acp_env(fn workspace, _trace ->
      write_fake_agent!(workspace.agent_path, stop_reason: "max_tokens")

      assert {:ok, %{stop_reason: "max_tokens"}} = run(workspace, on_message: collector())
      assert_received {:acp_message, %{event: :turn_completed, note: "max_tokens"}}
    end)
  end

  test "times out a turn when the agent stops responding" do
    with_acp_env([acp_prompt_timeout_ms: 300, acp_stall_timeout_ms: 300], fn workspace, _trace ->
      write_fake_agent!(workspace.agent_path, silent_prompt: true)

      assert {:error, reason} = run(workspace, on_message: collector())
      assert reason in [:turn_timeout, :turn_stalled]
    end)
  end

  test "withholds Linear credentials from the agent process env" do
    previous = System.get_env("LINEAR_API_KEY")
    System.put_env("LINEAR_API_KEY", "super-secret-token")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous) end)

    with_acp_env(fn workspace, trace ->
      write_fake_agent!(workspace.agent_path, updates: [])

      assert {:ok, _} = run(workspace, on_message: collector())

      env_line = trace |> File.read!() |> String.split("\n", trim: true) |> Enum.find(&String.starts_with?(&1, "ENV:LINEAR_API_KEY="))
      assert env_line == "ENV:LINEAR_API_KEY=[]"
    end)
  end

  test "rejects a workspace outside the configured workspace root" do
    with_acp_env(fn workspace, _trace ->
      outside = Path.join(workspace.root, "../outside-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.expand(outside))

      assert {:error, {:invalid_workspace_cwd, _kind, _path, _root}} =
               AcpClient.run(Path.expand(outside), "do work", @issue)
    end)
  end

  # ── harness ────────────────────────────────────────────────────────────────

  defp run(workspace, opts) do
    AcpClient.run(workspace.binary, "do the work", @issue, opts)
  end

  defp collector do
    test_pid = self()
    fn message -> send(test_pid, {:acp_message, message}) end
  end

  # Sets up a workspace under the configured root, points `acp.command` at a
  # fake agent, runs `fun.(workspace, trace_path)`.
  defp with_acp_env(extra_overrides \\ [], fun) do
    root = Path.join(System.tmp_dir!(), "symphony-acp-#{System.unique_integer([:positive])}")
    workspace_dir = Path.join(root, "ACP-10")
    agent_path = Path.join(root, "fake-acp-agent.sh")
    trace = Path.join(root, "acp.trace")
    File.mkdir_p!(workspace_dir)

    overrides =
      [
        workspace_root: root,
        agent_backend: "acp",
        acp_command: "ACP_TRACE=#{trace} sh #{agent_path}"
      ] ++ extra_overrides

    write_workflow_file!(Workflow.workflow_file_path(), overrides)

    on_exit(fn -> File.rm_rf(root) end)

    workspace = %{binary: workspace_dir, root: root, agent_path: agent_path}

    try do
      fun.(workspace, trace)
    after
      :ok
    end
  end

  defp trace_message(trace, "client-permission-response") do
    trace
    |> read_trace_json()
    |> Enum.find(fn msg -> get_in(msg, ["result", "outcome", "outcome"]) == "selected" end)
  end

  defp trace_message(trace, method) do
    trace
    |> read_trace_json()
    |> Enum.find(fn msg -> Map.get(msg, "method") == method end)
  end

  defp read_trace_json(trace) do
    trace
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "JSON:"))
    |> Enum.map(&(&1 |> String.trim_leading("JSON:") |> Jason.decode!()))
  end

  defp agent_chunk(text) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => "sess-1",
        "update" => %{"sessionUpdate" => "agent_message_chunk", "content" => %{"type" => "text", "text" => text}}
      }
    })
  end

  defp thought_chunk(text) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => "sess-1",
        "update" => %{"sessionUpdate" => "agent_thought_chunk", "content" => %{"type" => "text", "text" => text}}
      }
    })
  end

  defp permission_request do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 555,
      "method" => "session/request_permission",
      "params" => %{
        "sessionId" => "sess-1",
        "toolCall" => %{"title" => "Run bash", "kind" => "execute"},
        "options" => [
          %{"optionId" => "opt-allow-once", "name" => "Allow once", "kind" => "allow_once"},
          %{"optionId" => "opt-allow-always", "name" => "Always allow", "kind" => "allow_always"},
          %{"optionId" => "opt-reject", "name" => "Reject", "kind" => "reject_once"}
        ]
      }
    })
  end

  # Builds a POSIX-sh fake agent at `agent_path`. `opts`:
  #   :updates       — list of raw session/update JSON to stream before the response
  #   :stop_reason   — stopReason in the session/prompt response (default "end_turn")
  #   :permission    — raw session/request_permission JSON; the agent emits it and
  #                    waits for the client's reply before responding end_turn
  #   :silent_prompt — never answer session/prompt (drives the timeout path)
  defp write_fake_agent!(agent_path, opts) do
    File.write!(agent_path, fake_agent_script(opts))
    File.chmod!(agent_path, 0o755)
    :ok
  end

  defp fake_agent_script(opts) do
    """
    #!/bin/sh
    trace="${ACP_TRACE}"
    emit() { printf '%s\\n' "$1"; }
    extract_id() { printf '%s' "$1" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p' | head -n1; }
    awaiting=0
    prompt_id=""
    while IFS= read -r line; do
      [ -n "$trace" ] && printf 'JSON:%s\\n' "$line" >> "$trace"
      case "$line" in
        *'"method":"initialize"'*)
          [ -n "$trace" ] && printf 'ENV:LINEAR_API_KEY=[%s]\\n' "$LINEAR_API_KEY" >> "$trace"
          emit '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{}}}'
          ;;
        *'"method":"session/new"'*)
          emit '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"sess-1"}}'
          ;;
        *'"method":"session/prompt"'*)
          prompt_id=$(extract_id "$line")
    #{prompt_body(opts)}
          ;;
        *'"outcome"'*)
          if [ "$awaiting" = "1" ]; then
            emit "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":$prompt_id,\\"result\\":{\\"stopReason\\":\\"end_turn\\"}}"
            exit 0
          fi
          ;;
      esac
    done
    """
  end

  defp prompt_body(opts) do
    cond do
      Keyword.get(opts, :silent_prompt, false) ->
        "      : # never answer the prompt"

      permission = Keyword.get(opts, :permission) ->
        "      emit '#{permission}'\n      awaiting=1"

      true ->
        updates = Keyword.get(opts, :updates, [])
        stop = Keyword.get(opts, :stop_reason, "end_turn")

        emits = Enum.map(updates, fn update -> "      emit '#{update}'" end)
        response = ~s|      emit "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":$prompt_id,\\"result\\":{\\"stopReason\\":\\"#{stop}\\"}}"|

        (emits ++ [response, "      exit 0"])
        |> Enum.join("\n")
    end
  end
end
