defmodule SymphonyElixir.SessionTranscript do
  @moduledoc """
  Compact, NDJSON-compatible session persistence with selective raw fidelity.

  The dashboard-compatible `.ndjson` file receives lifecycle, terminal item,
  tool, error, and other semantic records. High-frequency streaming chunks and
  cumulative token notifications are omitted because their accepted meaning is
  persisted in fleet telemetry. A single redacted protocol representation is
  written to a gzip sidecar while the run is active; the sidecar is retained for
  failures, configured sampling, or incident debug, and removed after ordinary
  successful sessions.
  """

  require Logger

  alias SymphonyElixir.{Telemetry, Utf8}

  @raw_suffix ".raw.ndjson.gz"
  @pending_suffix ".pending"
  @active_suffix ".active"
  @max_compact_stream_bytes 65_536
  @compact_boundary_events ~w(session_started turn_started turn_completed turn_failed turn_input_required turn_interruption_signal)
  @codex_tool_types ~w(commandExecution dynamicToolCall fileChange mcpToolCall collabAgentToolCall webSearch)

  @type outcome :: :success | :failure

  @doc "Persist one update and return log metadata augmented with storage paths."
  @spec persist(map(), map()) :: {:ok, map()} | {:error, term()}
  def persist(log_entry, record) when is_map(log_entry) and is_map(record) do
    persist(log_entry, record, Telemetry.observability())
  end

  @doc false
  @spec persist(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def persist(log_entry, record, policy)
      when is_map(log_entry) and is_map(record) and is_map(policy) do
    compact_path = Map.fetch!(log_entry, :path)
    raw_path = raw_path(compact_path)

    with :ok <- File.mkdir_p(Path.dirname(compact_path)),
         :ok <- ensure_active_marker(compact_path),
         {:ok, log_entry} <- maybe_append_compact(log_entry, record, policy),
         :ok <- maybe_append_raw(raw_path, record, policy) do
      {:ok,
       log_entry
       |> Map.put(:storage_schema_version, Telemetry.schema_version())
       |> Map.put(:observability_policy, policy)
       |> Map.put(:raw_trace_path, retained_raw_path(raw_path, policy))
       |> Map.put(:raw_trace_pending_path, retained_raw_pending_path(raw_path, policy))}
    end
  rescue
    error in [File.Error] -> {:error, error}
  end

  @doc "Finalize raw sidecars according to success/failure and sampling policy."
  @spec finalize([map()], outcome()) :: :ok
  def finalize(log_entries, outcome) when is_list(log_entries) and outcome in [:success, :failure] do
    Enum.each(log_entries, fn entry ->
      if path = Map.get(entry, :path) do
        policy = Map.get(entry, :observability_policy) || Telemetry.observability()
        flush_pending(path, entry)
        finalize_raw(raw_path(path), outcome, policy)
        remove_active_marker(path)
      end
    end)

    policy = log_entries |> List.first() |> then(&if(&1, do: Map.get(&1, :observability_policy), else: nil)) || Telemetry.observability()
    prune_raw(log_entries, policy.raw_trace_retention_days)
    :ok
  rescue
    error ->
      Logger.debug("Session raw-trace finalization failed: #{Exception.message(error)}")
      :ok
  end

  @doc "Whether a protocol notification belongs in the compact NDJSON stream."
  @spec compact_record?(map()) :: boolean()
  def compact_record?(record) when is_map(record) do
    event = string_value(record, :event)
    payload = flexible_value(record, :payload)
    method = if is_map(payload), do: string_value(payload, :method)

    cond do
      event in @compact_boundary_events ->
        true

      terminal_method?(method) ->
        true

      high_frequency_method?(method, payload) ->
        false

      event == "notification" and is_nil(method) ->
        false

      true ->
        true
    end
  end

  def compact_record?(_record), do: false

  @doc "Return the marker path used to protect an active compact transcript and its raw sidecars."
  @spec active_marker_path(Path.t()) :: Path.t()
  def active_marker_path(compact_path) when is_binary(compact_path),
    do: compact_path <> @active_suffix

  @doc "Read compact NDJSON or gzip raw fixtures as decoded records."
  @spec read_records(Path.t()) :: [map()]
  def read_records(path) when is_binary(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- decode_content(path, content) do
      decoded
      |> String.split("\n", trim: true)
      |> Enum.flat_map(&decode_line/1)
    else
      _unreadable -> []
    end
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, record} when is_map(record) -> [record]
      _invalid -> []
    end
  end

  @doc "Project raw or compact records to their terminal transcript meaning."
  @spec semantic_projection([map()]) :: [map()]
  def semantic_projection(records) when is_list(records) do
    records
    |> Enum.flat_map(fn record ->
      payload = flexible_value(record, :payload)
      method = if is_map(payload), do: string_value(payload, :method)

      if terminal_method?(method) do
        [
          %{
            "method" => method,
            "thread_id" => string_value(record, :thread_id),
            "turn_id" => string_value(record, :turn_id),
            "payload" => payload
          }
        ]
      else
        []
      end
    end)
  end

  defp maybe_append_compact(log_entry, record, %{session_compaction_enabled: false} = policy) do
    case append_json(log_entry.path, redact_transcript_record(record, policy)) do
      :ok -> {:ok, log_entry}
      error -> error
    end
  end

  defp maybe_append_compact(log_entry, record, policy) do
    prepared = record |> compact_record() |> Telemetry.redact(policy.redact_fields) |> bound_compact_values()

    case compact_action(prepared) do
      :skip ->
        {:ok, log_entry}

      :boundary ->
        flush_and_append(log_entry, prepared)

      {:append, key, field, text} ->
        {:ok, append_pending_text(log_entry, key, prepared, field, text)}

      {:latest, key} ->
        {:ok, put_pending(log_entry, key, prepared)}

      {:terminal, keys} ->
        append_terminal(log_entry, prepared, keys)

      {:terminal_flush, keys} ->
        append_terminal(log_entry, prepared, keys)

      :immediate ->
        append_immediate(log_entry, prepared)
    end
  end

  defp append_terminal(log_entry, prepared, keys) do
    log_entry |> drop_pending(keys) |> flush_and_append(prepared)
  end

  defp flush_and_append(log_entry, prepared) do
    with :ok <- flush_pending(log_entry.path, log_entry),
         :ok <- append_json(log_entry.path, prepared) do
      {:ok, clear_pending(log_entry)}
    end
  end

  defp append_immediate(log_entry, prepared), do: flush_and_append(log_entry, prepared)

  defp maybe_append_raw(path, record, policy) do
    raw_record = raw_record(record, policy)
    encoded = Jason.encode!(raw_record) <> "\n"
    File.write(path <> @pending_suffix, :zlib.gzip(encoded), [:append, :binary])
  end

  defp append_json(path, record) do
    File.write(path, Jason.encode!(record) <> "\n", [:append])
  end

  defp redact_transcript_record(record, policy) do
    redacted = Telemetry.redact(record, policy.redact_fields)

    if Map.has_key?(redacted, "raw") do
      Map.put(redacted, "raw", redacted_raw_payload(record, policy.redact_fields))
    else
      redacted
    end
  end

  defp redacted_raw_payload(record, fields) do
    case flexible_value(record, :raw) do
      raw when is_binary(raw) ->
        case Jason.decode(raw) do
          {:ok, decoded} -> Jason.encode!(Telemetry.redact(decoded, fields))
          _invalid -> "[REDACTED: unparsed protocol payload]"
        end

      _missing ->
        "[REDACTED: unparsed protocol payload]"
    end
  end

  defp compact_record(record) do
    record
    |> Map.drop([:raw, "raw", :workspace_path, "workspace_path"])
    |> Map.update(:payload, nil, &compact_payload/1)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> Map.put(:storage_schema_version, Telemetry.schema_version())
  end

  defp compact_payload(payload) when is_map(payload) do
    method = string_value(payload, :method)

    if terminal_method?(method) do
      payload
    else
      Map.take(payload, ["method", :method, "params", :params, "id", :id])
    end
  end

  defp compact_payload(_payload), do: nil

  defp raw_record(record, policy) do
    raw = flexible_value(record, :raw)

    record
    |> Map.drop([:raw, "raw", :summary, "summary", :workspace_path, "workspace_path"])
    |> Telemetry.redact(policy.redact_fields)
    |> Map.put("storage_schema_version", Telemetry.schema_version())
    |> Map.put("protocol_event", string_value(record, :event))
    |> put_protocol_raw(raw, policy.redact_fields)
  end

  defp put_protocol_raw(record, raw, fields) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} ->
        record
        |> Map.put("protocol_raw_present", true)
        |> Map.put("protocol_raw", Telemetry.redact(decoded, fields))

      _invalid ->
        record
        |> Map.put("protocol_raw_present", true)
        |> Map.put("protocol_raw_invalid", true)
        |> Map.put("protocol_raw_bytes", byte_size(raw))
        |> Map.put("protocol_raw_sha256", sha256(raw))
    end
  end

  defp put_protocol_raw(record, _raw, _fields), do: Map.put(record, "protocol_raw_present", false)

  defp compact_action(record) do
    event = string_value(record, :event)
    payload = flexible_value(record, :payload) || %{}
    method = string_value(payload, :method)
    params = flexible_value(payload, :params) || %{}
    item = flexible_value(params, :item) || %{}
    item_id = string_value(item, :id) || string_value(params, :itemId) || string_value(params, :callId)
    thread_id = string_value(record, :thread_id) || string_value(params, :threadId) || "thread-unreported"

    compact_action_for(event, method, payload, params, item, thread_id, item_id)
  end

  defp compact_action_for(event, _method, _payload, _params, _item, _thread_id, _item_id)
       when event in @compact_boundary_events,
       do: :boundary

  defp compact_action_for("tool_call_completed", _method, _payload, _params, _item, _thread_id, _item_id), do: :immediate

  defp compact_action_for(_event, "item/agentMessage/delta", _payload, params, _item, thread_id, item_id) do
    {:append, {:agent, thread_id, item_id}, [:payload, :params, :delta], string_value(params, :delta) || ""}
  end

  defp compact_action_for(_event, "item/reasoning/textDelta", _payload, params, _item, thread_id, item_id) do
    {:append, {:reasoning, thread_id, item_id}, [:payload, :params, :textDelta], string_value(params, :textDelta) || ""}
  end

  defp compact_action_for(
         _event,
         "item/commandExecution/outputDelta",
         _payload,
         params,
         _item,
         thread_id,
         item_id
       ) do
    if flexible_value(params, :terminal) == true do
      {:terminal_flush, [{:tool_output, thread_id, item_id}, {:tool_update, thread_id, item_id}]}
    else
      {:append, {:tool_output, thread_id, item_id}, [:payload, :params, :output], string_value(params, :output) || ""}
    end
  end

  defp compact_action_for(_event, "item/tool/call", _payload, _params, _item, thread_id, item_id),
    do: {:latest, {:tool_start, thread_id, item_id}}

  defp compact_action_for(_event, "item/started", _payload, _params, item, thread_id, item_id) do
    type = if codex_tool_item?(item), do: :tool_start, else: :item_start
    {:latest, {type, thread_id, item_id}}
  end

  defp compact_action_for(_event, "item/completed", _payload, _params, _item, thread_id, item_id),
    do: {:terminal, pending_keys(thread_id, item_id)}

  defp compact_action_for(_event, "session/update", _payload, params, _item, thread_id, _item_id),
    do: acp_compact_action(params, thread_id)

  defp compact_action_for(_event, method, payload, _params, _item, _thread_id, _item_id) do
    if token_method?(method) or high_frequency_method?(method, payload), do: :skip, else: :immediate
  end

  defp acp_compact_action(params, thread_id) do
    update = flexible_value(params, :update) || %{}
    type = string_value(update, :sessionUpdate)
    tool_id = string_value(update, :toolCallId) || string_value(update, :id)

    acp_update_action(type, update, thread_id, tool_id)
  end

  defp acp_update_action(type, update, thread_id, _tool_id) when type in ["agent_message_chunk", "agentMessageChunk"] do
    {:append, {:agent, thread_id, nil}, [:payload, :params, :update, :content, :text], acp_text(update)}
  end

  defp acp_update_action(type, update, thread_id, _tool_id)
       when type in ["thought_chunk", "thoughtChunk", "agent_thought_chunk", "agentThoughtChunk"] do
    {:append, {:reasoning, thread_id, nil}, [:payload, :params, :update, :content, :text], acp_text(update)}
  end

  defp acp_update_action(type, _update, thread_id, tool_id) when type in ["tool_call", "toolCall"],
    do: {:latest, {:tool_start, thread_id, tool_id}}

  defp acp_update_action(type, update, thread_id, tool_id) when type in ["tool_call_update", "toolCallUpdate"] do
    if terminal_acp_tool?(update) do
      {:terminal_flush, [{:tool_output, thread_id, tool_id}, {:tool_update, thread_id, tool_id}]}
    else
      {:latest, {:tool_update, thread_id, tool_id}}
    end
  end

  defp acp_update_action(type, _update, _thread_id, _tool_id) do
    if String.ends_with?(type || "", "_chunk") or String.ends_with?(type || "", "Chunk"), do: :skip, else: :immediate
  end

  defp acp_text(update) do
    update
    |> flexible_value(:content)
    |> case do
      content when is_map(content) -> string_value(content, :text) || ""
      _other -> ""
    end
  end

  defp terminal_acp_tool?(update) do
    status = update |> flexible_value(:status) |> to_string() |> String.downcase()
    status in ["completed", "failed", "error", "cancelled"]
  end

  defp codex_tool_item?(item), do: string_value(item, :type) in @codex_tool_types

  defp token_method?(method) when is_binary(method) do
    downcased = String.downcase(method)
    String.contains?(downcased, "tokenusage") or String.contains?(downcased, "token_count")
  end

  defp token_method?(_method), do: false

  defp pending_keys(thread_id, item_id) do
    [
      {:agent, thread_id, item_id},
      {:agent, thread_id, nil},
      {:reasoning, thread_id, item_id},
      {:reasoning, thread_id, nil},
      {:tool_start, thread_id, item_id},
      {:tool_output, thread_id, item_id},
      {:tool_output, thread_id, nil},
      {:tool_update, thread_id, item_id},
      {:item_start, thread_id, item_id}
    ]
    |> Enum.uniq()
  end

  defp append_pending_text(log_entry, key, record, field, text) do
    pending = Map.get(log_entry, :compact_pending, %{})

    updated =
      case Map.get(pending, key) do
        nil -> put_nested(record, field, bound_compact_text(text))
        prior -> put_nested(prior, field, bound_compact_text(nested_value(prior, field) <> text))
      end

    put_pending(log_entry, key, updated)
  end

  defp put_pending(log_entry, key, record) do
    pending = Map.get(log_entry, :compact_pending, %{})
    order = Map.get(log_entry, :compact_pending_order, [])

    record =
      case {key, Map.get(pending, key)} do
        {{:tool_update, _thread_id, _tool_id}, prior} when is_map(prior) -> deep_merge(prior, record)
        _other -> record
      end

    log_entry
    |> Map.put(:compact_pending, Map.put(pending, key, record))
    |> Map.put(:compact_pending_order, if(key in order, do: order, else: order ++ [key]))
  end

  defp drop_pending(log_entry, keys) do
    pending = Map.get(log_entry, :compact_pending, %{})
    order = Map.get(log_entry, :compact_pending_order, [])

    log_entry
    |> Map.put(:compact_pending, Map.drop(pending, keys))
    |> Map.put(:compact_pending_order, order -- keys)
  end

  defp clear_pending(log_entry), do: Map.drop(log_entry, [:compact_pending, :compact_pending_order])

  defp flush_pending(path, log_entry) do
    pending = Map.get(log_entry, :compact_pending, %{})

    log_entry
    |> Map.get(:compact_pending_order, [])
    |> Enum.reduce_while(:ok, &append_pending_record(path, pending, &1, &2))
  end

  defp append_pending_record(path, pending, key, :ok) do
    case Map.fetch(pending, key) do
      {:ok, record} -> continue_if_written(append_json(path, record))
      :error -> {:cont, :ok}
    end
  end

  defp continue_if_written(:ok), do: {:cont, :ok}
  defp continue_if_written(_error), do: {:halt, {:error, :compact_write_failed}}

  defp put_nested(map, [key], value), do: Map.put(map, Atom.to_string(key), value)

  defp put_nested(map, [key | rest], value) do
    string_key = Atom.to_string(key)
    Map.put(map, string_key, put_nested(Map.get(map, string_key) || %{}, rest, value))
  end

  defp nested_value(value, []), do: if(is_binary(value), do: value, else: "")
  defp nested_value(map, [key | rest]) when is_map(map), do: nested_value(Map.get(map, Atom.to_string(key)), rest)
  defp nested_value(_value, _path), do: ""

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value), do: deep_merge(left_value, right_value), else: right_value
    end)
  end

  defp bound_compact_text(text) when byte_size(text) <= @max_compact_stream_bytes, do: text

  defp bound_compact_text(text) do
    Utf8.safe_byte_prefix(text, @max_compact_stream_bytes) <>
      "…[coalesced stream truncated sha256=#{sha256(text)}]"
  end

  defp bound_compact_values(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, bound_compact_values(nested)} end)
  end

  defp bound_compact_values(value) when is_list(value), do: Enum.map(value, &bound_compact_values/1)
  defp bound_compact_values(value) when is_binary(value), do: bound_compact_text(value)
  defp bound_compact_values(value), do: value

  defp finalize_raw(path, outcome, policy) do
    pending = path <> @pending_suffix

    cond do
      not File.exists?(pending) ->
        :ok

      retain_raw?(path, outcome, policy) ->
        File.rename(pending, path)

      true ->
        File.rm(pending)
    end
  end

  defp ensure_active_marker(compact_path) do
    marker = active_marker_path(compact_path)

    contents =
      Jason.encode!(%{
        pid: System.pid(),
        started_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }) <> "\n"

    case File.write(marker, contents, [:exclusive]) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_active_marker(compact_path) do
    case File.rm(active_marker_path(compact_path)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp retain_raw?(_path, _outcome, %{raw_trace_debug: true}), do: true
  defp retain_raw?(_path, _outcome, %{raw_trace_policy: "all"}), do: true
  defp retain_raw?(_path, :failure, _policy), do: true
  defp retain_raw?(path, _outcome, %{raw_trace_policy: "sampled", raw_trace_sample_rate: rate}), do: sampled?(path, rate)
  defp retain_raw?(path, :success, %{raw_trace_policy: "failures", raw_trace_sample_rate: rate}), do: sampled?(path, rate)
  defp retain_raw?(_path, _outcome, _policy), do: false

  defp sampled?(_path, rate) when not is_number(rate) or rate <= 0, do: false
  defp sampled?(_path, rate) when rate >= 1, do: true
  defp sampled?(path, rate), do: :erlang.phash2(path, 1_000_000) < trunc(rate * 1_000_000)

  defp retained_raw_path(path, policy) do
    if policy.raw_trace_debug or policy.raw_trace_policy in ["none", "all", "failures", "sampled"], do: path
  end

  defp retained_raw_pending_path(path, policy) do
    if policy.raw_trace_debug or policy.raw_trace_policy in ["none", "all", "failures", "sampled"],
      do: path <> @pending_suffix
  end

  defp raw_path(compact_path), do: String.replace_suffix(compact_path, ".ndjson", @raw_suffix)

  defp prune_raw([], _days), do: :ok

  defp prune_raw([entry | _rest], days) when is_integer(days) and days >= 7 do
    with path when is_binary(path) <- Map.get(entry, :path),
         {:ok, files} <- File.ls(Path.dirname(path)) do
      cutoff = System.system_time(:second) - days * 86_400

      Enum.each(files, fn name ->
        maybe_prune_raw_file(Path.dirname(path), name, cutoff)
      end)
    end

    :ok
  end

  defp maybe_prune_raw_file(directory, name, cutoff) do
    if String.contains?(name, @raw_suffix) do
      prune_raw_file(Path.join(directory, name), cutoff)
    end
  end

  defp prune_raw_file(path, cutoff) do
    if active_raw_path?(path) do
      :ok
    else
      case File.stat(path, time: :posix) do
        {:ok, %{mtime: mtime}} when mtime < cutoff -> File.rm(path)
        _current -> :ok
      end
    end
  end

  defp active_raw_path?(path) do
    compact_path =
      path
      |> String.replace_suffix(@pending_suffix, "")
      |> String.replace_suffix(@raw_suffix, ".ndjson")

    File.exists?(active_marker_path(compact_path))
  end

  defp terminal_method?(method) when is_binary(method) do
    String.ends_with?(method, "/completed") or String.ends_with?(method, "/failed") or
      method in ["error", "turn/completed", "turn/failed"]
  end

  defp terminal_method?(_method), do: false

  defp high_frequency_method?(method, payload) when is_binary(method) do
    String.contains?(String.downcase(method), ["delta", "tokenusage", "token_count"]) or acp_chunk?(method, payload)
  end

  defp high_frequency_method?(_method, _payload), do: false

  defp acp_chunk?("session/update", payload) do
    update = path(payload, [:params, :update])

    case string_value(update || %{}, :sessionUpdate) do
      value when is_binary(value) -> String.ends_with?(value, "_chunk") or String.ends_with?(value, "Chunk")
      _value -> false
    end
  end

  defp acp_chunk?(_method, _payload), do: false

  defp decode_content(path, content) do
    if String.ends_with?(path, ".gz"), do: decode_gzip(content), else: {:ok, content}
  end

  # Each append is a complete gzip member. Normal readers accept concatenated
  # members; if the final write was interrupted, recover every preceding member
  # independently and discard only the incomplete tail.
  defp decode_gzip(content) do
    {:ok, :zlib.gunzip(content)}
  rescue
    _error -> recover_complete_gzip_members(content)
  end

  defp recover_complete_gzip_members(content) do
    recovered =
      content
      |> :binary.split(<<0x1F, 0x8B, 0x08>>, [:global])
      |> Enum.drop(1)
      |> Enum.reduce_while([], fn fragment, acc ->
        member = <<0x1F, 0x8B, 0x08>> <> fragment

        try do
          {:cont, [:zlib.gunzip(member) | acc]}
        rescue
          _error -> {:halt, acc}
        end
      end)
      |> Enum.reverse()

    if recovered == [], do: {:error, :invalid_gzip}, else: {:ok, IO.iodata_to_binary(recovered)}
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp string_value(map, key) when is_map(map) do
    case flexible_value(map, key) do
      nil -> nil
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      _value -> nil
    end
  end

  defp flexible_value(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp flexible_value(_map, _key), do: nil

  defp path(value, []), do: value
  defp path(map, [key | rest]) when is_map(map), do: map |> flexible_value(key) |> path(rest)
  defp path(_value, _path), do: nil
end
