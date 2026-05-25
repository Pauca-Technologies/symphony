defmodule Mix.Tasks.Telemetry.Report do
  @moduledoc """
  Symphony fleet-telemetry summary CLI (audit §9.7 / implementation plan T26).

  Reads `~/.symphony/telemetry/<YYYY-MM-DD>.jsonl` files and prints
  summary tables for fleet-scoped questions:

    * Symphony run completion rate (`run_start` vs `run_end` matched).
    * Cycle time per issue (median, p90 from `duration_ms`).
    * Routing/cardinality skip rate.

  Usage:

      mix telemetry.report
      mix telemetry.report --from 2026-06-01
      mix telemetry.report --from 2026-06-01 --to 2026-06-30
      mix telemetry.report --json

  Per-repo questions (first-pass landable-check rate, gate failure
  breakdown, etc.) belong to the consumer repo's own
  `pnpm telemetry:report`. This task is fleet-only.
  """

  use Mix.Task

  alias SymphonyElixir.Telemetry

  @shortdoc "Summarize Symphony fleet telemetry (~/.symphony/telemetry/*.jsonl)"

  @impl true
  def run(argv) do
    {opts, _argv, _invalid} =
      OptionParser.parse(argv,
        strict: [from: :string, to: :string, json: :boolean]
      )

    Mix.Task.run("app.start")

    from = parse_optional_date(opts[:from])
    to = parse_optional_date(opts[:to])

    events = Telemetry.read_events(from, to)
    summary = build_summary(events, from, to)

    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(summary))
    else
      print_text(summary)
    end
  end

  defp build_summary(events, from, to) do
    grouped = Enum.group_by(events, & &1["event"])

    starts = Map.get(grouped, "run_start", [])
    ends = Map.get(grouped, "run_end", [])
    skips_routing = Map.get(grouped, "routing_skip", [])
    skips_card = Map.get(grouped, "cardinality_skip", [])

    completion_rate =
      case length(starts) do
        0 -> nil
        n -> Float.round(length(ends) / n, 3)
      end

    durations =
      ends
      |> Enum.flat_map(fn event ->
        case event["duration_ms"] do
          n when is_integer(n) and n >= 0 -> [n]
          _ -> []
        end
      end)
      |> Enum.sort()

    %{
      from: format_date(from),
      to: format_date(to),
      run_starts: length(starts),
      run_ends: length(ends),
      completion_rate: completion_rate,
      duration_ms_median: percentile(durations, 0.5),
      duration_ms_p90: percentile(durations, 0.9),
      routing_skips: length(skips_routing),
      cardinality_skips: length(skips_card),
      outcomes: tally_outcomes(ends)
    }
  end

  defp tally_outcomes(ends) do
    Enum.reduce(ends, %{}, fn event, acc ->
      key =
        case event["outcome"] do
          v when is_binary(v) -> v
          _ -> "unknown"
        end

      Map.update(acc, key, 1, &(&1 + 1))
    end)
  end

  defp percentile([], _q), do: nil

  defp percentile(sorted, q) when is_list(sorted) and q >= 0 and q <= 1 do
    n = length(sorted)
    idx = max(0, min(n - 1, trunc(q * (n - 1))))
    Enum.at(sorted, idx)
  end

  defp print_text(s) do
    Mix.shell().info("Symphony fleet telemetry")
    Mix.shell().info("========================")
    Mix.shell().info("Window: #{s.from || "(beginning)"} → #{s.to || "(now)"}")
    Mix.shell().info("")
    Mix.shell().info("Runs started:  #{s.run_starts}")
    Mix.shell().info("Runs ended:    #{s.run_ends}")
    Mix.shell().info("Completion rate: #{format_rate(s.completion_rate)}")
    Mix.shell().info("Duration p50:  #{format_duration(s.duration_ms_median)}")
    Mix.shell().info("Duration p90:  #{format_duration(s.duration_ms_p90)}")
    Mix.shell().info("Routing skips: #{s.routing_skips}")
    Mix.shell().info("Cardinality skips: #{s.cardinality_skips}")

    if s.outcomes != %{} do
      Mix.shell().info("")
      Mix.shell().info("Outcomes:")

      Enum.each(s.outcomes, fn {outcome, count} ->
        Mix.shell().info("  #{outcome}: #{count}")
      end)
    end
  end

  defp parse_optional_date(nil), do: nil
  defp parse_optional_date(""), do: nil

  defp parse_optional_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> raise ArgumentError, "Invalid date: #{value}. Expected YYYY-MM-DD."
    end
  end

  defp format_date(nil), do: nil
  defp format_date(%Date{} = d), do: Date.to_iso8601(d)

  defp format_rate(nil), do: "n/a"
  defp format_rate(rate) when is_number(rate), do: :erlang.float_to_binary(rate * 1.0, decimals: 1) <> "%"

  defp format_duration(nil), do: "n/a"

  defp format_duration(ms) when is_integer(ms) and ms >= 60_000 do
    seconds = div(ms, 1000)
    "#{div(seconds, 60)}m#{rem(seconds, 60)}s"
  end

  defp format_duration(ms) when is_integer(ms), do: "#{ms}ms"
end
