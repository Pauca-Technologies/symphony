defmodule SymphonyElixir.RegressionCandidate do
  @moduledoc "Builds pending-only, deterministic privacy-safe regression candidates from compact telemetry."
  alias SymphonyElixir.RunManifest
  @schema_version 1
  @kind "symphony_regression_candidate_corpus"
  @policy_version "regression-candidates/v1"
  @max_input_events 50_000
  @max_candidates 100
  @max_samples 2
  @max_evidence_per_candidate 10
  @failure_classes ~w(
    agent_protocol_failure authentication_configuration review_configuration handoff_reviewer_gate rate_limited
    response_timeout_or_stall transient_infrastructure usage_quota_limit unknown
  )
  @task_families ~w(simple_direct ui security_tenant data_schema concurrency_liveness broad_architecture)
  @backends ~w(codex acp claude_code)
  @reasoning_efforts ~w(none minimal low medium high xhigh max ultra)
  @no_progress_kinds ~w(repeated_error repeated_success_no_progress detector_unavailable)
  @tool_classes ~w(shell read edit web mcp dynamic other)
  @result_classes ~w(success failed nonzero_exit cancelled unsupported timeout unknown_failure)
  @review_outcomes ~w(
    automated_review:approved automated_review:request_changes
    automated_review:automation_inconclusive automated_review:infrastructure_unavailable
    automated_review:budget_exhausted_with_findings exact_head_handoff:accepted
    material_progress:recorded ci:passed ci:failed human_review:passed human_review:failed
    pull_request:merged pull_request:reopened pull_request:reverted
  )
  @negative_review_outcomes ~w(
    automated_review:request_changes automated_review:automation_inconclusive
    automated_review:infrastructure_unavailable automated_review:budget_exhausted_with_findings
    ci:failed human_review:failed pull_request:reopened pull_request:reverted
  )
  @process_assertions ~w(
    detects_first_failure detects_extreme_budget detects_no_progress_alert
    detects_negative_review_outcome
  )
  @reason_assertions %{
    "first_failure" => "detects_first_failure",
    "extreme_budget" => "detects_extreme_budget",
    "no_progress_alert" => "detects_no_progress_alert",
    "negative_review_outcome" => "detects_negative_review_outcome"
  }
  @event_kinds ~w(run_manifest failure run_end budget_transition no_progress_loop task_outcome review)

  @spec build([map()], keyword()) :: map()
  def build(events, opts \\ []) when is_list(events) and is_list(opts) do
    window_days = if Keyword.get(opts, :window_days, 7) == 30, do: 30, else: 7
    input_count = length(events)

    normalized =
      events
      |> Enum.flat_map(&normalize_event/1)
      |> retain_normalized()
      |> correlate_delivery_events()

    {candidates, evidence} = build_candidates(normalized)

    corpus = %{
      "schema_version" => @schema_version,
      "kind" => @kind,
      "selection_policy" => @policy_version,
      "state" => "pending_review",
      "window_days" => window_days,
      "summary" => %{
        "input_events" => min(input_count, 1_000_000),
        "normalized_events" => length(normalized),
        "omitted_input_events" => max(input_count - @max_input_events, 0),
        "candidates" => length(candidates)
      },
      "candidates" => candidates,
      "evidence" => evidence,
      "review" => %{"status" => "pending", "required" => "external_manual"}
    }

    Map.put(corpus, "corpus_id", corpus_id(corpus))
  end

  @spec verify(term(), term()) :: {:ok, map()} | {:error, map()}
  def verify(corpus, opts \\ [])

  def verify(corpus, opts) when is_map(corpus) and is_list(opts) do
    require_accepted? = Keyword.get(opts, :require_accepted, false) == true

    errors =
      []
      |> validate_header(corpus)
      |> validate_bundle_size(corpus)
      |> validate_safe_shape(corpus)
      |> validate_review(corpus)
      |> validate_assertions(corpus)
      |> validate_replay(corpus)
      |> add_error(require_accepted? and corpus["state"] != "accepted", "accepted_corpus_required")

    if errors == [] do
      {:ok,
       %{
         schema_version: @schema_version,
         policy_version: @policy_version,
         corpus_id: corpus["corpus_id"],
         candidates: length(corpus["candidates"]),
         assertions: count_assertions(corpus),
         state: corpus["state"]
       }}
    else
      {:error, %{schema_version: @schema_version, errors: Enum.reverse(Enum.uniq(errors))}}
    end
  end

  def verify(_corpus, _opts),
    do: {:error, %{schema_version: @schema_version, errors: ["invalid_corpus"]}}

  defp normalize_event(event) when is_map(event) do
    kind = value(event, "event")

    if kind in @event_kinds do
      normalize_known_event(kind, event)
    else
      []
    end
  end

  defp normalize_event(_event), do: []

  defp normalize_known_event("run_manifest", event) do
    if value(event, "manifest_version") == 1 do
      manifest = %{
        "backend" => member(value(event, ["agent", "backend"]), @backends),
        "model" => safe_label(value(event, ["agent", "model"])),
        "reasoning_effort" => member(value(event, ["agent", "reasoning_effort"]), @reasoning_efforts),
        "task_family" => member(value(event, ["task", "type"]), @task_families),
        "config_digest" => digest(value(event, "config_digest")),
        "prompt_sha256" => digest(value(event, ["prompt", "template_sha256"])),
        "workflow_sha256" => digest(value(event, ["workflow", "prompt_template_sha256"])),
        "symphony_sha" => digest(value(event, ["symphony", "sha"])),
        "repository_head_sha" => digest(value(event, ["repository", "head_sha"]))
      }

      [normalized(event, "run_manifest", compact(manifest))]
    else
      []
    end
  end

  defp normalize_known_event("failure", event) do
    data = %{
      "failure_class" => member(value(event, "failure_class"), @failure_classes) || "unknown"
    }

    [normalized(event, "failure", compact(data))]
  end

  defp normalize_known_event("run_end", event) do
    if value(event, "outcome") == "error" do
      data = %{
        "failure_class" => member(value(event, "failure_class"), @failure_classes) || "unknown"
      }

      [normalized(event, "run_end", compact(data))]
    else
      []
    end
  end

  defp normalize_known_event("budget_transition", event) do
    if value(event, ["transition", "level"]) == "extreme" do
      data = %{
        "level" => "extreme",
        "task_family" => member(value(event, "task_type"), @task_families)
      }

      [normalized(event, "budget_transition", compact(data))]
    else
      []
    end
  end

  defp normalize_known_event("no_progress_loop", event) do
    with 1 <- value(event, "no_progress_version"),
         true <- value(event, "shadow") == true,
         "alert" <- value(event, "decision"),
         kind when is_binary(kind) <- member(value(event, "kind"), @no_progress_kinds),
         tool when is_binary(tool) <- member(value(event, "tool_class"), @tool_classes),
         result when is_binary(result) <- member(value(event, "result_class"), @result_classes),
         fingerprint when is_binary(fingerprint) <- digest(value(event, "fingerprint")),
         {:ok, warning_id} <- warning_id(value(event, "warning_id")) do
      data = %{
        "kind" => kind,
        "tool_class" => tool,
        "result_class" => result,
        "fingerprint" => fingerprint,
        "warning_id" => warning_id
      }

      [normalized(event, "no_progress_loop", compact(data))]
    else
      _invalid -> []
    end
  end

  defp normalize_known_event("task_outcome", event) do
    outcome = outcome_label(value(event, "stage"), value(event, "status"))

    if value(event, "outcome_version") == 1 and value(event, "authoritative") == true and
         outcome in @review_outcomes do
      [normalized(event, "task_outcome", %{"review_outcome" => outcome})]
    else
      []
    end
  end

  defp normalize_known_event("review", event) do
    outcome = outcome_label("automated_review", value(event, "outcome"))

    if value(event, "subtype") == "review" and value(event, "authoritative") == true and
         outcome in @review_outcomes do
      [normalized(event, "review", %{"review_outcome" => outcome})]
    else
      []
    end
  end

  defp normalized(event, kind, data) do
    base = %{
      "event" => kind,
      "schema_version" => schema_version(event),
      "ts" => timestamp(value(event, "ts")),
      "run_ref" => run_ref(event),
      "delivery_sha" => delivery_sha(event),
      "data" => data
    }

    ref = "telemetry:v1:#{event_date(base["ts"])}:sha256:#{hash(base)}"
    Map.put(base, "ref", ref)
  end

  defp retain_normalized(events) do
    {valid, invalid} = Enum.split_with(events, &is_binary(&1["ts"]))

    valid
    |> Enum.sort_by(&{&1["ts"], &1["ref"]}, :desc)
    |> Kernel.++(Enum.sort_by(invalid, & &1["ref"]))
    |> Enum.take(@max_input_events)
    |> Enum.sort_by(&event_sort_key/1)
  end

  defp correlate_delivery_events(events) do
    aliases =
      events
      |> Enum.filter(&(is_binary(&1["run_ref"]) and is_binary(&1["delivery_sha"])))
      |> Enum.group_by(& &1["delivery_sha"], & &1["run_ref"])
      |> Map.new(fn {sha, refs} -> {sha, Enum.min(refs)} end)

    Enum.map(events, fn event ->
      run_ref = event["run_ref"] || aliases[event["delivery_sha"]] || legacy_ref(event)
      event = event |> Map.put("run_ref", run_ref) |> Map.delete("ref")
      Map.put(event, "ref", evidence_ref(event))
    end)
  end

  defp build_candidates(events) do
    observations =
      events
      |> Enum.group_by(& &1["run_ref"])
      |> Enum.flat_map(fn {run_ref, rows} -> run_observations(run_ref, rows) end)

    candidates =
      observations
      |> Enum.group_by(& &1.cluster)
      |> Enum.map(fn {cluster, rows} -> candidate(cluster, rows) end)
      |> Enum.sort_by(& &1["candidate_id"])

    candidates = Enum.take(candidates, @max_candidates)
    used_refs = candidates |> Enum.flat_map(&candidate_refs/1) |> MapSet.new()

    evidence =
      events
      |> Enum.filter(&MapSet.member?(used_refs, &1["ref"]))
      |> Enum.uniq_by(& &1["ref"])
      |> Enum.sort_by(& &1["ref"])
      |> Enum.map(& &1)

    {candidates, evidence}
  end

  defp run_observations(run_ref, rows) do
    manifest = rows |> Enum.filter(&(&1["event"] == "run_manifest")) |> List.first()
    failure = first_failure(rows)
    extreme = Enum.find(rows, &(&1["event"] == "budget_transition"))
    review = review_outcome(rows)
    loops = rows |> Enum.filter(&(&1["event"] == "no_progress_loop")) |> Enum.uniq_by(& &1["data"]["fingerprint"])
    base_reasons = reasons(failure, extreme, review, nil)

    cond do
      loops != [] ->
        Enum.map(loops, &observation(run_ref, manifest, failure, extreme, review, &1))

      base_reasons != [] ->
        [observation(run_ref, manifest, failure, extreme, review, nil)]

      true ->
        []
    end
  end

  defp observation(run_ref, manifest, failure, extreme, review, loop) do
    manifest_data = if manifest, do: manifest["data"], else: %{}

    cluster = %{
      "first_failure_class" => data(failure, "failure_class") || "unknown",
      "task_family" => data(manifest, "task_family") || data(extreme, "task_family") || "unknown",
      "tool_error_fingerprint" => data(loop, "fingerprint") || "unknown",
      "prompt_sha256" => data(manifest, "prompt_sha256") || "unknown",
      "config_digest" => data(manifest, "config_digest") || "unknown",
      "review_outcome" => data(review, "review_outcome") || "unknown"
    }

    evidence = [manifest, failure, extreme, loop, review] |> Enum.reject(&is_nil/1) |> Enum.uniq_by(& &1["ref"])

    %{
      cluster: cluster,
      run_ref: run_ref,
      reproduction: manifest_data,
      reasons: reasons(failure, extreme, review, loop),
      evidence_refs: Enum.map(evidence, & &1["ref"])
    }
  end

  defp reasons(failure, extreme, review, loop) do
    []
    |> maybe_reason(failure, %{"kind" => "first_failure", "value" => data(failure, "failure_class")})
    |> maybe_reason(extreme, %{"kind" => "extreme_budget", "value" => "extreme"})
    |> maybe_reason(loop, %{"kind" => "no_progress_alert", "value" => data(loop, "kind")})
    |> maybe_negative_review_reason(review)
    |> Enum.sort_by(& &1["kind"])
  end

  defp maybe_reason(reasons, nil, _reason), do: reasons
  defp maybe_reason(reasons, _event, reason), do: [reason | reasons]

  defp maybe_negative_review_reason(reasons, review) do
    if data(review, "review_outcome") in @negative_review_outcomes do
      [%{"kind" => "negative_review_outcome", "value" => data(review, "review_outcome")} | reasons]
    else
      reasons
    end
  end

  defp candidate(cluster, observations) do
    candidate_id = "rgc-" <> String.slice(hash(%{"policy" => @policy_version, "cluster" => cluster}), 0, 32)

    samples =
      observations
      |> Enum.uniq_by(& &1.run_ref)
      |> Enum.sort_by(&hash(%{"candidate_id" => candidate_id, "run_ref" => &1.run_ref}))
      |> Enum.take(@max_samples)

    reasons =
      samples
      |> Enum.flat_map(& &1.reasons)
      |> Enum.uniq()
      |> Enum.sort_by(&{&1["kind"], &1["value"]})

    evidence_refs =
      samples
      |> Enum.flat_map(& &1.evidence_refs)
      |> Enum.uniq()
      |> Enum.sort()

    evidence_refs = Enum.take(evidence_refs, @max_evidence_per_candidate)

    %{
      "candidate_id" => candidate_id,
      "cluster" => cluster,
      "selection_reasons" => reasons,
      "samples" =>
        Enum.map(samples, fn sample ->
          %{
            "run_ref" => sample.run_ref,
            "reproduction" => sample.reproduction,
            "evidence_refs" => Enum.filter(sample.evidence_refs, &(&1 in evidence_refs))
          }
        end),
      "proposed_assertions" => %{
        "authority" => "proposal",
        "process" => reasons |> Enum.map(&@reason_assertions[&1["kind"]]) |> Enum.reject(&is_nil/1),
        "task_outcome" => "unknown"
      }
    }
  end

  defp candidate_refs(candidate), do: candidate["samples"] |> Enum.flat_map(& &1["evidence_refs"])

  defp first_failure(rows) do
    Enum.find(rows, &(&1["event"] == "failure")) || Enum.find(rows, &(&1["event"] == "run_end"))
  end

  defp review_outcome(rows) do
    rows
    |> Enum.filter(&(&1["event"] in ~w(task_outcome review) and is_binary(data(&1, "review_outcome"))))
    |> Enum.max_by(&review_sort_key/1, fn -> nil end)
  end

  defp review_sort_key(row) do
    outcome = data(row, "review_outcome")
    negative = if outcome in @negative_review_outcomes, do: 1, else: 0
    {if(is_binary(row["ts"]), do: 1, else: 0), row["ts"] || "", negative, row["ref"]}
  end

  defp validate_header(errors, corpus) do
    errors
    |> add_error(corpus["schema_version"] != @schema_version, "unsupported_schema")
    |> add_error(corpus["kind"] != @kind, "invalid_kind")
    |> add_error(corpus["selection_policy"] != @policy_version, "stale_policy")
    |> add_error(corpus["state"] not in ~w(pending_review accepted), "invalid_state")
    |> add_error(corpus["corpus_id"] != corpus_id(corpus), "corpus_id_mismatch")
    |> add_error(corpus["window_days"] not in [7, 30], "invalid_window")
    |> add_error(not is_list(corpus["candidates"]), "invalid_candidates")
    |> add_error(not is_list(corpus["evidence"]), "invalid_evidence")
  end

  defp validate_bundle_size(errors, corpus) do
    case Jason.encode(corpus) do
      {:ok, encoded} -> add_error(errors, byte_size(encoded) > 1_048_576, "bundle_too_large")
      {:error, _reason} -> ["invalid_json" | errors]
    end
  end

  defp validate_review(errors, corpus) do
    review = corpus["review"]

    valid? =
      if corpus["state"] == "accepted" do
        is_map(review) and review["status"] == "approved" and
          review["method"] in ~w(human independent) and valid_approval_ref?(review["approval_ref"]) and
          sha256?(review["reviewer_sha256"]) and timestamp(review["approved_at"]) == review["approved_at"]
      else
        review == %{"status" => "pending", "required" => "external_manual"}
      end

    add_error(errors, not valid?, "invalid_review")
  end

  defp validate_assertions(errors, corpus) do
    candidates = if corpus["state"] == "accepted" and is_list(corpus["candidates"]), do: corpus["candidates"], else: []
    Enum.reduce(candidates, errors, &validate_candidate_assertions/2)
  rescue
    _invalid -> ["invalid_assertions" | errors]
  end

  defp validate_candidate_assertions(candidate, errors) do
    assertions = candidate["assertions"]
    process = if is_map(assertions), do: assertions["process"], else: nil
    outcome = if is_map(assertions), do: assertions["task_outcome"], else: nil
    reasons = candidate |> Map.get("selection_reasons", []) |> Enum.map(& &1["kind"])

    valid_process? =
      is_map(assertions) and assertions["authority"] == "reviewed" and is_list(process) and process != [] and
        Enum.all?(process, &(&1 in @process_assertions)) and Enum.all?(process, &assertion_supported?(&1, reasons))

    errors
    |> add_error(not valid_process?, "invalid_assertions")
    |> add_error(not (outcome == "unknown" or outcome in @review_outcomes), "invalid_expected_outcome")
  end

  defp validate_replay(errors, corpus) do
    if safe_list?(corpus["evidence"], @max_candidates * @max_evidence_per_candidate, &safe_evidence?/1) and
         safe_list?(corpus["candidates"], @max_candidates, &safe_candidate?/1) do
      {replayed_candidates, _evidence} = build_candidates(corpus["evidence"])
      expected = Enum.map(corpus["candidates"], &Map.delete(&1, "assertions"))
      actual = replayed_candidates
      add_error(errors, expected != actual, "evidence_replay_mismatch")
    else
      errors
    end
  end

  defp validate_safe_shape(errors, corpus) do
    candidates = corpus["candidates"]
    evidence = corpus["evidence"]

    safe? =
      exact_keys?(corpus, ~w(schema_version kind selection_policy state window_days summary candidates evidence review corpus_id)) and
        exact_keys?(corpus["summary"], ~w(input_events normalized_events omitted_input_events candidates)) and
        valid_summary?(corpus["summary"]) and safe_review_shape?(corpus["state"], corpus["review"]) and
        safe_list?(candidates, @max_candidates, &safe_candidate?/1) and
        safe_list?(evidence, @max_candidates * @max_evidence_per_candidate, &safe_evidence?/1)

    add_error(errors, not safe?, "invalid_shape")
  end

  defp safe_candidate?(candidate) when is_map(candidate) do
    allowed = ~w(candidate_id cluster selection_reasons samples proposed_assertions assertions)
    cluster = candidate["cluster"]

    is_map(cluster) and Map.keys(candidate) -- allowed == [] and safe_term?(candidate) and
      candidate["candidate_id"] == "rgc-" <> String.slice(hash(%{"policy" => @policy_version, "cluster" => cluster}), 0, 32) and
      safe_cluster?(cluster)
  end

  defp safe_candidate?(_candidate), do: false

  defp safe_cluster?(cluster) do
    exact_keys?(cluster, ~w(first_failure_class task_family tool_error_fingerprint prompt_sha256 config_digest review_outcome)) and
      cluster["first_failure_class"] in @failure_classes and cluster["task_family"] in ["unknown" | @task_families] and
      cluster["review_outcome"] in ["unknown" | @review_outcomes] and
      Enum.all?(~w(tool_error_fingerprint prompt_sha256 config_digest), &(cluster[&1] == "unknown" or digest(cluster[&1]) == cluster[&1]))
  end

  defp safe_review_shape?("pending_review", review),
    do: exact_keys?(review, ~w(status required))

  defp safe_review_shape?("accepted", review),
    do: exact_keys?(review, ~w(status method approval_ref reviewer_sha256 approved_at))

  defp safe_review_shape?(_state, _review), do: false

  defp safe_list?(values, max, validator),
    do: is_list(values) and length(values) <= max and Enum.all?(values, validator)

  defp safe_evidence?(event) when is_map(event) do
    exact_keys?(event, ~w(event schema_version ts run_ref delivery_sha data ref)) and
      event["event"] in @event_kinds and is_map(event["data"]) and safe_term?(event) and
      event["ref"] == evidence_ref(Map.delete(event, "ref")) and
      Map.keys(event["data"]) -- evidence_data_keys(event["event"]) == []
  end

  defp safe_evidence?(_event), do: false

  defp safe_term?(value) when is_binary(value) do
    byte_size(value) <= 160 and String.valid?(value) and
      Regex.match?(~r/\A[a-zA-Z0-9._:+\/-]+\z/, value)
  end

  defp safe_term?(value) when is_integer(value), do: valid_count?(value)
  defp safe_term?(value) when is_boolean(value) or is_nil(value), do: true
  defp safe_term?(value) when is_list(value), do: Enum.all?(value, &safe_term?/1)

  defp safe_term?(value) when is_map(value),
    do: Enum.all?(value, fn {key, nested} -> is_binary(key) and safe_term?(key) and safe_term?(nested) end)

  defp safe_term?(_value), do: false

  defp evidence_data_keys("run_manifest"),
    do: ~w(backend model reasoning_effort task_family config_digest prompt_sha256 workflow_sha256 symphony_sha repository_head_sha)

  defp evidence_data_keys("failure"), do: ~w(failure_class)
  defp evidence_data_keys("run_end"), do: ~w(failure_class)
  defp evidence_data_keys("budget_transition"), do: ~w(level task_family)
  defp evidence_data_keys("no_progress_loop"), do: ~w(kind tool_class result_class fingerprint warning_id)
  defp evidence_data_keys(kind) when kind in ~w(task_outcome review), do: ~w(review_outcome)

  defp evidence_ref(event),
    do: "telemetry:v1:#{event_date(event["ts"])}:sha256:#{hash(event)}"

  defp exact_keys?(map, keys) when is_map(map), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp exact_keys?(_map, _keys), do: false

  defp valid_count?(value), do: is_integer(value) and value >= 0 and value <= 1_000_000_000

  defp valid_summary?(summary),
    do: Enum.all?(Map.values(summary), &valid_count?/1)

  defp assertion_supported?(assertion, reasons) do
    Enum.any?(reasons, fn reason -> @reason_assertions[reason] == assertion end)
  end

  defp count_assertions(corpus) do
    corpus["candidates"]
    |> Enum.map(&get_in(&1, ["assertions", "process"]))
    |> Enum.filter(&is_list/1)
    |> Enum.map(&length/1)
    |> Enum.sum()
  end

  defp corpus_id(corpus) do
    identity = %{
      "selection_policy" => corpus["selection_policy"],
      "window_days" => corpus["window_days"],
      "summary" => corpus["summary"],
      "candidates" => candidate_cores(corpus["candidates"]),
      "evidence" => corpus["evidence"]
    }

    "rgc-corpus-" <> String.slice(hash(identity), 0, 32)
  rescue
    _invalid -> nil
  end

  defp candidate_cores(candidates) when is_list(candidates),
    do: Enum.map(candidates, &if(is_map(&1), do: Map.delete(&1, "assertions"), else: &1))

  defp candidate_cores(invalid), do: invalid

  defp schema_version(event) do
    case value(event, "schema_version") do
      version when version in [0, 1] -> version
      _unknown -> 0
    end
  end

  defp run_ref(event) do
    case value(event, "run_id") do
      run_id when is_binary(run_id) and byte_size(run_id) <= 128 and run_id != "" ->
        if Regex.match?(~r/\A[0-9a-f-]{8,128}\z/i, run_id),
          do: String.downcase(run_id),
          else: "run-" <> String.slice(hash(run_id), 0, 24)

      _missing ->
        nil
    end
  end

  defp legacy_ref(event) do
    identity = %{
      "issue" => value(event, "issue_id") || value(event, "issue_identifier") || "unknown",
      "date" => event_date(timestamp(value(event, "ts")))
    }

    "legacy-" <> String.slice(hash(identity), 0, 24)
  end

  defp delivery_sha(event) do
    [
      value(event, "exact_sha"),
      value(event, "candidate_sha"),
      value(event, "reviewed_sha"),
      value(event, "head_sha"),
      value(event, ["repository", "head_sha"])
    ]
    |> Enum.find_value(&digest/1)
  end

  defp data(nil, _key), do: nil
  defp data(event, key), do: get_in(event, ["data", key])

  defp event_sort_key(event), do: {event["ts"] || "9999-12-31T23:59:59Z", event["ref"]}

  defp event_date(nil), do: "unknown"
  defp event_date(timestamp), do: String.slice(timestamp, 0, 10)

  defp timestamp(value) when is_binary(value) and byte_size(value) <= 64 do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_iso8601(datetime)
      _invalid -> nil
    end
  end

  defp timestamp(_value), do: nil

  defp warning_id(nil), do: {:ok, nil}

  defp warning_id("npw-" <> digest = warning_id) when byte_size(digest) == 24 do
    if Regex.match?(~r/\A[0-9a-f]{24}\z/, digest), do: {:ok, warning_id}, else: :error
  end

  defp warning_id(_invalid), do: :error

  defp digest(value) when is_binary(value) and byte_size(value) in [40, 64] do
    if Regex.match?(~r/\A[0-9a-f]+\z/i, value), do: String.downcase(value)
  end

  defp digest(_value), do: nil

  defp sha256?(value) when is_binary(value) and byte_size(value) == 64,
    do: Regex.match?(~r/\A[0-9a-f]{64}\z/i, value)

  defp sha256?(_value), do: false

  defp safe_label(value) when is_binary(value) and byte_size(value) <= 128 do
    if Regex.match?(~r/\A[a-zA-Z0-9._:+\/-]+\z/, value), do: value
  end

  defp safe_label(_value), do: nil

  defp member(value, allowed) when is_binary(value), do: if(value in allowed, do: value)
  defp member(_value, _allowed), do: nil

  defp outcome_label(stage, status) when is_binary(stage) and is_binary(status), do: stage <> ":" <> status
  defp outcome_label(_stage, _status), do: nil

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp value(map, path) when is_map(map) and is_list(path), do: Enum.reduce_while(path, map, &nested_value/2)
  defp value(map, key) when is_map(map), do: Map.get(map, key)

  defp nested_value(key, map) when is_map(map) do
    {:cont, Map.get(map, key)}
  end

  defp nested_value(_key, _value), do: {:halt, nil}

  defp hash(value), do: RunManifest.config_digest(%{"value" => value})

  defp valid_approval_ref?(value) when is_binary(value) and byte_size(value) <= 128 do
    Regex.match?(~r/\A(?:github:pr:[1-9][0-9]*|linear:comment:[0-9a-f-]{36}|manual:[0-9a-f]{64})\z/, value)
  end

  defp valid_approval_ref?(_value), do: false

  defp add_error(errors, true, code), do: [code | errors]
  defp add_error(errors, false, _code), do: errors
end
