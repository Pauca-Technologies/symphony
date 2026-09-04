defmodule Mix.Tasks.Symphony.Cardinality do
  @moduledoc """
  Symphony cardinality dry-run audit (audit §9.4 / implementation plan T23).

  Walks the currently-visible Linear issues and reports cardinality
  contract violations without writing comments or labels. Intended for
  pre-cutover surveying so the operator can pick a sensible
  `cardinality_enforced_from` date.

  Usage:

      mix symphony.cardinality --all --dry-run
      mix symphony.cardinality --all --dry-run --json

  Output (text format): violation counts grouped by type plus the first
  N example identifiers per type. `--json` switches to machine-readable
  JSON for piping into a follow-up tooling step.

  The task uses `Tracker.fetch_candidate_issues/0`, which respects the
  multi-repo Symphony team-based polling path when `repos.yaml` is
  configured. With no `repos.yaml`, falls back to legacy single-repo
  polling.
  """

  use Mix.Task

  alias SymphonyElixir.{Cardinality, Linear.Issue, RepoConfig, Tracker}

  @shortdoc "Run the cardinality gate against all visible issues (dry-run)"

  @example_limit 5

  @impl true
  def run(argv) do
    {opts, _argv, _invalid} =
      OptionParser.parse(argv,
        strict: [all: :boolean, dry_run: :boolean, json: :boolean]
      )

    if !Keyword.get(opts, :dry_run, false) do
      Mix.shell().error("Refusing to run without --dry-run. This task only supports dry-run mode (T23).")

      System.halt(2)
    end

    Mix.Task.run("app.start")

    {:ok, repo_config} = RepoConfig.load()

    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        report = build_report(issues, repo_config)

        if Keyword.get(opts, :json, false) do
          IO.puts(Jason.encode!(report))
        else
          print_text_report(report, repo_config)
        end

      {:error, reason} ->
        Mix.shell().error("Failed to fetch candidate issues: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp build_report(issues, repo_config) do
    violations =
      Enum.flat_map(issues, fn
        %Issue{} = issue ->
          case Cardinality.check(issue, repo_config) do
            {:violations, list} ->
              Enum.map(list, &{&1, issue.identifier, issue.id, issue.created_at})

            _ ->
              []
          end

        _ ->
          []
      end)

    by_type =
      violations
      |> Enum.group_by(fn {kind, _id, _uuid, _ts} -> kind end)
      |> Enum.into(%{}, fn {kind, entries} ->
        examples =
          entries
          |> Enum.take(@example_limit)
          |> Enum.map(fn {_kind, identifier, _id, _ts} -> identifier end)

        {kind,
         %{
           count: length(entries),
           examples: examples
         }}
      end)

    %{
      total_issues: length(issues),
      total_violations: length(violations),
      cardinality_enforced_from:
        case repo_config.defaults.cardinality_enforced_from do
          %Date{} = date -> Date.to_iso8601(date)
          _ -> nil
        end,
      by_type: by_type
    }
  end

  defp print_text_report(report, repo_config) do
    Mix.shell().info("Cardinality dry-run report")
    Mix.shell().info("==========================")
    Mix.shell().info("Repos configured: #{length(repo_config.repos)}")

    Mix.shell().info("Cutover date: #{report.cardinality_enforced_from || "(not set — gate is open)"}")

    Mix.shell().info("Issues scanned: #{report.total_issues}")
    Mix.shell().info("Total violations: #{report.total_violations}")
    Mix.shell().info("")

    if report.total_violations == 0 do
      Mix.shell().info("No violations — safe to enable enforcement.")
    else
      Enum.each(report.by_type, &print_violation_type/1)
    end
  end

  defp print_violation_type({kind, %{count: count, examples: examples}}) do
    Mix.shell().info("#{kind}: #{count}")
    Enum.each(examples, fn id -> Mix.shell().info("  - #{id}") end)
  end
end
