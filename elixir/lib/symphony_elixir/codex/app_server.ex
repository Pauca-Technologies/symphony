defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  @behaviour SymphonyElixir.AgentBackend

  require Logger
  alias SymphonyElixir.{AgentTransport, Codex.DynamicTool, Config, PathSafety, SSH}

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @interruption_log_bytes 500
  @post_completion_audit_attempts 80
  @post_completion_audit_sleep_ms 25
  @interruption_markers [
    "<turn_aborted>",
    "aborted by user",
    "interrupted by user",
    "turn_aborted",
    "turn/aborted",
    "turn/interrupted"
  ]
  # Methods that end a turn. A terminal event whose turn id differs from the
  # turn we started belongs to a subagent thread multiplexed onto the same
  # app-server connection — see `handle_incoming/7`.
  @turn_terminal_methods [
    "turn/completed",
    "turn/failed",
    "turn/cancelled",
    "turn/aborted",
    "turn/interrupted"
  ]
  @non_interactive_tool_input_answer "This is a non-interactive session. Operator input is unavailable."
  @linear_save_issue_denial_tool "save issue"
  @source_env_pattern ~r/(?:^|[\s;&|('"])(?:\.|source)\s+(?:"([^"]+)"|'([^']+)'|([^\s;&|]+))/
  # Same vars the Claude/ACP paths scrub; the agent reaches Linear only through
  # the gated dynamic tool, which holds the token server-side. Unlike those
  # backends, `codex app-server` inherits the parent env, so without this scrub
  # the agent could curl Linear directly and bypass the handoff gate.
  @linear_credential_env_vars [
    ~c"LINEAR_API_KEY",
    ~c"LINEAR_TOKEN",
    ~c"LINEAR_API_TOKEN",
    ~c"LINEAR_ACCESS_TOKEN"
  ]

  @type session :: %{
          port: port(),
          metadata: map(),
          model: String.t() | nil,
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          thread_path: Path.t() | nil,
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil
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

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         :ok <- prepare_sourced_env_files(expanded_workspace, worker_host),
         {:ok, port} <- start_port(expanded_workspace, worker_host) do
      metadata = port_metadata(port, worker_host)

      with {:ok, session_policies} <- session_policies(expanded_workspace, worker_host),
           {:ok, thread} <- do_start_session(port, expanded_workspace, session_policies) do
        thread_id = Map.fetch!(thread, :id)

        {:ok,
         %{
           port: port,
           metadata: metadata,
           model: Map.get(thread, :model),
           approval_policy: session_policies.approval_policy,
           auto_approve_requests: session_policies.approval_policy == "never",
           thread_path: Map.get(thread, :path),
           thread_sandbox: session_policies.thread_sandbox,
           turn_sandbox_policy: session_policies.turn_sandbox_policy,
           thread_id: thread_id,
           workspace: expanded_workspace,
           worker_host: worker_host
         }}
      else
        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          approval_policy: approval_policy,
          auto_approve_requests: auto_approve_requests,
          model: model,
          turn_sandbox_policy: turn_sandbox_policy,
          thread_id: thread_id,
          thread_path: thread_path,
          workspace: workspace
        },
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments)
      end)

    case start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
      {:ok, turn_id} ->
        session_id = "#{thread_id}-#{turn_id}"
        Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")

        emit_message(
          on_message,
          :session_started,
          %{
            session_id: session_id,
            thread_id: thread_id,
            turn_id: turn_id,
            model: model
          },
          metadata
        )

        case await_turn_completion(port, on_message, turn_id, tool_executor, auto_approve_requests) do
          {:ok, result} ->
            handle_turn_success(
              result,
              thread_path,
              thread_id,
              turn_id,
              session_id,
              issue,
              on_message,
              metadata
            )

          {:error, reason} ->
            Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

            emit_message(
              on_message,
              :turn_ended_with_error,
              %{
                session_id: session_id,
                reason: reason
              },
              metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, reason}
    end
  end

  defp handle_turn_success(
         result,
         thread_path,
         thread_id,
         turn_id,
         session_id,
         issue,
         on_message,
         metadata
       ) do
    case post_completion_turn_audit(thread_path, turn_id) do
      :ok ->
        Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

        {:ok,
         %{
           result: result,
           session_id: session_id,
           thread_id: thread_id,
           turn_id: turn_id
         }}

      {:error, reason} ->
        Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

        emit_message(
          on_message,
          :turn_ended_with_error,
          %{
            session_id: session_id,
            reason: reason
          },
          metadata
        )

        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp start_port(workspace, nil) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(AgentTransport.with_pre_command(Config.settings!().codex.command))],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes,
            # Mark this process as the inner agent so consumer-repo hooks can
            # tell "Symphony is running me as the agent" from "Symphony is
            # running me as an outer hook". UDP's before-handoff Stop hook
            # reads both vars and skips when SYMPHONY_RUN=1 AND SYMPHONY_AGENT=1.
            # See docs/symphony.md in the consumer repo.
            env: agent_env()
          ]
        )

      {:ok, port}
    end
  end

  defp start_port(workspace, worker_host) when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp agent_env do
    base = [
      {~c"SYMPHONY_RUN", ~c"1"},
      {~c"SYMPHONY_AGENT", ~c"1"}
    ]

    if Config.settings!().codex.withhold_linear_credentials do
      # A `false` value tells Port.open's `env:` option to unset the variable in
      # the child, so the agent cannot inherit Linear creds and bypass the gate.
      base ++ Enum.map(@linear_credential_env_vars, &{&1, false})
    else
      base
    end
  end

  defp prepare_sourced_env_files(workspace, nil) when is_binary(workspace) do
    # Sanitize `.env` files sourced by either the codex command or the global
    # `agent.pre_command` (when pre_command is unset this is the codex command
    # alone — byte-for-byte unchanged).
    [Config.settings!().codex.command, AgentTransport.pre_command()]
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&sourced_env_files(&1, workspace))
    |> Enum.uniq()
    |> Enum.each(&sanitize_sourced_env_file(&1, workspace))

    :ok
  end

  defp prepare_sourced_env_files(_workspace, worker_host) when is_binary(worker_host), do: :ok

  defp sourced_env_files(command, workspace) when is_binary(command) and is_binary(workspace) do
    @source_env_pattern
    |> Regex.scan(command)
    |> Enum.map(fn [_match | captures] -> Enum.find(captures, &(&1 != "")) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&String.ends_with?(&1, ".env"))
    |> Enum.map(&Path.expand(&1, workspace))
    |> Enum.uniq()
    |> Enum.filter(&workspace_file?(&1, workspace))
  end

  defp sanitize_sourced_env_file(path, workspace) do
    with true <- File.regular?(path),
         {:ok, content} <- File.read(path),
         {:ok, sanitized_content, removed_count} <- sanitize_shell_env_content(content),
         true <- sanitized_content != content,
         :ok <- File.write(path, sanitized_content) do
      Logger.warning("Sanitized sourced env file before Codex startup workspace=#{workspace} path=#{path} removed_lines=#{removed_count}")
    else
      _ -> :ok
    end
  end

  defp sanitize_shell_env_content(content) when is_binary(content) do
    lines = String.split(content, "\n", trim: false)

    {sanitized_lines, removed_count, assignment_count} =
      Enum.reduce(lines, {[], 0, 0}, fn line, {kept, removed, assignments} ->
        cond do
          shell_env_assignment_line?(line) ->
            {[line | kept], removed, assignments + 1}

          shell_env_ignored_line?(line) ->
            {[line | kept], removed, assignments}

          true ->
            {kept, removed + 1, assignments}
        end
      end)

    if removed_count > 0 and assignment_count > 0 do
      {:ok, sanitized_lines |> Enum.reverse() |> Enum.join("\n"), removed_count}
    else
      :skip
    end
  end

  defp shell_env_assignment_line?(line) when is_binary(line) do
    String.match?(line, ~r/^\s*(?:export\s+)?[A-Za-z_][A-Za-z0-9_]*=/)
  end

  defp shell_env_ignored_line?(line) when is_binary(line) do
    trimmed = String.trim_leading(line)
    trimmed == "" or String.starts_with?(trimmed, "#")
  end

  defp workspace_file?(path, workspace) do
    with {:ok, canonical_path} <- PathSafety.canonicalize(path),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace) do
      String.starts_with?(canonical_path <> "/", canonical_workspace <> "/")
    else
      _ -> false
    end
  end

  defp remote_launch_command(workspace) when is_binary(workspace) do
    # SSH does not forward our local env, so the inner-agent markers have to
    # be inlined into the remote shell command. Matches `agent_env/0` for the
    # local Port.open path.
    #
    # SSH does not carry our local `{var, false}` scrub either, and the remote
    # worker host may itself have Linear creds in its shell env that
    # `codex app-server` would inherit. Prepend an `unset` step (mirroring the
    # local scrub) so remote runs can't bypass the gate. When withholding is
    # off the command is byte-for-byte unchanged from today.
    [
      "cd #{shell_escape(workspace)}",
      remote_unset_linear_credentials(),
      "export SYMPHONY_RUN=1",
      "export SYMPHONY_AGENT=1",
      AgentTransport.with_pre_command("exec #{Config.settings!().codex.command}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp remote_unset_linear_credentials do
    if Config.settings!().codex.withhold_linear_credentials do
      vars = Enum.map_join(@linear_credential_env_vars, " ", &to_string/1)
      "unset #{vars}"
    end
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp send_initialize(port) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    with {:ok, _} <- await_response(port, @initialize_id) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp session_policies(workspace, nil) do
    Config.codex_runtime_settings(workspace)
  end

  defp session_policies(workspace, worker_host) when is_binary(worker_host) do
    Config.codex_runtime_settings(workspace, remote: true)
  end

  defp do_start_session(port, workspace, session_policies) do
    case send_initialize(port) do
      :ok -> start_thread(port, workspace, session_policies)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_thread(port, workspace, %{approval_policy: approval_policy, thread_sandbox: thread_sandbox}) do
    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => %{
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "cwd" => workspace,
        "dynamicTools" => DynamicTool.tool_specs()
      }
    })

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => thread_payload} = response} ->
        case thread_payload do
          %{"id" => thread_id} ->
            {:ok,
             %{
               id: thread_id,
               path: Map.get(thread_payload, "path"),
               model: Map.get(response, "model")
             }}

          _ ->
            {:error, {:invalid_thread_payload, thread_payload}}
        end

      other ->
        other
    end
  end

  defp start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => %{
        "threadId" => thread_id,
        "input" => [
          %{
            "type" => "text",
            "text" => prompt
          }
        ],
        "cwd" => workspace,
        "title" => "#{issue.identifier}: #{issue.title}",
        "approvalPolicy" => approval_policy,
        "sandboxPolicy" => turn_sandbox_policy
      }
    })

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp await_turn_completion(port, on_message, turn_id, tool_executor, auto_approve_requests) do
    receive_loop(
      port,
      on_message,
      turn_id,
      Config.settings!().codex.turn_timeout_ms,
      "",
      tool_executor,
      auto_approve_requests
    )
  end

  # `turn_id` is the id of the turn this loop started (`turn/start` response).
  # Subagents spawned by the agent run as child threads multiplexed onto the
  # same app-server connection, so their `turn/{completed,failed,cancelled}`
  # notifications arrive here too. We only terminate on a terminal event for
  # *our* turn — see `handle_incoming/7` — so the first subagent to finish is
  # not mistaken for the parent turn completing.
  defp receive_loop(port, on_message, turn_id, timeout_ms, pending_line, tool_executor, auto_approve_requests) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_incoming(port, on_message, turn_id, complete_line, timeout_ms, tool_executor, auto_approve_requests)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          turn_id,
          timeout_ms,
          pending_line <> to_string(chunk),
          tool_executor,
          auto_approve_requests
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_incoming(port, on_message, turn_id, data, timeout_ms, tool_executor, auto_approve_requests) do
    payload_string = to_string(data)
    decoded = Jason.decode(payload_string)

    if foreign_turn_terminal_event?(decoded, turn_id) do
      # A subagent thread finished on the shared connection. Stream it for
      # observability, but keep waiting for our own turn rather than tearing the
      # session down on the first subagent to complete.
      handle_foreign_turn_event(decoded, payload_string, port, on_message, turn_id, timeout_ms, tool_executor, auto_approve_requests)
    else
      dispatch_incoming(decoded, payload_string, port, on_message, turn_id, timeout_ms, tool_executor, auto_approve_requests)
    end
  end

  # A turn-terminal event whose turn id differs from the one we started: it
  # belongs to a subagent thread on the shared connection, not our turn.
  defp foreign_turn_terminal_event?(
         {:ok, %{"method" => method, "params" => %{"turn" => %{"id" => event_turn_id}}}},
         turn_id
       )
       when is_binary(turn_id) and is_binary(event_turn_id) do
    event_turn_id != turn_id and method in @turn_terminal_methods
  end

  defp foreign_turn_terminal_event?(_decoded, _turn_id), do: false

  # NOTE: only *terminal* foreign-turn events are routed here. A subagent's
  # non-terminal events (agent-message/tool/output deltas) flow through the normal
  # `dispatch_incoming/8` path, but each carries its own `params.threadId`. The
  # observability transcript pipeline (Orchestrator/Presenter) distinguishes
  # subagent turns by comparing that thread to the session's parent thread (the
  # leading UUID of `session_id`), so no extra tagging is needed here.
  defp handle_foreign_turn_event({:ok, payload}, payload_string, port, on_message, turn_id, timeout_ms, tool_executor, auto_approve_requests) do
    method = Map.get(payload, "method")
    event_turn_id = get_in(payload, ["params", "turn", "id"])

    Logger.debug("Codex foreign-turn #{method} ignored (subagent) turn_id=#{event_turn_id} parent_turn_id=#{turn_id}")

    emit_message(
      on_message,
      :subagent_turn_event,
      %{payload: payload, raw: payload_string, method: method, turn_id: event_turn_id},
      metadata_from_message(port, payload)
    )

    receive_loop(port, on_message, turn_id, timeout_ms, "", tool_executor, auto_approve_requests)
  end

  defp dispatch_incoming(decoded, payload_string, port, on_message, turn_id, timeout_ms, tool_executor, auto_approve_requests) do
    case decoded do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        handle_turn_completed(on_message, payload, payload_string, port)

      {:ok, %{"method" => "turn/failed", "params" => _} = payload} ->
        maybe_emit_interruption_signal(
          on_message,
          "turn/failed",
          payload,
          payload_string,
          metadata_from_message(port, payload)
        )

        emit_turn_event(
          on_message,
          :turn_failed,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_failed, Map.get(payload, "params")}}

      {:ok, %{"method" => "turn/cancelled", "params" => _} = payload} ->
        maybe_emit_interruption_signal(
          on_message,
          "turn/cancelled",
          payload,
          payload_string,
          metadata_from_message(port, payload)
        )

        emit_turn_event(
          on_message,
          :turn_cancelled,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_cancelled, Map.get(payload, "params")}}

      {:ok, %{"method" => method} = payload}
      when is_binary(method) ->
        handle_turn_method(
          port,
          on_message,
          turn_id,
          payload,
          payload_string,
          timeout_ms,
          tool_executor,
          auto_approve_requests
        )

      {:ok, payload} ->
        emit_message(
          on_message,
          :other_message,
          %{
            payload: payload,
            raw: payload_string
          },
          metadata_from_message(port, payload)
        )

        receive_loop(port, on_message, turn_id, timeout_ms, "", tool_executor, auto_approve_requests)

      {:error, _reason} ->
        log_non_json_stream_line(payload_string, "turn stream")

        if protocol_message_candidate?(payload_string) do
          emit_message(
            on_message,
            :malformed,
            %{
              payload: payload_string,
              raw: payload_string
            },
            metadata_from_message(port, %{raw: payload_string})
          )
        end

        receive_loop(port, on_message, turn_id, timeout_ms, "", tool_executor, auto_approve_requests)
    end
  end

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload)
    )
  end

  defp handle_turn_completed(on_message, payload, payload_string, port) do
    metadata = metadata_from_message(port, payload)
    maybe_emit_interruption_signal(on_message, "turn/completed", payload, payload_string, metadata)

    case abnormal_turn_completion_reason(payload) do
      nil ->
        emit_turn_event(on_message, :turn_completed, payload, payload_string, port, payload)
        {:ok, :turn_completed}

      reason ->
        emit_message(
          on_message,
          :turn_completed_abnormally,
          %{
            payload: payload,
            raw: payload_string,
            details: reason
          },
          metadata
        )

        {:error, {:turn_completed_abnormally, reason}}
    end
  end

  defp handle_turn_method(
         port,
         on_message,
         turn_id,
         payload,
         payload_string,
         timeout_ms,
         tool_executor,
         auto_approve_requests
       ) do
    method = Map.get(payload, "method")
    metadata = metadata_from_message(port, payload)

    case maybe_handle_approval_request(
           port,
           method,
           payload,
           payload_string,
           on_message,
           metadata,
           tool_executor,
           auto_approve_requests
         ) do
      :input_required ->
        emit_message(
          on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      :approved ->
        receive_loop(port, on_message, turn_id, timeout_ms, "", tool_executor, auto_approve_requests)

      :approval_required ->
        emit_message(
          on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      :unhandled ->
        handle_unhandled_turn_method(%{
          port: port,
          on_message: on_message,
          turn_id: turn_id,
          payload: payload,
          payload_string: payload_string,
          method: method,
          metadata: metadata,
          timeout_ms: timeout_ms,
          tool_executor: tool_executor,
          auto_approve_requests: auto_approve_requests
        })
    end
  end

  defp handle_unhandled_turn_method(
         %{
           method: method,
           payload: payload,
           on_message: on_message,
           payload_string: payload_string,
           metadata: metadata
         } = context
       ) do
    if needs_input?(method, payload) do
      emit_message(
        on_message,
        :turn_input_required,
        %{payload: payload, raw: payload_string},
        metadata
      )

      {:error, {:turn_input_required, payload}}
    else
      handle_unhandled_notification(context)
    end
  end

  defp handle_unhandled_notification(%{
         port: port,
         on_message: on_message,
         turn_id: turn_id,
         payload: payload,
         payload_string: payload_string,
         method: method,
         metadata: metadata,
         timeout_ms: timeout_ms,
         tool_executor: tool_executor,
         auto_approve_requests: auto_approve_requests
       }) do
    case maybe_emit_interruption_signal(on_message, method, payload, payload_string, metadata) do
      {:interrupted, details} ->
        {:error, {:turn_interruption_signal, details}}

      :ok ->
        emit_message(
          on_message,
          :notification,
          %{
            payload: payload,
            raw: payload_string
          },
          metadata
        )

        Logger.debug("Codex notification: #{inspect(method)}")
        receive_loop(port, on_message, turn_id, timeout_ms, "", tool_executor, auto_approve_requests)
    end
  end

  defp maybe_emit_interruption_signal(on_message, method, payload, payload_string, metadata) do
    if interruption_signal?(method, payload, payload_string) do
      summary = interruption_summary(method, payload_string)
      Logger.warning("Codex interruption signal method=#{inspect(method)} summary=#{summary}")

      emit_message(
        on_message,
        :turn_interruption_signal,
        %{
          payload: payload,
          raw: payload_string,
          summary: summary
        },
        metadata
      )

      {:interrupted, %{method: method, summary: summary, payload: payload}}
    else
      :ok
    end
  end

  defp interruption_signal?(method, payload, payload_string) do
    method in ["turn/aborted", "turn/interrupted"] ||
      abnormal_turn_status?(turn_status_type(payload)) ||
      payload_string
      |> String.downcase()
      |> String.contains?(@interruption_markers)
  end

  defp abnormal_turn_completion_reason(payload) when is_map(payload) do
    status_type = turn_status_type(payload)

    if abnormal_turn_status?(status_type) do
      %{
        status_type: status_type,
        status: turn_status(payload),
        turn: map_at_path(payload, ["params", "turn"]) || map_at_path(payload, [:params, :turn])
      }
    end
  end

  defp abnormal_turn_status?(status_type) when is_binary(status_type) do
    status_type
    |> String.downcase()
    |> then(&(&1 in ["aborted", "cancelled", "canceled", "failed", "interrupted"]))
  end

  defp abnormal_turn_status?(_status_type), do: false

  defp turn_status_type(payload) when is_map(payload) do
    case turn_status(payload) do
      %{"type" => type} when is_binary(type) -> type
      %{type: type} when is_binary(type) -> type
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  defp turn_status(payload) when is_map(payload) do
    map_at_path(payload, ["params", "turn", "status"]) ||
      map_at_path(payload, [:params, :turn, :status]) ||
      map_at_path(payload, ["params", "status"]) ||
      map_at_path(payload, [:params, :status]) ||
      Map.get(payload, "status") ||
      Map.get(payload, :status)
  end

  defp interruption_summary(method, payload_string) do
    excerpt =
      payload_string
      |> interruption_excerpt()
      |> String.replace(~r/\s+/, " ")
      |> String.slice(0, @interruption_log_bytes)

    "#{method}: #{excerpt}"
  end

  defp interruption_excerpt(payload_string) do
    normalized_payload = String.downcase(payload_string)

    case interruption_marker_match(normalized_payload) do
      {index, _length} ->
        start = max(index - 120, 0)
        String.slice(payload_string, start, @interruption_log_bytes)

      nil ->
        String.slice(payload_string, 0, @interruption_log_bytes)
    end
  end

  defp interruption_marker_match(normalized_payload) do
    Enum.find_value(@interruption_markers, fn marker ->
      match = :binary.match(normalized_payload, marker)
      if match == :nomatch, do: nil, else: match
    end)
  end

  defp maybe_handle_approval_request(
         port,
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         tool_executor,
         _auto_approve_requests
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    result =
      tool_name
      |> tool_executor.(arguments)
      |> normalize_dynamic_tool_result()

    send_message(port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: %{result: observable_dynamic_tool_result(result)}
      },
      metadata
    )

    :approved
  end

  defp maybe_handle_approval_request(
         port,
         "execCommandApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "applyPatchApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    :unhandled
  end

  defp normalize_dynamic_tool_result(%{"success" => success} = result) when is_boolean(success) do
    output =
      case Map.get(result, "output") do
        existing_output when is_binary(existing_output) -> existing_output
        _ -> dynamic_tool_output(result)
      end

    content_items =
      case Map.get(result, "contentItems") do
        existing_items when is_list(existing_items) -> existing_items
        _ -> dynamic_tool_content_items(output)
      end

    result
    |> Map.put("output", output)
    |> Map.put("contentItems", content_items)
  end

  defp normalize_dynamic_tool_result(result) do
    %{
      "success" => false,
      "output" => inspect(result),
      "contentItems" => dynamic_tool_content_items(inspect(result))
    }
  end

  defp observable_dynamic_tool_result(result) do
    result
    |> Map.take(["success", "output"])
    |> Map.update("output", nil, &decode_dynamic_tool_output/1)
  end

  defp decode_dynamic_tool_output(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> output
    end
  end

  defp decode_dynamic_tool_output(output), do: output

  defp dynamic_tool_output(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text), do: text
  defp dynamic_tool_output(result), do: Jason.encode!(result, pretty: true)

  defp dynamic_tool_content_items(output) when is_binary(output) do
    [
      %{
        "type" => "inputText",
        "text" => output
      }
    ]
  end

  defp approve_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    emit_message(
      on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: decision},
      metadata
    )

    :approved
  end

  defp approve_or_require(
         _port,
         _id,
         _decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ) do
    :approval_required
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, answers, decision} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: decision},
          metadata
        )

        :approved

      :error ->
        reply_with_non_interactive_tool_input_answer(
          port,
          id,
          params,
          payload,
          payload_string,
          on_message,
          metadata
        )
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         false
       ) do
    reply_with_non_interactive_tool_input_answer(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata
    )
  end

  defp tool_request_user_input_approval_answers(%{"questions" => questions}) when is_list(questions) do
    result =
      Enum.reduce_while(questions, {%{}, []}, fn question, {answer_acc, decision_acc} ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label, decision} ->
            answers = Map.put(answer_acc, question_id, %{"answers" => [answer_label]})
            {:cont, {answers, [decision | decision_acc]}}

          :error ->
            {:halt, :error}
        end
      end)

    case result do
      :error -> :error
      {answer_map, decisions} when map_size(answer_map) > 0 -> {:ok, answer_map, approval_decision(decisions)}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp reply_with_non_interactive_tool_input_answer(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata
       ) do
    case tool_request_user_input_unavailable_answers(params) do
      {:ok, answers} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :tool_input_auto_answered,
          %{payload: payload, raw: payload_string, answer: @non_interactive_tool_input_answer},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp tool_request_user_input_unavailable_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_question_id(question) do
          {:ok, question_id} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [@non_interactive_tool_input_answer]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map}
      _ -> :error
    end
  end

  defp tool_request_user_input_unavailable_answers(_params), do: :error

  defp tool_request_user_input_question_id(%{"id" => question_id}) when is_binary(question_id),
    do: {:ok, question_id}

  defp tool_request_user_input_question_id(_question), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options} = question)
       when is_binary(question_id) and is_list(options) do
    if deny_linear_save_issue_request?(question) do
      case tool_request_user_input_deny_option_label(options) do
        nil -> :error
        answer_label -> {:ok, question_id, answer_label, answer_label}
      end
    else
      case tool_request_user_input_approval_option_label(options) do
        nil -> :error
        answer_label -> {:ok, question_id, answer_label, answer_label}
      end
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp approval_decision(decisions) do
    if Enum.any?(decisions, &(&1 == "Deny")), do: "Deny", else: "Approve this Session"
  end

  defp deny_linear_save_issue_request?(%{"question" => question, "options" => options})
       when is_binary(question) and is_list(options) do
    normalized_question =
      question
      |> String.downcase()
      |> String.replace(~r/\s+/, " ")

    String.contains?(normalized_question, "linear mcp server") and
      String.contains?(normalized_question, @linear_save_issue_denial_tool) and
      is_binary(tool_request_user_input_deny_option_label(options))
  end

  defp deny_linear_save_issue_request?(_question), do: false

  defp tool_request_user_input_deny_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.find(&(&1 == "Deny"))
  end

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or String.starts_with?(normalized_label, "allow")
  end

  defp await_response(port, request_id) do
    with_timeout_response(port, request_id, Config.settings!().codex.read_timeout_ms, "")
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp post_completion_turn_audit(thread_path, turn_id) when is_binary(thread_path) and is_binary(turn_id) do
    case find_session_turn_aborted(thread_path, turn_id, @post_completion_audit_attempts) do
      {:ok, nil} ->
        :ok

      {:ok, payload} ->
        {:error, {:turn_aborted, payload}}

      {:error, reason} ->
        Logger.debug("Codex session post-completion audit skipped path=#{thread_path} reason=#{inspect(reason)}")
        :ok
    end
  end

  defp post_completion_turn_audit(_thread_path, _turn_id), do: :ok

  defp find_session_turn_aborted(thread_path, turn_id, attempts_left) do
    cond do
      File.regular?(thread_path) ->
        thread_path
        |> read_session_turn_aborted(turn_id)
        |> maybe_retry_session_turn_aborted(thread_path, turn_id, attempts_left)

      attempts_left > 0 ->
        Process.sleep(@post_completion_audit_sleep_ms)
        find_session_turn_aborted(thread_path, turn_id, attempts_left - 1)

      true ->
        {:error, :session_log_unavailable}
    end
  rescue
    error -> {:error, {error.__struct__, Exception.message(error)}}
  end

  defp read_session_turn_aborted(thread_path, turn_id) do
    with {:ok, contents} <- File.read(thread_path) do
      payload =
        contents
        |> String.split("\n", trim: true)
        |> Enum.find_value(&decode_turn_aborted_event(&1, turn_id))

      {:ok, payload}
    end
  end

  defp maybe_retry_session_turn_aborted({:ok, nil}, thread_path, turn_id, attempts_left)
       when attempts_left > 0 do
    Process.sleep(@post_completion_audit_sleep_ms)
    find_session_turn_aborted(thread_path, turn_id, attempts_left - 1)
  end

  defp maybe_retry_session_turn_aborted(result, _thread_path, _turn_id, _attempts_left), do: result

  defp decode_turn_aborted_event(line, turn_id) do
    case Jason.decode(line) do
      {:ok, %{"type" => "event_msg", "payload" => %{"type" => "turn_aborted", "turn_id" => ^turn_id} = payload}} ->
        payload

      _ ->
        nil
    end
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp metadata_from_message(port, payload) do
    port |> port_metadata(nil) |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp map_at_path(payload, keys) when is_map(payload) and is_list(keys) do
    Enum.reduce_while(keys, payload, fn key, acc ->
      case acc do
        map when is_map(map) -> {:cont, Map.get(map, key)}
        _ -> {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _keys), do: nil

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") || Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp tool_call_arguments(_params), do: %{}

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end
