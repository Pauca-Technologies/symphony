defmodule Mix.Tasks.Telemetry.ExperimentReportTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Telemetry.ExperimentReport

  @through ~D[2026-09-03]
  @digest String.duplicate("a", 64)
  @control_digest String.duplicate("b", 64)
  @variant_digest String.duplicate("c", 64)
  @run_control "11111111-1111-4111-a111-111111111111"
  @run_variant "22222222-2222-4222-a222-222222222222"
  @run_missing "33333333-3333-4333-a333-333333333333"

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "experiment-report-task-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    previous = Application.get_env(:symphony_elixir, :telemetry_dir)
    Application.put_env(:symphony_elixir, :telemetry_dir, root)
    write_events(root, @through)

    on_exit(fn ->
      File.rm_rf!(root)

      if previous,
        do: Application.put_env(:symphony_elixir, :telemetry_dir, previous),
        else: Application.delete_env(:symphony_elixir, :telemetry_dir)
    end)

    %{root: root}
  end

  test "JSON uses an exact reproducible window and safe filters" do
    output =
      run_task([
        "--days",
        "30",
        "--through",
        "2026-09-03",
        "--experiment",
        "effort-runtime",
        "--revision",
        "1",
        "--repository",
        "symphony",
        "--task-family",
        "simple_direct",
        "--json"
      ])

    assert {:ok, report} = Jason.decode(String.trim(output))
    assert report["mode"] == "descriptive_only"
    assert report["window"] == %{"days" => 30, "from" => "2026-08-05", "to" => "2026-09-03"}

    assert report["filters"] == %{
             "experiment_id" => "effort-runtime",
             "revision" => 1,
             "repository" => "symphony",
             "task_family" => "simple_direct"
           }

    assert [
             %{
               "experiment_id" => "effort-runtime",
               "repository" => "symphony",
               "task_family" => "simple_direct"
             }
           ] = report["experiments"]
  end

  test "human output is concise about denominators, contamination, and unavailable trial metrics", %{
    root: root
  } do
    output = run_task(["--through", "2026-09-03"])

    assert output =~ "Symphony experiment report (schema v1; descriptive only)"
    assert output =~ "2026-08-28 through 2026-09-03 (7 days)"
    assert output =~ "repository=symphony task=simple_direct"
    assert output =~ "units 2/2 comparable, 0 contaminated"
    assert output =~ "repository=unknown task=unknown; units 0/1 comparable, 1 contaminated"
    assert output =~ "missing_run_manifest=1"
    assert output =~ "worker-ended=1/1"
    assert output =~ "descriptive delta low - control"
    assert output =~ "worker completion=-1.0"
    assert output =~ "unavailable(insufficient_control_sample)"
    assert output =~ "pairing and Pass@k/Pass^k: unavailable (no_repeated_trial_protocol)"
    refute output =~ "significant"
    refute output =~ "causal"

    path = Path.join(root, "2026-09-03.jsonl")

    clean_rows =
      path
      |> File.stream!()
      |> Enum.reject(&String.contains?(&1, @run_missing))

    File.write!(path, clean_rows)
    assert run_task(["--through", "2026-09-03"]) =~ "units 2/2 comparable, 0 contaminated"
  end

  test "offline report does not start the Symphony application", %{root: root} do
    script = """
    Application.put_env(:symphony_elixir, :telemetry_dir, #{inspect(root)})
    Mix.Task.run("telemetry.experiment_report", ["--through", "2026-09-03"])
    IO.puts("symphony_started=\#{inspect(Application.started_applications() |> Enum.any?(&(elem(&1, 0) == :symphony_elixir)))}")
    """

    {output, status} =
      System.cmd("mix", ["run", "--no-start", "-e", script],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"}, {"ERL_FLAGS", "+S 2:2"}],
        stderr_to_stdout: true
      )

    assert status == 0
    assert output =~ "Symphony experiment report"
    assert output =~ "symphony_started=false"
  end

  test "rejects unsupported windows and unsafe or unknown filters" do
    assert run_task(["--experiment", "no-match", "--through", "2026-09-03"]) =~
             "No valid experiment cohorts matched"

    assert_raise Mix.Error, ~r/exactly 7 or 30/, fn -> run_task(["--days", "8"]) end
    assert_raise Mix.Error, ~r/safe id/, fn -> run_task(["--experiment", "raw\nvalue"]) end

    assert_raise Mix.Error, ~r/safe id/, fn ->
      run_task(["--experiment", String.duplicate("x", 65)])
    end

    assert_raise Mix.Error, ~r/safe id/, fn -> run_task(["--repository", "raw/repo"]) end
    assert_raise Mix.Error, ~r/supported task family/, fn -> run_task(["--task-family", "unknown"]) end
    assert_raise Mix.Error, ~r/revision/, fn -> run_task(["--revision", "0"]) end
    assert_raise Mix.Error, ~r/ISO date/, fn -> run_task(["--through", "yesterday"]) end
    assert_raise Mix.Error, ~r/invalid experiment report arguments/, fn -> run_task(["--write"]) end
  end

  defp run_task(args) do
    Mix.Task.reenable("telemetry.experiment_report")
    capture_io(fn -> ExperimentReport.run(args) end)
  end

  defp write_events(root, date) do
    variant_manifest =
      manifest()
      |> put_in([:run_id], @run_variant)
      |> put_in([:config_digest], @variant_digest)
      |> put_in([:configuration, :experiment, :arm_id], "low")
      |> put_in([:configuration, :experiment, :arm_role], "variant")
      |> put_in([:configuration, :experiment, :reasoning_effort], "low")
      |> put_in([:configuration, :experiment, :arm_config_digest], @variant_digest)

    variant =
      exposure()
      |> Map.merge(%{
        exposure_id: "exe-" <> String.duplicate("4", 32),
        unit_id: "exu-" <> String.duplicate("5", 32),
        assignment_id: "exa-" <> String.duplicate("6", 32),
        arm_id: "low",
        arm_role: "variant",
        arm_config_digest: @variant_digest,
        reasoning_effort: "low",
        run_id: @run_variant
      })

    missing_manifest =
      variant
      |> Map.merge(%{
        exposure_id: "exe-" <> String.duplicate("7", 32),
        unit_id: "exu-" <> String.duplicate("8", 32),
        assignment_id: "exa-" <> String.duplicate("9", 32),
        run_id: @run_missing
      })

    events = [manifest(), exposure(), run_end(), variant_manifest, variant, missing_manifest]

    File.write!(
      Path.join(root, "#{Date.to_iso8601(date)}.jsonl"),
      Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n"
    )
  end

  defp manifest do
    %{
      schema_version: 1,
      event: "run_manifest",
      manifest_version: 1,
      run_id: @run_control,
      config_digest: @control_digest,
      agent: %{backend: "codex"},
      repository: %{id: "symphony"},
      task: %{type: "simple_direct"},
      configuration: %{
        experiment: %{
          assignment_version: 1,
          experiment_id: "effort-runtime",
          revision: 1,
          experiment_manifest_digest: @digest,
          arm_id: "control",
          arm_role: "control",
          reasoning_effort: "xhigh",
          baseline_reasoning_effort: "xhigh",
          arm_config_digest: @control_digest,
          control_config_digest: @control_digest
        }
      }
    }
  end

  defp exposure do
    %{
      schema_version: 1,
      event: "experiment_exposure",
      experiment_event_version: 1,
      exposure_id: "exe-" <> String.duplicate("1", 32),
      assignment_reason: "deterministic_opt_in",
      mode: "apply",
      delivery: "initial",
      experiment_id: "effort-runtime",
      experiment_revision: 1,
      experiment_manifest_digest: @digest,
      unit_id: "exu-" <> String.duplicate("2", 32),
      assignment_id: "exa-" <> String.duplicate("3", 32),
      arm_id: "control",
      arm_role: "control",
      arm_config_digest: @control_digest,
      control_config_digest: @control_digest,
      reasoning_effort: "xhigh",
      baseline_reasoning_effort: "xhigh",
      run_id: @run_control,
      retry_attempt: 0
    }
  end

  defp run_end do
    %{
      schema_version: 1,
      event: "run_end",
      run_id: @run_control,
      outcome: "ok",
      duration_ms: 100,
      cost_usd: 1.0
    }
  end
end
