defmodule SymphonyElixir.Telemetry.EvaluationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TaskOutcome
  alias SymphonyElixir.Telemetry
  alias SymphonyElixir.Telemetry.Evaluation

  test "separates worker completion, task delivery, downstream reliability, tokens, and unavailable cost" do
    evaluation = Evaluation.build(events(), 7)

    assert evaluation.fleet.worker_runs_started == 3
    assert evaluation.fleet.worker_runs_ended == 3
    assert evaluation.fleet.worker_runs_completed_normally == 2
    assert evaluation.fleet.worker_run_completion_rate == 1.0
    assert_in_delta evaluation.fleet.worker_normal_completion_rate, 2 / 3, 0.0001
    assert_in_delta evaluation.fleet.worker_failure_rate, 1 / 3, 0.0001
    assert evaluation.fleet.material_progress_runs == 1
    assert evaluation.fleet.accepted_handoffs == 1
    assert evaluation.fleet.legacy_handoff_evidence == 1
    assert evaluation.fleet.accepted_handoff_rate == 1.0
    assert evaluation.fleet.post_handoff == %{evaluated: 1, reliable: 1, reliability_rate: 1.0, unknown: 0}
    assert evaluation.fleet.tokens.total_tokens == 400
    assert evaluation.fleet.tokens_p50 == 100
    assert evaluation.fleet.tokens_p90 == 300
    assert evaluation.fleet.tokens_per_accepted_handoff == 400.0
    assert evaluation.fleet.explicit_cost_usd == nil
    assert evaluation.fleet.cost_per_accepted_handoff_usd == nil
    assert evaluation.fleet.duration_ms_p50 == 200
    assert evaluation.fleet.duration_ms_p90 == 300

    assert evaluation.outcomes.by_stage["exact_head_handoff"] == %{"accepted" => 1}
    assert evaluation.outcomes.by_stage["pull_request"] == %{"merged" => 1}

    assert evaluation.outcomes.summary == %{
             ci_passed: 1,
             ci_failed: 0,
             human_review_passed: 0,
             human_review_failed: 0,
             merged: 1,
             reopened: 0,
             reverted: 0
           }

    assert length(evaluation.runs) == 3
    refute Enum.any?(evaluation.runs, &(&1.issue_identifier == "OLD-1"))

    alpha_run = Enum.find(evaluation.runs, &(&1.run_id == "run-alpha"))
    assert Enum.any?(alpha_run.outcomes, &(&1.stage == "ci" and &1.status == "passed"))
  end

  test "correlates SHA-only downstream outcomes and filters through the accepted handoff manifest" do
    evaluation =
      Evaluation.build(events(), 30, %{
        repository: "alpha",
        task_family: "implementation",
        model: "model-a",
        prompt_version: "prompt-a",
        config_digest: "config-a"
      })

    assert evaluation.fleet.worker_runs_started == 1
    assert evaluation.fleet.accepted_handoffs == 1
    assert evaluation.fleet.post_handoff.evaluated == 1
    assert evaluation.fleet.post_handoff.reliable == 1
    assert Enum.map(evaluation.runs, & &1.run_id) == ["run-alpha"]
    assert evaluation.filter_options.repository == ["alpha", "beta"]
    assert evaluation.filters.repository == "alpha"
  end

  test "normalizes only documented legacy quality outcomes and keeps malformed data partial" do
    rows = [
      event("quality_outcome", %{"issue_identifier" => "LEG-1", "outcome" => "handoff"}),
      event("quality_outcome", %{"issue_identifier" => "LEG-1", "outcome" => "unknown_future_value"}),
      event("task_outcome", %{"run_id" => "partial", "stage" => 42, "status" => []}),
      event("task_outcome", %{
        "run_id" => "partial",
        "stage" => "exact_head_handoff",
        "status" => "accepted",
        "authoritative" => true,
        "outcome_version" => 0
      }),
      %{"event" => "token_high_water", "cumulative" => "malformed"},
      event("token_high_water", %{
        "thread_id" => "valid-thread",
        "cumulative" => %{"total_tokens" => 50}
      }),
      event("budget_transition", %{"transition" => []}),
      event("budget_transition", %{"transition" => %{}}),
      event("base_drift", %{"gates_avoided" => 2}),
      event("base_drift", %{"gates_avoided" => "invalid"}),
      event("scheduling", %{"overlap_score" => 1}),
      event("scheduling", %{"overlap_score" => "invalid"}),
      event("gate", %{
        "attestation_report" => %{},
        "attestations" => %{},
        "severity_counts" => %{}
      }),
      event("review", %{"attestations" => 17, "severity_counts" => "invalid"}),
      %{"not_an_event" => true}
    ]

    evaluation = Evaluation.build(rows, 7)

    assert evaluation.fleet.worker_runs_started == 0
    assert evaluation.fleet.accepted_handoffs == 0
    assert evaluation.fleet.legacy_handoff_evidence == 1
    assert evaluation.fleet.explicit_cost_usd == nil
    assert evaluation.fleet.tokens.total_tokens == 50
    assert evaluation.runs == []

    assert evaluation.outcomes.by_stage == %{
             "exact_head_handoff" => %{"accepted" => 1},
             "legacy_handoff" => %{"accepted" => 1}
           }
  end

  test "malformed report-only values degrade to an empty base report" do
    evaluation =
      Evaluation.build(
        [event("quality_outcome", %{"issue_identifier" => "MALFORMED-1", "outcome" => %{}})],
        7,
        []
      )

    assert evaluation.fleet.worker_runs_started == 0
    assert evaluation.fleet.tokens.total_tokens == 0
    assert evaluation.filters == %{}
  end

  test "authoritative outcomes shadow equivalent compatibility evidence" do
    rows = [
      event("quality_outcome", %{
        "run_id" => "run-dual",
        "issue_identifier" => "DUAL-1",
        "outcome" => "handoff"
      }),
      event("task_outcome", %{
        "run_id" => "run-dual",
        "issue_identifier" => "DUAL-1",
        "stage" => "exact_head_handoff",
        "status" => "accepted",
        "authoritative" => true,
        "exact_sha" => "head-dual"
      }),
      event("quality_outcome", %{
        "run_id" => "run-dual",
        "issue_identifier" => "DUAL-1",
        "outcome" => "merge",
        "head_sha" => "head-dual"
      }),
      event("task_outcome", %{
        "run_id" => "run-dual",
        "issue_identifier" => "DUAL-1",
        "stage" => "pull_request",
        "status" => "merged",
        "authoritative" => true,
        "head_sha" => "head-dual"
      }),
      event("quality_outcome", %{
        "run_id" => "run-legacy-only",
        "issue_identifier" => "LEGACY-ONLY-1",
        "outcome" => "handoff"
      })
    ]

    evaluation = Evaluation.build(rows, 7)

    assert evaluation.fleet.accepted_handoffs == 1
    assert evaluation.fleet.legacy_handoff_evidence == 1

    assert evaluation.outcomes.by_stage == %{
             "exact_head_handoff" => %{"accepted" => 1},
             "legacy_handoff" => %{"accepted" => 1},
             "pull_request" => %{"merged" => 1}
           }

    assert Enum.count(evaluation.outcomes.timeline, &(&1.source == "quality_outcome")) == 1
    assert Enum.count(evaluation.outcomes.timeline, &(&1.source == "task_outcome")) == 2
  end

  test "keeps distinct accepted candidates with otherwise identical event dimensions" do
    common = %{
      "run_id" => "run-candidates",
      "issue_identifier" => "CANDIDATE-1",
      "stage" => "exact_head_handoff",
      "status" => "accepted",
      "authoritative" => true
    }

    evaluation =
      Evaluation.build(
        [
          event("run_start", %{"run_id" => "run-candidates"}),
          event("task_outcome", Map.put(common, "exact_sha", "head-1")),
          event("task_outcome", Map.put(common, "exact_sha", "head-2"))
        ],
        7
      )

    assert evaluation.fleet.accepted_handoffs == 2
    assert length(evaluation.outcomes.timeline) == 2
  end

  test "uses explicit numeric cost telemetry without inventing missing cost" do
    rows =
      events() ++
        [
          event("run_end", %{"run_id" => "run-alpha", "cost_usd" => 1.25}),
          event("tool", %{"run_id" => "run-alpha", "cumulative_cost_usd" => 1.0}),
          event("tool", %{"run_id" => "run-alpha", "cost_usd" => 0.75}),
          event("tool", %{"run_id" => "run-beta", "cumulative_cost_usd" => 2.0}),
          event("tool", %{"run_id" => "run-beta", "cost_usd" => "unknown"})
        ]

    evaluation = Evaluation.build(rows, 7)
    assert evaluation.fleet.explicit_cost_usd == 3.25
    assert evaluation.fleet.cost_per_accepted_handoff_usd == 3.25
  end

  test "reconstructs bounded historical issue detail after live state is absent" do
    assert {:ok, detail} = Evaluation.issue_from_events(events(), "ALPHA-1")
    assert detail.historical
    assert detail.issue_identifier == "ALPHA-1"
    assert detail.status == "merged"
    assert detail.agent.model == "model-a"
    assert [%{run_id: "run-alpha"}] = detail.runs
    assert Enum.all?(detail.recent_events, &(map_size(&1) <= 10))

    assert {:error, :issue_not_found} = Evaluation.issue_from_events(events(), "MISSING-1")
  end

  test "historical status prefers the latest explicit CI outcome over worker completion" do
    rows = [
      event("run_start", %{"run_id" => "run-ci", "issue_identifier" => "CI-1"}),
      event("run_end", %{"run_id" => "run-ci", "issue_identifier" => "CI-1", "outcome" => "ok"}),
      event("task_outcome", %{
        "issue_identifier" => "CI-1",
        "stage" => "ci",
        "status" => "failed",
        "authoritative" => true,
        "ts" => "2026-09-01T13:00:00Z"
      })
    ]

    assert {:ok, %{status: "ci failed"}} = Evaluation.issue_from_events(rows, "CI-1")
  end

  test "historical status labels explicit stages and preserves worker-only fallbacks" do
    for {stage, status, expected} <- [
          {"exact_head_handoff", "accepted", "handoff accepted"},
          {"material_progress", "recorded", "progress recorded"},
          {"human_review", "passed", "human review passed"},
          {"automated_review", "blocking_findings", "automated review blocking_findings"}
        ] do
      rows = [
        event("task_outcome", %{
          "issue_identifier" => "STAGE-1",
          "stage" => stage,
          "status" => status,
          "authoritative" => true
        })
      ]

      assert {:ok, %{status: ^expected}} = Evaluation.issue_from_events(rows, "STAGE-1")
    end

    assert {:ok, %{status: "legacy handoff evidence"}} =
             Evaluation.issue_from_events(
               [event("quality_outcome", %{"issue_identifier" => "LEGACY-1", "outcome" => "handoff"})],
               "LEGACY-1"
             )

    for {worker_outcome, expected} <- [{"ok", "worker completed"}, {"error", "worker failed"}] do
      rows = [
        event("run_start", %{"run_id" => "worker-#{worker_outcome}", "issue_identifier" => "WORKER-1"}),
        event("run_end", %{
          "run_id" => "worker-#{worker_outcome}",
          "issue_identifier" => "WORKER-1",
          "outcome" => worker_outcome
        }),
        event("task_outcome", %{
          "run_id" => "worker-#{worker_outcome}",
          "issue_identifier" => "WORKER-1",
          "stage" => "future_stage",
          "status" => "unknown",
          "authoritative" => false
        })
      ]

      assert {:ok, %{status: ^expected}} = Evaluation.issue_from_events(rows, "WORKER-1")
    end

    assert {:ok, %{status: "historical", agent: %{model: nil}}} =
             Evaluation.issue_from_events(
               [event("quality_outcome", %{"issue_identifier" => "UNKNOWN-1", "outcome" => "unknown"})],
               "UNKNOWN-1"
             )
  end

  test "default query and issue arities read retained telemetry and TaskOutcome defaults are versioned" do
    Application.put_env(:symphony_elixir, :telemetry_enabled, true)

    Telemetry.with_context(%{run_id: "run-default", issue_identifier: "DEFAULT-1"}, fn ->
      Telemetry.emit(:run_start, %{})
      TaskOutcome.emit(:ci, :passed)
      Telemetry.emit(:run_end, %{outcome: "ok"})
    end)

    assert Evaluation.query(7).fleet.worker_runs_started == 1
    assert Evaluation.query(7, %{}).fleet.worker_runs_ended == 1
    assert {:ok, %{issue_identifier: "DEFAULT-1", status: "ci passed"}} = Evaluation.issue("DEFAULT-1")
  end

  test "bounded telemetry reads retain only the newest files and rows" do
    Application.put_env(:symphony_elixir, :telemetry_enabled, true)
    telemetry_dir = Application.fetch_env!(:symphony_elixir, :telemetry_dir)
    File.mkdir_p!(telemetry_dir)

    for {date, ids} <- [
          {~D[2026-08-30], ["old"]},
          {~D[2026-08-31], ["middle"]},
          {~D[2026-09-01], ["new-1", "new-2"]}
        ] do
      body = Enum.map_join(ids, "\n", &Jason.encode!(%{"event" => "run_start", "run_id" => &1}))
      File.write!(Path.join(telemetry_dir, "#{Date.to_iso8601(date)}.jsonl"), body <> "\n")
    end

    rows =
      Telemetry.read_events(~D[2026-08-30], ~D[2026-09-01],
        max_files: 2,
        max_events: 2
      )

    assert Enum.map(rows, & &1["run_id"]) == ["new-1", "new-2"]
  end

  defp events do
    [
      manifest("run-alpha", "ALPHA-1", "alpha", "implementation", "model-a", "prompt-a", "config-a", "head-a"),
      event("run_start", %{"run_id" => "run-alpha", "issue_identifier" => "ALPHA-1", "repository" => "alpha"}),
      event("token_high_water", %{
        "run_id" => "run-alpha",
        "issue_identifier" => "ALPHA-1",
        "repository" => "alpha",
        "thread_id" => "thread-alpha",
        "cumulative" => %{"total_tokens" => 100}
      }),
      event("task_outcome", %{
        "run_id" => "run-alpha",
        "issue_identifier" => "ALPHA-1",
        "stage" => "material_progress",
        "status" => "recorded",
        "authoritative" => true
      }),
      event("gate", %{
        "run_id" => "run-alpha",
        "issue_identifier" => "ALPHA-1",
        "subtype" => "before_handoff",
        "outcome" => "passed"
      }),
      event("task_outcome", %{
        "run_id" => "run-alpha",
        "issue_identifier" => "ALPHA-1",
        "stage" => "exact_head_handoff",
        "status" => "accepted",
        "authoritative" => true,
        "exact_sha" => "head-a",
        "candidate_sha" => "head-a"
      }),
      event("task_outcome", %{
        "issue_identifier" => "ALPHA-1",
        "stage" => "ci",
        "status" => "passed",
        "authoritative" => true,
        "reviewed_sha" => "head-a"
      }),
      event("quality_outcome", %{
        "issue_identifier" => "ALPHA-1",
        "outcome" => "merge",
        "head_sha" => "head-a",
        "ts" => "2026-09-01T13:00:00Z"
      }),
      event("run_end", %{
        "run_id" => "run-alpha",
        "issue_identifier" => "ALPHA-1",
        "repository" => "alpha",
        "duration_ms" => 100,
        "outcome" => "ok"
      }),
      manifest("run-beta", "BETA-1", "beta", "maintenance", "model-b", "prompt-b", "config-b", "head-b"),
      event("run_start", %{"run_id" => "run-beta", "issue_identifier" => "BETA-1", "repository" => "beta"}),
      event("token_high_water", %{
        "run_id" => "run-beta",
        "issue_identifier" => "BETA-1",
        "repository" => "beta",
        "thread_id" => "thread-beta",
        "cumulative" => %{"total_tokens" => 300}
      }),
      event("run_end", %{
        "run_id" => "run-beta",
        "issue_identifier" => "BETA-1",
        "repository" => "beta",
        "duration_ms" => 300,
        "outcome" => "error",
        "failure_class" => "backend"
      }),
      event("run_start", %{"run_id" => "run-gamma", "issue_identifier" => "GAMMA-1", "repository" => "alpha"}),
      event("run_end", %{
        "run_id" => "run-gamma",
        "issue_identifier" => "GAMMA-1",
        "repository" => "alpha",
        "duration_ms" => 200,
        "outcome" => "ok"
      }),
      event("quality_outcome", %{"issue_identifier" => "OLD-1", "outcome" => "handoff"})
    ]
  end

  defp manifest(run_id, issue, repository, task, model, prompt, digest, head) do
    event("run_manifest", %{
      "run_id" => run_id,
      "issue_identifier" => issue,
      "repository" => %{"id" => repository, "head_sha" => head},
      "task" => %{"type" => task},
      "agent" => %{"model" => model},
      "prompt" => %{"template_sha256" => prompt},
      "config_digest" => digest
    })
  end

  defp event(name, attrs) do
    base = %{"event" => name, "ts" => "2026-09-01T12:00:00Z"}
    base = if name == "task_outcome", do: Map.put(base, "outcome_version", 1), else: base
    Map.merge(base, attrs)
  end
end
