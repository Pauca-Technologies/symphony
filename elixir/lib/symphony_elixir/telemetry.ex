defmodule SymphonyElixir.Telemetry do
  @moduledoc """
  Versioned, compact, local-only fleet analytics.

  Version 1 events are append-only JSONL under
  `~/.symphony/telemetry/<YYYY-MM-DD>.jsonl`. The envelope is stable and small:
  `schema_version`, `event`, `category`, `ts`, and event-specific fields. Old
  unversioned JSONL remains readable as schema version 0.

  Values are recursively redacted before persistence. Telemetry is best effort:
  an encoding, retention, or disk failure never breaks an agent run.
  """

  require Logger

  alias SymphonyElixir.{Config, Utf8}

  @default_subdir "telemetry"
  @schema_version 1
  @max_string_bytes 8_192
  @benign_debug_cache_key {__MODULE__, :benign_notification_debug}
  @context_key {__MODULE__, :event_context}

  @type event_kind ::
          :run_start
          | :run_end
          | :run_manifest
          | :experiment_exposure
          | :experiment_suspended
          | :task_outcome
          | :no_progress_loop
          | :prompt_built
          | :lifecycle
          | :token_high_water
          | :phase
          | :tool
          | :retry_policy
          | :failure
          | :quota_circuit
          | :gate
          | :review
          | :lease
          | :base_drift
          | :quality_outcome
          | :routing_decision
          | :review_routing_decision
          | :budget_transition
          | :scheduling
          | :routing_skip
          | :cardinality_skip
          | :gc_removed
          | :gc_skipped
          | :gc_pass_summary

  @doc "Current fleet-event schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec root_dir() :: String.t()
  def root_dir do
    Application.get_env(:symphony_elixir, :telemetry_dir) ||
      Path.join([System.user_home!(), ".symphony", @default_subdir])
  end

  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:symphony_elixir, :telemetry_enabled, true) == true
  end

  @doc "Emit one redacted fleet event."
  @spec emit(event_kind(), map()) :: :ok
  def emit(kind, attrs) when is_atom(kind) and is_map(attrs) do
    if enabled?(), do: do_emit(kind, attrs, redact_fields())
    :ok
  end

  def emit(_kind, _attrs), do: :ok

  @doc "Emit one fleet event using a policy snapshot captured for the current run."
  @spec emit(event_kind(), map(), map()) :: :ok
  def emit(kind, attrs, policy) when is_atom(kind) and is_map(attrs) and is_map(policy) do
    if enabled?(), do: do_emit(kind, attrs, policy_redact_fields(policy))
    :ok
  end

  def emit(_kind, _attrs, _policy), do: :ok

  @doc "Run a function with additive fleet-event context scoped to the current process."
  @spec with_context(map(), (-> result)) :: result when result: term()
  def with_context(context, fun) when is_map(context) and is_function(fun, 0) do
    previous = Process.get(@context_key)
    Process.put(@context_key, Map.merge(previous || %{}, context))

    try do
      fun.()
    after
      if is_map(previous),
        do: Process.put(@context_key, previous),
        else: Process.delete(@context_key)
    end
  end

  @doc "Return the fleet-event context scoped to the current process."
  @spec current_context() :: map()
  def current_context, do: Process.get(@context_key, %{})

  @doc "Build the exact versioned/redacted document written by `emit/2`."
  @spec build_event(event_kind(), map(), DateTime.t()) :: map()
  def build_event(kind, attrs, %DateTime{} = timestamp) when is_atom(kind) and is_map(attrs) do
    event = Atom.to_string(kind)

    attrs
    |> redact()
    |> bound_event_strings()
    |> Map.put("schema_version", @schema_version)
    |> Map.put("event", event)
    |> Map.put("category", category(event, attrs))
    |> Map.put("ts", DateTime.to_iso8601(timestamp))
  end

  @doc "Recursively redact configured secret fields while preserving document shape."
  @spec redact(term()) :: term()
  def redact(value), do: sanitize(value, redact_fields())

  @doc "Recursively redact explicit secret fields without truncating the document."
  @spec redact(term(), [String.t()]) :: term()
  def redact(value, fields) when is_list(fields), do: sanitize(value, effective_redact_fields(fields))

  @doc "Read legacy and versioned JSONL fleet events in a UTC date window."
  @spec read_events(Date.t() | nil, Date.t() | nil) :: [map()]
  def read_events(from, to) do
    root_dir()
    |> list_files()
    |> Enum.filter(&within_range?(&1, from, to))
    |> Enum.flat_map(&parse_event_file/1)
  end

  @doc "Read a date window with explicit newest-file and newest-event bounds."
  @spec read_events(Date.t() | nil, Date.t() | nil, keyword()) :: [map()]
  def read_events(from, to, opts) when is_list(opts) do
    max_files = positive_limit(Keyword.get(opts, :max_files), 60)
    max_events = positive_limit(Keyword.get(opts, :max_events), 50_000)

    root_dir()
    |> list_files()
    |> Enum.filter(&within_range?(&1, from, to))
    |> Enum.take(-max_files)
    |> Enum.reverse()
    |> Enum.reduce_while({[], max_events}, fn path, {acc, remaining} ->
      rows = path |> parse_event_file() |> Enum.take(-remaining)
      next = {rows ++ acc, remaining - length(rows)}
      if elem(next, 1) == 0, do: {:halt, next}, else: {:cont, next}
    end)
    |> elem(0)
  end

  @doc "Delete analytics files older than the configured rolling window."
  @spec prune() :: :ok
  def prune do
    cutoff = Date.add(Date.utc_today(), -observability().telemetry_retention_days)

    root_dir()
    |> list_files()
    |> Enum.each(&prune_path(&1, cutoff))

    :ok
  rescue
    error ->
      Logger.debug("Telemetry retention failed: #{Exception.message(error)}")
      :ok
  end

  defp prune_path(path, cutoff) do
    case date_from_path(path) do
      {:ok, date} -> if Date.compare(date, cutoff) == :lt, do: File.rm(path), else: :ok
      _current_or_unknown -> :ok
    end
  end

  @doc "Configured observability policy with safe defaults when config is unavailable."
  @spec observability() :: map()
  def observability do
    Config.observability_settings()
  rescue
    _error ->
      %{
        telemetry_retention_days: 30,
        session_retention_days: 30,
        raw_trace_retention_days: 7,
        raw_trace_policy: "failures",
        raw_trace_sample_rate: 0.01,
        raw_trace_debug: false,
        session_compaction_enabled: true,
        benign_notification_debug: false,
        prompt_debug: false,
        prompt_debug_max_bytes: 32_000,
        redact_fields: default_redact_fields()
      }
  end

  @doc "Whether benign protocol chatter should be debug-logged for this process lifecycle."
  @spec benign_notification_debug?() :: boolean()
  def benign_notification_debug? do
    cached_benign_notification_debug(@benign_debug_cache_key, &observability/0)
  end

  @doc false
  @spec benign_notification_debug_for_test(term(), (-> map())) :: boolean()
  def benign_notification_debug_for_test(cache_key, resolver) when is_function(resolver, 0) do
    cached_benign_notification_debug(cache_key, resolver)
  end

  defp do_emit(kind, attrs, fields) do
    payload = build_event(kind, Map.merge(current_context(), attrs), DateTime.utc_now(), fields)

    with {:ok, encoded} <- Jason.encode(payload),
         path <- today_path(),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, encoded <> "\n", [:append]) do
      maybe_prune_today()
      :ok
    else
      {:error, reason} -> Logger.debug("Telemetry write failed: #{inspect(reason)}")
    end
  rescue
    error -> Logger.debug("Telemetry write failed: #{Exception.message(error)}")
  end

  defp maybe_prune_today do
    today = Date.utc_today()

    if Process.get({__MODULE__, :last_prune}) != today do
      Process.put({__MODULE__, :last_prune}, today)
      prune()
    end
  end

  defp today_path do
    Path.join(root_dir(), "#{Date.to_iso8601(Date.utc_today())}.jsonl")
  end

  defp list_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&(String.ends_with?(&1, ".jsonl") or String.ends_with?(&1, ".jsonl.gz")))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.sort()

      {:error, _reason} ->
        []
    end
  end

  defp positive_limit(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_limit(_value, default), do: default

  defp within_range?(path, from, to) do
    case date_from_path(path) do
      {:ok, date} -> (is_nil(from) or Date.compare(date, from) != :lt) and (is_nil(to) or Date.compare(date, to) != :gt)
      _invalid -> false
    end
  end

  defp date_from_path(path) do
    name = path |> Path.basename() |> String.replace_suffix(".gz", "") |> String.replace_suffix(".jsonl", "")
    Date.from_iso8601(name)
  end

  defp parse_event_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- maybe_gunzip(path, content) do
      decoded
      |> String.split("\n", trim: true)
      |> Enum.flat_map(&decode_jsonl_line/1)
    else
      _unreadable -> []
    end
  end

  defp maybe_gunzip(path, content) do
    if String.ends_with?(path, ".gz") do
      {:ok, :zlib.gunzip(content)}
    else
      {:ok, content}
    end
  rescue
    _error -> {:error, :invalid_gzip}
  end

  defp decode_jsonl_line(line) do
    case Jason.decode(line) do
      {:ok, decoded} when is_map(decoded) -> [Map.put_new(decoded, "schema_version", 0)]
      _invalid -> []
    end
  end

  defp sanitize(%DateTime{} = value, _fields), do: DateTime.to_iso8601(value)

  defp sanitize(value, fields) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      normalized_key = to_string(key)

      sanitized =
        if redacted_key?(normalized_key, fields) do
          "[REDACTED]"
        else
          sanitize(nested, fields)
        end

      Map.put(acc, normalized_key, sanitized)
    end)
  end

  defp sanitize(value, fields) when is_list(value), do: Enum.map(value, &sanitize(&1, fields))
  defp sanitize(value, _fields) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp sanitize(value, _fields) when is_atom(value), do: Atom.to_string(value)

  defp sanitize(value, _fields) when is_binary(value), do: value

  defp sanitize(value, _fields), do: inspect(value, limit: 20)

  defp bound_event_strings(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, bound_event_strings(nested)} end)
  end

  defp bound_event_strings(value) when is_list(value), do: Enum.map(value, &bound_event_strings/1)

  defp bound_event_strings(value) when is_binary(value) do
    if byte_size(value) > @max_string_bytes do
      Utf8.safe_byte_prefix(value, @max_string_bytes) <> "…[truncated sha256=#{sha256(value)}]"
    else
      value
    end
  end

  defp bound_event_strings(value), do: value

  defp redacted_key?(key, fields) do
    canonical = canonical_key(key)
    Enum.any?(fields, &(canonical_key(&1) == canonical))
  end

  defp canonical_key(key), do: key |> String.downcase() |> String.replace(["_", "-"], "")

  defp redact_fields do
    observability().redact_fields
  end

  defp policy_redact_fields(policy) do
    policy
    |> then(&(Map.get(&1, :redact_fields) || Map.get(&1, "redact_fields") || []))
    |> effective_redact_fields()
  end

  defp effective_redact_fields(fields), do: Enum.uniq(default_redact_fields() ++ fields)

  defp cached_benign_notification_debug(cache_key, resolver) do
    case Process.get(cache_key) do
      value when is_boolean(value) ->
        value

      _missing ->
        value = resolver.().benign_notification_debug == true
        Process.put(cache_key, value)
        value
    end
  end

  defp default_redact_fields do
    [
      "authorization",
      "api_key",
      "token",
      "access_token",
      "refresh_token",
      "cookie",
      "set-cookie",
      "password",
      "secret",
      "client_secret",
      "private_key",
      "x-api-key"
    ]
  end

  defp build_event(kind, attrs, timestamp, fields) do
    event = Atom.to_string(kind)

    attrs
    |> redact(fields)
    |> bound_event_strings()
    |> Map.put("schema_version", @schema_version)
    |> Map.put("event", event)
    |> Map.put("category", category(event, attrs))
    |> Map.put("ts", DateTime.to_iso8601(timestamp))
  end

  defp category("run_" <> _rest, _attrs), do: "run"
  defp category("gc_" <> _rest, _attrs), do: "retention"
  defp category("quota_circuit", _attrs), do: "circuit"
  defp category("retry_policy", _attrs), do: "failure"
  defp category("prompt_built", _attrs), do: "prompt"
  defp category(event, _attrs), do: event

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
