defmodule SymphonyElixir.ReviewTelemetry do
  @moduledoc """
  Attributes review usage to the parent reviewer and each delegated lens.

  The collector is scoped to one `ReviewGate.run/5` call and lives in that
  process. It forwards every app-server event to the lifecycle heartbeat while
  independently retaining only bounded counters and identities.
  """

  alias SymphonyElixir.{Linear.Issue, Telemetry}

  @event [:symphony_elixir, :gate, :review_thread]

  @type handle :: reference()

  @doc "Start a per-review collector and return its app-server callback."
  @spec start(Issue.t(), map(), (map() -> term()) | nil) :: {handle(), (map() -> :ok)}
  def start(%Issue{} = issue, packet, forward) do
    handle = make_ref()

    Process.put(key(handle), %{
      issue: issue,
      packet_id: packet.packet_id,
      packet_bytes: packet |> Jason.encode!() |> byte_size(),
      requested_lenses: get_in(packet, [:requested_lenses]) || [],
      reviewed_sha: packet.candidate.head_sha,
      started_ms: System.monotonic_time(:millisecond),
      order: [],
      threads: %{}
    })

    callback = fn message ->
      record(handle, message)
      forward_message(forward, message)
      :ok
    end

    {handle, callback}
  end

  @doc "Record one bounded app-server event for a review or lens thread."
  @spec record(handle(), map()) :: :ok
  def record(handle, message) when is_reference(handle) and is_map(message) do
    case Process.get(key(handle)) do
      nil -> :ok
      state -> Process.put(key(handle), update_state(state, message))
    end

    :ok
  end

  @doc "Emit one attributed telemetry event per observed review/lens thread."
  @spec finish(handle(), atom(), map() | nil) :: :ok
  def finish(handle, outcome, verdict \\ nil) when is_reference(handle) and is_atom(outcome) do
    state = Process.delete(key(handle))

    if is_map(state) do
      threads = ensure_parent_thread(state)
      parent_id = List.first(state.order) || threads |> Map.keys() |> List.first()

      Enum.each(threads, fn {thread_id, thread} ->
        emit_thread(state, thread_id, thread, parent_id, outcome, verdict)
      end)
    end

    :ok
  end

  @doc "The telemetry event emitted for every parent reviewer and lens thread."
  @spec event() :: [atom()]
  def event, do: @event

  defp key(handle), do: {__MODULE__, handle}

  defp update_state(state, message) do
    id = thread_id(message) || fallback_thread_id(state)
    new_thread? = not Map.has_key?(state.threads, id)
    thread = Map.get(state.threads, id, default_thread(message))

    thread = %{
      thread
      | model: string_value(message, :model) || thread.model,
        reasoning_effort: string_value(message, :reasoning_effort) || thread.reasoning_effort,
        tokens: max(thread.tokens, usage_tokens(message)),
        findings: max(thread.findings, finding_count(message)),
        last_ms: System.monotonic_time(:millisecond)
    }

    %{
      state
      | order: if(new_thread?, do: state.order ++ [id], else: state.order),
        threads: Map.put(state.threads, id, thread)
    }
  end

  defp default_thread(message) do
    now = System.monotonic_time(:millisecond)

    %{
      model: string_value(message, :model),
      reasoning_effort: string_value(message, :reasoning_effort),
      tokens: usage_tokens(message),
      findings: finding_count(message),
      started_ms: now,
      last_ms: now
    }
  end

  defp ensure_parent_thread(%{threads: threads}) when map_size(threads) > 0, do: threads

  defp ensure_parent_thread(state) do
    now = System.monotonic_time(:millisecond)

    %{
      "review-thread-unreported" => %{
        model: nil,
        reasoning_effort: nil,
        tokens: 0,
        findings: 0,
        started_ms: state.started_ms,
        last_ms: now
      }
    }
  end

  defp emit_thread(state, thread_id, thread, parent_id, outcome, verdict) do
    role = if thread_id == parent_id, do: "parent_reviewer", else: "lens"
    findings = if role == "parent_reviewer", do: max(thread.findings, verdict_findings(verdict)), else: thread.findings
    duration_ms = max(thread.last_ms - thread.started_ms, 0)

    attrs = %{
      subtype: "review_thread",
      issue_id: state.issue.id,
      issue_identifier: state.issue.identifier,
      packet_id: state.packet_id,
      reviewed_sha: state.reviewed_sha,
      thread_id: thread_id,
      parent_thread_id: parent_id,
      role: role,
      outcome: Atom.to_string(outcome),
      tokens: thread.tokens,
      duration_ms: duration_ms,
      model: thread.model,
      reasoning_effort: thread.reasoning_effort,
      findings: findings,
      packet_bytes: state.packet_bytes,
      requested_lenses: state.requested_lenses
    }

    Telemetry.emit(:review, attrs)
    :telemetry.execute(@event, %{count: 1, tokens: thread.tokens, duration_ms: duration_ms, findings: findings}, attrs)
  end

  defp thread_id(message) do
    [
      string_value(message, :thread_id),
      flexible_path(message, [:payload, :params, :threadId]),
      flexible_path(message, [:payload, :params, :thread_id]),
      flexible_path(message, [:payload, :params, :thread, :id]),
      flexible_path(message, [:payload, :params, :turn, :threadId]),
      flexible_path(message, [:payload, :params, :turn, :thread_id]),
      flexible_path(message, [:payload, :params, :msg, :threadId]),
      flexible_path(message, [:payload, :params, :msg, :thread_id]),
      flexible_path(message, [:payload, :params, :msg, :payload, :threadId]),
      flexible_path(message, [:payload, :params, :msg, :payload, :thread_id])
    ]
    |> Enum.find(&is_binary/1)
  end

  defp fallback_thread_id(%{order: [only_thread]}), do: only_thread
  defp fallback_thread_id(_state), do: "review-thread-unreported"

  defp string_value(map, key) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> value
      _value -> nil
    end
  end

  defp usage_tokens(message) when is_map(message) do
    message
    |> usage_candidates()
    |> Enum.find_value(0, &absolute_total/1)
  end

  defp usage_candidates(message) do
    [
      flexible_value(message, :usage),
      flexible_path(message, [:payload, :params, :tokenUsage, :total]),
      flexible_path(message, [:payload, :tokenUsage, :total]),
      flexible_path(message, [:payload, :params, :msg, :payload, :info, :total_token_usage]),
      flexible_path(message, [:payload, :params, :msg, :info, :total_token_usage]),
      flexible_path(message, [:payload, :params, :usage]),
      flexible_path(message, [:payload, :usage]),
      flexible_path(message, [:payload, :params, :update, :usage]),
      flexible_path(message, [:payload, :params, :update])
    ]
  end

  defp absolute_total(usage) when is_map(usage) do
    explicit = token_integer(usage, [:total_tokens, :totalTokens, :total])
    input = token_integer(usage, [:input_tokens, :inputTokens, :prompt_tokens, :promptTokens, :input])
    output = token_integer(usage, [:output_tokens, :outputTokens, :completion_tokens, :completionTokens, :output])

    cond do
      is_integer(explicit) -> explicit
      is_integer(input) and is_integer(output) -> input + output
      true -> nil
    end
  end

  defp absolute_total(_usage), do: nil

  defp token_integer(usage, keys) do
    Enum.find_value(keys, fn key -> usage |> flexible_value(key) |> integer_like() end)
  end

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _invalid -> nil
    end
  end

  defp integer_like(_value), do: nil

  defp flexible_path(value, []), do: value

  defp flexible_path(map, [key | rest]) when is_map(map) do
    map |> flexible_value(key) |> flexible_path(rest)
  end

  defp flexible_path(_value, _path), do: nil

  defp flexible_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp flexible_value(_map, _key), do: nil

  defp finding_count(message) do
    case Map.get(message, :findings) || Map.get(message, "findings") do
      findings when is_list(findings) -> length(findings)
      count when is_integer(count) and count >= 0 -> count
      _value -> 0
    end
  end

  defp verdict_findings(%{comments: comments}) when is_list(comments), do: length(comments)
  defp verdict_findings(_verdict), do: 0

  defp forward_message(forward, message) when is_function(forward, 1) do
    forward.(message)
    :ok
  rescue
    _error -> :ok
  end

  defp forward_message(_forward, _message), do: :ok
end
