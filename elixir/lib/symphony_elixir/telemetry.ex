defmodule SymphonyElixir.Telemetry do
  @moduledoc """
  Local-only JSONL telemetry sink for Symphony (T26).

  Per the audit (§9.7) and implementation plan: Symphony writes one JSON
  object per line to `~/.symphony/telemetry/<YYYY-MM-DD>.jsonl`. There is
  no external sink (no Langfuse, no Sentry, no Datadog) — re-evaluate
  after 60 days of data.

  Each event must be small (< 1KB target) and append-only. We never
  read these files from inside Symphony itself; the `mix
  telemetry.report` task reads and summarizes them.

  Failure-mode: telemetry must never break a run. All writes are
  best-effort, exceptions logged and swallowed.
  """

  require Logger

  @default_subdir "telemetry"

  @type event_kind ::
          :run_start
          | :run_end
          | :gate
          | :routing_skip
          | :cardinality_skip
          | :gc_removed
          | :gc_skipped
          | :gc_pass_summary

  @spec root_dir() :: String.t()
  def root_dir do
    Application.get_env(:symphony_elixir, :telemetry_dir) ||
      Path.join([System.user_home!(), ".symphony", @default_subdir])
  end

  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:symphony_elixir, :telemetry_enabled, true) == true
  end

  @doc """
  Emit a telemetry event. Adds `ts` (ISO8601) automatically. Drops the
  event silently when telemetry is disabled or the write fails.
  """
  @spec emit(event_kind(), map()) :: :ok
  def emit(kind, attrs) when is_atom(kind) and is_map(attrs) do
    if enabled?() do
      do_emit(kind, attrs)
    end

    :ok
  end

  def emit(_kind, _attrs), do: :ok

  defp do_emit(kind, attrs) do
    payload =
      attrs
      |> Map.put(:ts, DateTime.utc_now() |> DateTime.to_iso8601())
      |> Map.put(:event, Atom.to_string(kind))

    case Jason.encode(payload) do
      {:ok, encoded} ->
        path = today_path()
        File.mkdir_p(Path.dirname(path))
        File.write(path, encoded <> "\n", [:append])

      {:error, reason} ->
        Logger.debug("Telemetry encode failed: #{inspect(reason)}")
    end
  rescue
    err ->
      Logger.debug("Telemetry write failed: #{inspect(err)}")
  end

  defp today_path do
    date =
      DateTime.utc_now()
      |> DateTime.to_date()
      |> Date.to_iso8601()

    Path.join(root_dir(), "#{date}.jsonl")
  end

  @doc """
  Read and parse all JSONL telemetry files within `[from, to]` (UTC dates).
  Used by `mix telemetry.report`.
  """
  @spec read_events(Date.t() | nil, Date.t() | nil) :: [map()]
  def read_events(from, to) do
    files = list_files()

    files
    |> Enum.filter(&within_range?(&1, from, to))
    |> Enum.flat_map(&parse_jsonl_file/1)
  end

  defp list_files do
    dir = root_dir()

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp within_range?(path, from, to) do
    name = path |> Path.basename() |> String.replace_suffix(".jsonl", "")

    case Date.from_iso8601(name) do
      {:ok, date} ->
        ge?(date, from) and le?(date, to)

      _ ->
        false
    end
  end

  defp ge?(_date, nil), do: true
  defp ge?(date, %Date{} = from), do: Date.compare(date, from) != :lt

  defp le?(_date, nil), do: true
  defp le?(date, %Date{} = to), do: Date.compare(date, to) != :gt

  defp parse_jsonl_file(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&decode_jsonl_line/1)

      _ ->
        []
    end
  end

  defp decode_jsonl_line(line) do
    case Jason.decode(line) do
      {:ok, decoded} -> [decoded]
      _ -> []
    end
  end
end
