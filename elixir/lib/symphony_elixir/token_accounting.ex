defmodule SymphonyElixir.TokenAccounting do
  @moduledoc """
  Normalizes cumulative backend usage by the *actual* agent thread.

  Provider token notifications are absolute snapshots, not deltas. Keeping one
  high-water mark per thread makes duplicate/out-of-order snapshots free while
  still retaining the latest valid usage for interrupted threads. Cached input
  and reasoning tokens remain independent dimensions; they are never added to
  `total_tokens` a second time.
  """

  @type counters :: %{
          input_tokens: non_neg_integer(),
          cached_input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          reasoning_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          context_window: non_neg_integer() | nil
        }

  @type observation :: %{
          thread_id: String.t(),
          cumulative: counters(),
          accepted_delta: counters()
        }

  @zero %{
    input_tokens: 0,
    cached_input_tokens: 0,
    output_tokens: 0,
    reasoning_tokens: 0,
    total_tokens: 0,
    context_window: nil
  }

  @doc "Observe one backend update and accept only increasing cumulative values."
  @spec observe(map(), map(), String.t() | nil) :: {map(), observation() | nil}
  def observe(high_waters, update, fallback_thread_id)
      when is_map(high_waters) and is_map(update) do
    case extract_usage(update) do
      %{} = usage -> observe_usage(high_waters, update, fallback_thread_id, usage)
      nil -> {high_waters, nil}
    end
  end

  defp observe_usage(high_waters, update, fallback_thread_id, usage) do
    thread_id = actual_thread_id(update, fallback_thread_id)
    previous = Map.get(high_waters, thread_id, @zero)
    cumulative = merge_high_water(previous, usage)
    delta = accepted_delta(previous, cumulative)

    observation = %{
      thread_id: thread_id,
      cumulative: cumulative,
      accepted_delta: delta
    }

    {Map.put(high_waters, thread_id, cumulative), observation}
  end

  @doc "Extract the backend thread identity carried by an update."
  @spec actual_thread_id(map(), String.t() | nil) :: String.t()
  def actual_thread_id(update, fallback) when is_map(update) do
    first_string([
      flexible_value(update, :thread_id),
      path(update, [:payload, :params, :threadId]),
      path(update, [:payload, :params, :thread_id]),
      path(update, [:payload, :params, :thread, :id]),
      path(update, [:payload, :params, :turn, :threadId]),
      path(update, [:payload, :params, :turn, :thread_id]),
      path(update, [:payload, :params, :msg, :threadId]),
      path(update, [:payload, :params, :msg, :thread_id]),
      path(update, [:payload, :params, :msg, :payload, :threadId]),
      path(update, [:payload, :params, :msg, :payload, :thread_id]),
      fallback
    ]) || "thread-unreported"
  end

  @doc "Return normalized cumulative usage while preserving token semantics."
  @spec extract_usage(map()) :: counters() | nil
  def extract_usage(update) when is_map(update) do
    usage =
      usage_candidates(update)
      |> Enum.find(&usage_map?/1)

    if is_map(usage) do
      input = input_tokens(usage)
      output = output_tokens(usage)
      cached = cached_input_tokens(usage)
      reasoning = reasoning_tokens(usage)
      total = token(usage, [:total_tokens, :totalTokens, :total]) || input + output
      context_window = context_window(usage, update)

      %{
        input_tokens: input,
        cached_input_tokens: cached,
        output_tokens: output,
        reasoning_tokens: reasoning,
        total_tokens: total,
        context_window: context_window
      }
    end
  end

  def extract_usage(_update), do: nil

  defp input_tokens(usage),
    do: token(usage, [:input_tokens, :inputTokens, :prompt_tokens, :promptTokens, :input]) || 0

  defp output_tokens(usage),
    do: token(usage, [:output_tokens, :outputTokens, :completion_tokens, :completionTokens, :output]) || 0

  defp cached_input_tokens(usage) do
    token(usage, [:cached_input_tokens, :cachedInputTokens, :cache_read_input_tokens, :cacheReadInputTokens]) ||
      nested_token(usage, [:input_tokens_details, :cached_tokens]) ||
      nested_token(usage, [:inputTokensDetails, :cachedTokens]) || 0
  end

  defp reasoning_tokens(usage) do
    token(usage, [:reasoning_tokens, :reasoningTokens, :reasoning_output_tokens]) ||
      nested_token(usage, [:output_tokens_details, :reasoning_tokens]) ||
      nested_token(usage, [:outputTokensDetails, :reasoningTokens]) || 0
  end

  defp context_window(usage, update) do
    token(usage, [:context_window, :contextWindow, :model_context_window, :modelContextWindow]) ||
      update_context_window(update)
  end

  @doc "Empty counter set used by callers and report fixtures."
  @spec zero() :: counters()
  def zero, do: @zero

  defp usage_candidates(update) do
    [
      flexible_value(update, :usage),
      path(update, [:payload, :params, :tokenUsage, :total]),
      path(update, [:payload, :tokenUsage, :total]),
      path(update, [:payload, :params, :msg, :payload, :info, :total_token_usage]),
      path(update, [:payload, :params, :msg, :info, :total_token_usage]),
      path(update, [:payload, :params, :usage]),
      path(update, [:payload, :usage]),
      path(update, [:payload, :params, :update, :usage]),
      path(update, [:payload, :params, :update]),
      path(update, [:payload, :usageMetadata])
    ]
  end

  defp usage_map?(value) when is_map(value) do
    Enum.any?(
      [
        :input_tokens,
        :inputTokens,
        :prompt_tokens,
        :output_tokens,
        :outputTokens,
        :completion_tokens,
        :total_tokens,
        :totalTokens,
        :total
      ],
      &(not is_nil(flexible_value(value, &1)))
    )
  end

  defp usage_map?(_value), do: false

  defp merge_high_water(previous, usage) do
    Enum.reduce(Map.keys(@zero), @zero, fn
      :context_window, acc ->
        Map.put(acc, :context_window, max_optional(previous[:context_window], usage[:context_window]))

      key, acc ->
        Map.put(acc, key, max(previous[key] || 0, usage[key] || 0))
    end)
  end

  defp accepted_delta(previous, cumulative) do
    Enum.reduce(Map.keys(@zero), @zero, fn
      :context_window, acc ->
        Map.put(acc, :context_window, cumulative.context_window)

      key, acc ->
        Map.put(acc, key, max((cumulative[key] || 0) - (previous[key] || 0), 0))
    end)
  end

  defp update_context_window(update) do
    first_integer([
      flexible_value(update, :context_window),
      path(update, [:payload, :params, :contextWindow]),
      path(update, [:payload, :params, :modelContextWindow]),
      path(update, [:payload, :params, :update, :contextWindow])
    ])
  end

  defp token(map, keys), do: keys |> Enum.map(&flexible_value(map, &1)) |> first_integer()
  defp nested_token(map, keys), do: map |> path(keys) |> integer_like()

  defp first_integer(values) when is_list(values), do: Enum.find_value(values, &integer_like/1)

  defp first_string(values) do
    Enum.find_value(values, fn
      value when is_binary(value) -> if String.trim(value) == "", do: nil, else: value
      _value -> nil
    end)
  end

  defp max_optional(nil, nil), do: nil
  defp max_optional(left, nil), do: left
  defp max_optional(nil, right), do: right
  defp max_optional(left, right), do: max(left, right)

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_float(value) and value >= 0,
    do: trunc(value)

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _invalid -> nil
    end
  end

  defp integer_like(_value), do: nil

  defp path(value, []), do: value

  defp path(map, [key | rest]) when is_map(map) do
    map |> flexible_value(key) |> path(rest)
  end

  defp path(_value, _keys), do: nil

  defp flexible_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp flexible_value(_map, _key), do: nil
end
