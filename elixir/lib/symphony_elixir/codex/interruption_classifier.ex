defmodule SymphonyElixir.Codex.InterruptionClassifier do
  @moduledoc false

  @terminal_methods ["turn/aborted", "turn/interrupted"]
  @abnormal_status_types ["aborted", "cancelled", "canceled", "failed", "interrupted"]
  @legacy_function_output_markers [
    "<turn_aborted>",
    "aborted by user",
    "interrupted by user",
    "turn_aborted",
    "turn/aborted",
    "turn/interrupted"
  ]

  @type classification ::
          %{kind: :terminal_method, method: String.t()}
          | %{kind: :turn_status, status: term(), status_type: String.t()}
          | %{kind: :legacy_function_output, marker: String.t()}

  @doc "Classifies protocol-level evidence that the current Codex turn was interrupted."
  @spec classify(String.t() | atom() | nil, map()) :: classification() | nil
  def classify(method, payload) when is_map(payload) do
    normalized_method = normalize_method(method)

    cond do
      normalized_method in @terminal_methods ->
        %{kind: :terminal_method, method: normalized_method}

      status_type = abnormal_turn_status_type(payload) ->
        %{kind: :turn_status, status: turn_status(payload), status_type: status_type}

      marker = legacy_function_output_marker(normalized_method, payload) ->
        %{kind: :legacy_function_output, marker: marker}

      true ->
        nil
    end
  end

  def classify(_method, _payload), do: nil

  @doc "Returns the explicit nested turn status from an app-server payload."
  @spec turn_status(map()) :: term() | nil
  def turn_status(payload) when is_map(payload) do
    payload
    |> fetch_key("params", :params)
    |> fetch_key("turn", :turn)
    |> fetch_key("status", :status)
  end

  def turn_status(_payload), do: nil

  @doc "Returns the normalized type of an explicit nested turn status."
  @spec turn_status_type(map()) :: String.t() | nil
  def turn_status_type(payload) when is_map(payload) do
    case turn_status(payload) do
      status when is_map(status) ->
        status
        |> fetch_key("type", :type)
        |> normalize_status_type()

      status ->
        normalize_status_type(status)
    end
  end

  def turn_status_type(_payload), do: nil

  @doc "Reports whether a normalized turn status is terminal and unsuccessful."
  @spec abnormal_turn_status?(term()) :: boolean()
  def abnormal_turn_status?(status_type) when is_binary(status_type) do
    String.downcase(status_type) in @abnormal_status_types
  end

  def abnormal_turn_status?(_status_type), do: false

  defp abnormal_turn_status_type(payload) do
    status_type = turn_status_type(payload)
    if abnormal_turn_status?(status_type), do: status_type
  end

  # Older Codex versions reported a user-aborted command only as a completed
  # function-call output. Keep that compatibility fallback scoped to the exact
  # event and field shape; arbitrary notification text is never turn control.
  defp legacy_function_output_marker("item/completed", payload) do
    item = payload |> fetch_key("params", :params) |> fetch_key("item", :item)

    if fetch_key(item, "type", :type) == "function_call_output" do
      item
      |> fetch_key("output", :output)
      |> matching_legacy_marker()
    end
  end

  defp legacy_function_output_marker(_method, _payload), do: nil

  defp matching_legacy_marker(output) when is_binary(output) do
    normalized_output = String.downcase(output)
    Enum.find(@legacy_function_output_markers, &String.contains?(normalized_output, &1))
  end

  defp matching_legacy_marker(_output), do: nil

  defp fetch_key(map, string_key, atom_key) when is_map(map) do
    case Map.fetch(map, string_key) do
      {:ok, value} -> value
      :error -> Map.get(map, atom_key)
    end
  end

  defp fetch_key(_value, _string_key, _atom_key), do: nil

  defp normalize_method(method) when is_binary(method), do: method
  defp normalize_method(method) when is_atom(method), do: Atom.to_string(method)
  defp normalize_method(_method), do: nil

  defp normalize_status_type(status_type) when is_binary(status_type), do: String.downcase(status_type)
  defp normalize_status_type(_status_type), do: nil
end
