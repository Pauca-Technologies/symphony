defmodule Mix.Tasks.SessionLogs.Prune do
  use Mix.Task

  alias SymphonyElixir.{Config, SessionLogMaintenance}

  @shortdoc "Dry-run or apply age-based Symphony session-log cleanup"

  @moduledoc """
  Plans age-based removal of compact session logs and raw sidecars. The command
  is a dry run unless `--apply` is provided. Active marker paths are always
  protected; `--active-path` may be repeated for legacy live sessions and
  `--verbose` lists every selected candidate.

      mix session_logs.prune --root /srv/symphony/log/codex_sessions
      mix session_logs.prune --root /srv/symphony/log/codex_sessions --older-than-days 30
      mix session_logs.prune --root /srv/symphony/log/codex_sessions --older-than-days 30 --apply
  """

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [
          active_path: :keep,
          apply: :boolean,
          help: :boolean,
          older_than_days: :integer,
          root: :string,
          verbose: :boolean
        ],
        aliases: [h: :help]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      argv != [] or invalid != [] ->
        Mix.raise("Invalid arguments: #{inspect(argv ++ invalid)}")

      true ->
        root = opts[:root] || SessionLogMaintenance.default_root()
        days = opts[:older_than_days] || Config.observability_settings().session_retention_days

        maintenance_opts =
          [apply: Keyword.get(opts, :apply, false)] ++
            Enum.map(Keyword.get_values(opts, :active_path), &{:active_path, &1})

        case SessionLogMaintenance.run(root, days, maintenance_opts) do
          {:ok, summary} -> print_summary(summary, Keyword.get(opts, :verbose, false))
          {:error, reason} -> Mix.raise("Session-log maintenance failed: #{inspect(reason)}")
        end
    end
  end

  defp print_summary(summary, verbose?) do
    Mix.shell().info(
      "session_logs mode=#{summary.mode} root=#{summary.root} older_than_days=#{summary.older_than_days} " <>
        "candidates=#{summary.candidate_files} candidate_bytes=#{summary.candidate_bytes} " <>
        "protected_active=#{summary.protected_active_files} removed=#{summary.removed_files} " <>
        "reclaimed_bytes=#{summary.removed_bytes} skipped_active=#{summary.skipped_active_files} " <>
        "failures=#{length(summary.failures)}"
    )

    if summary.mode == :dry_run do
      Mix.shell().info("Dry run only. Review the summary, drain active work, then rerun with --apply.")
    end

    if verbose? do
      Enum.each(summary.candidates, fn candidate ->
        Mix.shell().info("candidate path=#{candidate.path} bytes=#{candidate.bytes} mtime=#{candidate.mtime}")
      end)
    end
  end
end
