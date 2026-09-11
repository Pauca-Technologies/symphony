defmodule Mix.Tasks.Telemetry.RegressionCandidates do
  @moduledoc "Builds or verifies bounded, privacy-safe regression candidate corpora."

  use Mix.Task

  alias SymphonyElixir.RegressionCandidate
  alias SymphonyElixir.RegressionCorpus
  alias SymphonyElixir.Telemetry

  @shortdoc "Builds privacy-safe pending regression candidates from compact telemetry"

  @switches [
    days: :integer,
    through: :string,
    telemetry_root: :string,
    json: :boolean,
    export: :string,
    verify: :string
  ]

  @reproduction_fields ~w(
    backend config_digest model prompt_sha256 reasoning_effort repository_head_sha
    symphony_sha task_family workflow_sha256
  )
  @caps [
    files: 60,
    rows: 50_000,
    source_bytes: 256 * 1024 * 1024,
    expanded_bytes: 256 * 1024 * 1024,
    line_bytes: 16 * 1024,
    corpus_bytes: 1024 * 1024
  ]

  @impl Mix.Task
  def run(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, [], []} -> run_checked(opts)
      _other -> Mix.raise("invalid regression candidate arguments; run mix help telemetry.regression_candidates")
    end
  end

  defp run_checked(opts) do
    if Keyword.has_key?(opts, :verify) do
      verify_only!(opts)
    else
      scan_or_export!(opts)
    end
  end

  defp verify_only!(verify: path) do
    validate_absolute_path!(path, "verification file")

    with {:ok, corpus} <- RegressionCorpus.read(path),
         {:ok, result} <- RegressionCandidate.verify(corpus, require_accepted: true) do
      Mix.shell().info(
        "Accepted regression corpus verified: #{result.corpus_id} " <>
          "(#{result.candidates} candidates, #{result.assertions} reviewed assertions)"
      )
    else
      {:error, %{errors: errors}} when is_list(errors) ->
        Mix.raise("regression corpus verification failed: #{Enum.join(errors, ",")}")

      {:error, _reason} ->
        Mix.raise("regression corpus could not be read safely")
    end
  end

  defp verify_only!(_opts) do
    Mix.raise("--verify is mutually exclusive with scan, JSON, and export options")
  end

  defp scan_or_export!(opts) do
    if Keyword.has_key?(opts, :json) and Keyword.has_key?(opts, :export) do
      Mix.raise("--json and --export are mutually exclusive")
    end

    days = Keyword.get(opts, :days, 7)
    through = parse_through!(Keyword.get(opts, :through))
    root = Keyword.get(opts, :telemetry_root, Telemetry.root_dir())

    unless days in [7, 30], do: Mix.raise("--days must be exactly 7 or 30")
    validate_absolute_path!(root, "telemetry root")

    {:ok, result} = RegressionCorpus.scan(root, through, window_days: days)
    render_or_export!(result, opts, through)
  end

  defp render_or_export!(result, opts, through) do
    cond do
      Keyword.get(opts, :json, false) ->
        Mix.shell().info(Jason.encode!(result))

      export_dir = Keyword.get(opts, :export) ->
        validate_absolute_path!(export_dir, "export directory")
        print_human(result, false, through)
        export!(result.corpus, export_dir)

      true ->
        print_human(result, true, through)
    end
  end

  defp export!(corpus, export_dir) do
    case RegressionCorpus.export(corpus, export_dir) do
      {:ok, %{status: status}} ->
        Mix.shell().info("Pending corpus #{corpus["corpus_id"]} #{status} in the private staging directory.")

      {:error, :conflicting_export} ->
        Mix.raise("a different corpus already occupies the deterministic export filename")

      {:error, _reason} ->
        Mix.raise(
          "export requires an existing private directory outside the source tree; " <>
            "create one first with: mkdir -m 700 /absolute/staging-dir"
        )
    end
  end

  defp print_human(result, include_dry_run?, through) do
    corpus = result.corpus
    days = corpus["window_days"]
    from = Date.add(through, 1 - days)

    Mix.shell().info(
      "Regression candidates: #{length(corpus["candidates"])} pending review " <>
        "(#{days} days, #{from} through #{through})"
    )

    Mix.shell().info("Caps: " <> Enum.map_join(@caps, " ", fn {key, value} -> "#{key}=#{value}" end))
    print_diagnostics(result.diagnostics)
    Enum.each(corpus["candidates"], &print_candidate/1)

    if include_dry_run? do
      Mix.shell().info("Dry run: no files written.")

      Mix.shell().info("To export, create a private staging directory first: mkdir -m 700 /absolute/staging-dir")
    end
  end

  defp print_diagnostics(diagnostics) do
    counts =
      diagnostics
      |> Map.drop(["omissions"])
      |> Enum.sort()
      |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{value}" end)

    omissions =
      diagnostics["omissions"]
      |> Enum.sort()
      |> Enum.map_join(",", fn {code, count} -> "#{code}=#{count}" end)

    Mix.shell().info("Scan: #{counts}; omissions=#{if(omissions == "", do: "none", else: omissions)}")
  end

  defp print_candidate(candidate) do
    reasons =
      candidate["selection_reasons"]
      |> Enum.map_join(",", fn reason -> "#{reason["kind"]}=#{reason["value"]}" end)

    fields =
      candidate["samples"]
      |> Enum.flat_map(&Map.keys(&1["reproduction"]))
      |> Enum.uniq()
      |> Enum.filter(&(&1 in @reproduction_fields))
      |> Enum.sort()
      |> Enum.join(",")

    refs =
      candidate["samples"]
      |> Enum.flat_map(& &1["evidence_refs"])
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.join(",")

    Mix.shell().info("Candidate #{candidate["candidate_id"]}")
    Mix.shell().info("  selection: #{reasons}")
    Mix.shell().info("  reproduction fields: #{if(fields == "", do: "none", else: fields)}")
    Mix.shell().info("  evidence refs: #{if(refs == "", do: "none", else: refs)}")
  end

  defp parse_through!(nil), do: Date.utc_today()

  defp parse_through!(value) do
    with true <- is_binary(value) and Regex.match?(~r/\A\d{4}-\d{2}-\d{2}\z/, value),
         {:ok, date} <- Date.from_iso8601(value) do
      date
    else
      _invalid -> Mix.raise("--through must be an ISO date in YYYY-MM-DD form")
    end
  end

  defp validate_absolute_path!(path, label) do
    valid? =
      is_binary(path) and String.valid?(path) and Path.type(path) == :absolute and
        not String.match?(path, ~r/[\x00-\x1f\x7f]/)

    unless valid?, do: Mix.raise("#{label} must be an absolute single-line path")
  end
end
