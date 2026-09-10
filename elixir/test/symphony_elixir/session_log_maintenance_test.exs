defmodule SymphonyElixir.SessionLogMaintenanceTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{SessionLogMaintenance, SessionTranscript}

  setup do
    root = Path.join(System.tmp_dir!(), "session-log-maintenance-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "dry-run and apply select old legacy logs while protecting active and recent files", %{root: root} do
    now = 1_800_000_000
    old_mtime = now - 40 * 86_400
    recent_mtime = now - 2 * 86_400

    old_compact = create_file(root, "old.ndjson", "legacy-compact", old_mtime)
    old_raw = create_file(root, "old.raw.ndjson.gz", "legacy-raw", old_mtime)
    recent = create_file(root, "recent.ndjson", "recent", recent_mtime)
    active = create_file(root, "active.ndjson", "active", old_mtime)
    active_raw = create_file(root, "active.raw.ndjson.gz.pending", "active-raw", old_mtime)
    File.write!(SessionTranscript.active_marker_path(active), "{}\n")

    assert {:ok, dry_run} = SessionLogMaintenance.run(root, 30, now: now)
    assert dry_run.mode == :dry_run
    assert dry_run.candidate_files == 2
    assert Enum.map(dry_run.candidates, & &1.path) == [old_compact, old_raw]
    assert dry_run.candidate_bytes == byte_size("legacy-compactlegacy-raw")
    assert dry_run.protected_active_files == 2
    assert Enum.all?([old_compact, old_raw, recent, active, active_raw], &File.exists?/1)

    assert {:ok, applied} = SessionLogMaintenance.run(root, 30, now: now, apply: true)
    assert applied.mode == :apply
    assert applied.removed_files == 2
    assert applied.removed_bytes == byte_size("legacy-compactlegacy-raw")
    refute File.exists?(old_compact)
    refute File.exists?(old_raw)
    assert Enum.all?([recent, active, active_raw], &File.exists?/1)
  end

  test "explicit active paths protect markerless legacy sessions", %{root: root} do
    now = 1_800_000_000
    old_mtime = now - 40 * 86_400
    compact = create_file(root, "legacy-live.ndjson", "compact", old_mtime)
    raw = create_file(root, "legacy-live.raw.ndjson.gz", "raw", old_mtime)

    assert {:ok, summary} =
             SessionLogMaintenance.run(root, 30,
               now: now,
               apply: true,
               active_path: compact
             )

    assert summary.candidate_files == 0
    assert summary.protected_active_files == 2
    assert File.exists?(compact)
    assert File.exists?(raw)
  end

  test "rejects invalid retention and missing roots", %{root: root} do
    assert {:error, :invalid_retention_policy} = SessionLogMaintenance.run(root, 0)
    assert {:error, :enoent} = SessionLogMaintenance.run(Path.join(root, "missing"), 30)
  end

  test "apply lists the directory once and checks each candidate's current marker", %{root: root} do
    now = 1_800_000_000
    old_mtime = now - 40 * 86_400

    paths =
      for name <- ["compact.ndjson", "raw.raw.ndjson.gz", "pending.raw.ndjson.gz.pending"] do
        create_file(root, name, "old", old_mtime)
      end

    {result, calls} = trace_file_calls(fn -> SessionLogMaintenance.run(root, 30, now: now, apply: true) end)

    assert {:ok, %{removed_files: 3, failures: []}} = result
    assert Enum.count(calls, &(&1 == {:ls, [root]})) == 1

    for marker <- ["compact.ndjson.active", "raw.ndjson.active", "pending.ndjson.active"] do
      assert {:regular?, [Path.join(root, marker)]} in calls
    end

    refute Enum.any?(paths, &File.exists?/1)
  end

  test "apply preserves symlink candidates and active raw sidecars", %{root: root} do
    now = 1_800_000_000
    old_mtime = now - 40 * 86_400
    target = create_file(root, "retained.txt", "keep", old_mtime)
    link = Path.join(root, "symlink.ndjson")
    File.ln_s!(target, link)

    compact = create_file(root, "live.ndjson", "compact", old_mtime)
    raw = create_file(root, "live.raw.ndjson.gz", "raw", old_mtime)
    pending = create_file(root, "live.raw.ndjson.gz.pending", "pending", old_mtime)
    File.write!(SessionTranscript.active_marker_path(compact), "{}\n")

    assert {:ok, %{removed_files: 0, protected_active_files: 3}} =
             SessionLogMaintenance.run(root, 30, now: now, apply: true)

    assert Enum.all?([target, link, compact, raw, pending], &File.exists?/1)
    assert {:ok, %{type: :symlink}} = File.lstat(link)
  end

  defp trace_file_calls(fun) do
    tracer = spawn_link(fn -> collect_file_calls([]) end)
    functions = [{File, :ls, 1}, {File, :regular?, 1}]

    try do
      Enum.each(functions, &:erlang.trace_pattern(&1, true, [:local]))
      :erlang.trace(self(), true, [:call, {:tracer, tracer}])
      result = fun.()
      :erlang.trace(self(), false, [:call])
      ref = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _, ^ref}, 1_000
      send(tracer, {:calls, self()})
      assert_receive {:file_calls, calls}, 1_000
      {result, calls}
    after
      :erlang.trace(self(), false, [:call])
      Enum.each(functions, &:erlang.trace_pattern(&1, false, [:local]))
      send(tracer, :stop)
    end
  end

  defp collect_file_calls(calls) do
    receive do
      {:trace, _, :call, {File, function, args}} -> collect_file_calls([{function, args} | calls])
      {:calls, caller} -> send(caller, {:file_calls, Enum.reverse(calls)})
      :stop -> :ok
    end
  end

  defp create_file(root, name, content, mtime) do
    path = Path.join(root, name)
    File.write!(path, content)
    File.touch!(path, mtime)
    path
  end
end
