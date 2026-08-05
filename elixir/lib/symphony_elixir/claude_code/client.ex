defmodule SymphonyElixir.ClaudeCode.Client do
  @moduledoc """
  Native Claude Code backend — drives `claude -p` in headless stream-json mode
  (`docs/acp-support-plan.md` §14).

  Claude Code's non-interactive interface is `claude --print` with
  `--input-format stream-json` / `--output-format stream-json`: line-framed JSON
  over stdio, the same transport family as the Codex app-server and ACP. This is
  Claude Code itself, no bridge process. Each Symphony turn writes one user
  message line to stdin and reads the streamed `system` / `assistant` /
  `tool_use` / `tool_result` events until the terminal `result` message carries
  the stop reason.

  Conforms to `SymphonyElixir.AgentBackend` and emits the same `on_message`
  event vocabulary as the other backends (§2.2). Streamed events are normalized
  into Symphony's existing transcript shape (Option A, §6) by synthesizing the
  Codex `payload["method"]` the orchestrator already understands — so the
  dashboard/CLI renderer needs no Claude-specific code (the same synthetic
  methods the ACP backend emits).

  ## Linear tools and handoff gate

  Reuses the ACP work wholesale. Symphony's server-authenticated Linear tools
  are served by an in-VM MCP HTTP endpoint (`SymphonyElixir.Acp.LinearGate`)
  advertised to Claude Code via `--mcp-config` (HTTP server, first-class) +
  `--strict-mcp-config` (so the agent uses *only* that server — an explicit
  lock, stronger than the ACP
  path's implicit "we just didn't pass a Linear MCP"). Tool calls dispatch back
  into *this* process — the one running `run_turn/4` — so
  `SymphonyElixir.Codex.DynamicTool` runs the before_handoff + reviewer gates
  with the run's `handoff_gate_context` and process-dictionary state intact. The
  hard guarantee is credential withholding: the agent env is scrubbed of Linear
  tokens (`claude_code.withhold_linear_credentials`), so the gate holds even if
  the agent ignores guidance (§5.5, §14.3).
  """

  @behaviour SymphonyElixir.AgentBackend

  require Logger

  alias SymphonyElixir.Acp.LinearGate
  alias SymphonyElixir.{AgentTransport, Codex.DynamicTool, Config, Telemetry, TestWorkerBudget}

  # Same vars the ACP path scrubs; the agent reaches Linear only through the
  # gated MCP tools, which hold the token server-side.
  @linear_credential_env_vars [
    ~c"LINEAR_API_KEY",
    ~c"LINEAR_TOKEN",
    ~c"LINEAR_API_TOKEN",
    ~c"LINEAR_ACCESS_TOKEN"
  ]

  @type session :: %{
          port: port(),
          session_id: String.t() | nil,
          worker_host: String.t() | nil,
          gate: LinearGate.t(),
          claude_code: map(),
          workspace: Path.t(),
          metadata: map()
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @impl true
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    overrides = Keyword.get(opts, :overrides, %{})

    with {:ok, base_cc} <- Config.claude_code_runtime_settings(),
         cc = apply_overrides(base_cc, overrides),
         {:ok, expanded_workspace} <- AgentTransport.validate_workspace_cwd(workspace, worker_host),
         :ok <- AgentTransport.prepare_sourced_env_files(expanded_workspace, worker_host, cc.command) do
      maybe_warn_remote_gate(worker_host)

      start_agent_session(
        expanded_workspace,
        worker_host,
        cc,
        Keyword.get(opts, :issue_context_file)
      )
    end
  end

  # Merge per-task overrides (e.g. %{model: ...} from an agent.label_presets
  # entry) over the config-derived settings. Empty overrides ⇒ identical to the
  # global-config path. Claude Code takes the model as a native `--model` flag.
  defp apply_overrides(cc, overrides) when is_map(overrides) do
    Map.merge(cc, Map.take(overrides, [:model]))
  end

  defp apply_overrides(cc, _overrides), do: cc

  @impl true
  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{port: port} = session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments)
      end)

    AgentTransport.send_message(port, user_message(prompt))
    Logger.info("Claude Code prompt sent for #{issue_context(issue)}")

    loop_state = %{
      session: session,
      on_message: on_message,
      tool_executor: tool_executor,
      pending: "",
      session_started?: false,
      session_id: session.session_id,
      deadline: System.monotonic_time(:millisecond) + session.claude_code.prompt_timeout_ms
    }

    case receive_loop(loop_state) do
      {:ok, result} ->
        Logger.info("Claude Code turn completed for #{issue_context(issue)} session_id=#{result.session_id} stop_reason=#{result.stop_reason}")
        {:ok, result}

      {:error, reason} ->
        Logger.warning("Claude Code turn ended with error for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(session, on_message, :turn_ended_with_error, %{reason: reason})
        {:error, reason}
    end
  end

  @impl true
  @spec stop_session(session() | map()) :: :ok
  def stop_session(%{port: port} = session) do
    if is_port(port), do: AgentTransport.stop_port(port)
    LinearGate.stop(Map.get(session, :gate))
    :ok
  end

  def stop_session(_session), do: :ok

  # ── session bring-up ──────────────────────────────────────────────────────
  #
  # Unlike ACP there is no `initialize`/`session/new` handshake on the wire:
  # `claude -p` waits on stdin and emits its `system/init` (with the session id)
  # only after the first user message. So `start_session` just spawns the port;
  # the session id is discovered per-turn from the stream.

  defp start_agent_session(workspace, worker_host, cc, issue_context_file) do
    case LinearGate.start(session_pid: self()) do
      {:ok, gate} -> start_agent_port(workspace, worker_host, cc, gate, issue_context_file)
      {:error, reason} -> {:error, {:gate_start_failed, reason}}
    end
  end

  defp start_agent_port(workspace, worker_host, cc, gate, issue_context_file) do
    command = build_command(cc, workspace, gate)

    case AgentTransport.start_port(
           workspace,
           worker_host,
           command,
           agent_env(cc, issue_context_file)
         ) do
      {:ok, port} ->
        {:ok,
         %{
           port: port,
           session_id: nil,
           worker_host: worker_host,
           gate: gate,
           claude_code: cc,
           workspace: workspace,
           metadata: AgentTransport.port_metadata(port, worker_host)
         }}

      {:error, reason} ->
        LinearGate.stop(gate)
        {:error, reason}
    end
  end

  # ── command construction ────────────────────────────────────────────────────

  defp build_command(cc, workspace, gate) do
    base = String.trim(cc.command)

    flags =
      [
        "-p",
        "--output-format",
        "stream-json",
        "--input-format",
        "stream-json",
        "--verbose",
        "--permission-mode",
        cc.permission_mode,
        "--add-dir",
        workspace,
        "--mcp-config",
        mcp_config_json(gate),
        "--strict-mcp-config"
      ] ++ model_flags(cc) ++ (cc.extra_args || [])

    Enum.join([base | Enum.map(flags, &shell_escape/1)], " ")
  end

  defp model_flags(%{model: model}) when is_binary(model) do
    case String.trim(model) do
      "" -> []
      trimmed -> ["--model", trimmed]
    end
  end

  defp model_flags(_cc), do: []

  # `--mcp-config` accepts an inline JSON string. Point it at the in-VM gated
  # Linear endpoint; `--strict-mcp-config` (added in build_command) makes Claude
  # ignore every other MCP source.
  defp mcp_config_json(%{url: url, server_name: server_name}) do
    Jason.encode!(%{
      "mcpServers" => %{server_name => %{"type" => "http", "url" => url}}
    })
  end

  defp user_message(prompt) do
    %{
      "type" => "user",
      "message" => %{
        "role" => "user",
        "content" => [%{"type" => "text", "text" => prompt}]
      }
    }
  end

  # ── turn receive loop ───────────────────────────────────────────────────────

  defp receive_loop(%{session: %{port: port}} = state) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = state.pending <> to_string(chunk)
        dispatch_line(%{state | pending: ""}, line)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(%{state | pending: state.pending <> to_string(chunk)})

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}

      {:acp_tool_call, ref, from, tool_name, arguments} ->
        result = state.tool_executor.(tool_name, arguments)
        send(from, {:acp_tool_result, ref, result})
        receive_loop(state)
    after
      receive_timeout(state) ->
        if turn_deadline_passed?(state), do: {:error, :turn_timeout}, else: {:error, :turn_stalled}
    end
  end

  defp receive_timeout(%{deadline: deadline, session: %{claude_code: cc}}) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))
    stall = cc.stall_timeout_ms

    if stall > 0, do: min(stall, remaining), else: remaining
  end

  defp turn_deadline_passed?(%{deadline: deadline}) do
    System.monotonic_time(:millisecond) >= deadline
  end

  defp dispatch_line(state, line) do
    case Jason.decode(line) do
      {:ok, decoded} ->
        dispatch_message(state, decoded, line)

      {:error, _reason} ->
        log_non_json_line(line)
        receive_loop(state)
    end
  end

  # The terminal `result` message ends the turn and carries the stop reason.
  defp dispatch_message(state, %{"type" => "result"} = result, raw) do
    finish_turn(state, result, raw)
  end

  defp dispatch_message(state, %{"type" => "system", "subtype" => "init"} = message, _raw) do
    session_id = Map.get(message, "session_id")
    state = %{state | session_id: session_id || state.session_id}

    state =
      if state.session_started? do
        state
      else
        # `system/init` reports the model Claude actually resolved — surface it so
        # the dashboard shows the real model, not just whatever was configured.
        emit_message(state.session, state.on_message, :session_started, %{
          session_id: session_id,
          model: Map.get(message, "model")
        })

        %{state | session_started?: true}
      end

    receive_loop(state)
  end

  # `thinking_tokens` is a high-frequency token counter with no transcript
  # value; drop it to avoid spamming the event log.
  defp dispatch_message(state, %{"type" => "system", "subtype" => "thinking_tokens"}, _raw) do
    receive_loop(state)
  end

  defp dispatch_message(state, %{"type" => "assistant", "message" => message}, raw)
       when is_map(message) do
    emit_content_blocks(state, Map.get(message, "content"), raw)
    receive_loop(state)
  end

  defp dispatch_message(state, %{"type" => "user", "message" => message}, raw)
       when is_map(message) do
    emit_content_blocks(state, Map.get(message, "content"), raw)
    receive_loop(state)
  end

  # Any other event (rate_limit_event, other system subtypes, …): forward as a
  # generic notification for fidelity; the transcript pipeline ignores unknown
  # methods, so it never renders a spurious block.
  defp dispatch_message(state, message, raw) do
    emit_message(state.session, state.on_message, :notification, %{payload: message, raw: raw})
    receive_loop(state)
  end

  # ── content-block normalization (Option A) ──────────────────────────────────

  defp emit_content_blocks(state, blocks, raw) when is_list(blocks) do
    Enum.each(blocks, &emit_content_block(state, &1, raw))
  end

  defp emit_content_blocks(_state, _blocks, _raw), do: :ok

  defp emit_content_block(state, %{"type" => _} = block, raw) do
    case synthetic_payload(block, state.session_id) do
      nil -> :ok
      payload -> emit_message(state.session, state.on_message, :notification, %{payload: payload, raw: raw})
    end
  end

  defp emit_content_block(_state, _block, _raw), do: :ok

  defp synthetic_payload(%{"type" => "text", "text" => text}, session_id) when is_binary(text) do
    text_payload("item/agentMessage/delta", "delta", text, session_id)
  end

  defp synthetic_payload(%{"type" => "thinking", "thinking" => text}, session_id) when is_binary(text) do
    text_payload("item/reasoning/textDelta", "textDelta", text, session_id)
  end

  # Claude's planning surfaces through the `TodoWrite` builtin tool. Render it as
  # a plan checklist — the same `session/update`/`plan` block the ACP backend
  # feeds the transcript pipeline — instead of a raw tool-call args dump. Each
  # entry `status` (pending/in_progress/completed) already matches the plan
  # block's expected statuses.
  defp synthetic_payload(%{"type" => "tool_use", "name" => "TodoWrite", "input" => %{"todos" => todos}}, session_id)
       when is_list(todos) do
    %{
      "method" => "session/update",
      "params" => %{
        "sessionId" => session_id,
        "update" => %{
          "sessionUpdate" => "plan",
          "entries" => Enum.map(todos, &todo_plan_entry/1)
        }
      }
    }
  end

  defp synthetic_payload(%{"type" => "tool_use"} = block, session_id) do
    call_id = Map.get(block, "id")

    %{
      "method" => "item/tool/call",
      "params" => %{
        "callId" => call_id,
        "itemId" => call_id,
        "name" => to_string(Map.get(block, "name") || "tool"),
        "arguments" => Map.get(block, "input") || %{},
        "threadId" => session_id
      }
    }
  end

  defp synthetic_payload(%{"type" => "tool_result"} = block, session_id) do
    text = tool_result_text(Map.get(block, "content")) || ""
    call_id = Map.get(block, "tool_use_id")
    error? = Map.get(block, "is_error") == true

    case tool_result_output(text, error?) do
      output when is_binary(output) ->
        %{
          "method" => "item/commandExecution/outputDelta",
          "params" => %{
            "callId" => call_id,
            "itemId" => call_id,
            "output" => output,
            "status" => if(error?, do: "failed", else: "completed"),
            "terminal" => true,
            "threadId" => session_id
          }
        }

      _ ->
        nil
    end
  end

  defp synthetic_payload(_block, _session_id), do: nil

  defp todo_plan_entry(todo) when is_map(todo) do
    %{"content" => Map.get(todo, "content"), "status" => Map.get(todo, "status")}
  end

  defp todo_plan_entry(_todo), do: %{}

  # A failed Claude tool (`is_error: true`) would otherwise be indistinguishable
  # from normal output; mark it so it reads as an error in the transcript.
  defp tool_result_output("", true), do: "[tool error]"
  defp tool_result_output("", false), do: nil
  defp tool_result_output(text, true), do: "[tool error] " <> text
  defp tool_result_output(text, false), do: text

  defp text_payload(_method, _key, "", _session_id), do: nil

  defp text_payload(method, key, text, session_id) do
    %{"method" => method, "params" => %{key => text, "threadId" => session_id}}
  end

  # tool_result `content` is a string or a list of `{type:"text", text:...}` blocks.
  defp tool_result_text(text) when is_binary(text), do: text

  defp tool_result_text(blocks) when is_list(blocks) do
    Enum.map_join(blocks, "", fn
      %{"text" => text} when is_binary(text) -> text
      text when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp tool_result_text(_content), do: nil

  # ── turn completion (result) ────────────────────────────────────────────────

  defp finish_turn(state, result, raw) do
    subtype = Map.get(result, "subtype")
    is_error = Map.get(result, "is_error") == true
    stop_reason = Map.get(result, "stop_reason")
    session_id = Map.get(result, "session_id") || state.session_id

    cond do
      is_error or subtype != "success" ->
        abnormal(state, stop_reason || subtype || "error", result, raw, session_id)

      stop_reason in ["max_tokens", "max_turn_requests"] ->
        complete(state, stop_reason, result, raw, session_id, note: stop_reason)

      true ->
        complete(state, stop_reason || "end_turn", result, raw, session_id)
    end
  end

  defp complete(state, stop_reason, result, raw, session_id, opts \\ []) do
    details = %{payload: result, raw: raw, stop_reason: stop_reason}
    details = if note = Keyword.get(opts, :note), do: Map.put(details, :note, note), else: details
    emit_message(state.session, state.on_message, :turn_completed, details)
    {:ok, %{session_id: session_id, stop_reason: stop_reason}}
  end

  defp abnormal(state, stop_reason, result, raw, session_id) do
    emit_message(state.session, state.on_message, :turn_completed_abnormally, %{
      payload: result,
      raw: raw,
      details: %{stop_reason: stop_reason}
    })

    {:error, {:turn_completed_abnormally, %{stop_reason: stop_reason, session_id: session_id}}}
  end

  # ── env / shell ──────────────────────────────────────────────────────────────

  defp agent_env(cc, issue_context_file) do
    base =
      [
        {~c"SYMPHONY_RUN", ~c"1"},
        {~c"SYMPHONY_AGENT", ~c"1"}
      ] ++ TestWorkerBudget.port_env() ++ issue_context_env(issue_context_file)

    if cc.withhold_linear_credentials do
      base ++ Enum.map(@linear_credential_env_vars, &{&1, false})
    else
      base
    end
  end

  defp issue_context_env(path) when is_binary(path) and path != "" do
    [{~c"SYMPHONY_ISSUE_CONTEXT_FILE", String.to_charlist(path)}]
  end

  defp issue_context_env(_path), do: []

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp maybe_warn_remote_gate(nil), do: :ok

  defp maybe_warn_remote_gate(worker_host) when is_binary(worker_host) do
    Logger.warning(
      "Claude Code backend on a remote worker host (#{worker_host}): the in-VM Linear gate listens on " <>
        "Symphony's loopback, which the remote agent cannot reach. Remote runs are not supported (see docs/claude-code.md)."
    )
  end

  # ── helpers ───────────────────────────────────────────────────────────────────

  defp emit_message(session, on_message, event, details) when is_function(on_message, 1) do
    metadata = message_metadata(session, details)

    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp message_metadata(session, details) do
    base = Map.get(session, :metadata, %{})

    case extract_usage(Map.get(details, :payload)) do
      usage when is_map(usage) -> Map.put(base, :usage, usage)
      _ -> base
    end
  end

  defp extract_usage(%{"message" => %{"usage" => usage}}) when is_map(usage), do: usage
  defp extract_usage(%{"usage" => usage}) when is_map(usage), do: usage
  defp extract_usage(_payload), do: nil

  defp log_non_json_line(line) do
    text = line |> to_string() |> String.trim() |> String.slice(0, 1_000)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Claude Code stream output: #{text}")
      else
        maybe_log_benign_stream(text)
      end
    end
  end

  defp maybe_log_benign_stream(text) do
    if benign_notification_debug?(), do: Logger.debug("Claude Code stream output: #{text}")
  end

  defp benign_notification_debug?, do: Telemetry.benign_notification_debug?()

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp issue_context(_issue), do: "issue_id=n/a issue_identifier=n/a"

  defp default_on_message(_message), do: :ok
end
