defmodule SymphonyElixir.ToolAttempt do
  @moduledoc """
  Reduces backend tool updates to bounded, non-secret correlation signals.

  Raw arguments are canonicalized only long enough to hash them. Raw call ids,
  canonical text, URLs with credentials or queries, and tool output are never
  returned or retained.
  """

  @tool_items ~w(commandExecution dynamicToolCall fileChange mcpToolCall collabAgentToolCall webSearch)
  @dynamic_terminals ~w(tool_call_completed tool_call_failed unsupported_tool_call)
  @secret_keys ~w(accesskey apikey authorization clientsecret cookie credential password passwd privatekey secret token)
  @max_depth 3
  @max_entries 12
  @max_value_bytes 512
  @max_canonical_bytes 8_192
  @max_operation_bytes 64

  @type result_class ::
          :success
          | :failed
          | :nonzero_exit
          | :cancelled
          | :unsupported
          | :timeout
          | :unknown_failure

  @type signal :: %{
          required(:kind) => :start | :terminal | :omission,
          optional(:sequence) => non_neg_integer(),
          optional(:correlation_sha256) => String.t(),
          optional(:thread_scope_sha256) => String.t(),
          optional(:operation) => String.t(),
          optional(:operation_identity_sha256) => String.t(),
          optional(:arguments_sha256) => String.t(),
          optional(:result_class) => result_class(),
          optional(:reason) => String.t()
        }

  @doc "Normalize a Codex, ACP, dynamic-tool, or Claude update into a safe signal."
  @spec normalize(map()) :: {:ok, signal()} | :ignore
  def normalize(update) when is_map(update) do
    normalize_update(update)
  rescue
    _error -> omission("normalization_failed")
  end

  defp normalize_update(update) do
    payload = value(update, :payload, %{})
    method = string(value(payload, :method))
    params = value(payload, :params, %{})

    case method do
      lifecycle when lifecycle in ["item/started", "item/completed"] ->
        item_lifecycle(lifecycle, params, update)

      "session/update" ->
        acp_update(params, update)

      "item/tool/call" ->
        dynamic_tool(params, update)

      "item/commandExecution/outputDelta" ->
        terminal_output(params, update)

      _other ->
        :ignore
    end
  end

  defp item_lifecycle(method, params, update) do
    item = value(params, :item, %{})
    type = string(value(item, :type))

    if type in @tool_items do
      {correlation, thread_scope} = correlation_context(update, params, item)
      operation = item_operation(item, type)

      if method == "item/started",
        do: start_signal(correlation, thread_scope, operation),
        else: terminal_signal(correlation, thread_scope, operation, result_class(item, :completed))
    else
      :ignore
    end
  end

  defp acp_update(params, outer) do
    update = value(params, :update, %{})
    type = string(value(update, :sessionUpdate))
    {correlation, thread_scope} = correlation_context(outer, params, update)
    operation = operation(value(update, :kind) || value(update, :title), fetch(update, :rawInput))

    cond do
      type in ["tool_call", "toolCall"] ->
        start_signal(correlation, thread_scope, operation)

      type in ["tool_call_update", "toolCallUpdate"] and terminal_status?(value(update, :status)) ->
        terminal_signal(correlation, thread_scope, operation, result_class(update, :terminal))

      true ->
        :ignore
    end
  end

  defp dynamic_tool(params, update) do
    event = update |> value(:event) |> string()
    {correlation, thread_scope} = correlation_context(update, %{}, params)
    operation = dynamic_operation(params)

    if event in @dynamic_terminals,
      do: terminal_signal(correlation, thread_scope, operation, dynamic_result(event, update)),
      else: start_signal(correlation, thread_scope, operation)
  end

  defp terminal_output(params, update) do
    if value(params, :terminal) == true do
      {correlation, thread_scope} = correlation_context(update, %{}, params)

      terminal_signal(
        correlation,
        thread_scope,
        dynamic_operation(params),
        result_class(params, :terminal)
      )
    else
      :ignore
    end
  end

  defp start_signal(nil, _thread_scope, _operation), do: omission("start_missing_correlation")
  defp start_signal(_correlation, _thread_scope, :missing), do: omission("start_missing_operation")

  defp start_signal(correlation, thread_scope, {:ok, name, identity, arguments}) do
    {:ok,
     %{
       kind: :start,
       correlation_sha256: correlation,
       thread_scope_sha256: thread_scope,
       operation: name,
       operation_identity_sha256: identity,
       arguments_sha256: arguments_hash(identity, arguments)
     }}
  end

  defp terminal_signal(nil, _thread_scope, :missing, _result), do: omission("terminal_missing_operation")

  defp terminal_signal(correlation, thread_scope, :missing, result) do
    {:ok,
     %{
       kind: :terminal,
       correlation_sha256: correlation,
       thread_scope_sha256: thread_scope,
       result_class: result
     }}
  end

  defp terminal_signal(correlation, thread_scope, {:ok, name, identity, arguments}, result) do
    {:ok,
     %{
       kind: :terminal,
       correlation_sha256: correlation,
       thread_scope_sha256: thread_scope,
       operation: name,
       operation_identity_sha256: identity,
       arguments_sha256: arguments_hash(identity, arguments),
       result_class: result
     }}
  end

  defp omission(reason), do: {:ok, %{kind: :omission, reason: reason}}

  defp item_operation(item, "commandExecution") do
    operation("commandExecution", map_if_present(item, :command, "command"))
  end

  defp item_operation(item, "fileChange") do
    operation("fileChange", map_if_present(item, :changes, "changes"))
  end

  defp item_operation(item, "mcpToolCall") do
    name = "mcp:#{external_name(value(item, :server))}/#{external_name(value(item, :tool) || value(item, :name))}"
    operation(name, fetch(item, :arguments), :mcp)
  end

  defp item_operation(item, type) do
    name = value(item, :tool) || value(item, :name) || type
    fallback = if type == "dynamicToolCall", do: :dynamic, else: :other
    operation(name, first_fetch(item, [:arguments, :input, :query]), fallback)
  end

  defp dynamic_operation(params) do
    operation(
      value(params, :name) || value(params, :tool),
      first_fetch(params, [:arguments, :input, :command]),
      :dynamic
    )
  end

  defp operation(name, arguments), do: operation(name, arguments, :other)
  defp operation(nil, _arguments, _fallback), do: :missing
  defp operation(_name, :error, _fallback), do: :missing

  defp operation(name, {:ok, arguments}, fallback) do
    {class, identity} = operation_identity(name, fallback)
    identity_hash = sha256(["tool-identity-v1\n", identity])
    {:ok, class, identity_hash, normalize_argument_shape(class, arguments)}
  end

  defp operation_identity(name, fallback) do
    normalized = name |> string() |> to_string() |> String.downcase()
    compact = String.replace(normalized, ~r/[^a-z0-9]+/u, "")

    cond do
      compact in ~w(commandexecution bash execcommand) -> {:shell, "shell"}
      compact in ~w(read readfile) -> {:read, "read"}
      compact in ~w(filechange edit write applypatch) -> {:edit, "edit"}
      compact == "websearch" -> {:web, "web"}
      String.starts_with?(normalized, "mcp:") -> {:mcp, truncate_utf8(normalized, @max_operation_bytes)}
      fallback == :dynamic -> {:dynamic, "dynamic:" <> external_name(normalized)}
      true -> {:other, "other:" <> external_name(normalized)}
    end
    |> then(fn {class, identity} -> {Atom.to_string(class), identity} end)
  end

  defp normalize_argument_shape("shell", command) when is_binary(command),
    do: %{"command" => command}

  defp normalize_argument_shape("read", path) when is_binary(path),
    do: %{"path" => path}

  defp normalize_argument_shape(name, arguments) when name in ["shell", "read"] and is_map(arguments) do
    aliases = if name == "shell", do: %{"cmd" => "command"}, else: %{"filePath" => "path", "file_path" => "path"}

    arguments
    |> Enum.map(fn {key, nested} ->
      key = normalized_key(key)
      {Map.get(aliases, key, key), nested}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
  end

  defp normalize_argument_shape(_name, arguments), do: arguments

  defp arguments_hash(identity_hash, arguments) do
    body = IO.iodata_to_binary(["tool-arguments-v1\n", identity_hash, "\n", canonical(arguments, 0, nil)])
    sha256(if(byte_size(body) > @max_canonical_bytes, do: binary_part(body, 0, @max_canonical_bytes), else: body))
  end

  defp canonical(_value, depth, _key) when depth > @max_depth, do: "depth-limit"

  defp canonical(value, depth, key) do
    if is_binary(key) and secret_key?(key) do
      "redacted"
    else
      canonical_value(value, depth)
    end
  end

  defp canonical_value(nil, _depth), do: "null"
  defp canonical_value(value, _depth) when is_boolean(value), do: "bool:#{value}"
  defp canonical_value(value, _depth) when is_integer(value), do: ["int:", Integer.to_string(value)]
  defp canonical_value(value, _depth) when is_float(value), do: ["float:", :erlang.float_to_binary(value, [:compact])]

  defp canonical_value(value, _depth) when is_binary(value) do
    sanitized = sanitize_string(value)
    bounded = if byte_size(sanitized) > @max_value_bytes, do: binary_part(sanitized, 0, @max_value_bytes), else: sanitized
    ["string:", Integer.to_string(byte_size(sanitized)), ":", bounded]
  end

  defp canonical_value(value, depth) when is_atom(value), do: canonical(Atom.to_string(value), depth, nil)

  defp canonical_value(value, depth) when is_list(value) do
    [
      "list:",
      Integer.to_string(length(value)),
      ":[",
      value |> Enum.take(@max_entries) |> Enum.map_intersperse(",", &canonical(&1, depth + 1, nil)),
      "]"
    ]
  end

  defp canonical_value(value, depth) when is_map(value) do
    entries = bounded_entries(value)

    [
      "map:",
      Integer.to_string(map_size(value)),
      ":{",
      Enum.map_intersperse(entries, ",", fn {key, nested} ->
        [canonical(key, depth + 1, nil), "=>", canonical(nested, depth + 1, key)]
      end),
      "}"
    ]
  end

  defp canonical_value(_value, _depth), do: "type:unsupported"

  defp sanitize_string(value) do
    value
    |> valid_utf8()
    |> then(
      &Regex.replace(
        ~r/\b([A-Za-z][A-Za-z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|AUTHORIZATION|COOKIE|PRIVATE_KEY|CLIENT_SECRET)[A-Za-z0-9_]*)=(?:"[^"]*"|'[^']*'|[^\s]+)/iu,
        &1,
        "\\1=<redacted>"
      )
    )
    |> then(
      &Regex.replace(
        ~r/(--(?:api[-_]?key|token|password|passwd|secret|authorization|cookie|private[-_]?key|client[-_]?secret))(?:=|\s+)(?:"[^"]*"|'[^']*'|[^\s]+)/iu,
        &1,
        "\\1=<redacted>"
      )
    )
    |> then(&Regex.replace(~r/\b(authorization|cookie)\s*:\s*[^\r\n]+/iu, &1, "\\1:<redacted>"))
    |> sanitize_urls()
  end

  defp sanitize_urls(value) do
    Regex.replace(~r{[A-Za-z][A-Za-z0-9+.-]*://[^\s"'<>]+}u, value, fn url ->
      case URI.parse(url) do
        %URI{host: host} when host in [nil, ""] ->
          "url:<redacted>"

        parsed ->
          URI.to_string(%{parsed | userinfo: nil, query: nil, fragment: nil})
      end
    end)
  end

  defp secret_key?(key) do
    compact = key |> String.downcase() |> String.replace(~r/[^a-z0-9]+/u, "")
    Enum.any?(@secret_keys, &String.contains?(compact, &1))
  end

  defp result_class(data, default) do
    exit_code = value(data, :exitCode) || value(data, :exit_code)
    status = data |> value(:status) |> string() |> to_string() |> String.downcase()

    if is_integer(exit_code) and exit_code != 0,
      do: :nonzero_exit,
      else: status_result(status, default)
  end

  defp status_result(status, _default) when status in ~w(failed failure error), do: :failed
  defp status_result(status, _default) when status in ~w(cancelled canceled aborted), do: :cancelled
  defp status_result(status, _default) when status in ~w(timeout timed_out), do: :timeout
  defp status_result("unsupported", _default), do: :unsupported
  defp status_result(status, _default) when status in ~w(completed complete success succeeded ok), do: :success
  defp status_result(_status, :completed), do: :success
  defp status_result(_status, _default), do: :unknown_failure

  defp dynamic_result("tool_call_completed", update) do
    result = update |> value(:details, %{}) |> value(:result, %{})
    if value(result, :success) == false, do: :failed, else: :success
  end

  defp dynamic_result("unsupported_tool_call", _update), do: :unsupported
  defp dynamic_result("tool_call_failed", _update), do: :failed

  defp terminal_status?(status) do
    normalized = status |> string() |> to_string() |> String.downcase()

    normalized in ~w(completed complete success succeeded failed failure error cancelled canceled aborted timeout timed_out unsupported)
  end

  defp correlation_context(update, params, data) do
    call_id = first_string(data, [:id, :callId, :itemId, :toolCallId]) || first_string(params, [:callId, :itemId, :toolCallId])

    thread_id =
      first_string(data, [:threadId, :sessionId]) ||
        first_string(params, [:threadId, :sessionId]) ||
        first_string(update, [:thread_id, :threadId, :session_id, :sessionId]) ||
        "thread-unreported"

    thread_scope = sha256(["tool-thread-v1\n", thread_id])
    correlation = if call_id, do: sha256(["tool-call-v1\n", thread_scope, "\n", call_id])

    {correlation, thread_scope}
  end

  defp map_if_present(map, key, output_key) do
    case fetch(map, key) do
      {:ok, nested} -> {:ok, %{output_key => nested}}
      :error -> :error
    end
  end

  defp first_fetch(map, keys) do
    Enum.find_value(keys, :error, fn key ->
      case fetch(map, key) do
        {:ok, nested} -> {:ok, nested}
        :error -> nil
      end
    end)
  end

  defp first_string(map, keys) do
    Enum.find_value(keys, fn key ->
      case value(map, key) do
        nested when is_binary(nested) and nested != "" -> nested
        nested when is_integer(nested) -> Integer.to_string(nested)
        _missing -> nil
      end
    end)
  end

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, nested} -> {:ok, nested}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp fetch(_other, _key), do: :error

  defp value(map, key, default \\ nil) do
    case fetch(map, key) do
      {:ok, nested} -> nested
      :error -> default
    end
  end

  defp string(value) when is_binary(value), do: value
  defp string(value) when is_atom(value), do: Atom.to_string(value)
  defp string(_value), do: nil

  defp normalized_key(key) when is_atom(key), do: Atom.to_string(key)

  defp normalized_key(key) when is_binary(key) do
    key = valid_utf8(key)
    if byte_size(key) <= 64, do: key, else: "key:oversized"
  end

  defp normalized_key(_key), do: "key:unsupported"

  defp external_name(value) do
    value
    |> string()
    |> to_string()
    |> valid_utf8()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/u, "-")
    |> String.trim("-")
    |> truncate_utf8(@max_operation_bytes)
  end

  defp valid_utf8(value), do: if(String.valid?(value), do: value, else: "binary:" <> sha256(value))

  defp bounded_entries(map) do
    Enum.reduce(map, [], fn {key, nested}, selected ->
      entry = {normalized_key(key), nested}

      [entry | selected]
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.take(@max_entries)
    end)
  end

  defp truncate_utf8(value, max) when byte_size(value) <= max, do: value

  defp truncate_utf8(value, max) do
    Enum.reduce_while(String.codepoints(value), "", fn point, acc ->
      if byte_size(acc) + byte_size(point) <= max, do: {:cont, acc <> point}, else: {:halt, acc}
    end)
  end

  defp sha256(value) do
    value
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
