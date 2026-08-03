defmodule SymphonyElixir.Acp.Client do
  @moduledoc """
  Agent Client Protocol (ACP) backend.

  Speaks ACP JSON-RPC-over-stdio (`initialize` → `session/new` →
  `session/prompt`, streaming `session/update`, answering
  `session/request_permission`) to an ACP-capable agent such as
  `opencode acp`. Conforms to `SymphonyElixir.AgentBackend` and emits the same
  `on_message` event vocabulary as the Codex app-server backend, so the
  orchestrator/observability pipeline stays backend-agnostic. Streaming
  `session/update` notifications are forwarded verbatim and rendered natively
  by the observability pipeline (`docs/acp-support-plan.md` §2.2, §6 Option B).

  ## Linear tools and handoff gate

  ACP has no `dynamicTools`, so Symphony's server-authenticated Linear tools are
  exposed through an in-VM MCP HTTP endpoint (`SymphonyElixir.Acp.LinearGate`)
  listed in `session/new.mcpServers`. Tool calls route back into *this*
  process — the one running `run_turn/4`, which is `AgentRunner`'s run process
  — so `SymphonyElixir.Codex.DynamicTool` runs the before_handoff + reviewer
  gates with the run's `handoff_gate_context` and process-dictionary state
  intact, exactly as on Codex. The hard guarantee is credential withholding:
  the agent env is scrubbed of Linear tokens and given no native Linear MCP, so
  the gate cannot be routed around even if the agent ignores guidance (§5.5).
  """

  @behaviour SymphonyElixir.AgentBackend

  require Logger

  alias SymphonyElixir.Acp.LinearGate
  alias SymphonyElixir.{AgentTransport, Codex.DynamicTool, Config, Telemetry}

  @initialize_id 1
  @session_new_id 2

  @client_name "symphony-orchestrator"
  @client_version "0.1.0"

  # Linear credential env vars scrubbed from the agent process when
  # `acp.withhold_linear_credentials` is true. The agent reaches Linear only
  # through Symphony's gated MCP tools, which hold the token server-side.
  @linear_credential_env_vars [
    ~c"LINEAR_API_KEY",
    ~c"LINEAR_TOKEN",
    ~c"LINEAR_API_TOKEN",
    ~c"LINEAR_ACCESS_TOKEN"
  ]

  @type session :: %{
          port: port(),
          session_id: String.t(),
          worker_host: String.t() | nil,
          auto_approve: boolean(),
          agent_capabilities: map(),
          gate: LinearGate.t(),
          acp: map(),
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

    with {:ok, base_acp} <- Config.acp_runtime_settings(),
         acp = apply_overrides(base_acp, overrides),
         {:ok, expanded_workspace} <- AgentTransport.validate_workspace_cwd(workspace, worker_host),
         :ok <- AgentTransport.prepare_sourced_env_files(expanded_workspace, worker_host, acp.command) do
      maybe_warn_remote_gate(worker_host)

      start_agent_session(
        expanded_workspace,
        worker_host,
        acp,
        Keyword.get(opts, :issue_context_file)
      )
    end
  end

  # Merge per-task overrides (e.g. %{model: ...} from an agent.label_presets
  # entry) over the config-derived settings. Empty overrides ⇒ identical to the
  # global-config path. Only keys the backend consumes are honored.
  defp apply_overrides(acp, overrides) when is_map(overrides) do
    Map.merge(acp, Map.take(overrides, [:model]))
  end

  defp apply_overrides(acp, _overrides), do: acp

  @impl true
  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{port: port, session_id: session_id} = session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments)
      end)

    prompt_id = next_prompt_id()

    AgentTransport.send_message(port, %{
      "jsonrpc" => "2.0",
      "id" => prompt_id,
      "method" => "session/prompt",
      "params" => %{
        "sessionId" => session_id,
        "prompt" => [%{"type" => "text", "text" => prompt}]
      }
    })

    Logger.info("ACP session prompt sent for #{issue_context(issue)} session_id=#{session_id}")
    emit_message(session, on_message, :session_started, %{session_id: session_id})

    now = System.monotonic_time(:millisecond)

    loop_state = %{
      session: session,
      on_message: on_message,
      prompt_id: prompt_id,
      tool_executor: tool_executor,
      pending: "",
      deadline: now + session.acp.prompt_timeout_ms,
      last_activity: now,
      heartbeats: 0
    }

    case receive_loop(loop_state) do
      {:ok, result} ->
        Logger.info("ACP session completed for #{issue_context(issue)} session_id=#{session_id} stop_reason=#{result.stop_reason}")
        {:ok, result}

      {:error, reason} ->
        Logger.warning("ACP session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")
        emit_message(session, on_message, :turn_ended_with_error, %{session_id: session_id, reason: reason})
        {:error, reason}
    end
  end

  @impl true
  @spec stop_session(session() | map()) :: :ok
  def stop_session(%{port: port} = session) do
    # Best-effort graceful cancel before closing the connection. The agent may
    # already have exited (port closed); never let that crash teardown.
    if is_port(port) and port_alive?(port) and is_binary(Map.get(session, :session_id)) do
      safe_cancel(port, session.session_id)
    end

    if is_port(port), do: AgentTransport.stop_port(port)
    LinearGate.stop(Map.get(session, :gate))
    :ok
  end

  def stop_session(_session), do: :ok

  defp port_alive?(port), do: :erlang.port_info(port) != :undefined

  defp safe_cancel(port, session_id) do
    # Writing to a port whose OS process has already exited delivers an `:epipe`
    # *exit signal* through the port link, which would otherwise kill the run
    # process. Trap exits for the duration of the write so a dead pipe degrades
    # to a drained message instead of a crash.
    was_trapping = Process.flag(:trap_exit, true)

    try do
      AgentTransport.send_message(port, %{
        "jsonrpc" => "2.0",
        "method" => "session/cancel",
        "params" => %{"sessionId" => session_id}
      })
    rescue
      _error -> :ok
    catch
      :exit, _reason -> :ok
    end

    receive do
      {:EXIT, ^port, _reason} -> :ok
    after
      0 -> :ok
    end

    unless was_trapping, do: Process.flag(:trap_exit, false)
    :ok
  end

  # ── session bring-up ────────────────────────────────────────────────────

  defp start_agent_session(workspace, worker_host, acp, issue_context_file) do
    case LinearGate.start(session_pid: self()) do
      {:ok, gate} -> start_agent_port(workspace, worker_host, acp, gate, issue_context_file)
      {:error, reason} -> {:error, {:gate_start_failed, reason}}
    end
  end

  defp start_agent_port(workspace, worker_host, acp, gate, issue_context_file) do
    case AgentTransport.start_port(
           workspace,
           worker_host,
           acp.command,
           agent_env(acp, issue_context_file)
         ) do
      {:ok, port} ->
        finish_session_bringup(workspace, worker_host, acp, gate, port)

      {:error, reason} ->
        LinearGate.stop(gate)
        {:error, reason}
    end
  end

  defp finish_session_bringup(workspace, worker_host, acp, gate, port) do
    metadata = AgentTransport.port_metadata(port, worker_host)

    case handshake(port, workspace, gate, acp) do
      {:ok, session_id, agent_capabilities} ->
        {:ok,
         %{
           port: port,
           session_id: session_id,
           worker_host: worker_host,
           auto_approve: acp.auto_approve,
           agent_capabilities: agent_capabilities,
           gate: gate,
           acp: acp,
           workspace: workspace,
           metadata: metadata
         }}

      {:error, reason} ->
        AgentTransport.stop_port(port)
        LinearGate.stop(gate)
        {:error, reason}
    end
  end

  defp handshake(port, workspace, gate, acp) do
    with :ok <- send_initialize(port, acp),
         {:ok, init_result} <- await_response(port, @initialize_id, acp.read_timeout_ms),
         {:ok, session_id} <- send_session_new(port, workspace, gate, acp) do
      {:ok, session_id, Map.get(init_result, "agentCapabilities", %{})}
    end
  end

  defp send_initialize(port, acp) do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => @initialize_id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => acp.protocol_version,
        "clientCapabilities" => %{
          "fs" => %{
            "readTextFile" => acp.advertise_fs,
            "writeTextFile" => acp.advertise_fs
          },
          "terminal" => acp.advertise_terminal
        },
        "clientInfo" => %{"name" => @client_name, "version" => @client_version}
      }
    }

    true = AgentTransport.send_message(port, payload)
    :ok
  rescue
    ArgumentError -> {:error, :initialize_send_failed}
  end

  defp send_session_new(port, workspace, gate, acp) do
    AgentTransport.send_message(port, %{
      "jsonrpc" => "2.0",
      "id" => @session_new_id,
      "method" => "session/new",
      "params" => %{
        "cwd" => workspace,
        "mcpServers" => [LinearGate.mcp_server_entry(gate)]
      }
    })

    case await_response(port, @session_new_id, acp.read_timeout_ms) do
      {:ok, %{"sessionId" => session_id}} when is_binary(session_id) ->
        {:ok, session_id}

      {:ok, other} ->
        {:error, {:invalid_session_new_result, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── handshake response waiting (matches a specific request id) ───────────

  defp await_response(port, request_id, timeout_ms) do
    with_response(port, request_id, timeout_ms, "")
  end

  defp with_response(port, request_id, timeout_ms, pending) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        handle_response_line(port, request_id, timeout_ms, pending <> to_string(chunk))

      {^port, {:data, {:noeol, chunk}}} ->
        with_response(port, request_id, timeout_ms, pending <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response_line(port, request_id, timeout_ms, line) do
    case Jason.decode(line) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, _other} ->
        with_response(port, request_id, timeout_ms, "")

      {:error, _reason} ->
        log_non_json_line(line)
        with_response(port, request_id, timeout_ms, "")
    end
  end

  # ── turn receive loop ────────────────────────────────────────────────────

  defp receive_loop(%{session: %{port: port}} = state) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = state.pending <> to_string(chunk)
        dispatch_line(%{state | pending: "", last_activity: System.monotonic_time(:millisecond)}, line)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(%{
          state
          | pending: state.pending <> to_string(chunk),
            last_activity: System.monotonic_time(:millisecond)
        })

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}

      {:acp_tool_call, ref, from, tool_name, arguments} ->
        result = state.tool_executor.(tool_name, arguments)
        send(from, {:acp_tool_result, ref, result})
        receive_loop(%{state | last_activity: System.monotonic_time(:millisecond)})
    after
      receive_timeout(state) -> on_idle_timeout(state)
    end
  end

  # The `after` window is sliced to the soonest of: turn deadline, stall
  # deadline (since the last agent output), and the heartbeat interval. When it
  # fires we distinguish a real timeout/stall from "still idle, emit a
  # heartbeat and keep waiting".
  defp on_idle_timeout(state) do
    cond do
      turn_deadline_passed?(state) -> {:error, :turn_timeout}
      stalled?(state) -> {:error, :turn_stalled}
      true -> receive_loop(emit_heartbeat(state))
    end
  end

  defp receive_timeout(%{deadline: deadline, last_activity: last, session: %{acp: acp}}) do
    now = System.monotonic_time(:millisecond)
    turn_remaining = max(0, deadline - now)

    stall_remaining =
      if acp.stall_timeout_ms > 0, do: max(0, acp.stall_timeout_ms - (now - last)), else: turn_remaining

    heartbeat = if acp.heartbeat_ms > 0, do: acp.heartbeat_ms, else: turn_remaining

    Enum.min([turn_remaining, stall_remaining, heartbeat])
  end

  defp stalled?(%{last_activity: last, session: %{acp: %{stall_timeout_ms: stall}}}) do
    stall > 0 and System.monotonic_time(:millisecond) - last >= stall
  end

  # Emit a "still waiting" liveness signal during a silent turn so a model that
  # has gone quiet (e.g. an unreported opencode rate-limit) shows a visible
  # countdown to `stall_timeout_ms` instead of dead air. Renders to no
  # transcript block (unknown method), so it is purely advisory.
  defp emit_heartbeat(%{session: %{acp: %{stall_timeout_ms: stall}} = session, last_activity: last} = state) do
    idle_ms = System.monotonic_time(:millisecond) - last
    count = state.heartbeats + 1

    Logger.info("ACP turn idle #{idle_ms}ms (no agent output) session_id=#{session.session_id} heartbeat=#{count} stall_timeout_ms=#{stall}")

    emit_message(session, state.on_message, :notification, %{
      kind: :idle_heartbeat,
      idle_ms: idle_ms,
      heartbeat: count,
      stall_timeout_ms: stall
    })

    %{state | heartbeats: count}
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

  # The `session/prompt` response carries the turn's stopReason.
  defp dispatch_message(%{prompt_id: id} = state, %{"id" => id, "result" => result}, raw) do
    finish_turn(state, result, raw)
  end

  defp dispatch_message(%{prompt_id: id} = state, %{"id" => id, "error" => error}, raw) do
    emit_message(state.session, state.on_message, :turn_failed, %{payload: error, raw: raw})
    {:error, {:prompt_failed, error}}
  end

  # Agent -> client request: has both id and method.
  defp dispatch_message(state, %{"id" => id, "method" => method} = message, raw)
       when not is_nil(id) and is_binary(method) do
    handle_agent_request(state, id, method, message, raw)
  end

  # session/update streaming notification.
  defp dispatch_message(state, %{"method" => "session/update", "params" => params} = message, raw)
       when is_map(params) do
    handle_session_update(state, message, raw)
    receive_loop(state)
  end

  # Any other notification.
  defp dispatch_message(state, %{"method" => _method} = message, raw) do
    emit_message(state.session, state.on_message, :notification, %{payload: message, raw: raw})
    receive_loop(state)
  end

  defp dispatch_message(state, message, raw) do
    emit_message(state.session, state.on_message, :other_message, %{payload: message, raw: raw})
    receive_loop(state)
  end

  # ── agent -> client requests ─────────────────────────────────────────────

  defp handle_agent_request(state, id, "session/request_permission", message, raw) do
    handle_permission_request(state, id, message, raw)
  end

  defp handle_agent_request(state, id, "fs/" <> _ = method, message, raw) do
    decline_unsupported_request(state, id, method, message, raw)
  end

  defp handle_agent_request(state, id, "terminal/" <> _ = method, message, raw) do
    decline_unsupported_request(state, id, method, message, raw)
  end

  defp handle_agent_request(state, id, method, message, raw) do
    decline_unsupported_request(state, id, method, message, raw)
  end

  defp decline_unsupported_request(state, id, method, message, raw) do
    respond_error(state.session.port, id, -32_601, "Method not supported: #{method}")
    emit_message(state.session, state.on_message, :notification, %{payload: message, raw: raw})
    receive_loop(state)
  end

  defp handle_permission_request(%{session: %{auto_approve: true}} = state, id, message, raw) do
    params = Map.get(message, "params") || %{}
    options = Map.get(params, "options") || []
    tool_call = Map.get(params, "toolCall") || %{}

    {option_id, decision} =
      if linear_write_bypass?(tool_call) do
        {reject_option_id(options), "rejected"}
      else
        {allow_option_id(options), "approved"}
      end

    respond_permission(state.session.port, id, option_id)

    emit_message(state.session, state.on_message, :approval_auto_approved, %{
      payload: message,
      raw: raw,
      decision: decision
    })

    receive_loop(state)
  end

  defp handle_permission_request(%{session: %{auto_approve: false}} = state, _id, message, raw) do
    emit_message(state.session, state.on_message, :approval_required, %{payload: message, raw: raw})
    {:error, {:approval_required, message}}
  end

  defp respond_permission(port, id, option_id) when is_binary(option_id) do
    AgentTransport.send_message(port, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => option_id}}
    })
  end

  defp respond_permission(port, id, _option_id) do
    # No selectable option offered: cancel the request.
    AgentTransport.send_message(port, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"outcome" => %{"outcome" => "cancelled"}}
    })
  end

  defp respond_error(port, id, code, message) do
    AgentTransport.send_message(port, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })
  end

  # Pick an allow-ish option, preferring "always" then "once", then any.
  defp allow_option_id(options) when is_list(options) do
    option_id_by_kind(options, "allow_always") ||
      option_id_by_kind(options, "allow_once") ||
      option_id_matching(options, &allow_kind?/1) ||
      first_option_id(options)
  end

  defp reject_option_id(options) when is_list(options) do
    option_id_by_kind(options, "reject_once") ||
      option_id_by_kind(options, "reject_always") ||
      option_id_matching(options, &reject_kind?/1)
  end

  defp option_id_by_kind(options, kind) do
    Enum.find_value(options, fn
      %{"kind" => ^kind, "optionId" => id} when is_binary(id) -> id
      _ -> nil
    end)
  end

  defp option_id_matching(options, predicate) do
    Enum.find_value(options, fn
      %{"kind" => kind, "optionId" => id} when is_binary(id) -> if predicate.(kind), do: id
      _ -> nil
    end)
  end

  defp first_option_id(options) do
    Enum.find_value(options, fn
      %{"optionId" => id} when is_binary(id) -> id
      _ -> nil
    end)
  end

  defp allow_kind?(kind) when is_binary(kind), do: String.starts_with?(kind, "allow")
  defp allow_kind?(_kind), do: false

  defp reject_kind?(kind) when is_binary(kind), do: String.starts_with?(kind, "reject")
  defp reject_kind?(_kind), do: false

  # Defense-in-depth (§5.5): deny a permission request that targets a native
  # Linear write. Best-effort — credential withholding is the real guarantee.
  defp linear_write_bypass?(tool_call) when is_map(tool_call) do
    text =
      [
        Map.get(tool_call, "title"),
        Map.get(tool_call, "kind"),
        inspect(Map.get(tool_call, "rawInput"))
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(text, "api.linear.app") or
      (String.contains?(text, "linear") and String.contains?(text, "save issue")) or
      (String.contains?(text, "linear") and String.contains?(text, "save_issue"))
  end

  defp linear_write_bypass?(_tool_call), do: false

  # ── turn completion (stopReason) ─────────────────────────────────────────

  defp finish_turn(state, result, raw) do
    stop_reason = Map.get(result, "stopReason")
    classify_stop_reason(state, stop_reason, result, raw)
  end

  defp classify_stop_reason(state, "end_turn", result, raw) do
    complete(state, "end_turn", result, raw)
  end

  defp classify_stop_reason(state, reason, result, raw)
       when reason in ["max_tokens", "max_turn_requests"] do
    complete(state, reason, result, raw, note: reason)
  end

  defp classify_stop_reason(state, "refusal" = reason, result, raw) do
    abnormal(state, reason, result, raw)
  end

  defp classify_stop_reason(state, "cancelled" = reason, result, raw) do
    emit_message(state.session, state.on_message, :turn_interruption_signal, %{
      payload: result,
      raw: raw,
      summary: "session/prompt cancelled"
    })

    abnormal(state, reason, result, raw)
  end

  # Unknown / missing stopReason: tolerant — treat as a completed turn so a new
  # ACP stopReason variant never wedges a healthy run (decoder stays lenient).
  defp classify_stop_reason(state, reason, result, raw) do
    complete(state, reason || "unknown", result, raw, note: reason || "unknown")
  end

  defp complete(state, stop_reason, result, raw, opts \\ []) do
    details = %{payload: result, raw: raw, stop_reason: stop_reason}
    details = if note = Keyword.get(opts, :note), do: Map.put(details, :note, note), else: details
    emit_message(state.session, state.on_message, :turn_completed, details)
    {:ok, %{session_id: state.session.session_id, stop_reason: stop_reason}}
  end

  defp abnormal(state, stop_reason, result, raw) do
    emit_message(state.session, state.on_message, :turn_completed_abnormally, %{
      payload: result,
      raw: raw,
      details: %{stop_reason: stop_reason}
    })

    {:error, {:turn_completed_abnormally, %{stop_reason: stop_reason}}}
  end

  # ── session/update pass-through (Option B: native ACP rendering) ─────────
  #
  # Emit the native ACP `session/update` message verbatim. The observability
  # pipeline (orchestrator/presenter/`CodexSessionLogRenderer`) understands the
  # ACP `update.sessionUpdate` discriminator directly — agent/thought chunks,
  # tool calls (with their ACP `kind`), tool-call output, and `plan` updates —
  # so no Codex method names are synthesized here. This keeps ACP-only data
  # (plans, tool kinds) visible instead of flattening it into a Codex shape.
  # `raw` keeps the real ACP JSON; the Codex/Claude-Code paths are untouched.
  defp handle_session_update(state, message, raw) do
    emit_message(state.session, state.on_message, :notification, %{payload: message, raw: raw})
  end

  # ── env / config ─────────────────────────────────────────────────────────

  defp agent_env(acp, issue_context_file) do
    base =
      [
        {~c"SYMPHONY_RUN", ~c"1"},
        {~c"SYMPHONY_AGENT", ~c"1"}
      ] ++ issue_context_env(issue_context_file) ++ model_env(acp)

    if acp.withhold_linear_credentials do
      base ++ Enum.map(@linear_credential_env_vars, &{&1, false})
    else
      base
    end
  end

  defp issue_context_env(path) when is_binary(path) and path != "" do
    [{~c"SYMPHONY_ISSUE_CONTEXT_FILE", String.to_charlist(path)}]
  end

  defp issue_context_env(_path), do: []

  # OpenCode reads its model from config, not from a flag: `opencode acp` rejects
  # `--model` and ignores OPENCODE_MODEL, but honors inline config via
  # OPENCODE_CONFIG_CONTENT. So `acp.model` is surfaced that way. This is
  # OpenCode-specific; other ACP agents ignore the var and pick the model through
  # their own configuration.
  defp model_env(%{model: model}) when is_binary(model) do
    case String.trim(model) do
      "" -> []
      trimmed -> [{~c"OPENCODE_CONFIG_CONTENT", String.to_charlist(Jason.encode!(%{"model" => trimmed}))}]
    end
  end

  defp model_env(_acp), do: []

  defp maybe_warn_remote_gate(nil), do: :ok

  defp maybe_warn_remote_gate(worker_host) when is_binary(worker_host) do
    Logger.warning(
      "ACP backend on a remote worker host (#{worker_host}): the in-VM Linear gate listens on Symphony's loopback, " <>
        "which the remote agent cannot reach. Remote ACP is not supported in Phase 2 (see docs/acp.md)."
    )
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp next_prompt_id, do: System.unique_integer([:positive, :monotonic]) + 1000

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

  defp extract_usage(payload) when is_map(payload) do
    get_in(payload, ["params", "update", "usage"]) ||
      get_in(payload, ["params", "usage"]) ||
      Map.get(payload, "usage")
  end

  defp extract_usage(_payload), do: nil

  defp log_non_json_line(line) do
    text = line |> to_string() |> String.trim() |> String.slice(0, 1_000)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("ACP stream output: #{text}")
      else
        maybe_log_benign_stream(text)
      end
    end
  end

  defp maybe_log_benign_stream(text) do
    if benign_notification_debug?(), do: Logger.debug("ACP stream output: #{text}")
  end

  defp benign_notification_debug?, do: Telemetry.benign_notification_debug?()

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp issue_context(_issue), do: "issue_id=n/a issue_identifier=n/a"

  defp default_on_message(_message), do: :ok
end
