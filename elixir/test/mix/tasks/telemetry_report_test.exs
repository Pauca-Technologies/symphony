defmodule Mix.Tasks.TelemetryReportTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Telemetry.Report, as: TelemetryReportTask

  setup do
    root = Path.join(System.tmp_dir!(), "telemetry-report-task-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:symphony_elixir, :telemetry_dir)
    Application.put_env(:symphony_elixir, :telemetry_dir, root)
    File.mkdir_p!(root)

    events = [
      %{schema_version: 1, event: "run_start", ts: "2026-08-01T00:00:00Z", issue_identifier: "UDPE-1"},
      %{schema_version: 1, event: "run_end", ts: "2026-08-01T00:00:01Z", issue_identifier: "UDPE-1", duration_ms: 1_000, outcome: "ok"},
      %{
        schema_version: 1,
        event: "token_high_water",
        ts: "2026-08-01T00:00:01Z",
        issue_identifier: "UDPE-1",
        repository: "symphony",
        thread_id: "parent",
        parent_thread_id: "parent",
        thread_role: "parent",
        cumulative: %{input_tokens: 80, output_tokens: 20, total_tokens: 100}
      }
    ]

    File.write!(Path.join(root, "2026-08-01.jsonl"), Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n")

    on_exit(fn ->
      File.rm_rf!(root)
      if previous, do: Application.put_env(:symphony_elixir, :telemetry_dir, previous), else: Application.delete_env(:symphony_elixir, :telemetry_dir)
    end)

    :ok
  end

  test "--json exposes bounded fleet and grouping views" do
    Mix.Task.reenable("telemetry.report")

    output =
      capture_io(fn ->
        TelemetryReportTask.run(["--from", "2026-08-01", "--to", "2026-08-01", "--json"])
      end)

    assert {:ok, report} = Jason.decode(String.trim(output))
    assert report["fleet"]["tokens"]["total_tokens"] == 100
    assert report["repositories"]["symphony"]["tokens"]["total_tokens"] == 100
    assert report["issues"]["UDPE-1"]["tokens"]["total_tokens"] == 100
    assert is_map(report["parent_subagents"])
    assert is_map(report["phases"])
    assert is_map(report["failures"])
    assert report["from"] == "2026-08-01"
    assert report["to"] == "2026-08-01"
    assert report["run_starts"] == 1
    assert report["run_ends"] == 1
    assert report["completion_rate"] == 1.0
    assert report["duration_ms_median"] == 1_000
    assert report["duration_ms_p90"] == 1_000
    assert report["routing_skips"] == 0
    assert report["cardinality_skips"] == 0
    assert report["outcomes"] == %{"ok" => 1}
    assert report["gc"] == %{"passes" => 0, "removed" => 0, "skipped" => 0}
  end

  test "text output includes efficiency and quality sections" do
    Mix.Task.reenable("telemetry.report")

    output =
      capture_io(fn ->
        TelemetryReportTask.run(["--from", "2026-08-01", "--to", "2026-08-01"])
      end)

    assert output =~ "Symphony fleet efficiency"
    assert output =~ "Worker runs ended: 1/1 (worker-run completion 100.0%)"
    assert output =~ "Tokens: 100 total"
    assert output =~ "Repositories:"
    assert output =~ "Parent/subagent reconciliation:"
  end
end
