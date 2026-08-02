defmodule SymphonyElixir.FleetEvent do
  @moduledoc """
  Converts backend updates into the stable, low-cardinality fleet event model.

  Streaming text is deliberately absent. Lifecycle, phase, tool boundaries and
  accepted token high-water deltas carry enough information for bounded weekly
  efficiency reporting without reproducing a session transcript.
  """

  alias SymphonyElixir.{Telemetry, TokenAccounting}

  @lifecycle_events ~w(session_started turn_started turn_completed turn_failed turn_input_required turn_interruption_signal)
  @codex_tool_types ~w(commandExecution dynamicToolCall fileChange mcpToolCall collabAgentToolCall webSearch)
  @tool_categories [
    {"test", ["mix test", "make all", "pytest", "vitest", "jest", "cargo test"]},
    {"quality_gate", ["dialyzer", "credo", "eslint", "lint", "typecheck", "format --check"]},
    {"evidence", ["git diff", "git status", "git show", "git log"]},
    {"file_change", ["apply_patch", "filechange", "write", "edit"]},
    {"tracker", ["linear", "issueupdate", "save_issue"]},
    {"browser", ["browser", "playwright", "screenshot"]},
    {"network", ["web", "search", "http", "curl"]},
    {"delegation", ["collab", "spawn_agent", "subagent"]}
  ]

  @doc "Emit compact analytics for one backend update and return updated event state."
  @spec observe(map(), map(), TokenAccounting.observation() | nil) :: map()
  def observe(running_entry, update, token_observation)
      when is_map(running_entry) and is_map(update) do
    parent_thread_id = parent_thread_id(running_entry)
    attrs = common_attrs(running_entry, update, parent_thread_id)
    policy = Map.get(running_entry, :observability_policy) || Telemetry.observability()

    maybe_emit_lifecycle(update, attrs, policy)
    maybe_emit_tokens(token_observation, attrs, parent_thread_id, policy)

    {running_entry, phase} = maybe_emit_tool(running_entry, update, attrs, policy)
    phase = phase || phase_for_update(update)
    maybe_transition_phase(running_entry, phase, attrs, policy)
  end

  @doc "Normalize a command/tool into a report-safe category."
  @spec tool_category(String.t() | nil, String.t() | nil) :: String.t()
  def tool_category(name, command) do
    value = String.downcase("#{name || ""} #{command || ""}")

    Enum.find_value(@tool_categories, "other", fn {category, patterns} ->
      if String.contains?(value, patterns), do: category
    end)
  end

  @doc "Return bytes from one terminal tool event across Codex, ACP, and Claude shapes."
  @spec terminal_tool_output_bytes(map()) :: non_neg_integer()
  def terminal_tool_output_bytes(update) when is_map(update) do
    case tool_signal(update) do
      %{action: "end", output_bytes: bytes} when is_integer(bytes) and bytes >= 0 -> bytes
      _streaming_or_non_tool -> 0
    end
  end

  defp maybe_emit_lifecycle(update, attrs, policy) do
    event = update |> flexible_value(:event) |> to_string()

    if event in @lifecycle_events do
      Telemetry.emit(:lifecycle, Map.put(attrs, :action, event), policy)
    end
  end

  defp maybe_emit_tokens(nil, _attrs, _parent_thread_id, _policy), do: :ok

  defp maybe_emit_tokens(observation, attrs, parent_thread_id, policy) do
    delta = observation.accepted_delta

    if Enum.any?([:input_tokens, :cached_input_tokens, :output_tokens, :reasoning_tokens, :total_tokens], &((delta[&1] || 0) > 0)) do
      role = if observation.thread_id == parent_thread_id, do: "parent", else: "delegated"

      Telemetry.emit(
        :token_high_water,
        attrs
        |> Map.put(:thread_id, observation.thread_id)
        |> Map.put(:parent_thread_id, parent_thread_id)
        |> Map.put(:thread_role, role)
        |> Map.put(:cumulative, observation.cumulative)
        |> Map.put(:accepted_delta, delta),
        policy
      )
    end
  end

  defp maybe_emit_tool(running_entry, update, attrs, policy) do
    case tool_signal(update) do
      nil -> {running_entry, nil}
      signal -> record_tool(running_entry, update, attrs, signal, policy)
    end
  end

  defp record_tool(running_entry, update, attrs, signal, policy) do
    item_id = signal.id || "tool-unreported"
    item_type = signal.name
    category = tool_category(item_type, signal.command)
    action = signal.action
    timestamp = flexible_value(update, :timestamp)
    starts = Map.get(running_entry, :fleet_tool_starts, %{})

    Telemetry.emit(
      :tool,
      tool_attrs(attrs, signal, item_id, item_type, category, action, tool_duration(starts[item_id], timestamp)),
      policy
    )

    updated_starts = update_tool_starts(starts, item_id, timestamp, action)
    {Map.put(running_entry, :fleet_tool_starts, updated_starts), phase_for_tool(category)}
  end

  defp tool_attrs(attrs, signal, item_id, item_type, category, action, duration_ms) do
    %{
      issue_id: attrs.issue_id,
      issue_identifier: attrs.issue_identifier,
      repository: attrs.repository,
      session_id: attrs.session_id,
      thread_id: attrs.thread_id,
      turn_id: attrs.turn_id,
      tool_id: item_id,
      tool_name: item_type,
      action: action,
      category: category,
      duration_ms: if(action == "end", do: duration_ms),
      outcome: if(action == "end", do: signal.outcome),
      output_bytes: if(action == "end", do: signal.output_bytes, else: 0),
      artifact_ref: signal.artifact_ref
    }
  end

  defp update_tool_starts(starts, item_id, timestamp, "start"), do: Map.put(starts, item_id, timestamp)
  defp update_tool_starts(starts, item_id, _timestamp, _action), do: Map.delete(starts, item_id)

  defp tool_signal(update) do
    payload = flexible_value(update, :payload) || %{}
    method = string_value(payload, :method)
    params = path(payload, [:params]) || %{}
    signal_for_method(method, params, update)
  end

  defp signal_for_method(method, params, _update) when method in ["item/started", "item/completed"] do
    item = path(params, [:item]) || %{}

    if codex_tool_item?(item) do
      signal_from_item(item, if(method == "item/started", do: "start", else: "end"))
    end
  end

  defp signal_for_method("session/update", params, _update), do: signal_from_acp(path(params, [:update]) || %{})

  defp signal_for_method("item/tool/call", params, update) do
    event = update |> flexible_value(:event) |> to_string()

    if event in ["tool_call_completed", "tool_call_failed", "unsupported_tool_call"] do
      dynamic_tool_terminal_signal(params, update, event)
    else
      %{
        action: "start",
        id: string_value(params, :callId) || string_value(params, :itemId),
        name: string_value(params, :name) || string_value(params, :tool),
        command: command_value(flexible_value(params, :arguments)),
        outcome: nil,
        output_bytes: 0,
        artifact_ref: nil
      }
    end
  end

  defp signal_for_method("item/commandExecution/outputDelta", params, _update) do
    if flexible_value(params, :terminal) == true, do: terminal_output_signal(params)
  end

  defp signal_for_method(_method, _params, _update), do: nil

  defp dynamic_tool_terminal_signal(params, update, event) do
    result = path(update, [:details, :result])

    %{
      action: "end",
      id: string_value(params, :callId) || string_value(params, :itemId),
      name: string_value(params, :name) || string_value(params, :tool),
      command: command_value(flexible_value(params, :arguments)),
      outcome: if(event == "tool_call_completed", do: "completed", else: "failed"),
      output_bytes: value_bytes(result),
      artifact_ref: nil
    }
  end

  defp terminal_output_signal(params) do
    %{
      action: "end",
      id: string_value(params, :callId) || string_value(params, :itemId),
      name: string_value(params, :name) || "commandExecution",
      command: nil,
      outcome: string_value(params, :status) || "completed",
      output_bytes: value_bytes(flexible_value(params, :output)),
      artifact_ref: flexible_value(params, :artifact_ref)
    }
  end

  defp codex_tool_item?(item), do: string_value(item, :type) in @codex_tool_types

  defp signal_from_item(item, action) do
    %{
      action: action,
      id: string_value(item, :id),
      name: string_value(item, :type),
      command: command_text(item),
      outcome: if(action == "end", do: tool_outcome(item)),
      output_bytes: if(action == "end", do: output_bytes(item), else: 0),
      artifact_ref: artifact_reference(item)
    }
  end

  defp signal_from_acp(update) do
    type = string_value(update, :sessionUpdate)

    cond do
      type in ["tool_call", "toolCall"] ->
        %{
          action: "start",
          id: string_value(update, :toolCallId),
          name: string_value(update, :kind) || string_value(update, :title),
          command: command_value(flexible_value(update, :rawInput)),
          outcome: nil,
          output_bytes: 0,
          artifact_ref: flexible_value(update, :path)
        }

      type in ["tool_call_update", "toolCallUpdate"] and terminal_acp_tool?(update) ->
        %{
          action: "end",
          id: string_value(update, :toolCallId),
          name: string_value(update, :kind) || string_value(update, :title),
          command: command_value(flexible_value(update, :rawInput)),
          outcome: string_value(update, :status) || "completed",
          output_bytes: value_bytes(flexible_value(update, :content) || flexible_value(update, :rawOutput)),
          artifact_ref: flexible_value(update, :path)
        }

      true ->
        nil
    end
  end

  defp terminal_acp_tool?(update) do
    status = update |> flexible_value(:status) |> to_string() |> String.downcase()
    status in ["completed", "failed", "error", "cancelled"]
  end

  defp command_value(value) when is_binary(value), do: value
  defp command_value(nil), do: ""
  defp command_value(value), do: inspect(value)

  defp value_bytes(value) when is_binary(value), do: byte_size(value)
  defp value_bytes(nil), do: 0
  defp value_bytes(value), do: value |> inspect() |> byte_size()

  defp maybe_transition_phase(running_entry, nil, _attrs, _policy), do: running_entry

  defp maybe_transition_phase(running_entry, phase, attrs, policy) do
    previous = Map.get(running_entry, :fleet_phase)

    if previous != phase do
      Telemetry.emit(:phase, Map.merge(attrs, %{from_phase: previous, phase: phase, action: "transition"}), policy)
      Map.put(running_entry, :fleet_phase, phase)
    else
      running_entry
    end
  end

  defp phase_for_update(update) do
    event = update |> flexible_value(:event) |> to_string()
    payload = flexible_value(update, :payload)
    method = if is_map(payload), do: string_value(payload, :method)

    cond do
      event == "session_started" -> "startup"
      event == "turn_started" -> "planning"
      event in ["turn_failed", "turn_interruption_signal"] -> "retry"
      event == "turn_input_required" -> "waiting"
      method in ["turn/completed", "item/completed"] -> "evidence"
      true -> nil
    end
  end

  defp phase_for_tool("test"), do: "validation"
  defp phase_for_tool("quality_gate"), do: "validation"
  defp phase_for_tool("evidence"), do: "evidence"
  defp phase_for_tool("file_change"), do: "implementation"
  defp phase_for_tool("delegation"), do: "planning"
  defp phase_for_tool(_category), do: nil

  defp common_attrs(running_entry, update, parent_thread_id) do
    issue = Map.get(running_entry, :issue, %{})
    actual_thread = TokenAccounting.actual_thread_id(update, parent_thread_id)

    %{
      issue_id: Map.get(issue, :id),
      issue_identifier: Map.get(issue, :identifier) || Map.get(running_entry, :identifier),
      parent_issue_id: Map.get(issue, :parent_id),
      repository: repository(issue),
      backend: Map.get(running_entry, :backend),
      model: Map.get(running_entry, :model),
      reasoning_effort: Map.get(running_entry, :reasoning_effort),
      worker_host: Map.get(running_entry, :worker_host) || "local",
      session_id: Map.get(running_entry, :session_id),
      thread_id: actual_thread,
      parent_thread_id: parent_thread_id,
      turn_id: flexible_value(update, :turn_id)
    }
  end

  defp repository(%{labels: labels}) when is_list(labels) do
    Enum.find_value(labels, fn
      "repo:" <> name -> name
      _label -> nil
    end) || "default"
  end

  defp repository(_issue), do: "default"

  defp parent_thread_id(running_entry) do
    case Map.get(running_entry, :session_id) do
      session_id when is_binary(session_id) and byte_size(session_id) >= 73 ->
        if binary_part(session_id, 36, 1) == "-", do: binary_part(session_id, 0, 36), else: session_id

      session_id when is_binary(session_id) ->
        session_id

      _missing ->
        "thread-unreported"
    end
  end

  defp tool_duration(%DateTime{} = started, %DateTime{} = finished),
    do: max(DateTime.diff(finished, started, :millisecond), 0)

  defp tool_duration(_started, _finished), do: nil

  defp command_text(item) do
    value = flexible_value(item, :command) || flexible_value(item, :arguments)
    if is_binary(value), do: value, else: inspect(value || "")
  end

  defp output_bytes(item) do
    value =
      flexible_value(item, :aggregatedOutput) || flexible_value(item, :output) || flexible_value(item, :result) ||
        flexible_value(item, :content) || ""

    if is_binary(value), do: byte_size(value), else: byte_size(inspect(value))
  end

  defp tool_outcome(item) do
    cond do
      value = flexible_value(item, :status) -> to_string(value)
      value = flexible_value(item, :exitCode) -> if value == 0, do: "ok", else: "error"
      true -> "completed"
    end
  end

  defp artifact_reference(item) do
    flexible_value(item, :artifact_ref) || flexible_value(item, :path) || flexible_value(item, :outputFile)
  end

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
