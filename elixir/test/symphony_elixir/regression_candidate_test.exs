defmodule SymphonyElixir.RegressionCandidateTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RegressionCandidate

  @sha String.duplicate("a", 64)
  @sha_b String.duplicate("b", 64)
  @sha_c String.duplicate("c", 64)
  @run "123e4567-e89b-12d3-a456-426614174000"

  test "builds one deterministic pending corpus from failure, outlier, loop, manifest, and review evidence" do
    events = events()
    corpus = RegressionCandidate.build(events, window_days: 30)
    shuffled = RegressionCandidate.build(Enum.reverse(events), window_days: 30)

    assert corpus == shuffled
    assert corpus["schema_version"] == 1
    assert corpus["kind"] == "symphony_regression_candidate_corpus"
    assert corpus["selection_policy"] == "regression-candidates/v1"
    assert corpus["state"] == "pending_review"
    assert corpus["window_days"] == 30
    assert corpus["review"] == %{"status" => "pending", "required" => "external_manual"}
    assert String.starts_with?(corpus["corpus_id"], "rgc-corpus-")

    assert [candidate] = corpus["candidates"]

    assert candidate["cluster"] == %{
             "config_digest" => @sha_b,
             "first_failure_class" => "response_timeout_or_stall",
             "prompt_sha256" => @sha,
             "review_outcome" => "human_review:failed",
             "task_family" => "concurrency_liveness",
             "tool_error_fingerprint" => @sha_c
           }

    assert Enum.map(candidate["selection_reasons"], & &1["kind"]) ==
             ~w(extreme_budget first_failure negative_review_outcome no_progress_alert)

    assert candidate["proposed_assertions"] == %{
             "authority" => "proposal",
             "process" => ~w(detects_extreme_budget detects_first_failure detects_negative_review_outcome detects_no_progress_alert),
             "task_outcome" => "unknown"
           }

    refute Map.has_key?(candidate, "assertions")
    assert length(candidate["samples"]) == 1
    assert length(corpus["evidence"]) == 5
    assert byte_size(Jason.encode!(corpus)) <= 1_048_576
  end

  test "strict projection excludes secrets, prompt bodies, issue content, tool values, findings, and free-form failures" do
    poison = "BEGIN PROMPT\nBearer top-secret\nraw tool output"

    events =
      events()
      |> Enum.map(fn event ->
        Map.merge(event, %{
          "title" => poison,
          "description" => poison,
          "labels" => [poison],
          "prompt" => Map.merge(event["prompt"] || %{}, %{"body" => poison}),
          "agent" => Map.merge(event["agent"] || %{}, %{"model" => poison}),
          "tool_args" => %{"password" => poison},
          "output" => poison,
          "findings" => [%{"body" => poison}],
          "failure_reason" => poison,
          "worker_host" => "/tmp/#{poison}",
          "workspace" => "/source/repo"
        })
      end)

    encoded = events |> RegressionCandidate.build() |> Jason.encode!()

    refute encoded =~ "BEGIN PROMPT"
    refute encoded =~ "top-secret"
    refute encoded =~ "raw tool output"
    refute encoded =~ "tool_args"
    refute encoded =~ "findings"
    refute encoded =~ "worker_host"
    refute encoded =~ "workspace"
    refute encoded =~ "title"
    refute encoded =~ "description"
  end

  test "deduplicates replayed alerts and samples distinct runs deterministically" do
    events =
      1..6
      |> Enum.flat_map(fn index ->
        run = "123e4567-e89b-12d3-a456-42661417400#{index}"
        base = Enum.map(events(), &Map.put(&1, "run_id", run))
        base ++ [base |> Enum.find(&(&1["event"] == "no_progress_loop"))]
      end)

    first = RegressionCandidate.build(events)
    second = RegressionCandidate.build(Enum.shuffle(events))
    [candidate] = first["candidates"]

    assert first == second
    refute Map.has_key?(candidate, "sampling")
    assert length(candidate["samples"]) == 2
    assert Enum.uniq_by(first["evidence"], & &1["ref"]) == first["evidence"]
  end

  test "distinct no-progress fingerprints form distinct candidates" do
    other =
      events()
      |> Enum.find(&(&1["event"] == "no_progress_loop"))
      |> Map.put("fingerprint", String.duplicate("d", 64))
      |> Map.put("warning_id", "npw-" <> String.duplicate("d", 24))

    corpus = RegressionCandidate.build(events() ++ [other])

    assert Enum.map(corpus["candidates"], & &1["cluster"]["tool_error_fingerprint"]) |> Enum.sort() ==
             Enum.sort([@sha_c, String.duplicate("d", 64)])
  end

  test "uses explicit first failure before error run_end and hashes malformed run identities" do
    events = [
      manifest("malicious\nrun"),
      event("run_end", "malicious\nrun", %{
        "outcome" => "error",
        "failure_class" => "agent_protocol_failure",
        "duration_ms" => 4
      }),
      event("failure", "malicious\nrun", %{
        "failure_class" => "transient_infrastructure",
        "failure_scope" => "issue"
      })
    ]

    corpus = RegressionCandidate.build(events)
    [candidate] = corpus["candidates"]

    assert candidate["cluster"]["first_failure_class"] == "transient_infrastructure"
    assert [%{"run_ref" => "run-" <> digest}] = candidate["samples"]
    assert byte_size(digest) == 24
    refute Jason.encode!(corpus) =~ "malicious"
  end

  test "correlates SHA-only authoritative outcome to a run-scoped candidate" do
    handoff =
      event("task_outcome", @run, %{
        "outcome_version" => 1,
        "authoritative" => true,
        "stage" => "exact_head_handoff",
        "status" => "accepted",
        "exact_sha" => @sha_c
      })

    downstream = %{
      "schema_version" => 1,
      "event" => "task_outcome",
      "ts" => "2026-09-03T00:00:09Z",
      "outcome_version" => 1,
      "authoritative" => true,
      "stage" => "human_review",
      "status" => "failed",
      "reviewed_sha" => @sha_c
    }

    corpus = RegressionCandidate.build([manifest(@run), failure(@run), handoff, downstream])
    assert [candidate] = corpus["candidates"]
    assert candidate["cluster"]["review_outcome"] == "human_review:failed"
  end

  test "latest authoritative review wins and a negative outcome wins an exact timestamp tie" do
    passed =
      event("task_outcome", @run, %{
        "outcome_version" => 1,
        "authoritative" => true,
        "stage" => "ci",
        "status" => "passed"
      })

    failed = %{passed | "status" => "failed"}
    rows = [manifest(@run), failure(@run), failed, passed]
    assert [candidate] = RegressionCandidate.build(rows)["candidates"]
    assert candidate["cluster"]["review_outcome"] == "ci:failed"

    later = %{passed | "ts" => "2026-09-03T00:00:07Z"}
    assert [candidate] = RegressionCandidate.build([later | rows])["candidates"]
    assert candidate["cluster"]["review_outcome"] == "ci:passed"
  end

  test "legacy error telemetry remains a pending candidate with unknown provenance" do
    legacy = %{
      "event" => "run_end",
      "ts" => "2026-09-02T00:00:00Z",
      "issue_identifier" => "LEGACY-1",
      "outcome" => "error"
    }

    corpus = RegressionCandidate.build([legacy, %{"bad" => "row"}, "not a map"])
    assert [candidate] = corpus["candidates"]

    assert candidate["cluster"] == %{
             "config_digest" => "unknown",
             "first_failure_class" => "unknown",
             "prompt_sha256" => "unknown",
             "review_outcome" => "unknown",
             "task_family" => "unknown",
             "tool_error_fingerprint" => "unknown"
           }

    assert [%{"run_ref" => "legacy-" <> digest}] = candidate["samples"]
    assert byte_size(digest) == 24
    refute Jason.encode!(corpus) =~ "LEGACY-1"
  end

  test "malformed and non-authoritative evidence is ignored rather than inferred" do
    rows = [
      event("no_progress_loop", @run, %{
        "no_progress_version" => 1,
        "shadow" => true,
        "decision" => "alert",
        "kind" => "prompt\ninjection",
        "tool_class" => "shell",
        "result_class" => "failed",
        "fingerprint" => @sha
      }),
      event("task_outcome", @run, %{
        "outcome_version" => 1,
        "authoritative" => false,
        "stage" => "human_review",
        "status" => "failed"
      }),
      event("review", @run, %{
        "subtype" => "review",
        "authoritative" => true,
        "outcome" => "raw\nreview prose"
      }),
      event("run_end", @run, %{"outcome" => "ok"})
    ]

    corpus = RegressionCandidate.build(rows)
    assert corpus["candidates"] == []
    assert corpus["evidence"] == []
    refute Jason.encode!(corpus) =~ "injection"
    refute Jason.encode!(corpus) =~ "review prose"
  end

  test "safe review evidence, nil warning ids, and invalid timestamps stay deterministic" do
    loop =
      event("no_progress_loop", @run, %{
        "no_progress_version" => 1,
        "shadow" => true,
        "decision" => "alert",
        "kind" => "repeated_error",
        "tool_class" => "mcp",
        "result_class" => "timeout",
        "fingerprint" => @sha_c
      })
      |> Map.put("ts", 12)

    review =
      event("review", @run, %{
        "subtype" => "review",
        "authoritative" => true,
        "outcome" => "request_changes"
      })

    malformed_outcome =
      event("task_outcome", @run, %{
        "outcome_version" => 1,
        "authoritative" => true,
        "stage" => "ci",
        "status" => 500
      })

    corpus = RegressionCandidate.build([manifest(@run), loop, review, malformed_outcome])
    assert [candidate] = corpus["candidates"]
    assert candidate["cluster"]["review_outcome"] == "automated_review:request_changes"
    assert Enum.any?(corpus["evidence"], &(&1["ts"] == nil))
    assert {:ok, %{assertions: 0}} = RegressionCandidate.verify(corpus)
  end

  test "a safe manifest without a qualifying observation creates no candidate" do
    corpus = RegressionCandidate.build([manifest(@run), %{"event" => 7}])
    assert corpus["candidates"] == []
    assert corpus["evidence"] == []
  end

  test "maximum candidate corpus remains deterministic, verifiable, and within its byte cap" do
    events =
      1..101
      |> Enum.flat_map(fn index ->
        run = "123e4567-e89b-12d3-a456-#{String.pad_leading(Integer.to_string(index), 12, "0")}"
        fingerprint = :crypto.hash(:sha256, Integer.to_string(index)) |> Base.encode16(case: :lower)

        [
          manifest(run, fingerprint),
          event("no_progress_loop", run, %{
            "no_progress_version" => 1,
            "shadow" => true,
            "decision" => "alert",
            "kind" => "repeated_error",
            "tool_class" => "shell",
            "result_class" => "failed",
            "fingerprint" => fingerprint,
            "warning_id" => "npw-" <> String.slice(fingerprint, 0, 24)
          })
        ]
      end)

    events = events ++ List.duplicate(%{"event" => "ignored"}, 50_000 - length(events))
    corpus = RegressionCandidate.build(events)
    assert length(corpus["candidates"]) == 100
    assert corpus["summary"]["input_events"] == 50_000
    assert byte_size(Jason.encode!(corpus)) <= 1_048_576
    assert {:ok, %{candidates: 100}} = RegressionCandidate.verify(corpus)
  end

  test "invalid timestamps cannot displace valid events at the normalized input cap" do
    invalid = %{
      "event" => "run_end",
      "ts" => "not-a-time",
      "issue_identifier" => "LEGACY-CAP",
      "outcome" => "error"
    }

    valid = event("failure", @run, %{"failure_class" => "transient_infrastructure"})
    corpus = RegressionCandidate.build([valid | List.duplicate(invalid, 50_000)])

    assert corpus["summary"]["normalized_events"] == 50_000
    assert corpus["summary"]["omitted_input_events"] == 1
    assert Enum.any?(corpus["evidence"], &(&1["ts"] == valid["ts"]))
    assert {:ok, _report} = RegressionCandidate.verify(corpus)
  end

  test "verify accepts pending structure but evaluates assertions only after external review" do
    pending = RegressionCandidate.build(events())
    assert {:ok, pending_report} = RegressionCandidate.verify(pending)
    assert pending_report.assertions == 0

    accepted = accept(pending)

    assert {:ok, report} = RegressionCandidate.verify(accepted)
    assert report.policy_version == "regression-candidates/v1"
    assert report.candidates == 1
    assert report.assertions == 4
    assert report.state == "accepted"
    assert {:ok, %{state: "accepted"}} = RegressionCandidate.verify(accepted, require_accepted: true)
  end

  test "verify rejects stale policy, forged approval, unsupported assertions, and evidence tampering" do
    accepted = accept(RegressionCandidate.build(events()))

    stale = Map.put(accepted, "selection_policy", "regression-candidates/v0")
    assert {:error, %{errors: stale_errors}} = RegressionCandidate.verify(stale)
    assert "stale_policy" in stale_errors

    forged = put_in(accepted, ["review", "approval_ref"], "raw\nself-approved")
    assert {:error, %{errors: forged_errors}} = RegressionCandidate.verify(forged)
    assert "invalid_review" in forged_errors

    unsupported = put_in(accepted, ["candidates", Access.at(0), "assertions", "process"], ["changes_prompt"])
    assert {:error, %{errors: assertion_errors}} = RegressionCandidate.verify(unsupported)
    assert "invalid_assertions" in assertion_errors

    failure_index = Enum.find_index(accepted["evidence"], &(&1["event"] == "failure"))

    tampered =
      put_in(
        accepted,
        ["evidence", Access.at(failure_index), "data", "failure_class"],
        "agent_protocol_failure"
      )

    assert {:error, %{errors: tampered_errors}} = RegressionCandidate.verify(tampered)
    assert "corpus_id_mismatch" in tampered_errors
    assert "invalid_shape" in tampered_errors
  end

  test "replay binds every generated candidate field, not only the candidate id" do
    pending = RegressionCandidate.build(events())

    altered = [
      put_in(pending, ["candidates", Access.at(0), "samples", Access.at(0), "run_ref"], "aaaaaaaa-bbbb"),
      put_in(pending, ["candidates", Access.at(0), "samples", Access.at(0), "reproduction", "model"], "safe-model"),
      put_in(pending, ["candidates", Access.at(0), "selection_reasons", Access.at(0), "value"], "other"),
      put_in(pending, ["candidates", Access.at(0), "proposed_assertions", "task_outcome"], "ci:failed")
    ]

    for corpus <- altered do
      assert {:error, %{errors: errors}} = RegressionCandidate.verify(corpus)
      assert "corpus_id_mismatch" in errors
      assert "evidence_replay_mismatch" in errors
    end
  end

  test "verify rejects malformed corpora, oversized bundles, and invalid expected outcomes" do
    assert {:error, %{errors: ["invalid_corpus"]}} = RegressionCandidate.verify(:bad)

    accepted = accept(RegressionCandidate.build(events()))
    oversized = Map.put(accepted, "padding", String.duplicate("x", 1_048_576))
    assert {:error, %{errors: size_errors}} = RegressionCandidate.verify(oversized)
    assert "bundle_too_large" in size_errors

    bad_outcome = put_in(accepted, ["candidates", Access.at(0), "assertions", "task_outcome"], "prompt\ninjected")
    assert {:error, %{errors: outcome_errors}} = RegressionCandidate.verify(bad_outcome)
    assert "invalid_expected_outcome" in outcome_errors

    short_reviewer = put_in(accepted, ["review", "reviewer_sha256"], String.duplicate("a", 40))
    assert {:error, %{errors: reviewer_errors}} = RegressionCandidate.verify(short_reviewer)
    assert "invalid_review" in reviewer_errors

    noncanonical_time = put_in(accepted, ["review", "approved_at"], "2026-09-03T00:00:00+00:00")
    assert {:error, %{errors: time_errors}} = RegressionCandidate.verify(noncanonical_time)
    assert "invalid_review" in time_errors
  end

  test "verify is total for malformed nested corpus shapes and rejects unknown fields" do
    pending = RegressionCandidate.build(events())

    malformed_json = put_in(pending, ["summary", "normalized_events"], self())
    assert {:error, %{errors: json_errors}} = RegressionCandidate.verify(malformed_json)
    assert "invalid_json" in json_errors
    assert "invalid_shape" in json_errors

    bad_candidates = %{pending | "candidates" => :invalid, "corpus_id" => "invalid"}
    assert {:error, %{errors: candidate_errors}} = RegressionCandidate.verify(bad_candidates)
    assert "invalid_candidates" in candidate_errors

    bad_evidence = %{pending | "evidence" => :invalid, "corpus_id" => "invalid"}
    assert {:error, %{errors: evidence_errors}} = RegressionCandidate.verify(bad_evidence)
    assert "invalid_evidence" in evidence_errors

    malformed_shapes = [
      %{pending | "evidence" => ["not-an-event"]},
      put_in(pending, ["evidence", Access.at(0), "data"], ["not-a-map"]),
      put_in(pending, ["candidates", Access.at(0), "cluster"], ["not-a-map"]),
      put_in(pending, ["candidates", Access.at(0), "samples"], "not-a-list")
    ]

    for corpus <- malformed_shapes do
      assert {:error, %{errors: errors}} = RegressionCandidate.verify(corpus)
      assert errors != []
      assert Enum.all?(errors, &(&1 in ~w(corpus_id_mismatch invalid_shape evidence_replay_mismatch)))
    end

    [first | rest] = pending["evidence"]
    unknown = Map.put(first, "raw", "secret-token")
    unsafe = %{pending | "evidence" => [unknown | rest]}
    assert {:error, %{errors: unsafe_errors}} = RegressionCandidate.verify(unsafe)
    assert "invalid_shape" in unsafe_errors

    accepted = accept(pending)
    invalid_review = put_in(accepted, ["review", "approval_ref"], 123)
    assert {:error, %{errors: review_errors}} = RegressionCandidate.verify(invalid_review)
    assert "invalid_review" in review_errors
  end

  test "rare malformed branches remain bounded and non-blocking" do
    pending = RegressionCandidate.build(events())
    accepted = accept(pending)

    bad_candidate = %{accepted | "candidates" => [nil], "corpus_id" => "invalid"}
    assert {:error, %{errors: bad_candidate_errors}} = RegressionCandidate.verify(bad_candidate)
    assert "invalid_assertions" in bad_candidate_errors
    assert "invalid_shape" in bad_candidate_errors

    bad_state = %{pending | "state" => "other"}
    assert {:error, %{errors: bad_state_errors}} = RegressionCandidate.verify(bad_state)
    assert "invalid_state" in bad_state_errors
    assert "invalid_shape" in bad_state_errors

    bad_row = %{pending | "evidence" => [nil], "corpus_id" => "invalid"}
    assert {:error, %{errors: bad_row_errors}} = RegressionCandidate.verify(bad_row)
    assert "invalid_shape" in bad_row_errors

    bad_summary = %{pending | "summary" => nil}
    assert {:error, %{errors: summary_errors}} = RegressionCandidate.verify(bad_summary)
    assert "invalid_shape" in summary_errors

    nonnumeric_summary = put_in(pending, ["summary", "candidates"], "one")
    assert {:error, %{errors: count_errors}} = RegressionCandidate.verify(nonnumeric_summary)
    assert "invalid_shape" in count_errors

    unsafe_nested =
      put_in(
        pending,
        ["candidates", Access.at(0), "proposed_assertions", "task_outcome"],
        {:not, "json"}
      )

    assert {:error, %{errors: unsafe_nested_errors}} = RegressionCandidate.verify(unsafe_nested)
    assert "invalid_shape" in unsafe_nested_errors

    [candidate | candidates] = pending["candidates"]
    cluster = Map.put(candidate["cluster"], "raw", "secret-token")
    identity = %{"policy" => "regression-candidates/v1", "cluster" => cluster}
    digest = SymphonyElixir.RunManifest.config_digest(%{"value" => identity})
    candidate = %{candidate | "cluster" => cluster, "candidate_id" => "rgc-" <> String.slice(digest, 0, 32)}
    bad_cluster = %{pending | "candidates" => [candidate | candidates]}
    assert {:error, %{errors: cluster_errors}} = RegressionCandidate.verify(bad_cluster)
    assert "invalid_shape" in cluster_errors

    legacy =
      RegressionCandidate.build([
        %{
          "event" => "run_end",
          "ts" => "not-a-time",
          "issue_identifier" => "LEGACY-2",
          "outcome" => "error"
        }
      ])

    assert {:ok, %{assertions: 0}} = RegressionCandidate.verify(legacy)

    invalid_warning =
      event("no_progress_loop", @run, %{
        "no_progress_version" => 1,
        "shadow" => true,
        "decision" => "alert",
        "kind" => "repeated_error",
        "tool_class" => "shell",
        "result_class" => "failed",
        "fingerprint" => @sha,
        "warning_id" => "bad"
      })

    malformed_manifest =
      manifest(@run)
      |> put_in(["agent", "model"], {:not, "json"})
      |> put_in(["task", "type"], 1)

    assert RegressionCandidate.build([invalid_warning, malformed_manifest])["candidates"] == []
  end

  defp accept(corpus) do
    candidates =
      Enum.map(corpus["candidates"], fn candidate ->
        process = candidate["proposed_assertions"]["process"]

        Map.put(candidate, "assertions", %{
          "authority" => "reviewed",
          "process" => process,
          "task_outcome" => "human_review:failed"
        })
      end)

    corpus
    |> Map.put("state", "accepted")
    |> Map.put("candidates", candidates)
    |> Map.put("review", %{
      "status" => "approved",
      "method" => "human",
      "approval_ref" => "github:pr:7504",
      "reviewer_sha256" => String.duplicate("e", 64),
      "approved_at" => "2026-09-03T00:00:00Z"
    })
  end

  defp events do
    [
      manifest(@run),
      failure(@run),
      event("budget_transition", @run, %{
        "task_type" => "concurrency_liveness",
        "budget_profile" => "high_risk",
        "transition" => %{"level" => "extreme"}
      }),
      event("no_progress_loop", @run, %{
        "no_progress_version" => 1,
        "shadow" => true,
        "decision" => "alert",
        "kind" => "repeated_error",
        "tool_class" => "shell",
        "result_class" => "failed",
        "fingerprint" => @sha_c,
        "warning_id" => "npw-" <> String.duplicate("c", 24),
        "repeat_count" => 4,
        "no_progress_turns" => 1
      }),
      event("task_outcome", @run, %{
        "outcome_version" => 1,
        "authoritative" => true,
        "stage" => "human_review",
        "status" => "failed",
        "reviewed_sha" => @sha_c
      })
    ]
  end

  defp manifest(run, prompt_sha \\ @sha) do
    event("run_manifest", run, %{
      "manifest_version" => 1,
      "agent" => %{"backend" => "codex", "model" => "gpt-5.6-sol", "reasoning_effort" => "xhigh"},
      "task" => %{"type" => "concurrency_liveness"},
      "config_digest" => @sha_b,
      "prompt" => %{"template_sha256" => prompt_sha},
      "workflow" => %{
        "prompt_template_sha256" => prompt_sha,
        "review_prompt_template_sha256" => @sha_b
      },
      "symphony" => %{"sha" => @sha},
      "repository" => %{"head_sha" => @sha_c, "base_sha" => @sha}
    })
  end

  defp failure(run) do
    event("failure", run, %{
      "failure_class" => "response_timeout_or_stall",
      "failure_scope" => "issue",
      "trusted_failure" => false
    })
  end

  defp event(kind, run, attrs) do
    Map.merge(
      %{
        "schema_version" => 1,
        "event" => kind,
        "ts" => timestamp(kind),
        "run_id" => run
      },
      attrs
    )
  end

  defp timestamp("run_manifest"), do: "2026-09-03T00:00:00Z"
  defp timestamp("failure"), do: "2026-09-03T00:00:01Z"
  defp timestamp("run_end"), do: "2026-09-03T00:00:02Z"
  defp timestamp("budget_transition"), do: "2026-09-03T00:00:03Z"
  defp timestamp("no_progress_loop"), do: "2026-09-03T00:00:04Z"
  defp timestamp("task_outcome"), do: "2026-09-03T00:00:05Z"
  defp timestamp("review"), do: "2026-09-03T00:00:06Z"
end
