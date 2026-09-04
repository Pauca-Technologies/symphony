defmodule Mix.Tasks.Telemetry.ExperimentReport do
  @moduledoc """
  Produces a bounded descriptive report for explicitly opted-in experiments.

      mix telemetry.experiment_report --days 7
      mix telemetry.experiment_report --days 30 --through 2026-09-03 --json
      mix telemetry.experiment_report --experiment effort-runtime --revision 1 --repository symphony

  This offline task never changes experiment mode or routing. Comparisons are
  descriptive and retries are reported as run exposures, never repeated trials.
  """

  use Mix.Task

  alias SymphonyElixir.Telemetry
  alias SymphonyElixir.Telemetry.ExperimentEvaluation

  @shortdoc "Reports bounded descriptive experiment cohorts from compact telemetry"
  @switches [
    days: :integer,
    through: :string,
    experiment: :string,
    revision: :integer,
    repository: :string,
    task_family: :string,
    json: :boolean
  ]
  @safe_id ~r/\A[a-z0-9][a-z0-9._-]*\z/
  @task_families ~w(simple_direct ui security_tenant data_schema concurrency_liveness broad_architecture)
  @max_events 50_000
  @max_files 60

  @impl Mix.Task
  def run(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, [], []} -> run_checked(opts)
      _invalid -> Mix.raise("invalid experiment report arguments; run mix help telemetry.experiment_report")
    end
  end

  defp run_checked(opts) do
    days = Keyword.get(opts, :days, 7)
    through = parse_through!(Keyword.get(opts, :through))
    experiment_id = parse_experiment!(Keyword.get(opts, :experiment))
    revision = parse_revision!(Keyword.get(opts, :revision))
    repository = parse_safe_id!(Keyword.get(opts, :repository), "--repository")
    task_family = parse_task_family!(Keyword.get(opts, :task_family))

    unless days in [7, 30], do: Mix.raise("--days must be exactly 7 or 30")

    from = Date.add(through, 1 - days)

    report =
      Telemetry.read_events(from, through,
        max_files: min(days * 2, @max_files),
        max_events: @max_events
      )
      |> ExperimentEvaluation.build(
        window_days: days,
        through: through,
        experiment_id: experiment_id,
        revision: revision,
        repository: repository,
        task_family: task_family
      )

    if Keyword.get(opts, :json, false), do: Mix.shell().info(Jason.encode!(report)), else: print_report(report)
  end

  defp print_report(report) do
    Mix.shell().info("Symphony experiment report (schema v#{report.schema_version}; descriptive only)")
    Mix.shell().info("Window: #{report.window.from} through #{report.window.to} (#{report.window.days} days)")

    Mix.shell().info(
      "Input: #{report.diagnostics.events_considered} events; " <>
        "#{report.diagnostics.events_omitted} omitted by cap; " <>
        "#{report.diagnostics.invalid_experiment_events} malformed experiment events ignored"
    )

    if report.experiments == [] do
      Mix.shell().info("No valid experiment cohorts matched the selected window and filters.")
    else
      Enum.each(report.experiments, &print_experiment/1)
    end
  end

  defp print_experiment(experiment) do
    units = experiment.units

    Mix.shell().info("")

    Mix.shell().info(
      "Experiment #{experiment.experiment_id} revision #{experiment.revision}: " <>
        "repository=#{experiment.repository} task=#{experiment.task_family}; " <>
        "units #{units.comparable}/#{units.observed} comparable, #{units.contaminated} contaminated"
    )

    print_counts("  contamination", experiment.contamination)
    Enum.each(experiment.arms, &print_arm/1)
    Enum.each(experiment.comparisons, &print_comparison/1)
    Mix.shell().info("  pairing and Pass@k/Pass^k: unavailable (no_repeated_trial_protocol)")
  end

  defp print_arm(arm) do
    runs = arm.metrics.worker_runs
    outcomes = arm.metrics.task_outcomes
    handoff = arm.metrics.post_handoff
    duration = arm.metrics.duration_ms
    tokens = arm.metrics.tokens
    cost = arm.metrics.explicit_cost_usd

    Mix.shell().info(
      "  arm #{arm.arm_id} (#{arm.role}, effort=#{arm.reasoning_effort}): " <>
        "exposures=#{arm.exposures.comparable} " <>
        "(initial=#{arm.exposures.initial_runs}, retry=#{arm.exposures.retry_runs}); " <>
        "worker-ended=#{runs.ended}/#{runs.denominator}; normal=#{runs.completed_normally}/#{runs.denominator}; " <>
        "exact-head=#{outcomes.exact_head_accepted_runs}/#{outcomes.run_denominator}"
    )

    Mix.shell().info(
      "    post-handoff reliable=#{handoff.reliable}/#{handoff.evaluated} " <>
        "unknown=#{handoff.unknown}; duration p50/p90=#{number(duration.p50)}/#{number(duration.p90)}ms; " <>
        "tokens total=#{tokens.total} p50/p90=#{number(tokens.p50)}/#{number(tokens.p90)}; " <>
        "explicit cost=#{cost(cost.total)}"
    )
  end

  defp print_comparison(comparison) do
    Mix.shell().info(
      "  descriptive delta #{comparison.treatment_arm_id} - #{comparison.control_arm_id}: " <>
        "worker completion=#{delta(comparison.deltas.worker_completion_rate)}; " <>
        "exact-head=#{delta(comparison.deltas.exact_head_acceptance_rate)}; " <>
        "post-handoff=#{delta(comparison.deltas.post_handoff_reliability_rate)}; " <>
        "tokens p50=#{delta(comparison.deltas.tokens_p50)}"
    )
  end

  defp print_counts(_label, counts) when map_size(counts) == 0, do: :ok

  defp print_counts(label, counts) do
    rendered = counts |> Enum.sort() |> Enum.map_join(", ", fn {key, value} -> "#{key}=#{value}" end)
    Mix.shell().info("#{label}: #{rendered}")
  end

  defp delta(%{available: true, delta: value}), do: signed(value)
  defp delta(%{available: false, reason: reason}), do: "unavailable(#{reason})"

  defp signed(value) when is_number(value) and value >= 0, do: "+#{value}"
  defp signed(value), do: to_string(value)
  defp number(nil), do: "n/a"
  defp number(value), do: to_string(value)
  defp cost(nil), do: "unavailable"
  defp cost(value), do: "$#{value}"

  defp parse_through!(nil), do: Date.utc_today()

  defp parse_through!(value) do
    with true <- is_binary(value) and Regex.match?(~r/\A\d{4}-\d{2}-\d{2}\z/, value),
         {:ok, date} <- Date.from_iso8601(value) do
      date
    else
      _invalid -> Mix.raise("--through must be an ISO date in YYYY-MM-DD form")
    end
  end

  defp parse_experiment!(value), do: parse_safe_id!(value, "--experiment")

  defp parse_safe_id!(nil, _flag), do: nil

  defp parse_safe_id!(value, flag) when is_binary(value) and byte_size(value) <= 64 do
    if Regex.match?(@safe_id, value), do: value, else: Mix.raise("#{flag} is not a safe id")
  end

  defp parse_safe_id!(_value, flag), do: Mix.raise("#{flag} is not a safe id")

  defp parse_task_family!(nil), do: nil
  defp parse_task_family!(value) when value in @task_families, do: value
  defp parse_task_family!(_value), do: Mix.raise("--task-family is not a supported task family")

  defp parse_revision!(nil), do: nil

  defp parse_revision!(value) when is_integer(value) and value in 1..1_000_000,
    do: value

  defp parse_revision!(_value), do: Mix.raise("--revision must be between 1 and 1000000")
end
