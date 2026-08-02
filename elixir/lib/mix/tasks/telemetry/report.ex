defmodule Mix.Tasks.Telemetry.Report do
  @moduledoc """
  Produce bounded fleet efficiency and quality reports from compact telemetry.

      mix telemetry.report
      mix telemetry.report --from 2026-06-01 --to 2026-06-30
      mix telemetry.report --json

  JSON contains fleet, repository, issue, parent/subagent, phase, failure and
  tool views. Legacy unversioned JSONL input is accepted; token efficiency is
  available once version 1 `token_high_water` events are present.
  """

  use Mix.Task

  alias SymphonyElixir.Telemetry
  alias SymphonyElixir.Telemetry.Report

  @shortdoc "Report Symphony fleet efficiency from compact local telemetry"

  @impl true
  def run(argv) do
    {opts, _argv, _invalid} =
      OptionParser.parse(argv,
        strict: [from: :string, to: :string, json: :boolean]
      )

    Mix.Task.run("app.start")
    from = parse_optional_date(opts[:from])
    to = parse_optional_date(opts[:to])
    summary = Telemetry.read_events(from, to) |> Report.build(from, to)

    if Keyword.get(opts, :json, false), do: IO.puts(Jason.encode!(summary)), else: print_text(summary)
  end

  defp print_text(summary) do
    fleet = summary.fleet
    Mix.shell().info("Symphony fleet efficiency (schema v#{summary.schema_version})")
    Mix.shell().info("================================================")
    Mix.shell().info("Window: #{summary.window.from || "(beginning)"} → #{summary.window.to || "(now)"}")
    Mix.shell().info("")
    Mix.shell().info("Runs: #{fleet.run_ends}/#{fleet.run_starts} completed (#{format_rate(fleet.completion_rate)})")
    Mix.shell().info("Time p50/p90: #{format_duration(fleet.duration_ms_p50)} / #{format_duration(fleet.duration_ms_p90)}")
    Mix.shell().info("Tokens: #{fleet.tokens.total_tokens} total; p50/p90 per thread #{format_number(fleet.tokens_p50)} / #{format_number(fleet.tokens_p90)}")
    Mix.shell().info("  input=#{fleet.tokens.input_tokens} cached_input=#{fleet.tokens.cached_input_tokens} output=#{fleet.tokens.output_tokens} reasoning=#{fleet.tokens.reasoning_tokens}")
    Mix.shell().info("Delegation share: #{format_rate(fleet.delegation_share)}")
    Mix.shell().info("Tool output bytes: #{fleet.output_bytes}")
    Mix.shell().info("Gate reuse: #{fleet.gate_reuse.reused} reused / #{fleet.gate_reuse.rerun} rerun (#{format_rate(fleet.gate_reuse.reuse_rate)})")

    print_map("Retries by failure class", fleet.retries_by_class)
    print_group("Repositories", summary.repositories)
    print_group("Issues", summary.issues)
    print_group("Parent/subagent reconciliation", summary.parent_subagents)
    print_group("Phases", summary.phases)
    print_map("Failure classes", summary.failures.by_class)
    print_map("Quality outcomes", fleet.quality_guardrails.outcomes)
  end

  defp print_group(_title, group) when map_size(group) == 0, do: :ok

  defp print_group(title, group) do
    Mix.shell().info("")
    Mix.shell().info("#{title}:")
    Enum.each(Enum.sort(group), fn {name, values} -> Mix.shell().info("  #{name}: #{inspect(values)}") end)
  end

  defp print_map(_title, values) when map_size(values) == 0, do: :ok

  defp print_map(title, values) do
    Mix.shell().info("")
    Mix.shell().info("#{title}:")
    Enum.each(Enum.sort(values), fn {name, count} -> Mix.shell().info("  #{name}: #{count}") end)
  end

  defp parse_optional_date(nil), do: nil
  defp parse_optional_date(""), do: nil

  defp parse_optional_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _invalid -> raise ArgumentError, "Invalid date: #{value}. Expected YYYY-MM-DD."
    end
  end

  defp format_rate(nil), do: "n/a"
  defp format_rate(rate), do: :erlang.float_to_binary(rate * 100.0, decimals: 1) <> "%"
  defp format_number(nil), do: "n/a"
  defp format_number(value), do: to_string(value)
  defp format_duration(nil), do: "n/a"
  defp format_duration(ms) when ms >= 60_000, do: "#{div(trunc(ms), 60_000)}m#{div(rem(trunc(ms), 60_000), 1_000)}s"
  defp format_duration(ms), do: "#{trunc(ms)}ms"
end
