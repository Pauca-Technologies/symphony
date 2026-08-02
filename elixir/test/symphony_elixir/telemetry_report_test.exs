defmodule SymphonyElixir.Telemetry.ReportTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Telemetry.Report

  test "reconciles parent and delegated high waters without double counting" do
    events = [
      token("parent", "parent", "parent", 100, "repo-a", "UDPE-1"),
      token("parent", "parent", "parent", 100, "repo-a", "UDPE-1"),
      token("parent", "parent", "parent", 140, "repo-a", "UDPE-1"),
      token("lens", "parent", "delegated", 60, "repo-a", "UDPE-1"),
      %{"event" => "run_start", "issue_identifier" => "UDPE-1", "ts" => "2026-08-01T00:00:00Z"},
      %{"event" => "run_end", "issue_identifier" => "UDPE-1", "duration_ms" => 1_000, "outcome" => "ok", "ts" => "2026-08-01T00:00:01Z"}
    ]

    report = Report.build(events)

    assert report.fleet.tokens.total_tokens == 200
    assert report.fleet.tokens_p50 == 60
    assert report.fleet.tokens_p90 == 140
    assert report.fleet.delegation_share == 0.3
    assert report.repositories["repo-a"].tokens.total_tokens == 200
    assert report.issues["UDPE-1"].tokens.total_tokens == 200
    assert report.parent_subagents["parent"].parent_tokens.total_tokens == 140
    assert report.parent_subagents["parent"].delegated_tokens.total_tokens == 60
    assert report.parent_subagents["parent"].total_tokens.total_tokens == 200
  end

  test "reports percentiles retries gates output phases and quality guardrails" do
    events = [
      token("one", "one", "parent", 10, "repo", "I-1"),
      token("two", "two", "parent", 30, "repo", "I-2"),
      token("three", "three", "parent", 90, "repo", "I-3"),
      %{"event" => "run_end", "issue_identifier" => "I-1", "duration_ms" => 100, "outcome" => "ok", "ts" => "2026-08-01T00:00:01Z"},
      %{"event" => "run_end", "issue_identifier" => "I-2", "duration_ms" => 500, "outcome" => "error", "failure_class" => "infra", "ts" => "2026-08-01T00:00:02Z"},
      %{"event" => "run_end", "issue_identifier" => "I-3", "duration_ms" => 900, "outcome" => "ok", "ts" => "2026-08-01T00:00:03Z"},
      %{"event" => "retry_policy", "failure_class" => "infra", "action" => "scheduled"},
      %{"event" => "gate", "outcome" => "passed", "attestation_report" => %{"reused" => ["mix test"], "rerun" => ["dialyzer"]}},
      %{"event" => "review", "outcome" => "request_changes", "severity_counts" => %{"major" => 2}},
      %{"event" => "tool", "action" => "end", "category" => "test", "outcome" => "ok", "duration_ms" => 250, "output_bytes" => 4_096},
      %{"event" => "phase", "issue_identifier" => "I-1", "session_id" => "s", "thread_id" => "one", "phase" => "implementation", "ts" => "2026-08-01T00:00:00Z"},
      %{"event" => "phase", "issue_identifier" => "I-1", "session_id" => "s", "thread_id" => "one", "phase" => "validation", "ts" => "2026-08-01T00:00:00.500Z"},
      %{"event" => "quality_outcome", "outcome" => "reopen"},
      %{"event" => "quota_circuit", "action" => "opened"}
    ]

    report = Report.build(events)

    assert report.fleet.tokens_p50 == 30
    assert report.fleet.tokens_p90 == 90
    assert report.fleet.duration_ms_p50 == 500
    assert report.fleet.duration_ms_p90 == 900
    assert report.fleet.retries_by_class == %{"infra" => 1}
    assert report.fleet.output_bytes == 4_096
    assert report.fleet.gate_reuse == %{reused: 1, rerun: 1, reuse_rate: 0.5}
    assert report.fleet.quality_guardrails.review_findings_by_severity == %{"major" => 2}
    assert report.phases["implementation"].duration_ms == 500
    assert report.failures.circuits == %{"opened" => 1}
  end

  test "preserves the legacy top-level summary contract" do
    report =
      Report.build(
        [
          %{"event" => "run_start"},
          %{"event" => "run_end", "duration_ms" => 321, "outcome" => "ok"},
          %{"event" => "routing_skip"},
          %{"event" => "cardinality_skip"},
          %{"event" => "gc_pass_summary"},
          %{"event" => "gc_removed"}
        ],
        ~D[2026-07-01],
        ~D[2026-07-31]
      )

    assert %{
             from: "2026-07-01",
             to: "2026-07-31",
             run_starts: 1,
             run_ends: 1,
             completion_rate: 1.0,
             duration_ms_median: 321,
             duration_ms_p90: 321,
             routing_skips: 1,
             cardinality_skips: 1,
             outcomes: %{"ok" => 1},
             gc: %{passes: 1, removed: 1, skipped: 0}
           } = report
  end

  test "counts one authoritative verdict while preserving requested lens names" do
    lens_names = [%{"name" => "security"}, %{"name" => "correctness"}]

    events = [
      %{"event" => "review", "subtype" => "review_thread", "packet_id" => "packet-1", "thread_id" => "parent-thread", "role" => "parent_reviewer", "tokens" => 100, "requested_lenses" => lens_names},
      %{"event" => "review", "subtype" => "review_thread", "packet_id" => "packet-1", "thread_id" => "lens-thread-1", "role" => "lens", "tokens" => 20, "requested_lenses" => lens_names},
      %{"event" => "review", "subtype" => "review_thread", "packet_id" => "packet-1", "thread_id" => "lens-thread-2", "role" => "lens", "tokens" => 30, "requested_lenses" => lens_names},
      %{"event" => "review", "subtype" => "review", "packet_id" => "packet-1", "iteration" => 1, "outcome" => "request_changes", "severity_counts" => %{"major" => 2, "minor" => 1}},
      %{"event" => "gate", "subtype" => "review", "packet_id" => "packet-1", "iteration" => 1, "outcome" => "request_changes", "severity_counts" => %{"major" => 2, "minor" => 1}},
      %{"event" => "quality_outcome", "outcome" => "human_blocking_findings", "packet_id" => "packet-1", "severity_counts" => %{"major" => 2, "minor" => 1}}
    ]

    report = Report.build(events)

    assert report.reviews.verdicts == %{"request_changes" => 1}
    assert report.reviews.findings_by_severity == %{"major" => 2, "minor" => 1}
    assert report.reviews.packets["packet-1"].verdicts == %{"request_changes" => 1}
    assert report.reviews.packets["packet-1"].findings_by_severity == %{"major" => 2, "minor" => 1}
    assert report.reviews.packets["packet-1"].lenses == ["security", "correctness"]
    assert report.fleet.quality_guardrails.review_findings_by_severity == %{"major" => 2, "minor" => 1}
  end

  test "unreported review threads remain distinct across packet context" do
    events = [
      %{"event" => "review", "subtype" => "review_thread", "packet_id" => "packet-a", "role" => "parent_reviewer", "tokens" => 100, "issue_identifier" => "I-1"},
      %{
        "event" => "review",
        "subtype" => "review_thread",
        "packet_id" => "packet-b",
        "thread_id" => "review-thread-unreported",
        "role" => "parent_reviewer",
        "tokens" => 60,
        "issue_identifier" => "I-1"
      }
    ]

    report = Report.build(events)

    assert report.fleet.tokens.total_tokens == 160
    assert report.fleet.tokens_p50 == 60
    assert report.fleet.tokens_p90 == 100
    assert report.reviews.tokens == 160
    assert report.reviews.packets["packet-a"].tokens == 100
    assert report.reviews.packets["packet-b"].tokens == 60
  end

  test "phase durations stop at the matching attempt terminal" do
    events = [
      %{"event" => "phase", "issue_identifier" => "I-1", "session_id" => "attempt-1", "thread_id" => "t-1", "phase" => "implementation", "ts" => "2026-08-01T00:00:00Z"},
      %{"event" => "phase", "issue_identifier" => "I-1", "session_id" => "attempt-1", "thread_id" => "t-1", "phase" => "validation", "ts" => "2026-08-01T00:00:05Z"},
      %{"event" => "run_end", "issue_identifier" => "I-1", "outcome" => "error", "ts" => "2026-08-01T00:00:10Z"},
      %{"event" => "phase", "issue_identifier" => "I-1", "session_id" => "attempt-2", "thread_id" => "t-2", "phase" => "implementation", "ts" => "2026-08-01T00:00:20Z"},
      %{"event" => "phase", "issue_identifier" => "I-1", "session_id" => "attempt-2", "thread_id" => "t-2", "phase" => "validation", "ts" => "2026-08-01T00:00:25Z"},
      %{"event" => "run_end", "issue_identifier" => "I-1", "outcome" => "ok", "ts" => "2026-08-01T00:00:30Z"}
    ]

    report = Report.build(events)

    assert report.phases["implementation"].duration_ms == 10_000
    assert report.phases["validation"].duration_ms == 10_000
  end

  test "one explicit failure plus run end and retry counts one failed attempt" do
    events = [
      %{"event" => "failure", "issue_identifier" => "I-1", "repository" => "repo", "worker_host" => "local", "failure_class" => "infra"},
      %{"event" => "run_end", "issue_identifier" => "I-1", "repository" => "repo", "worker_host" => "local", "outcome" => "error", "failure_class" => "infra"},
      %{"event" => "retry_policy", "issue_identifier" => "I-1", "failure_class" => "infra", "action" => "scheduled"}
    ]

    report = Report.build(events)

    assert report.failures.by_class == %{"infra" => 1}
    assert report.failures.retry_actions == %{"scheduled" => 1}
    assert report.fleet.retries_by_class == %{"infra" => 1}
  end

  defp token(thread, parent, role, total, repository, issue) do
    %{
      "event" => "token_high_water",
      "thread_id" => thread,
      "parent_thread_id" => parent,
      "thread_role" => role,
      "repository" => repository,
      "issue_identifier" => issue,
      "cumulative" => %{
        "input_tokens" => total - 2,
        "cached_input_tokens" => div(total, 2),
        "output_tokens" => 2,
        "reasoning_tokens" => 1,
        "total_tokens" => total
      }
    }
  end
end
