defmodule SymphonyElixir.SessionLogMaintenance do
  @moduledoc """
  Plans and optionally applies age-based session-log cleanup.

  Cleanup is dry-run unless `apply: true` is passed. Active transcript markers
  and caller-supplied active paths protect the compact log and both raw sidecars.
  Candidates are revalidated immediately before removal.
  """

  alias SymphonyElixir.LogFile

  @seconds_per_day 86_400
  @raw_suffix ".raw.ndjson.gz"
  @pending_suffix ".pending"
  @active_suffix ".active"

  @type candidate :: %{path: Path.t(), bytes: non_neg_integer(), mtime: integer()}
  @type summary :: %{
          root: Path.t(),
          mode: :dry_run | :apply,
          older_than_days: pos_integer(),
          cutoff: integer(),
          candidates: [candidate()],
          candidate_files: non_neg_integer(),
          candidate_bytes: non_neg_integer(),
          protected_active_files: non_neg_integer(),
          active_paths: [Path.t()],
          removed_files: non_neg_integer(),
          removed_bytes: non_neg_integer(),
          skipped_active_files: non_neg_integer(),
          failures: [map()]
        }

  @doc "Return the session-log directory implied by the configured Symphony log file."
  @spec default_root() :: Path.t()
  def default_root do
    :symphony_elixir
    |> Application.get_env(:log_file, LogFile.default_log_file())
    |> Path.expand()
    |> Path.dirname()
    |> Path.join("codex_sessions")
  end

  @doc "Build an age-based cleanup plan without changing files."
  @spec plan(Path.t(), pos_integer(), keyword()) :: {:ok, summary()} | {:error, term()}
  def plan(root, older_than_days, opts \\ [])

  def plan(root, older_than_days, opts)
      when is_binary(root) and is_integer(older_than_days) and older_than_days > 0 do
    root = Path.expand(root)
    now = Keyword.get(opts, :now, System.system_time(:second))
    cutoff = now - older_than_days * @seconds_per_day

    with {:ok, names} <- File.ls(root) do
      active_paths = active_compact_paths(root, names, Keyword.get_values(opts, :active_path))

      {candidates, protected_active_files} =
        names
        |> Enum.sort()
        |> Enum.reduce(
          {[], 0},
          &accumulate_candidate(&1, &2, root, cutoff, active_paths)
        )

      candidates = Enum.reverse(candidates)

      {:ok,
       %{
         root: root,
         mode: :dry_run,
         older_than_days: older_than_days,
         cutoff: cutoff,
         candidates: candidates,
         candidate_files: length(candidates),
         candidate_bytes: Enum.sum(Enum.map(candidates, & &1.bytes)),
         protected_active_files: protected_active_files,
         active_paths: MapSet.to_list(active_paths),
         removed_files: 0,
         removed_bytes: 0,
         skipped_active_files: 0,
         failures: []
       }}
    end
  end

  def plan(_root, _older_than_days, _opts), do: {:error, :invalid_retention_policy}

  @doc "Return a dry-run summary, or remove only the planned files when `apply: true` is explicit."
  @spec run(Path.t(), pos_integer(), keyword()) :: {:ok, summary()} | {:error, term()}
  def run(root, older_than_days, opts \\ []) do
    with {:ok, plan} <- plan(root, older_than_days, opts) do
      if Keyword.get(opts, :apply, false), do: apply_plan(plan), else: {:ok, plan}
    end
  end

  defp apply_plan(plan) do
    {removed_files, removed_bytes, skipped_active_files, failures} =
      Enum.reduce(plan.candidates, {0, 0, 0, []}, fn candidate, {removed_files, removed_bytes, skipped_active_files, failures} ->
        case eligible_file(candidate.path, plan.cutoff) do
          :skip ->
            {removed_files, removed_bytes, skipped_active_files, failures}

          {:ok, current} ->
            remove_revalidated_candidate(
              current,
              plan,
              removed_files,
              removed_bytes,
              skipped_active_files,
              failures
            )
        end
      end)

    {:ok,
     %{
       plan
       | mode: :apply,
         removed_files: removed_files,
         removed_bytes: removed_bytes,
         skipped_active_files: skipped_active_files,
         failures: Enum.reverse(failures)
     }}
  end

  defp remove_revalidated_candidate(
         candidate,
         plan,
         removed_files,
         removed_bytes,
         skipped_active_files,
         failures
       ) do
    active_paths = current_active_paths(plan.root, plan.active_paths)

    if protected?(candidate.path, active_paths) do
      {removed_files, removed_bytes, skipped_active_files + 1, failures}
    else
      case File.rm(candidate.path) do
        :ok ->
          {removed_files + 1, removed_bytes + candidate.bytes, skipped_active_files, failures}

        {:error, reason} ->
          failure = %{path: candidate.path, reason: reason}
          {removed_files, removed_bytes, skipped_active_files, [failure | failures]}
      end
    end
  end

  defp eligible_file(path, cutoff) do
    if session_data_path?(path) do
      case File.lstat(path, time: :posix) do
        {:ok, %{type: :regular, mtime: mtime, size: size}} when mtime < cutoff ->
          {:ok, %{path: path, bytes: size, mtime: mtime}}

        _current_or_unsafe ->
          :skip
      end
    else
      :skip
    end
  end

  defp accumulate_candidate(name, {candidates, protected_count}, root, cutoff, active_paths) do
    path = Path.join(root, name)

    case eligible_file(path, cutoff) do
      {:ok, candidate} ->
        if protected?(path, active_paths),
          do: {candidates, protected_count + 1},
          else: {[candidate | candidates], protected_count}

      :skip ->
        {candidates, protected_count}
    end
  end

  defp session_data_path?(path) do
    String.ends_with?(path, [".ndjson", @raw_suffix, @raw_suffix <> @pending_suffix])
  end

  defp active_compact_paths(root, names, supplied_paths) do
    marker_paths =
      names
      |> Enum.filter(
        &(String.ends_with?(&1, ".ndjson" <> @active_suffix) and
            File.regular?(Path.join(root, &1)))
      )
      |> Enum.map(fn name ->
        name
        |> String.replace_suffix(@active_suffix, "")
        |> then(&Path.join(root, &1))
      end)

    supplied_paths
    |> Enum.map(&Path.expand(&1, root))
    |> Enum.map(&compact_path/1)
    |> Kernel.++(marker_paths)
    |> MapSet.new()
  end

  defp current_active_paths(root, supplied_paths) do
    marker_paths =
      case File.ls(root) do
        {:ok, names} -> active_compact_paths(root, names, [])
        {:error, _reason} -> MapSet.new()
      end

    Enum.reduce(supplied_paths, marker_paths, fn path, paths -> MapSet.put(paths, path) end)
  end

  defp protected?(path, active_paths), do: MapSet.member?(active_paths, compact_path(path))

  defp compact_path(path) do
    path
    |> String.replace_suffix(@pending_suffix, "")
    |> String.replace_suffix(@raw_suffix, ".ndjson")
    |> String.replace_suffix(@active_suffix, "")
  end
end
