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

  defp create_file(root, name, content, mtime) do
    path = Path.join(root, name)
    File.write!(path, content)
    File.touch!(path, mtime)
    path
  end
end
