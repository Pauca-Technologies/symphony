defmodule SymphonyElixir.WorkspaceGc do
  @moduledoc """
  Issue-state-driven worktree GC (implementation plan T28).

  Symphony schedules a pass at startup, then once every 24h. Each pass
  asks Linear for issues that transitioned to a terminal state
  (Done/Cancelled) within `gc.lookback_days` days (default 7), then —
  for each such issue — removes its worktree via plain
  `git worktree remove` (no `--force`).

  ## Why issue-state-driven rather than age-based

  Tying deletion to terminal state means the work is either merged
  (Done) or explicitly abandoned (Cancelled) — both signals come from
  a human. The GC therefore can never reap a paused workspace that
  still holds valuable uncommitted changes. Age-based pruning has no
  such guarantee.

  ## Why we don't force

  `git worktree remove` (without `--force`) refuses when the worktree
  has uncommitted changes or unmerged work. In that case the GC logs a
  `gc_skipped` event and leaves the worktree for a human to inspect.
  Symphony loses some disk; the human keeps their work. The trade is
  always worth it.

  ## Failure modes (handled, surfaced via telemetry)

    * Linear query fails — log warning, count as zero scanned/removed.
    * Worktree path doesn't exist — silent skip, not counted as
      scanned (the cleanup already happened on a prior pass or the
      worktree was never created).
    * Path exists but isn't a git worktree — `gc_skipped` with reason
      `:not_a_worktree`. Includes legacy single-repo plain-mkdir
      workspaces, which this GC deliberately does not touch.
    * `git worktree remove` fails — `gc_skipped` with the git error.

  ## Testing

  `run_pass/1` accepts an opts keyword list with overrides:

    * `:tracker` (module) — defaults to `SymphonyElixir.Tracker`.
    * `:remove_fn` ((path) -> :ok | {:error, term()}) — defaults to
      `&SymphonyElixir.BareClone.remove_worktree_safe/1`. Tests pass a
      stub so they don't need real git fixtures.
    * `:workspace_path_fn` ((identifier) -> Path.t() | nil) — defaults
      to `&SymphonyElixir.Workspace.workspace_path_for_identifier/1`.
  """

  require Logger

  alias SymphonyElixir.{BareClone, Config, Telemetry, Tracker, Workspace}
  alias SymphonyElixir.Linear.Issue

  @type pass_summary :: %{
          scanned: non_neg_integer(),
          removed: non_neg_integer(),
          skipped: non_neg_integer(),
          duration_ms: non_neg_integer(),
          lookback_days: pos_integer()
        }

  @spec run_pass() :: pass_summary()
  def run_pass, do: run_pass([])

  @spec run_pass(keyword()) :: pass_summary()
  def run_pass(opts) when is_list(opts) do
    started_at_ms = System.monotonic_time(:millisecond)
    lookback_days = configured_lookback_days()
    tracker = Keyword.get(opts, :tracker, Tracker)
    remove_fn = Keyword.get(opts, :remove_fn, &BareClone.remove_worktree_safe/1)

    workspace_path_fn =
      Keyword.get(opts, :workspace_path_fn, &Workspace.workspace_path_for_identifier/1)

    {scanned, removed, skipped} =
      case tracker.recently_terminal_issues(lookback_days) do
        {:ok, issues} when is_list(issues) ->
          process_issues(issues, workspace_path_fn, remove_fn)

        {:error, reason} ->
          Logger.warning(
            "WorkspaceGc skipped: failed to fetch terminal issues: #{inspect(reason)}"
          )

          {0, 0, 0}
      end

    duration_ms = System.monotonic_time(:millisecond) - started_at_ms

    Logger.info(
      "WorkspaceGc pass complete scanned=#{scanned} removed=#{removed} skipped=#{skipped} duration_ms=#{duration_ms} lookback_days=#{lookback_days}"
    )

    Telemetry.emit(:gc_pass_summary, %{
      scanned: scanned,
      removed: removed,
      skipped: skipped,
      duration_ms: duration_ms,
      lookback_days: lookback_days
    })

    %{
      scanned: scanned,
      removed: removed,
      skipped: skipped,
      duration_ms: duration_ms,
      lookback_days: lookback_days
    }
  end

  defp process_issues(issues, workspace_path_fn, remove_fn) do
    Enum.reduce(issues, {0, 0, 0}, fn issue, acc ->
      case process_issue(issue, workspace_path_fn, remove_fn) do
        :removed -> bump(acc, :removed)
        :skipped -> bump(acc, :skipped)
        :missing -> acc
      end
    end)
  end

  defp bump({scanned, removed, skipped}, :removed), do: {scanned + 1, removed + 1, skipped}
  defp bump({scanned, removed, skipped}, :skipped), do: {scanned + 1, removed, skipped + 1}

  defp process_issue(%Issue{identifier: identifier} = issue, workspace_path_fn, remove_fn)
       when is_binary(identifier) do
    case workspace_path_fn.(identifier) do
      nil ->
        :missing

      worktree_path ->
        cond do
          not File.exists?(worktree_path) ->
            :missing

          true ->
            attempt_remove(issue, worktree_path, remove_fn)
        end
    end
  end

  defp process_issue(_issue, _workspace_path_fn, _remove_fn), do: :missing

  defp attempt_remove(%Issue{} = issue, worktree_path, remove_fn) do
    case remove_fn.(worktree_path) do
      :ok ->
        Logger.info(
          "WorkspaceGc removed worktree identifier=#{issue.identifier} path=#{worktree_path}"
        )

        Telemetry.emit(:gc_removed, %{
          issue_identifier: issue.identifier,
          issue_id: issue.id,
          worktree_path: worktree_path,
          terminal_state: issue.state
        })

        :removed

      {:error, reason} ->
        Logger.warning(
          "WorkspaceGc skipped worktree identifier=#{issue.identifier} path=#{worktree_path} reason=#{inspect(reason)}"
        )

        Telemetry.emit(:gc_skipped, %{
          issue_identifier: issue.identifier,
          issue_id: issue.id,
          worktree_path: worktree_path,
          terminal_state: issue.state,
          reason: inspect(reason)
        })

        :skipped
    end
  end

  defp configured_lookback_days do
    case Config.settings!() do
      %{gc: %{lookback_days: days}} when is_integer(days) and days > 0 -> days
      _ -> 7
    end
  end
end
