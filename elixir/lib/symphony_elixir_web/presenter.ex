defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying)
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms, %{}) do
      {:ok, payload, _transcript_cache} -> {:ok, payload}
      error -> error
    end
  end

  # Cache-aware variant used by the live detail page. `transcript_cache` holds the
  # parsed transcript blocks for the session log keyed on the file's
  # `{mtime, size}` stamp, so the dashboard's per-event broadcasts don't re-read
  # and re-parse the whole transcript when the file hasn't changed (e.g. a
  # completed session, or a reload triggered by some *other* issue streaming).
  # Returns the (possibly updated) cache for the caller to hold onto.
  @spec issue_payload(String.t(), GenServer.name(), timeout(), map()) ::
          {:ok, map(), map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms, transcript_cache)
      when is_binary(issue_identifier) and is_map(transcript_cache) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) do
          {:error, :issue_not_found}
        else
          {body, new_cache} = issue_payload_body(issue_identifier, running, retry, transcript_cache)
          {:ok, body, new_cache}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry, transcript_cache) do
    {transcript, new_transcript_cache} = transcript_payload(running || retry, transcript_cache)

    body = %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      title: title_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry),
        host: workspace_host(running, retry)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      agent: agent_payload(running || retry || %{}),
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        codex_session_logs: codex_session_logs_payload(running, retry)
      },
      transcript: transcript,
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }

    {body, new_transcript_cache}
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp title_from_entries(running, retry),
    do: (running && Map.get(running, :title)) || (retry && Map.get(retry, :title))

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: Map.get(entry, :title),
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      agent: agent_payload(entry),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      recent_events: recent_events_payload(entry),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      },
      context: context_payload(entry)
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: Map.get(entry, :title),
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      agent: agent_payload(running),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      recent_events: recent_events_payload(running),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      },
      context: context_payload(running)
    }
  end

  # The actual backend + model the run is using, captured from the running
  # session (not re-derived from the issue's labels). `backend` is the resolved
  # backend module's config name; `model` is what was handed to/reported by the
  # agent (nil when unknown, e.g. Codex picks its model from its own config).
  defp agent_payload(entry) when is_map(entry) do
    %{
      backend: blank_to_nil(Map.get(entry, :backend)),
      model: blank_to_nil(Map.get(entry, :model))
    }
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp context_payload(entry) do
    tokens = Map.get(entry, :codex_context_tokens, 0)
    window = Map.get(entry, :codex_context_window)

    %{
      tokens: tokens,
      window: window,
      fill_ratio: context_fill_ratio(tokens, window)
    }
  end

  defp context_fill_ratio(tokens, window)
       when is_integer(tokens) and is_integer(window) and window > 0 do
    Float.round(min(tokens / window, 1.0), 4)
  end

  defp context_fill_ratio(_tokens, _window), do: nil

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp codex_session_logs_payload(running, retry) do
    logs =
      (running && Map.get(running, :codex_session_logs)) ||
        (retry && Map.get(retry, :codex_session_logs)) ||
        []

    Enum.map(logs, &codex_session_log_payload/1)
  end

  defp recent_events_payload(running) do
    running
    |> Map.get(:recent_codex_events, [])
    |> Enum.map(&recent_event_payload/1)
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp recent_event_payload(%{timestamp: timestamp, event: event} = message) do
    %{
      at: iso8601(timestamp),
      event: to_string(event),
      message: summarize_message(message)
    }
  end

  defp recent_event_payload(_message), do: %{at: nil, event: nil, message: nil}

  defp codex_session_log_payload(log_entry) when is_map(log_entry) do
    %{
      session_id: Map.get(log_entry, :session_id),
      path: Map.get(log_entry, :path),
      started_at: iso8601(Map.get(log_entry, :started_at)),
      last_event_at: iso8601(Map.get(log_entry, :last_event_at)),
      worker_host: Map.get(log_entry, :worker_host),
      workspace_path: Map.get(log_entry, :workspace_path)
    }
  end

  defp transcript_payload(entry, transcript_cache) when is_map(entry) do
    case latest_session_log_entry(entry) do
      %{path: path} = log_entry when is_binary(path) ->
        {blocks, new_cache} = transcript_blocks_for_entry(entry, path, transcript_cache)

        {%{
           session_id: Map.get(log_entry, :session_id),
           path: path,
           started_at: iso8601(Map.get(log_entry, :started_at)),
           last_event_at: iso8601(Map.get(log_entry, :last_event_at)),
           blocks: blocks
         }, new_cache}

      _ ->
        {%{session_id: nil, path: nil, started_at: nil, last_event_at: nil, blocks: []}, transcript_cache}
    end
  end

  defp transcript_payload(_entry, transcript_cache),
    do: {%{session_id: nil, path: nil, started_at: nil, last_event_at: nil, blocks: []}, transcript_cache}

  defp latest_session_log_entry(entry) do
    entry
    |> Map.get(:codex_session_logs, [])
    |> Enum.max_by(
      fn log_entry ->
        Map.get(log_entry, :last_event_at) || Map.get(log_entry, :started_at) || ~U[1970-01-01 00:00:00Z]
      end,
      fn -> nil end
    )
  end

  # The details page shows the full session transcript from the persisted log —
  # the *entire* history, for running entries too, not just completed ones. The
  # orchestrator's in-memory `recent_codex_transcript_blocks` is a small ring
  # buffer (kept lean so it's cheap to ship in every snapshot); it only holds the
  # most recent blocks, so reading it here would drop older entries as new ones
  # stream in. The on-disk log is the complete history, so prefer it and fall
  # back to the in-memory buffer only before the log exists (e.g. pre-`session_id`
  # events that aren't persisted yet).
  #
  # Re-parsing the whole log on every dashboard broadcast would be wasteful, so
  # the parsed blocks are memoized on the file's `{mtime, size}` stamp: an
  # unchanged file is served straight from `transcript_cache` without a re-read.
  defp transcript_blocks_for_entry(entry, path, transcript_cache)
       when is_map(entry) and is_binary(path) and is_map(transcript_cache) do
    case transcript_file_stamp(path) do
      {:ok, stamp} ->
        case Map.get(transcript_cache, path) do
          {^stamp, blocks} ->
            {blocks, transcript_cache}

          _ ->
            case load_transcript_blocks(path) do
              blocks when is_list(blocks) and blocks != [] ->
                # Replace the cache wholesale (single entry) so it never holds
                # blocks for a stale path — keeps per-connection memory bounded.
                {blocks, %{path => {stamp, blocks}}}

              _ ->
                {ring_buffer_blocks(entry), transcript_cache}
            end
        end

      :error ->
        {ring_buffer_blocks(entry), transcript_cache}
    end
  end

  defp ring_buffer_blocks(entry),
    do: entry |> Map.get(:recent_codex_transcript_blocks) |> List.wrap()

  defp transcript_file_stamp(path) when is_binary(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime, size: size}} -> {:ok, {mtime, size}}
      {:error, _reason} -> :error
    end
  end

  # Reads and parses the entire persisted session log. The on-disk log is the
  # complete history, so we deliberately read all of it — no byte/line/block
  # window — and never drop older entries. Callers memoize the result on the
  # file's stamp (see `transcript_blocks_for_entry/3`) to avoid re-parsing an
  # unchanged file on every dashboard refresh.
  defp load_transcript_blocks(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&transcript_record/1)
        |> Enum.reject(&is_nil/1)
        # `transcript_fragment/1` may yield a single fragment, nil, or a list
        # (an ACP `tool_call_update` produces both a tool and an output fragment).
        |> Enum.flat_map(fn record -> record |> transcript_fragment() |> List.wrap() end)
        |> merge_transcript_fragments()

      {:error, _reason} ->
        []
    end
  end

  defp load_transcript_blocks(_path), do: []

  defp transcript_record(line) when is_binary(line) do
    line
    |> String.trim()
    |> case do
      "" ->
        nil

      content ->
        case Jason.decode(content) do
          {:ok, payload} when is_map(payload) -> payload
          _ -> nil
        end
    end
  end

  defp transcript_fragment(%{"payload" => %{} = payload} = record) do
    method = map_value(payload, ["method"])
    at = Map.get(record, "at")
    origin = transcript_origin(payload, parent_thread_from_session_id(Map.get(record, "session_id")))

    cond do
      method in ["codex/event/agent_message_content_delta", "codex/event/agent_message_delta", "item/agentMessage/delta"] ->
        build_text_fragment("agent", at, extract_text(payload, agent_text_paths()), origin)

      method in ["codex/event/exec_command_output_delta", "item/commandExecution/outputDelta"] ->
        build_text_fragment("output", at, extract_text(payload, output_text_paths()), origin)

      method == "codex/event/exec_command_begin" ->
        build_text_fragment("command", at, extract_command(payload), origin)

      method in reasoning_methods() ->
        build_text_fragment("reasoning", at, extract_text(payload, reasoning_text_paths()), origin)

      method == "item/tool/call" ->
        build_tool_fragment(at, payload, origin)

      method in ["item/started", "item/completed"] ->
        codex_item_fragments(method, at, payload, origin)

      method == "thread/compacted" ->
        build_compaction_fragment(at, payload, origin)

      # Native ACP streaming notifications (Option B): dispatch on the
      # `update.sessionUpdate` discriminator so tool kinds and plans render.
      method == "session/update" ->
        build_acp_fragment(at, payload, origin)

      true ->
        nil
    end
  end

  defp transcript_fragment(_record), do: nil

  defp build_acp_fragment(at, payload, origin) do
    update = acp_update(payload)

    case map_value(update, ["sessionUpdate"]) do
      "agent_message_chunk" ->
        build_text_fragment("agent", at, acp_chunk_text(update), origin)

      "agent_thought_chunk" ->
        build_text_fragment("reasoning", at, acp_chunk_text(update), origin)

      "tool_call" ->
        build_acp_tool_fragment(at, update, origin)

      "tool_call_update" ->
        acp_tool_update_fragments(at, update, origin)

      "plan" ->
        build_acp_plan_fragment(at, update, origin)

      _ ->
        nil
    end
  end

  defp acp_update(payload) do
    case map_value(payload, ["params", "update"]) do
      %{} = update -> update
      _ -> %{}
    end
  end

  defp acp_chunk_text(update) when is_map(update), do: acp_content_text(Map.get(update, "content"))
  defp acp_chunk_text(_update), do: nil

  defp acp_content_text(%{"content" => nested}), do: acp_content_text(nested)
  defp acp_content_text(%{"text" => text}) when is_binary(text), do: text

  defp acp_content_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.map(&acp_content_text/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.join("")
  end

  defp acp_content_text(_content), do: nil

  defp build_acp_tool_fragment(at, update, origin) do
    Map.merge(
      %{
        kind: "tool",
        at: at,
        tool_call_id: acp_tool_call_id(update),
        title: acp_tool_title(update),
        text: normalize_transcript_text(acp_tool_arguments(update))
      },
      origin
    )
  end

  # See `Orchestrator.acp_tool_update_blocks/3`: a `tool_call_update` carries the
  # cumulative state of an in-flight tool call. Refresh the arguments and emit
  # the latest output, both keyed on `toolCallId` so `merge_transcript_fragments/1`
  # updates the existing fragments in place instead of duplicating them.
  defp acp_tool_update_fragments(at, update, origin) do
    [
      acp_tool_args_fragment(at, update, origin),
      acp_tool_output_fragment(at, update, origin)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp acp_tool_args_fragment(at, update, origin) do
    case acp_tool_arguments(update) do
      "" -> nil
      _args -> build_acp_tool_fragment(at, update, origin)
    end
  end

  defp acp_tool_output_fragment(at, update, origin) do
    case build_text_fragment("output", at, acp_chunk_text(update), origin) do
      nil -> nil
      fragment -> Map.put(fragment, :tool_call_id, acp_tool_call_id(update))
    end
  end

  defp acp_tool_call_id(update), do: presence(Map.get(update, "toolCallId"))

  defp acp_tool_title(update) do
    kind = presence(Map.get(update, "kind"))
    title = presence(Map.get(update, "title"))

    cond do
      kind && title && String.downcase(kind) == String.downcase(title) -> title
      kind && title -> "#{kind}: #{title}"
      title -> title
      kind -> kind
      true -> "tool"
    end
  end

  defp acp_tool_arguments(update) do
    case Map.get(update, "rawInput") do
      nil -> ""
      input -> format_tool_arguments(input)
    end
  end

  defp build_acp_plan_fragment(at, update, origin) do
    case acp_plan_text(update) do
      "" -> nil
      text -> Map.merge(%{kind: "plan", at: at, text: text}, origin)
    end
  end

  defp acp_plan_text(update) do
    update
    |> Map.get("entries", [])
    |> List.wrap()
    |> Enum.map(&acp_plan_entry/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp acp_plan_entry(%{"content" => content} = entry) when is_binary(content) do
    "#{acp_plan_marker(Map.get(entry, "status"))} #{String.trim(content)}"
  end

  defp acp_plan_entry(_entry), do: nil

  defp acp_plan_marker("completed"), do: "- [x]"
  defp acp_plan_marker("in_progress"), do: "- [~]"
  defp acp_plan_marker(_status), do: "- [ ]"

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp build_tool_fragment(at, payload, origin) when is_map(payload) do
    {name, args_text} = extract_tool(payload)
    Map.merge(%{kind: "tool", at: at, title: name, text: normalize_transcript_text(args_text)}, origin)
  end

  # Codex reports each tool call's lifecycle as an `item/started` then an
  # `item/completed` notification. The streamed deltas handled above already
  # cover the agent-message, reasoning and command *output* items, but the call
  # itself — the command line, the file diff, the MCP/web-search/subagent
  # invocation — only ever arrives inside these item events. Without rendering
  # them the details page showed orphaned command output with no command above
  # it, and surfaced no MCP/web/subagent tool calls at all. `dynamicToolCall` is
  # intentionally skipped: it is the Symphony-provided tool the app-server
  # dispatches via `item/tool/call`, already rendered by `build_tool_fragment/3`.
  defp codex_item_fragments(method, at, payload, origin) do
    with %{} = item <- map_value(payload, ["params", "item"]),
         type when is_binary(type) <- Map.get(item, "type") do
      codex_item_fragment(method, type, at, item, presence(Map.get(item, "id")), origin)
    else
      _ -> nil
    end
  end

  defp codex_item_fragment("item/started", "commandExecution", at, item, _id, origin),
    do: build_text_fragment("command", at, codex_command_text(item), origin)

  defp codex_item_fragment("item/started", "fileChange", at, item, id, origin),
    do: codex_item_tool_fragment(at, id, codex_file_change_title(item), codex_file_change_text(item), origin)

  defp codex_item_fragment("item/started", "collabAgentToolCall", at, item, id, origin),
    do: codex_item_tool_fragment(at, id, codex_collab_tool_title(item), codex_collab_tool_text(item), origin)

  defp codex_item_fragment("item/started", "webSearch", at, item, id, origin),
    do: codex_item_tool_fragment(at, id, "web_search", presence(Map.get(item, "query")), origin)

  defp codex_item_fragment("item/started", "mcpToolCall", at, item, id, origin),
    do: codex_item_tool_fragment(at, id, codex_mcp_tool_title(item), codex_mcp_args_text(item), origin)

  # The MCP result only lands on `item/completed`; emit it as an output block
  # keyed on the call id so it sits beside the tool block from `item/started`.
  defp codex_item_fragment("item/completed", "mcpToolCall", at, item, id, origin),
    do: codex_mcp_output_fragment(at, id, item, origin)

  defp codex_item_fragment(_method, _type, _at, _item, _id, _origin), do: nil

  defp codex_item_tool_fragment(at, id, title, text, origin) do
    fragment = Map.merge(%{kind: "tool", at: at, title: title, text: normalize_transcript_text(text || "")}, origin)
    if is_binary(id), do: Map.put(fragment, :tool_call_id, id), else: fragment
  end

  defp codex_command_text(item) do
    case Map.get(item, "command") do
      command when is_binary(command) -> "$ #{String.trim(command)}"
      _ -> nil
    end
  end

  defp codex_file_change_title(item) do
    case codex_file_change_paths(item) do
      [] -> "edit"
      [path] -> "edit: #{Path.basename(path)}"
      paths -> "edit: #{length(paths)} files"
    end
  end

  defp codex_file_change_paths(item) do
    item
    |> Map.get("changes", [])
    |> List.wrap()
    |> Enum.map(&Map.get(&1, "path"))
    |> Enum.filter(&is_binary/1)
  end

  defp codex_file_change_text(item) do
    item
    |> Map.get("changes", [])
    |> List.wrap()
    |> Enum.map(&codex_file_change_entry/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> truncate_tool_text()
  end

  defp codex_file_change_entry(%{"path" => path} = change) when is_binary(path) do
    case Map.get(change, "diff") do
      diff when is_binary(diff) -> "#{path}\n#{diff}"
      _ -> path
    end
  end

  defp codex_file_change_entry(_change), do: nil

  defp codex_collab_tool_title(item), do: presence(Map.get(item, "tool")) || "agent"

  defp codex_collab_tool_text(item) do
    case presence(Map.get(item, "prompt")) do
      nil -> nil
      prompt -> truncate_tool_text(prompt)
    end
  end

  defp codex_mcp_tool_title(item) do
    tool = presence(Map.get(item, "tool")) || "tool"

    case presence(Map.get(item, "server")) do
      nil -> tool
      server -> "#{server}: #{tool}"
    end
  end

  defp codex_mcp_args_text(item) do
    case Map.get(item, "arguments") do
      nil -> ""
      arguments -> format_tool_arguments(arguments)
    end
  end

  defp codex_mcp_output_fragment(at, id, item, origin) do
    with text when is_binary(text) and text != "" <- codex_mcp_result_text(item),
         fragment when is_map(fragment) <- build_text_fragment("output", at, truncate_tool_text(text), origin) do
      if is_binary(id), do: Map.put(fragment, :tool_call_id, id), else: fragment
    else
      _ -> nil
    end
  end

  defp codex_mcp_result_text(item) do
    case codex_mcp_error_text(item) do
      nil -> item |> Map.get("result") |> codex_mcp_content_text()
      error -> "Error: #{error}"
    end
  end

  defp codex_mcp_error_text(item) do
    case Map.get(item, "error") do
      error when is_binary(error) -> presence(error)
      %{} = error -> presence(inspect(error))
      _ -> nil
    end
  end

  defp codex_mcp_content_text(%{"content" => content}), do: acp_content_text(content)
  defp codex_mcp_content_text(_result), do: nil

  defp build_text_fragment(kind, at, text, origin) when is_binary(kind) and is_binary(text) do
    case normalize_transcript_text(text) do
      "" -> nil
      normalized -> Map.merge(%{kind: kind, at: at, text: normalized}, origin)
    end
  end

  defp build_text_fragment(_kind, _at, _text, _origin), do: nil

  defp build_compaction_fragment(at, payload, origin) when is_map(payload) do
    Map.merge(
      %{
        kind: "compaction",
        at: at,
        text: compaction_text(payload)
      },
      origin
    )
  end

  defp compaction_text(payload) when is_map(payload) do
    case string_path_value(payload, ["params", "turnId"]) || string_path_value(payload, ["params", "turn_id"]) do
      turn_id when is_binary(turn_id) and byte_size(turn_id) >= 8 ->
        "Context compacted for turn #{short_identifier(turn_id)}."

      _ ->
        "Context compacted."
    end
  end

  defp short_identifier(identifier) when is_binary(identifier) and byte_size(identifier) > 8,
    do: binary_part(identifier, 0, 8)

  defp short_identifier(identifier) when is_binary(identifier), do: identifier

  # Each event carries its thread (`params.threadId`); the session's own thread is
  # the first UUID of `session_id` ("<thread>-<turn>"). Anything else is a subagent.
  defp transcript_origin(payload, parent_thread_id) do
    event_thread_id = event_thread_id(payload)
    %{thread_id: event_thread_id, subagent: subagent_thread?(event_thread_id, parent_thread_id)}
  end

  defp event_thread_id(payload) when is_map(payload) do
    string_path_value(payload, ["params", "threadId"]) || string_path_value(payload, ["params", "thread_id"])
  end

  defp string_path_value(value, []), do: value

  defp string_path_value(map, [key | rest]) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      nil -> nil
      nested -> string_path_value(nested, rest)
    end
  end

  defp string_path_value(_map, _path), do: nil

  defp subagent_thread?(event_thread_id, parent_thread_id)
       when is_binary(event_thread_id) and is_binary(parent_thread_id),
       do: event_thread_id != parent_thread_id

  defp subagent_thread?(_event_thread_id, _parent_thread_id), do: false

  defp parent_thread_from_session_id(session_id)
       when is_binary(session_id) and byte_size(session_id) >= 73 do
    if binary_part(session_id, 36, 1) == "-", do: binary_part(session_id, 0, 36), else: nil
  end

  defp parent_thread_from_session_id(_session_id), do: nil

  defp merge_transcript_fragments(fragments) when is_list(fragments) do
    fragments
    |> Enum.reduce([], fn fragment, acc ->
      cond do
        # ACP tool/output fragments resend cumulative state per update; replace
        # the matching fragment in place (keyed on `tool_call_id`) so arguments
        # fill in and cumulative output isn't concatenated into itself.
        keyed_fragment?(fragment) ->
          upsert_keyed_fragment(acc, fragment)

        mergeable_text_head?(acc, fragment) ->
          [previous | rest] = acc
          [%{previous | text: previous.text <> fragment.text} | rest]

        true ->
          [fragment | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp mergeable_text_head?([%{kind: kind, thread_id: prev_thread} | _rest], fragment) do
    kind == fragment.kind and kind in ["agent", "output", "reasoning"] and
      prev_thread == fragment.thread_id and not keyed_fragment?(fragment)
  end

  defp mergeable_text_head?(_acc, _fragment), do: false

  defp keyed_fragment?(%{kind: kind, tool_call_id: id}) when kind in ["tool", "output"] and is_binary(id),
    do: true

  defp keyed_fragment?(_fragment), do: false

  defp upsert_keyed_fragment(acc, %{kind: kind, tool_call_id: id} = fragment) do
    if Enum.any?(acc, &keyed_fragment_match?(&1, kind, id)) do
      # Only the text changes between updates; keep the title/timestamp the
      # initial `tool_call` established (see `Orchestrator.upsert_keyed_transcript_block/4`).
      Enum.map(acc, &refresh_keyed_fragment(&1, kind, id, fragment.text))
    else
      [fragment | acc]
    end
  end

  defp refresh_keyed_fragment(fragment, kind, id, text) do
    if keyed_fragment_match?(fragment, kind, id), do: %{fragment | text: text}, else: fragment
  end

  defp keyed_fragment_match?(%{kind: kind, tool_call_id: id}, kind, id), do: true
  defp keyed_fragment_match?(_fragment, _kind, _id), do: false

  defp agent_text_paths do
    [
      ["params", "msg", "content"],
      ["params", "msg", "delta"],
      ["params", "delta"],
      ["params", "text"],
      ["params", "content"]
    ]
  end

  defp output_text_paths do
    [
      ["params", "msg", "content"],
      ["params", "msg", "delta"],
      ["params", "delta"],
      ["params", "output"],
      ["params", "content"]
    ]
  end

  defp reasoning_methods do
    [
      "codex/event/agent_reasoning_delta",
      "codex/event/reasoning_content_delta",
      "codex/event/agent_reasoning",
      "item/reasoning/textDelta",
      "item/reasoning/summaryTextDelta"
    ]
  end

  defp reasoning_text_paths do
    [
      ["params", "textDelta"],
      ["params", "summaryText"],
      ["params", "delta"],
      ["params", "msg", "content"],
      ["params", "text"],
      ["params", "content"]
    ]
  end

  defp extract_text(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      case map_value(payload, path) do
        text when is_binary(text) -> text
        _ -> nil
      end
    end)
  end

  defp extract_command(payload) when is_map(payload) do
    [
      ["params", "msg", "command"],
      ["params", "command"],
      ["params", "cmd"]
    ]
    |> Enum.find_value(fn path ->
      case map_value(payload, path) do
        command when is_binary(command) -> "$ #{String.trim(command)}"
        _ -> nil
      end
    end)
  end

  defp extract_tool(payload) when is_map(payload) do
    name =
      tool_name_value(map_value(payload, ["params", "tool"])) ||
        tool_name_value(map_value(payload, ["params", "name"])) ||
        "tool"

    args_text =
      case map_value(payload, ["params", "arguments"]) do
        nil -> ""
        args -> format_tool_arguments(args)
      end

    {name, args_text}
  end

  defp tool_name_value(name) when is_binary(name), do: name
  defp tool_name_value(_name), do: nil

  defp format_tool_arguments(args) when is_binary(args), do: truncate_tool_text(args)
  defp format_tool_arguments(args) when is_map(args) and map_size(args) == 0, do: ""

  defp format_tool_arguments(args),
    do: args |> inspect(pretty: true, limit: :infinity, width: 100) |> truncate_tool_text()

  @max_tool_argument_chars 4_000
  defp truncate_tool_text(text) when is_binary(text) do
    if String.length(text) > @max_tool_argument_chars do
      String.slice(text, 0, @max_tool_argument_chars) <> "\n… [truncated]"
    else
      text
    end
  end

  defp normalize_transcript_text(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.replace(~r/\x1B\[[0-9;]*[A-Za-z]/, "")
    |> String.replace(~r/\x1B./, "")
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
  end

  defp map_value(value, []), do: value

  defp map_value(map, [key | rest]) when is_map(map) do
    case fetch_either_key(map, key) do
      {:ok, nested} -> map_value(nested, rest)
      :error -> nil
    end
  end

  defp map_value(_map, _path), do: nil

  # Look a key up under both string and atom representations without bouncing
  # between them (the previous mutual recursion infinite-looped on absent keys).
  defp fetch_either_key(map, key) when is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> fetch_existing_atom_key(map, key)
    end
  end

  defp fetch_either_key(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp fetch_existing_atom_key(map, key) do
    Map.fetch(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> :error
  end

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
