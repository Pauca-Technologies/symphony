defmodule SymphonyElixir.ExperimentEvaluationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Telemetry.ExperimentEvaluation

  @digest_a String.duplicate("a", 64)
  @digest_b String.duplicate("b", 64)
  @digest_c String.duplicate("c", 64)
  @sha_a String.duplicate("a", 40)
  @sha_b String.duplicate("b", 40)

  test "reports strict comparable arm denominators and descriptive deltas" do
    control = cohort("control", "control", "xhigh", "run-control", "1", 0)
    variant = cohort("low", "variant", "low", "run-variant", "2", 1)

    events =
      control ++
        variant ++
        [
          run_end("run-control", "ok", 100, 1.25),
          run_end("run-variant", "error", 200, nil),
          %{
            "schema_version" => 1,
            "event" => "tool",
            "run_id" => run_id("run-control"),
            "cumulative_cost_usd" => 2.0
          },
          %{
            "schema_version" => 1,
            "event" => "arbitrary",
            "run_id" => run_id("run-control"),
            "cumulative_cost_usd" => 999.0
          },
          %{
            "schema_version" => 0,
            "event" => "tool",
            "run_id" => run_id("run-control"),
            "cumulative_cost_usd" => 999.0
          },
          token("run-control", "thread-a", 80),
          token("run-control", "thread-a", 100),
          token("run-control", "thread-b", 50),
          token("run-variant", "thread-v", 300),
          outcome("run-control", "exact_head_handoff", "accepted", @sha_a),
          outcome(nil, "ci", "passed", @sha_a),
          outcome("run-control", "material_progress", "recorded", nil),
          outcome("run-variant", "exact_head_handoff", "accepted", @sha_b),
          outcome(nil, "ci", "failed", @sha_b),
          # At-least-once replay is one logical exposure.
          exposure("control", "control", "xhigh", "run-control", "1", 0, "replay")
        ]

    report =
      ExperimentEvaluation.build(events,
        window_days: 7,
        through: ~D[2026-09-03]
      )

    assert report.mode == "descriptive_only"
    assert report.window == %{days: 7, from: "2026-08-28", to: "2026-09-03"}
    assert report.diagnostics.valid_exposures == 2
    assert report.diagnostics.invalid_experiment_events == 0
    assert report.limits == %{events: 50_000, experiments: 20, arms_per_experiment: 4, arm_rows: 80}

    assert [experiment] = report.experiments
    assert experiment.units == %{observed: 2, comparable: 2, contaminated: 0}
    assert experiment.contamination == %{}

    control_arm = Enum.find(experiment.arms, &(&1.role == "control"))
    variant_arm = Enum.find(experiment.arms, &(&1.role == "variant"))

    assert control_arm.exposures == %{observed: 1, comparable: 1, initial_runs: 1, retry_runs: 0}
    assert variant_arm.exposures == %{observed: 1, comparable: 1, initial_runs: 0, retry_runs: 1}

    assert control_arm.metrics.worker_runs == %{
             denominator: 1,
             ended: 1,
             completed_normally: 1,
             failed: 0,
             completion_rate: 1.0,
             normal_completion_rate: 1.0
           }

    assert variant_arm.metrics.worker_runs.failed == 1
    assert control_arm.metrics.task_outcomes.exact_head_accepted_runs == 1
    assert control_arm.metrics.task_outcomes.material_progress_runs == 1
    assert control_arm.metrics.task_outcomes.by_stage["ci"] == %{"passed" => 1}

    assert control_arm.metrics.post_handoff == %{
             accepted_handoff_denominator: 1,
             evaluated: 1,
             reliable: 1,
             negative: 0,
             unknown: 0,
             reliability_rate: 1.0
           }

    assert variant_arm.metrics.post_handoff.negative == 1
    assert control_arm.metrics.duration_ms == %{samples: 1, p50: 100, p90: 100}
    assert control_arm.metrics.tokens == %{samples: 1, p50: 150, p90: 150, total: 150}
    assert variant_arm.metrics.tokens.total == 300
    assert control_arm.metrics.explicit_cost_usd.total == 2.0
    assert variant_arm.metrics.explicit_cost_usd.total == nil

    assert [comparison] = experiment.comparisons
    assert comparison.descriptive_only
    assert comparison.deltas.worker_completion_rate.delta == 0.0
    assert comparison.deltas.post_handoff_reliability_rate.delta == -1.0
    assert comparison.deltas.duration_ms_p50.delta == 100

    assert comparison.deltas.explicit_cost_usd_p50 == %{
             available: false,
             reason: "insufficient_treatment_sample"
           }

    assert experiment.repeated_trial_metrics == %{
             pairing: %{available: false, reason: "no_repeated_trial_protocol"},
             pass_at_k: %{available: false, reason: "no_repeated_trial_protocol"},
             pass_power_k: %{available: false, reason: "no_repeated_trial_protocol"}
           }
  end

  test "contaminates ambiguous attribution and deduplicates suspension replay" do
    suspended = cohort("control", "control", "xhigh", "run-suspended", "3", 0)
    suspension = suspension("control", "control", "run-suspended", "3", "initial")

    missing_manifest =
      exposure("low", "variant", "low", "run-missing", "4", 0, "initial")

    conflict = exposure("low", "variant", "low", "run-conflict", "5", 0, "initial")

    conflicting =
      conflict
      |> Map.put("arm_id", "other")
      |> Map.put("arm_config_digest", @digest_c)

    events =
      suspended ++
        [
          suspension,
          %{suspension | "delivery" => "replay", "run_id" => run_id("run-suspension-retry")},
          missing_manifest,
          manifest("low", "variant", "low", "run-conflict"),
          conflict,
          conflicting
        ]

    experiments = ExperimentEvaluation.build(events).experiments
    assert length(experiments) == 2
    experiment = Enum.find(experiments, &(&1.repository == "symphony"))
    unknown = Enum.find(experiments, &(&1.repository == "unknown"))
    assert experiment.units.observed == 2
    assert experiment.units.comparable == 0
    assert experiment.units.contaminated == 2
    assert experiment.contamination["suspended"] == 1
    assert unknown.contamination["missing_run_manifest"] == 1
    assert experiment.contamination["conflicting_exposure"] == 1
    assert experiment.contamination["cross_arm"] == 1
    assert Enum.all?(experiment.arms, &(&1.exposures.comparable == 0))

    comparison = List.first(experiment.comparisons)
    assert comparison.deltas.worker_completion_rate.reason == "insufficient_control_sample"
  end

  test "filters safely, ignores malformed and legacy rows, and retains newest rows at the cap" do
    valid = cohort("control", "control", "xhigh", "run-valid", "6", 0)

    malformed = [
      %{"event" => "experiment_exposure", "experiment_event_version" => 1, "raw" => "secret\noutput"},
      %{"event" => "experiment_suspended", "experiment_event_version" => 99},
      %{
        "event" => "run_manifest",
        "manifest_version" => 1,
        "configuration" => %{"experiment" => %{"raw" => "secret"}}
      },
      %{"event" => "quality_outcome", "outcome" => "merge"},
      "not-a-map"
    ]

    padding = List.duplicate(%{"event" => "legacy"}, 50_001)

    report =
      ExperimentEvaluation.build(padding ++ malformed ++ valid,
        experiment_id: "effort-runtime",
        revision: 1,
        window_days: 30,
        through: ~D[2026-09-03]
      )

    assert report.window == %{days: 30, from: "2026-08-05", to: "2026-09-03"}

    assert report.filters == %{
             experiment_id: "effort-runtime",
             revision: 1,
             repository: nil,
             task_family: nil
           }

    assert length(report.experiments) == 1
    assert report.diagnostics.events_considered == 50_000
    assert report.diagnostics.events_omitted == 8
    assert report.diagnostics.invalid_experiment_events == 2

    empty = ExperimentEvaluation.build(valid, experiment_id: "different", revision: 2)
    assert empty.experiments == []

    assert empty.filters == %{
             experiment_id: "different",
             revision: 2,
             repository: nil,
             task_family: nil
           }

    refute inspect(report) =~ "secret"
  end

  test "manifest conflict and same-unit arm/config changes are excluded" do
    first = cohort("control", "control", "xhigh", "run-a", "7", 0)

    second =
      cohort("low", "variant", "low", "run-b", "8", 1)
      |> Enum.map(fn
        %{"event" => "experiment_exposure"} = event ->
          Map.put(event, "unit_id", unit_id("7"))

        event ->
          event
      end)

    conflicted = cohort("control", "control", "xhigh", "run-conflicted", "9", 0)

    conflicting_manifest =
      manifest("control", "control", "xhigh", "run-conflicted")
      |> Map.put("config_digest", @digest_c)

    experiments = ExperimentEvaluation.build(first ++ second ++ conflicted ++ [conflicting_manifest]).experiments
    assert length(experiments) == 2
    experiment = Enum.find(experiments, &(&1.repository == "symphony"))
    unknown = Enum.find(experiments, &(&1.repository == "unknown"))

    assert experiment.units == %{observed: 1, comparable: 0, contaminated: 1}
    assert experiment.contamination["cross_arm"] == 1
    assert experiment.contamination["multiple_assignments"] == 1
    assert unknown.contamination == %{"conflicting_run_manifest" => 1}
  end

  test "cohort-level configuration drift excludes otherwise distinct clean units" do
    first = cohort("control", "control", "xhigh", "run-config-a", "b", 0)

    second =
      cohort("control", "control", "xhigh", "run-config-b", "c", 0)
      |> Enum.map(fn
        %{"event" => "run_manifest"} = row ->
          row
          |> Map.put("config_digest", @digest_c)
          |> put_in(["configuration", "experiment", "arm_config_digest"], @digest_c)
          |> put_in(["configuration", "experiment", "control_config_digest"], @digest_c)

        %{"event" => "experiment_exposure"} = row ->
          row
          |> Map.put("arm_config_digest", @digest_c)
          |> Map.put("control_config_digest", @digest_c)
      end)

    assert [experiment] = ExperimentEvaluation.build(first ++ second).experiments
    assert experiment.units == %{observed: 2, comparable: 0, contaminated: 2}
    assert experiment.contamination["multiple_arm_config_digests"] == 2
    assert experiment.contamination["multiple_control_config_digests"] == 2
    assert experiment.contamination["multiple_run_config_digests"] == 2
  end

  test "revisions and repository task strata are independent attribution boundaries" do
    revision_one = cohort("control", "control", "xhigh", "run-r1", "10", 0)

    revision_two =
      cohort("control", "control", "xhigh", "run-r2", "11", 0)
      |> set_unit("10")
      |> set_revision(2, @digest_c)

    [r1, r2] =
      ExperimentEvaluation.build(revision_one ++ revision_two).experiments
      |> Enum.sort_by(& &1.revision)

    assert r1.revision == 1
    assert r2.revision == 2
    assert r1.units == %{observed: 1, comparable: 1, contaminated: 0}
    assert r2.units == %{observed: 1, comparable: 1, contaminated: 0}
    assert r1.contamination == %{}
    assert r2.contamination == %{}

    repo_control =
      cohort("control", "control", "xhigh", "run-repo-a", "12", 0)
      |> set_stratum("repo-a", "simple_direct")

    repo_variant =
      cohort("low", "variant", "low", "run-repo-b", "13", 0)
      |> set_stratum("repo-b", "ui")

    strata = ExperimentEvaluation.build(repo_control ++ repo_variant).experiments
    assert Enum.map(strata, &{&1.repository, &1.task_family}) == [{"repo-a", "simple_direct"}, {"repo-b", "ui"}]
    assert Enum.all?(strata, &(&1.comparisons == []))

    assert [filtered] =
             ExperimentEvaluation.build(repo_control ++ repo_variant,
               repository: "repo-b",
               task_family: "ui"
             ).experiments

    assert filtered.repository == "repo-b"
    assert filtered.task_family == "ui"
  end

  test "reconciles missing-manifest retries into one contaminated unit and fails closed on stratum spoofing" do
    initial = cohort("control", "control", "xhigh", "run-initial", "18", 0)
    retry_suspension = suspension("control", "control", "run-retry-missing", "18", "replay")

    assert [reconciled] = ExperimentEvaluation.build(initial ++ [retry_suspension]).experiments
    assert reconciled.repository == "symphony"
    assert reconciled.task_family == "simple_direct"
    assert reconciled.units == %{observed: 1, comparable: 0, contaminated: 1}
    assert reconciled.contamination["missing_run_manifest"] == 1
    assert reconciled.contamination["suspended"] == 1

    first = cohort("control", "control", "xhigh", "run-stratum-a", "19", 0)

    spoofed =
      cohort("control", "control", "xhigh", "run-stratum-b", "20", 0)
      |> set_unit("19")
      |> set_stratum("repo-b", "ui")

    strata = ExperimentEvaluation.build(first ++ spoofed).experiments
    assert length(strata) == 2
    assert Enum.all?(strata, &(&1.units == %{observed: 1, comparable: 0, contaminated: 1}))
    assert Enum.all?(strata, &(&1.contamination == %{"stratum_conflict" => 1}))
  end

  test "rejects spoofed arm invariants and fails closed on invalid stratum filters" do
    invalid_control =
      exposure("control", "control", "xhigh", "run-invalid-control", "14", 0, "initial")
      |> Map.put("arm_id", "not-control")

    invalid_variant =
      exposure("low", "variant", "xhigh", "run-invalid-variant", "15", 0, "initial")

    assert %{experiments: [], diagnostics: %{invalid_experiment_events: 2}} =
             ExperimentEvaluation.build([invalid_control, invalid_variant])

    invalid_manifest =
      manifest("control", "control", "xhigh", "run-invalid-manifest")
      |> put_in(["configuration", "experiment", "reasoning_effort"], "low")

    valid_exposure = exposure("control", "control", "xhigh", "run-invalid-manifest", "16", 0, "initial")
    assert [unknown] = ExperimentEvaluation.build([invalid_manifest, valid_exposure]).experiments
    assert unknown.repository == "unknown"
    assert unknown.contamination == %{"missing_run_manifest" => 1}

    invalid_filters =
      ExperimentEvaluation.build(cohort("control", "control", "xhigh", "run-filter", "17", 0),
        repository: "raw\nrepo",
        task_family: "unknown"
      )

    assert invalid_filters.experiments == []
    assert invalid_filters.diagnostics.invalid_filters == ["repository", "task_family"]
  end

  test "missing control, unmatched handoff evidence, and malformed scalar shapes remain total" do
    base_exposure = exposure("low", "variant", "low", "run-only-variant", "a", 0, "initial")
    base_manifest = manifest("low", "variant", "low", "run-only-variant")

    malformed = [
      %{base_exposure | "experiment_id" => []},
      %{base_exposure | "experiment_revision" => 0},
      %{base_exposure | "experiment_manifest_digest" => %{}},
      %{base_exposure | "unit_id" => 42},
      %{base_exposure | "assignment_id" => nil},
      %{base_exposure | "arm_id" => []},
      %{base_exposure | "arm_config_digest" => nil},
      %{base_exposure | "run_id" => []},
      %{base_exposure | "retry_attempt" => -1},
      %{base_exposure | "delivery" => "raw\nvalue"},
      %{
        "schema_version" => 1,
        "event" => "task_outcome",
        "outcome_version" => 1,
        "authoritative" => true,
        "stage" => "ci",
        "status" => "passed",
        "run_id" => "bad run",
        "head_sha" => @sha_b
      },
      %{
        "schema_version" => 1,
        "event" => "run_end",
        "run_id" => run_id("run-only-variant"),
        "outcome" => "ok",
        "ts" => []
      },
      %{
        "event" => "run_end",
        "run_id" => run_id("run-only-variant"),
        "outcome" => "ok",
        "duration_ms" => -1,
        "ts" => "not-a-time"
      },
      %{
        "schema_version" => 1,
        "event" => "run_end",
        "run_id" => run_id("orphan"),
        "outcome" => "ok",
        "duration_ms" => 1,
        "ts" => "not-a-time"
      },
      %{
        "schema_version" => 1,
        "event" => "token_high_water",
        "run_id" => [],
        "cumulative" => %{"total_tokens" => 1}
      },
      %{
        "schema_version" => 1,
        "event" => "token_high_water",
        "run_id" => run_id("run-only-variant"),
        "thread_id" => [],
        "cumulative" => %{"total_tokens" => 1}
      },
      %{"schema_version" => 1, "event" => "tool", "run_id" => [], "cumulative_cost_usd" => 1},
      []
    ]

    events =
      [
        base_manifest,
        base_exposure,
        outcome("run-only-variant", "exact_head_handoff", "accepted", @sha_a),
        %{
          "schema_version" => 1,
          "event" => "run_end",
          "run_id" => run_id("run-only-variant"),
          "outcome" => "ok"
        }
      ] ++ malformed

    report = ExperimentEvaluation.build(events)
    assert report.filters == %{experiment_id: nil, revision: nil, repository: nil, task_family: nil}
    assert [experiment] = report.experiments
    assert experiment.comparisons == []
    assert [arm] = experiment.arms
    assert arm.metrics.duration_ms == %{samples: 0, p50: nil, p90: nil}
    assert arm.metrics.post_handoff.unknown == 1
    assert report.diagnostics.invalid_experiment_events == 10

    invalid = ExperimentEvaluation.build(events, experiment_id: "raw\nfilter", revision: -1)
    assert invalid.experiments == []
    assert invalid.diagnostics.invalid_filters == ["experiment_id", "revision"]

    mismatch =
      base_manifest
      |> put_in(["configuration", "experiment", "reasoning_effort"], "medium")

    assert [mismatched] = ExperimentEvaluation.build([base_exposure, mismatch]).experiments
    assert mismatched.contamination == %{"manifest_mismatch" => 1}
  end

  test "experiment and arm output caps are deterministic" do
    experiment_events =
      Enum.flat_map(1..21, fn index ->
        id = "experiment-#{index}"
        digest = numbered_digest(index)
        run_id = "run-cap-#{index}"
        suffix = index |> Integer.to_string(16) |> String.downcase()

        [
          manifest("control", "control", "xhigh", run_id)
          |> Map.put("config_digest", digest)
          |> put_in(["configuration", "experiment", "experiment_id"], id)
          |> put_in(["configuration", "experiment", "experiment_manifest_digest"], digest),
          exposure("control", "control", "xhigh", run_id, suffix, 0, "initial")
          |> Map.put("experiment_id", id)
          |> Map.put("experiment_manifest_digest", digest)
        ]
      end)

    capped = ExperimentEvaluation.build(experiment_events)
    assert length(capped.experiments) == 20
    assert capped.diagnostics.experiments_omitted == 1
    assert Enum.map(capped.experiments, & &1.experiment_id) == Enum.sort(Enum.map(capped.experiments, & &1.experiment_id))

    arm_events =
      Enum.flat_map(0..4, fn index ->
        role = if index == 0, do: "control", else: "variant"
        arm_id = if index == 0, do: "control", else: "variant-#{index}"
        effort = Enum.at(~w(xhigh low medium high max), index)
        run_id = "run-arm-#{index}"
        suffix = index |> Kernel.+(32) |> Integer.to_string(16) |> String.downcase()
        arm_digest = numbered_digest(index + 100)

        [
          manifest(arm_id, role, effort, run_id)
          |> put_in(["configuration", "experiment", "arm_config_digest"], arm_digest),
          exposure(arm_id, role, effort, run_id, suffix, 0, "initial")
          |> Map.put("arm_config_digest", arm_digest)
        ]
      end)

    assert [arm_capped] = ExperimentEvaluation.build(arm_events).experiments
    assert length(arm_capped.arms) == 4
  end

  defp cohort(arm_id, role, effort, run_id, unit_suffix, retry_attempt) do
    [
      manifest(arm_id, role, effort, run_id),
      exposure(arm_id, role, effort, run_id, unit_suffix, retry_attempt, "initial")
    ]
  end

  defp set_unit(rows, suffix) do
    Enum.map(rows, fn
      %{"event" => event} = row when event in ["experiment_exposure", "experiment_suspended"] ->
        Map.put(row, "unit_id", unit_id(suffix))

      row ->
        row
    end)
  end

  defp set_revision(rows, revision, manifest_digest) do
    Enum.map(rows, fn
      %{"event" => "run_manifest"} = row ->
        row
        |> put_in(["configuration", "experiment", "revision"], revision)
        |> put_in(["configuration", "experiment", "experiment_manifest_digest"], manifest_digest)

      %{"event" => event} = row when event in ["experiment_exposure", "experiment_suspended"] ->
        row
        |> Map.put("experiment_revision", revision)
        |> Map.put("experiment_manifest_digest", manifest_digest)

      row ->
        row
    end)
  end

  defp set_stratum(rows, repository, task_family) do
    Enum.map(rows, fn
      %{"event" => "run_manifest"} = row ->
        row
        |> put_in(["repository", "id"], repository)
        |> put_in(["task", "type"], task_family)

      row ->
        row
    end)
  end

  defp exposure(arm_id, role, effort, run_id, unit_suffix, retry_attempt, delivery) do
    run_id = run_id(run_id)

    %{
      "schema_version" => 1,
      "event" => "experiment_exposure",
      "experiment_event_version" => 1,
      "exposure_id" => "exe-" <> String.pad_leading(unit_suffix, 32, "0"),
      "assignment_reason" => "deterministic_opt_in",
      "mode" => "apply",
      "delivery" => delivery,
      "experiment_id" => "effort-runtime",
      "experiment_revision" => 1,
      "experiment_manifest_digest" => @digest_a,
      "unit_id" => unit_id(unit_suffix),
      "assignment_id" => "exa-" <> String.pad_leading(unit_suffix, 32, "0"),
      "arm_id" => arm_id,
      "arm_role" => role,
      "arm_config_digest" => arm_digest(arm_id),
      "control_config_digest" => @digest_b,
      "reasoning_effort" => effort,
      "baseline_reasoning_effort" => "xhigh",
      "run_id" => run_id,
      "retry_attempt" => retry_attempt
    }
  end

  defp suspension(arm_id, role, run_id, unit_suffix, delivery) do
    exposure(arm_id, role, "xhigh", run_id, unit_suffix, 0, delivery)
    |> Map.drop(~w(exposure_id assignment_reason reasoning_effort baseline_reasoning_effort retry_attempt))
    |> Map.merge(%{
      "event" => "experiment_suspended",
      "suspension_id" => "exs-" <> String.pad_leading(unit_suffix, 32, "0"),
      "mode" => "baseline",
      "reason" => "kill_switch",
      "ever_exposed" => false,
      "contaminated" => true
    })
  end

  defp manifest(arm_id, role, effort, run_id) do
    run_id = run_id(run_id)

    %{
      "schema_version" => 1,
      "event" => "run_manifest",
      "manifest_version" => 1,
      "run_id" => run_id,
      "config_digest" => run_config_digest(arm_id),
      "agent" => %{"backend" => "codex"},
      "repository" => %{"id" => "symphony"},
      "task" => %{"type" => "simple_direct"},
      "configuration" => %{
        "experiment" => %{
          "assignment_version" => 1,
          "experiment_id" => "effort-runtime",
          "revision" => 1,
          "experiment_manifest_digest" => @digest_a,
          "arm_id" => arm_id,
          "arm_role" => role,
          "reasoning_effort" => effort,
          "baseline_reasoning_effort" => "xhigh",
          "arm_config_digest" => arm_digest(arm_id),
          "control_config_digest" => @digest_b
        }
      }
    }
  end

  defp run_end(run_id, outcome, duration, cost) do
    %{
      "schema_version" => 1,
      "event" => "run_end",
      "run_id" => run_id(run_id),
      "outcome" => outcome,
      "duration_ms" => duration,
      "cost_usd" => cost,
      "ts" => "2026-09-03T00:00:01Z"
    }
  end

  defp token(run_id, thread_id, total) do
    %{
      "schema_version" => 1,
      "event" => "token_high_water",
      "run_id" => run_id(run_id),
      "thread_id" => thread_id,
      "cumulative" => %{"total_tokens" => total}
    }
  end

  defp outcome(run_id, stage, status, sha) do
    %{
      "schema_version" => 1,
      "event" => "task_outcome",
      "outcome_version" => 1,
      "authoritative" => true,
      "run_id" => if(is_nil(run_id), do: nil, else: run_id(run_id)),
      "stage" => stage,
      "status" => status,
      "exact_sha" => sha
    }
  end

  defp unit_id(suffix), do: "exu-" <> String.pad_leading(suffix, 32, "0")
  defp arm_digest("control"), do: @digest_b
  defp arm_digest(_variant), do: @digest_c

  defp run_config_digest(arm_id) do
    :crypto.hash(:sha256, "run-config:" <> arm_id) |> Base.encode16(case: :lower)
  end

  defp numbered_digest(index),
    do: index |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0")

  defp run_id(label) do
    hex = :crypto.hash(:sha256, label) |> Base.encode16(case: :lower)
    "#{binary_part(hex, 0, 8)}-#{binary_part(hex, 8, 4)}-4#{binary_part(hex, 13, 3)}-a#{binary_part(hex, 17, 3)}-#{binary_part(hex, 20, 12)}"
  end
end
