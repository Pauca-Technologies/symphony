defmodule SymphonyElixir.AgentFailure do
  @moduledoc """
  Stable classification for failures crossing an agent-backend boundary.

  Backends retain their protocol-specific error as `details`, while the
  orchestrator consumes the small, backend-neutral `class`, `scope`, and
  retry/reset fields. Only exact provider signals are marked `trusted`; loose
  message matching must never turn an issue-local failure into a fleet-wide
  circuit.
  """

  @enforce_keys [:class, :message]
  defstruct [
    :class,
    :message,
    :backend,
    :reset_at,
    :retry_after_ms,
    :details,
    scope: :issue,
    trusted: false
  ]

  @type class ::
          :agent_protocol_failure
          | :response_timeout_or_stall
          | :transient_infrastructure
          | :authentication_configuration
          | :usage_quota_limit
          | :rate_limited
          | :review_configuration
          | :handoff_reviewer_gate

  @type t :: %__MODULE__{
          class: class(),
          message: String.t(),
          backend: String.t() | nil,
          scope: :issue | :backend_account,
          trusted: boolean(),
          reset_at: DateTime.t() | nil,
          retry_after_ms: non_neg_integer() | nil,
          details: term()
        }

  @usage_limit_code "usageLimitExceeded"
  @reset_keys ~w(resetAt reset_at resetsAt resets_at resetTime reset_time retryAt retry_at)
  @retry_after_keys ~w(retryAfterMs retry_after_ms retryAfter retry_after)
  @auth_tags [
    :authentication_failed,
    :authentication_error,
    :unauthorized,
    :invalid_api_key,
    :missing_api_key,
    :github_auth_failed,
    :invalid_configuration,
    :invalid_workflow_config
  ]
  @handoff_tags [
    :handoff_failed,
    :handoff_gate_failed,
    :handoff_review_timeout,
    :review_failed,
    :review_timeout,
    :gate_failed
  ]
  @infrastructure_tags [
    :handoff_gate_infrastructure,
    :review_gate_infrastructure,
    :review_packet_unavailable,
    :port_exit,
    :failed_to_spawn,
    :spawn_failed,
    :ssh_failed,
    :workspace_create_failed,
    :bash_not_found
  ]

  @doc "Classify a backend/protocol error without widening ambiguous failures."
  @spec classify(term(), keyword()) :: t()
  def classify(reason, opts \\ [])

  def classify(%__MODULE__{} = failure, opts) do
    case Keyword.get(opts, :backend) do
      backend when is_binary(backend) and is_nil(failure.backend) -> %{failure | backend: backend}
      _ -> failure
    end
  end

  def classify(reason, opts) do
    backend = Keyword.get(opts, :backend)

    if trusted_usage_limit?(reason, backend) do
      %__MODULE__{
        class: :usage_quota_limit,
        message: reason_message(reason),
        backend: backend,
        scope: :backend_account,
        trusted: true,
        reset_at: extract_reset_at(reason),
        details: reason
      }
    else
      classify_non_usage_limit_failure(reason, backend)
    end
  end

  defp classify_non_usage_limit_failure(reason, backend) do
    case nested_rate_limit(reason) do
      {:ok, retry_after_ms} ->
        %__MODULE__{
          class: :rate_limited,
          message: reason_message(reason),
          backend: backend,
          retry_after_ms: retry_after_ms,
          details: reason
        }

      :error ->
        classify_non_rate_limit_failure(reason, backend)
    end
  end

  defp classify_non_rate_limit_failure(reason, backend) do
    cond do
      transient_transport_failure?(reason) ->
        failure(:transient_infrastructure, reason, backend)

      timeout_or_stall?(reason) ->
        failure(:response_timeout_or_stall, reason, backend)

      deterministic_review_configuration_failure?(reason) ->
        failure(:review_configuration, reason, backend)

      tagged?(reason, @auth_tags) ->
        failure(:authentication_configuration, reason, backend)

      tagged?(reason, @handoff_tags) ->
        failure(:handoff_reviewer_gate, reason, backend)

      tagged?(reason, @infrastructure_tags) ->
        failure(:transient_infrastructure, reason, backend)

      true ->
        failure(:agent_protocol_failure, reason, backend)
    end
  end

  defp nested_rate_limit({:rate_limited, value})
       when (is_integer(value) and value >= 0) or is_nil(value),
       do: {:ok, value}

  defp nested_rate_limit({:rate_limited, value}), do: {:ok, retry_after_ms(value)}

  defp nested_rate_limit(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> nested_rate_limit()
  end

  defp nested_rate_limit(list) when is_list(list) do
    Enum.find_value(list, :error, fn value ->
      case nested_rate_limit(value) do
        {:ok, _retry_after_ms} = found -> found
        :error -> false
      end
    end)
  end

  defp nested_rate_limit(%_{} = struct),
    do: struct |> Map.from_struct() |> nested_rate_limit()

  defp nested_rate_limit(map) when is_map(map),
    do: nested_rate_limit(Map.to_list(map))

  defp nested_rate_limit(_reason), do: :error

  @doc "Return a JSON/dashboard-safe representation of a classified failure."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = failure) do
    %{
      class: Atom.to_string(failure.class),
      message: failure.message,
      backend: failure.backend,
      scope: Atom.to_string(failure.scope),
      trusted: failure.trusted,
      reset_at: iso8601(failure.reset_at),
      retry_after_ms: failure.retry_after_ms
    }
  end

  @doc "True only for a rate-limit payload that positively proves availability."
  @spec recovered_rate_limits?(term()) :: boolean()
  def recovered_rate_limits?(rate_limits) when is_map(rate_limits) do
    credits = map_value(rate_limits, ["credits", :credits])
    primary = map_value(rate_limits, ["primary", :primary])
    secondary = map_value(rate_limits, ["secondary", :secondary])

    positive_credits?(credits) or available_bucket?(primary) or available_bucket?(secondary)
  end

  def recovered_rate_limits?(_rate_limits), do: false

  defp failure(class, reason, backend) do
    %__MODULE__{
      class: class,
      message: reason_message(reason),
      backend: backend,
      details: reason
    }
  end

  defp trusted_usage_limit?(reason, "codex") do
    deep_value(reason, ["codexErrorInfo", :codexErrorInfo, "codex_error_info", :codex_error_info]) ==
      @usage_limit_code
  end

  defp trusted_usage_limit?(_reason, _backend), do: false

  defp timeout_or_stall?(reason) do
    tagged?(reason, [:response_timeout, :turn_timeout, :prompt_timeout, :stall, :stalled])
  end

  defp deterministic_review_configuration_failure?(reason) do
    contains_atom?(reason, :packet_bound_unachievable) or
      contains_internal_marker?(reason, "packet_bound_unachievable") or
      ((contains_atom?(reason, :review_gate_infrastructure) or
          contains_atom?(reason, :review_session_failed)) and
         contains_internal_marker?(reason, "contextWindowExceeded"))
  end

  defp contains_internal_marker?(value, marker) when is_binary(value),
    do: String.contains?(value, marker)

  defp contains_internal_marker?(tuple, marker) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.any?(&contains_internal_marker?(&1, marker))

  defp contains_internal_marker?(list, marker) when is_list(list),
    do: Enum.any?(list, &contains_internal_marker?(&1, marker))

  defp contains_internal_marker?(%_{} = struct, marker),
    do: struct |> Map.from_struct() |> contains_internal_marker?(marker)

  defp contains_internal_marker?(map, marker) when is_map(map) do
    Enum.any?(map, fn {key, value} ->
      contains_internal_marker?(key, marker) or contains_internal_marker?(value, marker)
    end)
  end

  defp contains_internal_marker?(_value, _marker), do: false

  defp tagged?(reason, tags) when is_list(tags) do
    Enum.any?(tags, &contains_atom?(reason, &1))
  end

  defp contains_atom?(atom, atom), do: true

  defp contains_atom?(tuple, atom) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.any?(&contains_atom?(&1, atom))
  end

  defp contains_atom?(list, atom) when is_list(list), do: Enum.any?(list, &contains_atom?(&1, atom))

  defp contains_atom?(%_{} = struct, atom),
    do: struct |> Map.from_struct() |> contains_atom?(atom)

  defp contains_atom?(map, atom) when is_map(map) do
    Enum.any?(map, fn {key, value} -> contains_atom?(key, atom) or contains_atom?(value, atom) end)
  end

  defp contains_atom?(_reason, _atom), do: false

  defp transient_transport_failure?(%Req.TransportError{}), do: true
  defp transient_transport_failure?(%Req.HTTPError{protocol: :http2, reason: :unprocessed}), do: true

  defp transient_transport_failure?({:linear_api_status, status})
       when is_integer(status) and status >= 500,
       do: true

  defp transient_transport_failure?(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.any?(&transient_transport_failure?/1)
  end

  defp transient_transport_failure?(list) when is_list(list),
    do: Enum.any?(list, &transient_transport_failure?/1)

  defp transient_transport_failure?(%_{} = struct),
    do: struct |> Map.from_struct() |> transient_transport_failure?()

  defp transient_transport_failure?(map) when is_map(map) do
    Enum.any?(map, fn {key, value} ->
      transient_transport_failure?(key) or transient_transport_failure?(value)
    end)
  end

  defp transient_transport_failure?(_reason), do: false

  defp extract_reset_at(reason) do
    reason
    |> deep_value(@reset_keys ++ Enum.map(@reset_keys, &String.to_atom/1))
    |> parse_datetime()
    |> case do
      %DateTime{} = reset_at -> reset_at
      nil -> parse_reset_from_message(reason_message(reason))
    end
  end

  defp retry_after_ms(reason) do
    case deep_value(reason, @retry_after_keys ++ Enum.map(@retry_after_keys, &String.to_atom/1)) do
      value when is_integer(value) and value >= 0 -> value
      _ -> nil
    end
  end

  defp parse_datetime(%DateTime{} = datetime), do: datetime

  defp parse_datetime(value) when is_integer(value) and value > 0 do
    unit = if value > 10_000_000_000, do: :millisecond, else: :second

    case DateTime.from_unix(value, unit) do
      {:ok, datetime} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  # Codex currently also embeds a UTC reset hint in its authoritative
  # usageLimitExceeded message. This parser is deliberately narrow and is only
  # reached after the exact provider code above has established trust.
  defp parse_reset_from_message(message) when is_binary(message) do
    regex =
      ~r/\bat\s+(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\s+(\d{1,2})(?:st|nd|rd|th)?,\s+(\d{4})\s+(\d{1,2}):(\d{2})\s+(AM|PM)\b/i

    case Regex.run(regex, message) do
      [_, month, day, year, hour, minute, meridiem] ->
        with month when is_integer(month) <- month_number(month),
             {day, ""} <- Integer.parse(day),
             {year, ""} <- Integer.parse(year),
             {hour, ""} <- Integer.parse(hour),
             {minute, ""} <- Integer.parse(minute),
             {:ok, date} <- Date.new(year, month, day),
             {:ok, time} <- Time.new(hour_24(hour, meridiem), minute, 0),
             {:ok, datetime} <- DateTime.new(date, time, "Etc/UTC") do
          datetime
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_reset_from_message(_message), do: nil

  defp month_number(month) do
    month
    |> String.downcase()
    |> String.slice(0, 3)
    |> then(&Enum.find_index(~w(jan feb mar apr may jun jul aug sep oct nov dec), fn item -> item == &1 end))
    |> case do
      nil -> nil
      index -> index + 1
    end
  end

  defp hour_24(12, meridiem) when meridiem in ["AM", "am"], do: 0
  defp hour_24(hour, meridiem) when meridiem in ["PM", "pm"] and hour < 12, do: hour + 12
  defp hour_24(hour, _meridiem), do: hour

  defp deep_value(%_{} = struct, keys), do: struct |> Map.from_struct() |> deep_value(keys)

  defp deep_value(value, keys) when is_map(value) do
    Enum.find_value(keys, &Map.get(value, &1)) ||
      Enum.find_value(value, fn {_key, nested} -> deep_value(nested, keys) end)
  end

  defp deep_value(value, keys) when is_tuple(value) do
    value |> Tuple.to_list() |> deep_value(keys)
  end

  defp deep_value(value, keys) when is_list(value) do
    Enum.find_value(value, &deep_value(&1, keys))
  end

  defp deep_value(_value, _keys), do: nil

  defp reason_message(reason) do
    deep_value(reason, ["message", :message]) || inspect(reason, limit: 30, printable_limit: 1_000)
  end

  defp positive_credits?(credits) when is_map(credits) do
    map_value(credits, ["unlimited", :unlimited]) == true or
      map_value(credits, ["hasCredits", :hasCredits, "has_credits", :has_credits]) == true
  end

  defp positive_credits?(_credits), do: false

  defp available_bucket?(bucket) when is_map(bucket) do
    used = map_value(bucket, ["usedPercent", :usedPercent, "used_percent", :used_percent])
    remaining = map_value(bucket, ["remaining", :remaining])

    (is_number(used) and used < 100) or (is_number(remaining) and remaining > 0)
  end

  defp available_bucket?(_bucket), do: false

  defp map_value(map, keys) when is_map(map), do: Enum.find_value(keys, &Map.get(map, &1))

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(_datetime), do: nil
end
