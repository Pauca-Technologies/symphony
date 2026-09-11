defmodule SymphonyElixir.CodexSessionLogRenderer do
  @moduledoc """
  Renders Codex session NDJSON logs into a readable terminal transcript.
  """

  @type render_option ::
          {:path, Path.t()}
          | {:use_color, boolean()}

  @type render_options :: [render_option()]

  @max_tool_string_lines 6
  @max_tool_string_chars 240
  @max_tool_list_items 8

  @spec render_file(Path.t(), render_options()) :: :ok | {:error, term()}
  def render_file(path, opts \\ []) do
    with {:ok, content} <- File.read(path) do
      path = Path.expand(path)
      IO.write(render_string(content, Keyword.put_new(opts, :path, path)))
      :ok
    end
  end

  @spec render_string(String.t(), render_options()) :: String.t()
  def render_string(content, opts \\ []) when is_binary(content) do
    state =
      content
      |> parse_records()
      |> finalize_state()

    format_document(state, opts)
  end

  defp parse_records(content) do
    Enum.reduce(String.split(content, "\n", trim: true), initial_state(), fn line, state ->
      case decode_record(line) do
        nil -> state
        record -> handle_record(state, record)
      end
    end)
  end

  defp initial_state do
    %{
      session: %{
        session_id: nil,
        issue_identifier: nil,
        workspace_path: nil,
        started_at: nil
      },
      entries: [],
      agent_messages: %{},
      reasoning: %{},
      commands: %{},
      command_output: %{}
    }
  end

  defp decode_record(line) do
    line
    |> String.trim()
    |> case do
      "" ->
        nil

      content ->
        case Jason.decode(content) do
          {:ok, record} when is_map(record) -> record
          _ -> nil
        end
    end
  end

  defp handle_record(state, record) do
    state
    |> capture_session_metadata(record)
    |> maybe_append_event_entry(record)
    |> handle_payload(record)
  end

  defp capture_session_metadata(state, record) do
    session = state.session

    updated =
      session
      |> put_if_missing(:session_id, Map.get(record, "session_id"))
      |> put_if_missing(:issue_identifier, Map.get(record, "issue_identifier"))
      |> put_if_missing(:workspace_path, Map.get(record, "workspace_path"))
      |> put_if_missing(:started_at, Map.get(record, "at"))

    %{state | session: updated}
  end

  defp maybe_append_event_entry(state, %{"event" => event} = record)
       when event in ["turn_failed", "turn_ended_with_error", "startup_failed"] do
    append_entry(state, %{
      kind: :event,
      at: Map.get(record, "at"),
      label: "EVENT",
      text: Map.get(record, "summary") || event
    })
  end

  defp maybe_append_event_entry(state, _record), do: state

  defp handle_payload(state, %{"payload" => %{} = payload} = record) do
    method = Map.get(payload, "method")
    at = Map.get(record, "at")

    dispatch_payload(method, state, at, payload, Map.get(record, "event"))
  end

  defp handle_payload(state, _record), do: state

  defp dispatch_payload("item/started", state, at, payload, _event), do: handle_item_started(state, at, payload)
  defp dispatch_payload("item/completed", state, at, payload, _event), do: handle_item_completed(state, at, payload)
  defp dispatch_payload("thread/compacted", state, at, payload, _event), do: append_compaction_entry(state, at, payload)

  defp dispatch_payload(method, state, at, payload, _event)
       when method in [
              "item/agentMessage/delta",
              "codex/event/agent_message_delta",
              "codex/event/agent_message_content_delta"
            ],
       do: buffer_agent_message(state, at, payload)

  defp dispatch_payload(method, state, at, payload, _event)
       when method in [
              "item/reasoning/textDelta",
              "item/reasoning/summaryTextDelta",
              "item/reasoning/summaryPartAdded",
              "codex/event/agent_reasoning_delta",
              "codex/event/reasoning_content_delta",
              "codex/event/agent_reasoning"
            ],
       do: buffer_reasoning(state, at, payload)

  defp dispatch_payload(method, state, at, payload, _event)
       when method in [
              "item/commandExecution/outputDelta",
              "codex/event/exec_command_output_delta"
            ],
       do: buffer_command_output(state, at, payload)

  defp dispatch_payload(method, state, at, payload, _event)
       when method in [
              "item/tool/requestUserInput",
              "tool/requestUserInput"
            ],
       do: append_input_required_entry(state, at, payload)

  defp dispatch_payload("item/tool/call", state, at, payload, event), do: render_tool_call(state, at, event, payload)

  # Native ACP streaming notifications (Option B). The ACP backend forwards
  # `session/update` verbatim; dispatch on `update.sessionUpdate`. ACP chunks
  # carry no item id and are never flushed by an `item/completed`, so each is
  # appended directly (mirroring the `{nil, delta}` branches above).
  defp dispatch_payload("session/update", state, at, payload, _event), do: handle_acp_update(state, at, payload)

  defp dispatch_payload(_method, state, _at, _payload, _event), do: state

  defp handle_acp_update(state, at, payload) do
    update = acp_update(payload)

    case Map.get(update, "sessionUpdate") do
      "agent_message_chunk" ->
        append_acp_text(state, at, :agent, "AGENT", acp_chunk_text(update))

      "agent_thought_chunk" ->
        append_acp_text(state, at, :reasoning, "REASONING", acp_chunk_text(update))

      "tool_call" ->
        # Emit on the initial call (even with an empty `rawInput`) so the tool's
        # title is captured before arguments stream in via tool_call_update.
        upsert_acp_tool(state, at, update, true)

      "tool_call_update" ->
        state
        |> upsert_acp_tool(at, update, false)
        |> upsert_acp_tool_output(at, update)

      "plan" ->
        append_entry(state, %{kind: :event, at: at, label: "PLAN", text: acp_plan_text(update)})

      _ ->
        state
    end
  end

  defp append_acp_text(state, at, kind, label, text) when is_binary(text) and text != "" do
    append_entry(state, %{kind: kind, at: at, label: label, text: text})
  end

  defp append_acp_text(state, _at, _kind, _label, _text), do: state

  # ACP resends the cumulative state of a tool call on every `tool_call_update`
  # (the initial `tool_call` usually has an empty `rawInput`, and `content` grows
  # as output streams). Key the tool/output entries on `toolCallId` so each
  # update refreshes the same entry in place — arguments fill in and cumulative
  # output isn't concatenated into itself.
  defp upsert_acp_tool(state, at, update, force?) do
    text = acp_tool_args_text(update)

    if is_nil(text) and not force? do
      state
    else
      upsert_acp_entry(state, {:tool, Map.get(update, "toolCallId")}, %{
        kind: :tool,
        at: at,
        label: "TOOL #{acp_tool_title(update)}",
        text: text
      })
    end
  end

  defp upsert_acp_tool_output(state, at, update) do
    case acp_chunk_text(update) do
      text when is_binary(text) and text != "" ->
        upsert_acp_entry(state, {:output, Map.get(update, "toolCallId")}, %{
          kind: :output,
          at: at,
          label: "OUT",
          text: text
        })

      _ ->
        state
    end
  end

  defp acp_tool_args_text(update) do
    case update |> Map.get("rawInput") |> compact_tool_arguments() do
      %{} = compacted when map_size(compacted) > 0 ->
        inspect(compacted, pretty: true, limit: :infinity, width: 100)

      _ ->
        nil
    end
  end

  # Replace the entry sharing this key in place (keeping its position and
  # original timestamp), else prepend a new one. Without a `toolCallId` there is
  # nothing to key on, so just append.
  defp upsert_acp_entry(state, {_kind, nil}, entry), do: append_entry(state, entry)

  defp upsert_acp_entry(state, key, entry) do
    tagged = Map.put(entry, :acp_key, key)
    update_in(state.entries, &merge_acp_entries(&1, key, tagged))
  end

  # Only the text changes between updates; keep the label/timestamp the initial
  # entry established.
  defp merge_acp_entries(entries, key, tagged) do
    if Enum.any?(entries, &(Map.get(&1, :acp_key) == key)) do
      Enum.map(entries, &refresh_acp_entry(&1, key, tagged.text))
    else
      [tagged | entries]
    end
  end

  defp refresh_acp_entry(entry, key, text) do
    if Map.get(entry, :acp_key) == key, do: %{entry | text: text}, else: entry
  end

  defp acp_update(payload) do
    case get_path(payload, ["params", "update"]) do
      %{} = update -> update
      _ -> %{}
    end
  end

  defp acp_chunk_text(update) when is_map(update), do: acp_content_text(Map.get(update, "content"))

  defp acp_content_text(%{"content" => nested}), do: acp_content_text(nested)
  defp acp_content_text(%{"text" => text}) when is_binary(text), do: text

  defp acp_content_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.map(&acp_content_text/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.join("")
  end

  defp acp_content_text(_content), do: nil

  defp acp_tool_title(update) do
    kind = acp_presence(Map.get(update, "kind"))
    title = acp_presence(Map.get(update, "title"))

    cond do
      kind && title -> "#{kind}: #{title}"
      title -> title
      kind -> kind
      true -> "tool"
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

  defp acp_presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp acp_presence(_value), do: nil

  defp handle_item_started(state, at, payload) do
    item = get_path(payload, ["params", "item"]) || %{}
    item_id = Map.get(item, "id")

    case Map.get(item, "type") do
      "commandExecution" when is_binary(item_id) ->
        command = extract_command(item)

        state
        |> put_command(item_id, %{at: at, command: command})
        |> append_entry(%{
          kind: :command,
          at: at,
          label: "CMD",
          text: command
        })

      "userMessage" ->
        append_entry(state, %{
          kind: :user,
          at: at,
          label: "USER",
          text: extract_user_message(item)
        })

      "agentMessage" when is_binary(item_id) ->
        put_in(state, [:agent_messages, item_id], %{
          at: at,
          phase: Map.get(item, "phase"),
          text: ""
        })

      "reasoning" when is_binary(item_id) ->
        put_in(state, [:reasoning, item_id], %{at: at, text: ""})

      _ ->
        state
    end
  end

  defp handle_item_completed(state, at, payload) do
    item = get_path(payload, ["params", "item"]) || %{}
    item_id = Map.get(item, "id")

    case Map.get(item, "type") do
      "agentMessage" when is_binary(item_id) ->
        complete_agent_message(state, at, item_id, item)

      "reasoning" when is_binary(item_id) ->
        complete_reasoning(state, at, item_id, item)

      "commandExecution" when is_binary(item_id) ->
        flush_completed_command(state, at, item_id, item)

      "userMessage" ->
        append_user_message(state, at, item)

      _ ->
        state
    end
  end

  defp complete_agent_message(state, at, item_id, item) do
    {buffer, state} = pop_in(state, [:agent_messages, item_id])
    text = Map.get(item, "text") || buffer_text(buffer)

    append_entry(state, %{
      kind: :agent,
      at: at || buffer_at(buffer),
      label: agent_label(Map.get(item, "phase") || buffer_phase(buffer), false),
      text: text
    })
  end

  defp complete_reasoning(state, at, item_id, item) do
    {buffer, state} = pop_in(state, [:reasoning, item_id])
    text = extract_reasoning_item_text(item) || buffer_text(buffer)

    append_entry(state, %{
      kind: :reasoning,
      at: at || buffer_at(buffer),
      label: "REASONING",
      text: text
    })
  end

  defp append_user_message(state, at, item) do
    append_entry(state, %{
      kind: :user,
      at: at,
      label: "USER",
      text: extract_user_message(item)
    })
  end

  defp append_input_required_entry(state, at, payload) do
    append_entry(state, %{
      kind: :event,
      at: at,
      label: "INPUT",
      text: extract_tool_input_text(payload)
    })
  end

  defp append_compaction_entry(state, at, payload) do
    append_entry(state, %{
      kind: :event,
      at: at,
      label: "COMPACTION",
      text: compaction_text(payload)
    })
  end

  defp compaction_text(payload) when is_map(payload) do
    case get_path(payload, ["params", "turnId"]) || get_path(payload, ["params", "turn_id"]) do
      turn_id when is_binary(turn_id) and byte_size(turn_id) >= 8 ->
        "Context compacted for turn #{short_identifier(turn_id)}."

      _ ->
        "Context compacted."
    end
  end

  defp short_identifier(identifier) when is_binary(identifier) and byte_size(identifier) > 8,
    do: binary_part(identifier, 0, 8)

  defp short_identifier(identifier) when is_binary(identifier), do: identifier

  defp buffer_agent_message(state, at, payload) do
    item_id = extract_item_id(payload)
    text = extract_stream_text(payload)

    case {item_id, text} do
      {id, delta} when is_binary(id) and is_binary(delta) ->
        update_in(state, [:agent_messages, id], fn buffer ->
          %{
            at: buffer_at(buffer) || at,
            phase: buffer_phase(buffer),
            text: buffer_text(buffer) <> delta
          }
        end)

      # ACP-normalized agent chunks (Option A) carry no item id and are never
      # followed by an `item/completed`, so there is nothing to flush later.
      # Append the chunk directly, mirroring `buffer_reasoning/3`. Codex agent
      # messages always have an item id, so this branch is ACP-only.
      {nil, delta} when is_binary(delta) ->
        append_entry(state, %{
          kind: :agent,
          at: at,
          label: agent_label(nil, false),
          text: delta
        })

      _ ->
        state
    end
  end

  defp buffer_reasoning(state, at, payload) do
    item_id = extract_item_id(payload)
    text = extract_reasoning_text(payload)

    case {item_id, text} do
      {id, delta} when is_binary(id) and is_binary(delta) ->
        update_in(state, [:reasoning, id], fn buffer ->
          %{
            at: buffer_at(buffer) || at,
            text: buffer_text(buffer) <> delta
          }
        end)

      {nil, delta} when is_binary(delta) ->
        append_entry(state, %{
          kind: :reasoning,
          at: at,
          label: "REASONING",
          text: delta
        })

      _ ->
        state
    end
  end

  defp buffer_command_output(state, at, payload) do
    item_id = extract_item_id(payload)
    text = extract_stream_text(payload)

    case {item_id, text} do
      {id, delta} when is_binary(id) and is_binary(delta) ->
        update_in(state, [:command_output, id], fn buffer ->
          %{
            at: buffer_at(buffer) || at,
            text: buffer_text(buffer) <> delta
          }
        end)

      _ ->
        state
    end
  end

  defp render_tool_call(state, at, event, payload) do
    tool = get_path(payload, ["params", "tool"]) || get_path(payload, ["params", "name"]) || "tool"

    args =
      payload
      |> get_path(["params", "arguments"])
      |> compact_tool_arguments()

    text =
      case args do
        %{} = compacted when map_size(compacted) > 0 ->
          inspect(compacted, pretty: true, limit: :infinity, width: 100)

        _ ->
          nil
      end

    append_entry(state, %{
      kind: :tool,
      at: at,
      label: tool_label(event, tool),
      text: text
    })
  end

  defp flush_completed_command(state, at, item_id, item) do
    {command_meta, state} = pop_in(state, [:commands, item_id])
    {output_meta, state} = pop_in(state, [:command_output, item_id])
    command = extract_command(item) || command_text(command_meta)

    state =
      if command_text(command_meta) == nil and is_binary(command) do
        append_entry(state, %{
          kind: :command,
          at: at,
          label: "CMD",
          text: command
        })
      else
        state
      end

    output =
      case buffer_text(output_meta) do
        "" -> Map.get(item, "aggregatedOutput")
        text -> text
      end

    append_entry(state, %{
      kind: :output,
      at: buffer_at(output_meta) || at || command_at(command_meta),
      label: output_label(item),
      text: output
    })
  end

  defp finalize_state(state) do
    state
    |> flush_remaining_agent_messages()
    |> flush_remaining_reasoning()
    |> flush_remaining_command_output()
  end

  defp flush_remaining_agent_messages(state) do
    Enum.reduce(state.agent_messages, %{state | agent_messages: %{}}, fn {item_id, buffer}, acc ->
      append_entry(acc, %{
        kind: :agent,
        at: buffer_at(buffer),
        label: agent_label(buffer_phase(buffer), true),
        text: buffer_text(buffer),
        id: item_id
      })
    end)
  end

  defp flush_remaining_reasoning(state) do
    Enum.reduce(state.reasoning, %{state | reasoning: %{}}, fn {_item_id, buffer}, acc ->
      append_entry(acc, %{
        kind: :reasoning,
        at: buffer_at(buffer),
        label: "REASONING (partial)",
        text: buffer_text(buffer)
      })
    end)
  end

  defp flush_remaining_command_output(state) do
    Enum.reduce(state.command_output, %{state | command_output: %{}}, fn {item_id, output}, acc ->
      command_meta = Map.get(acc.commands, item_id, %{})

      acc
      |> update_in([:commands], &Map.delete(&1, item_id))
      |> append_entry(%{
        kind: :output,
        at: buffer_at(output) || command_at(command_meta),
        label: "OUT (partial)",
        text: buffer_text(output)
      })
    end)
  end

  defp format_document(state, opts) do
    use_color = Keyword.get(opts, :use_color, IO.ANSI.enabled?())
    path = Keyword.get(opts, :path)

    header_lines =
      [
        "Session: #{state.session.session_id || "n/a"}",
        "Issue: #{state.session.issue_identifier || "n/a"}",
        "Workspace: #{state.session.workspace_path || "n/a"}",
        "Started: #{state.session.started_at || "n/a"}",
        if(is_binary(path), do: "File: #{path}", else: nil)
      ]
      |> Enum.reject(&is_nil/1)

    body =
      state.entries
      |> Enum.reverse()
      |> Enum.map_join("\n\n", &format_entry(&1, use_color))

    document =
      [Enum.join(header_lines, "\n"), String.duplicate("=", 80), body]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    if String.ends_with?(document, "\n"), do: document, else: document <> "\n"
  end

  defp format_entry(entry, use_color) do
    timestamp = "[#{entry.at || "unknown time"}]"
    header = "#{timestamp} #{colorize(entry.label, entry.kind, use_color)}"

    case normalized_text(entry.text) do
      "" ->
        header

      text ->
        header <> "\n" <> indent_block(text)
    end
  end

  defp append_entry(state, %{text: nil} = entry),
    do: update_in(state.entries, &[%{entry | text: nil} | &1])

  defp append_entry(state, %{text: text} = entry) do
    case normalized_text(text) do
      "" -> state
      normalized -> update_in(state.entries, &[%{entry | text: normalized} | &1])
    end
  end

  defp put_command(state, item_id, meta), do: put_in(state, [:commands, item_id], meta)

  defp extract_user_message(item) do
    item
    |> Map.get("content", [])
    |> Enum.map(&extract_content_part_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp extract_content_part_text(%{"text" => text}) when is_binary(text), do: text
  defp extract_content_part_text(_part), do: ""

  defp extract_reasoning_item_text(item) do
    text_from_content =
      item
      |> Map.get("content", [])
      |> Enum.map(&extract_content_part_text/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    text_from_summary =
      item
      |> Map.get("summary", [])
      |> Enum.map(&extract_content_part_text/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    first_present([text_from_content, text_from_summary])
  end

  defp extract_stream_text(payload) do
    first_present([
      get_path(payload, ["params", "delta"]),
      get_path(payload, ["params", "msg", "delta"]),
      get_path(payload, ["params", "msg", "content"]),
      get_path(payload, ["params", "content"]),
      get_path(payload, ["params", "output"]),
      get_path(payload, ["params", "text"])
    ])
  end

  defp extract_reasoning_text(payload) do
    first_present([
      get_path(payload, ["params", "textDelta"]),
      get_path(payload, ["params", "summaryText"]),
      get_path(payload, ["params", "part", "text"]),
      get_path(payload, ["params", "part", "summaryText"]),
      get_path(payload, ["params", "delta"]),
      get_path(payload, ["params", "text"]),
      get_path(payload, ["params", "content"]),
      get_path(payload, ["params", "msg", "content"])
    ])
  end

  defp extract_item_id(payload) do
    first_present([
      get_path(payload, ["params", "itemId"]),
      get_path(payload, ["params", "id"]),
      get_path(payload, ["params", "item", "id"])
    ])
  end

  defp extract_command(item) do
    first_present([
      get_path(item, ["commandActions", {:at, 0}, "command"]),
      Map.get(item, "command")
    ])
  end

  defp extract_tool_input_text(payload) do
    first_present([
      get_path(payload, ["params", "question"]),
      get_path(payload, ["params", "prompt"]),
      get_path(payload, ["params", "questions", {:at, 0}, "question"])
    ]) || "tool requires user input"
  end

  defp compact_tool_arguments(nil), do: nil

  defp compact_tool_arguments(%{} = arguments) do
    arguments
    |> Enum.map(fn {key, value} -> {key, compact_tool_value(value)} end)
    |> Enum.into(%{})
  end

  defp compact_tool_value(value) when is_binary(value) do
    lines = String.split(normalized_text(value), "\n")

    cond do
      length(lines) > @max_tool_string_lines ->
        Enum.take(lines, @max_tool_string_lines)
        |> Enum.join("\n")
        |> Kernel.<>("\n… [#{String.length(value)} chars]")

      String.length(value) > @max_tool_string_chars ->
        String.slice(value, 0, @max_tool_string_chars)
        |> Kernel.<>("… [#{String.length(value)} chars]")

      true ->
        value
    end
  end

  defp compact_tool_value(value) when is_list(value) do
    items =
      value
      |> Enum.take(@max_tool_list_items)
      |> Enum.map(&compact_tool_value/1)

    if length(value) > @max_tool_list_items do
      items ++ ["… [#{length(value) - @max_tool_list_items} more]"]
    else
      items
    end
  end

  defp compact_tool_value(%{} = value) do
    value
    |> Enum.map(fn {key, nested} -> {key, compact_tool_value(nested)} end)
    |> Enum.into(%{})
  end

  defp compact_tool_value(value), do: value

  defp output_label(item) do
    exit_code = Map.get(item, "exitCode")
    duration_ms = Map.get(item, "durationMs")

    suffix =
      []
      |> maybe_append("exit=#{exit_code}", is_integer(exit_code))
      |> maybe_append("#{duration_ms}ms", is_integer(duration_ms) and duration_ms > 0)
      |> Enum.join(", ")

    if suffix == "", do: "OUT", else: "OUT (#{suffix})"
  end

  defp tool_label("tool_call_completed", tool), do: "TOOL OK #{tool}"
  defp tool_label("tool_call_failed", tool), do: "TOOL FAILED #{tool}"
  defp tool_label("unsupported_tool_call", tool), do: "TOOL REJECTED #{tool}"
  defp tool_label(_event, tool), do: "TOOL #{tool}"

  defp agent_label("final", false), do: "AGENT FINAL"
  defp agent_label("final", true), do: "AGENT FINAL (partial)"
  defp agent_label(_phase, true), do: "AGENT (partial)"
  defp agent_label(_phase, false), do: "AGENT"

  defp command_text(%{command: command}) when is_binary(command), do: command
  defp command_text(_meta), do: nil

  defp command_at(%{at: at}) when is_binary(at), do: at
  defp command_at(_meta), do: nil

  defp buffer_text(%{text: text}) when is_binary(text), do: text
  defp buffer_text(_buffer), do: ""

  defp buffer_phase(%{phase: phase}) when is_binary(phase), do: phase
  defp buffer_phase(_buffer), do: nil

  defp buffer_at(%{at: at}) when is_binary(at), do: at
  defp buffer_at(_buffer), do: nil

  defp get_path(map, []), do: map

  defp get_path(map, [{:at, index} | rest]) when is_list(map) and is_integer(index) do
    case Enum.at(map, index) do
      nil -> nil
      value -> get_path(value, rest)
    end
  end

  defp get_path(map, [key | rest]) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      nil -> nil
      value -> get_path(value, rest)
    end
  end

  defp get_path(_value, _path), do: nil

  defp normalized_text(nil), do: ""

  defp normalized_text(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.replace(~r/\x1B\[[0-9;]*[A-Za-z]/, "")
    |> String.replace(~r/\x1B./, "")
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
    |> String.trim()
  end

  defp normalized_text(_text), do: ""

  defp indent_block(text) do
    text
    |> String.split("\n", trim: false)
    |> Enum.map_join("\n", &("  " <> &1))
  end

  defp colorize(text, kind, true) do
    ansi =
      Map.get(
        %{
          agent: IO.ANSI.cyan(),
          reasoning: IO.ANSI.yellow(),
          command: IO.ANSI.blue(),
          output: IO.ANSI.light_black(),
          tool: IO.ANSI.green(),
          event: IO.ANSI.red(),
          user: IO.ANSI.magenta()
        },
        kind,
        IO.ANSI.default_color()
      )

    IO.iodata_to_binary([IO.ANSI.bright(), ansi, text, IO.ANSI.reset()])
  end

  defp colorize(text, _kind, false), do: text

  defp first_present(values) do
    Enum.find_value(values, fn
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end)
  end

  defp maybe_append(list, value, true), do: list ++ [value]
  defp maybe_append(list, _value, false), do: list

  defp put_if_missing(map, key, value) when is_binary(value) do
    case Map.get(map, key) do
      nil -> Map.put(map, key, value)
      _existing -> map
    end
  end

  defp put_if_missing(map, _key, _value), do: map
end
