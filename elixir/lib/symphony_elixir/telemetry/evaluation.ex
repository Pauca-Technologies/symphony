defmodule SymphonyElixir.Telemetry.Evaluation do
  @moduledoc """
  Builds bounded historical harness-evaluation views from compact telemetry.

  A normal worker exit is reported separately from task-delivery evidence.
  Missing downstream evidence remains unknown rather than being inferred from
  worker completion or tracker state.
  """

  alias SymphonyElixir.Telemetry
  alias SymphonyElixir.Telemetry.Report

  @windows [7, 30]
  @max_events 50_000
  @max_files 60
  @max_runs 100
  @max_extreme_trajectories 20
  @max_issue_events 500
  @filter_keys ~w(repository task_family model prompt_version config_digest)a
  @terminal_gate_outcomes ~w(passed failed invalidated infrastructure_error)
  @negative_post_handoff MapSet.new([
                           {"ci", "failed"},
                           {"human_review", "failed"},
                           {"pull_request", "reopened"},
                           {"pull_request", "reverted"}
                         ])
  @positive_post_handoff MapSet.new([
                           {"ci", "passed"},
                           {"human_review", "passed"},
                           {"pull_request", "merged"}
                         ])
  @legacy_outcomes %{
    "handoff" => {"legacy_handoff", "accepted", false},
    "merge" => {"pull_request", "merged", true},
    "reopen" => {"pull_request", "reopened", true},
    "revert" => {"pull_request", "reverted", true},
    "ci_passed" => {"ci", "passed", true},
    "ci_regression" => {"ci", "failed", true},
    "human_review_passed" => {"human_review", "passed", true},
    "human_blocking_findings" => {"automated_review", "blocking_findings", true}
  }

  @doc "Query one supported historical window from retained compact telemetry."
  @spec query(7 | 30, map(), keyword()) :: map()
  def query(window_days, filters \\ %{}, opts \\ []) when window_days in @windows do
    today = Keyword.get(opts, :today, Date.utc_today())
    retention_days = min(max(telemetry_retention_days(), 1), 30)
    effective_days = min(window_days, retention_days)
    from = Date.add(today, -(effective_days - 1))

    events =
      Telemetry.read_events(from, today,
        max_files: min(effective_days * 2, @max_files),
        max_events: Keyword.get(opts, :max_events, @max_events)
      )

    events
    |> build(window_days, filters)
    |> Map.put(:window, %{
      days: window_days,
      effective_days: effective_days,
      from: Date.to_iso8601(from),
      to: Date.to_iso8601(today)
    })
  end

  @doc "Build a historical evaluation projection from an already bounded event list."
  @spec build([map()], 7 | 30, map()) :: map()
  def build(events, window_days, filters \\ %{}) when is_list(events) and window_days in @windows do
    events = Enum.filter(events, &valid_event?/1)
    manifests = manifest_index(events)
    normalized_filters = normalize_filters(filters)
    filtered = Enum.filter(events, &matches_filters?(&1, normalized_filters, manifests))
    base = safe_report(filtered)
    outcomes = normalize_outcomes(filtered)
    runs = run_summaries(filtered, manifests, outcomes)
    fleet = fleet_metrics(filtered, outcomes, base)

    %{
      schema_version: 1,
      window: %{days: window_days, effective_days: window_days, from: nil, to: nil},
      filters: normalized_filters,
      filter_options: filter_options(events, manifests),
      fleet: fleet,
      outcomes: outcome_view(outcomes, fleet),
      failures: base.failures,
      tools: base.tools,
      prompts: base.prompts,
      reviews: base.reviews,
      extreme_trajectories:
        runs
        |> Enum.filter(& &1.extreme)
        |> Enum.take(@max_extreme_trajectories),
      runs: Enum.take(runs, @max_runs),
      limits: %{events: @max_events, files: @max_files, rendered_runs: @max_runs}
    }
  end

  @doc "Look up one issue from the most recent retained 30-day compact telemetry window."
  @spec issue(String.t(), keyword()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue(identifier, opts \\ []) when is_binary(identifier) do
    today = Keyword.get(opts, :today, Date.utc_today())
    retention_days = min(max(telemetry_retention_days(), 1), 30)
    from = Date.add(today, -(retention_days - 1))

    events =
      Telemetry.read_events(from, today,
        max_files: min(retention_days * 2, @max_files),
        max_events: Keyword.get(opts, :max_events, @max_events)
      )

    issue_from_events(events, identifier)
  end

  @doc "Reconstruct bounded historical issue detail from compact telemetry events."
  @spec issue_from_events([map()], String.t()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_from_events(events, identifier) when is_list(events) and is_binary(identifier) do
    matching =
      events
      |> Enum.filter(&(valid_event?(&1) and issue_matches?(&1, identifier)))
      |> Enum.take(-@max_issue_events)

    case matching do
      [] ->
        {:error, :issue_not_found}

      rows ->
        evaluation = build(rows, 30, %{})
        latest_run = List.first(evaluation.runs)

        {:ok,
         %{
           historical: true,
           issue_identifier: issue_identifier(rows, identifier),
           issue_id: latest_present(rows, "issue_id"),
           title: latest_present(rows, "title"),
           status: historical_status(evaluation.outcomes.timeline, latest_run),
           agent: historical_agent(latest_run),
           workspace: %{path: nil, host: latest_present(rows, "worker_host")},
           runs: evaluation.runs,
           outcomes: evaluation.outcomes,
           fleet: evaluation.fleet,
           recent_events: rows |> Enum.reverse() |> Enum.take(50) |> Enum.map(&historical_event/1),
           retention: %{event_count: length(rows), capped: length(rows) == @max_issue_events}
         }}
    end
  end

  defp fleet_metrics(events, outcomes, base) do
    starts = Enum.filter(events, &(&1["event"] == "run_start"))
    ends = Enum.filter(events, &(&1["event"] == "run_end"))
    normal = Enum.count(ends, &(&1["outcome"] == "ok"))
    failed = Enum.count(ends, &(&1["outcome"] == "error"))
    accepted = outcome_identity_count(outcomes, "exact_head_handoff", "accepted")
    material = outcome_identity_count(outcomes, "material_progress", "recorded")
    legacy_handoffs = outcome_identity_count(outcomes, "legacy_handoff", "accepted")
    handoff_attempts = max(handoff_attempt_count(events), accepted)
    post_handoff = post_handoff_metrics(outcomes, accepted)
    explicit_cost = explicit_cost(events)
    total_tokens = base.fleet.tokens.total_tokens

    %{
      worker_runs_started: length(starts),
      worker_runs_ended: length(ends),
      worker_runs_completed_normally: normal,
      worker_run_completion_rate: rate(length(ends), length(starts)),
      worker_normal_completion_rate: rate(normal, length(starts)),
      worker_failure_rate: rate(failed, length(starts)),
      material_progress_runs: material,
      accepted_handoffs: accepted,
      legacy_handoff_evidence: legacy_handoffs,
      accepted_handoff_rate: rate(accepted, handoff_attempts),
      post_handoff: post_handoff,
      tokens: base.fleet.tokens,
      tokens_p50: base.fleet.tokens_p50,
      tokens_p90: base.fleet.tokens_p90,
      tokens_per_accepted_handoff: divide(total_tokens, accepted),
      explicit_cost_usd: explicit_cost,
      cost_per_accepted_handoff_usd: divide(explicit_cost, accepted),
      duration_ms_p50: base.fleet.duration_ms_p50,
      duration_ms_p90: base.fleet.duration_ms_p90
    }
  end

  defp outcome_view(outcomes, fleet) do
    %{
      by_stage:
        outcomes
        |> Enum.group_by(& &1.stage)
        |> Map.new(fn {stage, rows} -> {stage, Enum.frequencies_by(rows, & &1.status)} end),
      summary: %{
        ci_passed: outcome_status_count(outcomes, "ci", "passed"),
        ci_failed: outcome_status_count(outcomes, "ci", "failed"),
        human_review_passed: outcome_status_count(outcomes, "human_review", "passed"),
        human_review_failed: outcome_status_count(outcomes, "human_review", "failed"),
        merged: outcome_status_count(outcomes, "pull_request", "merged"),
        reopened: outcome_status_count(outcomes, "pull_request", "reopened"),
        reverted: outcome_status_count(outcomes, "pull_request", "reverted")
      },
      timeline: outcomes |> Enum.sort_by(&(&1.ts || ""), :desc),
      unknown_post_handoff: fleet.post_handoff.unknown
    }
  end

  defp outcome_status_count(outcomes, stage, status) do
    Enum.count(outcomes, &(&1.authoritative and &1.stage == stage and &1.status == status))
  end

  defp post_handoff_metrics(outcomes, accepted_count) do
    accepted_keys = outcome_keys(outcomes, "exact_head_handoff", "accepted")

    downstream =
      outcomes
      |> Enum.filter(
        &(&1.authoritative and MapSet.member?(accepted_keys, &1.delivery_identity) and
            post_handoff_outcome?(&1))
      )
      |> Enum.group_by(& &1.delivery_identity)

    evaluated = map_size(downstream)

    reliable =
      Enum.count(downstream, fn {_identity, rows} ->
        pairs = MapSet.new(rows, &{&1.stage, &1.status})

        MapSet.disjoint?(pairs, @negative_post_handoff) and
          not MapSet.disjoint?(pairs, @positive_post_handoff)
      end)

    %{
      evaluated: evaluated,
      reliable: reliable,
      reliability_rate: rate(reliable, evaluated),
      unknown: max(accepted_count - evaluated, 0)
    }
  end

  defp post_handoff_outcome?(outcome) do
    MapSet.member?(@negative_post_handoff, {outcome.stage, outcome.status}) or
      MapSet.member?(@positive_post_handoff, {outcome.stage, outcome.status})
  end

  defp run_summaries(events, manifests, outcomes) do
    events
    |> Enum.group_by(&event_identity/1)
    |> Enum.reject(&outcome_only_group?/1)
    |> Enum.map(fn {identity, rows} -> run_summary(identity, rows, manifests, outcomes) end)
    |> Enum.sort_by(&(&1.started_at || &1.ended_at || ""), :desc)
  end

  defp outcome_only_group?({_identity, rows}) do
    not Enum.any?(rows, &(&1["event"] in ~w(run_start run_end run_manifest)))
  end

  defp run_summary(identity, events, manifests, outcomes) do
    manifest = Enum.find(events, &(&1["event"] == "run_manifest")) || manifests[run_id(events)] || %{}
    end_event = events |> Enum.filter(&(&1["event"] == "run_end")) |> List.last()

    delivery_keys =
      outcomes
      |> Enum.filter(&(&1.identity == identity and &1.stage == "exact_head_handoff"))
      |> MapSet.new(& &1.delivery_identity)

    run_outcomes =
      Enum.filter(outcomes, fn outcome ->
        outcome.identity == identity or MapSet.member?(delivery_keys, outcome.delivery_identity)
      end)

    %{
      identity: identity,
      run_id: run_id(events),
      issue_id: latest_present(events, "issue_id"),
      issue_identifier: latest_present(events, "issue_identifier") || latest_present(events, "identifier"),
      title: latest_present(events, "title"),
      repository: dimension(manifest, :repository, manifests) || latest_present(events, "repository"),
      task_family: dimension(manifest, :task_family, manifests),
      model: dimension(manifest, :model, manifests),
      prompt_version: dimension(manifest, :prompt_version, manifests),
      config_digest: dimension(manifest, :config_digest, manifests),
      started_at: event_timestamp(events, "run_start", :first),
      ended_at: event_timestamp(events, "run_end", :last),
      duration_ms: end_event && numeric(end_event["duration_ms"]),
      worker_outcome: end_event && end_event["outcome"],
      tokens: run_tokens(events),
      failure_class: latest_present(events, "failure_class"),
      outcomes: run_outcomes,
      extreme: extreme_run?(events)
    }
  end

  defp normalize_outcomes(events) do
    events
    |> Enum.flat_map(&normalize_outcome/1)
    |> Enum.uniq_by(&{&1.identity, &1.delivery_identity, &1.stage, &1.status, &1.ts, &1.source})
    |> shadow_legacy_outcomes()
  end

  defp shadow_legacy_outcomes(outcomes) do
    authoritative =
      Enum.filter(outcomes, &(&1.authoritative and &1.source == "task_outcome"))

    Enum.reject(outcomes, fn
      %{source: "quality_outcome"} = legacy ->
        Enum.any?(authoritative, &equivalent_outcome?(legacy, &1))

      _outcome ->
        false
    end)
  end

  defp equivalent_outcome?(legacy, authoritative) do
    equivalent_stage_status?(legacy, authoritative) and same_outcome_scope?(legacy, authoritative)
  end

  defp equivalent_stage_status?(
         %{stage: "legacy_handoff", status: "accepted"},
         %{stage: "exact_head_handoff", status: "accepted"}
       ),
       do: true

  defp equivalent_stage_status?(legacy, authoritative),
    do: legacy.stage == authoritative.stage and legacy.status == authoritative.status

  defp same_outcome_scope?(legacy, authoritative) do
    legacy_delivery? = delivery_key?(legacy.delivery_identity)
    authoritative_delivery? = delivery_key?(authoritative.delivery_identity)

    if legacy_delivery? and authoritative_delivery? do
      legacy.delivery_identity == authoritative.delivery_identity
    else
      legacy.identity == authoritative.identity
    end
  end

  defp delivery_key?("delivery:" <> _sha), do: true
  defp delivery_key?(_identity), do: false

  defp normalize_outcome(%{"event" => "task_outcome", "stage" => stage, "status" => status} = event)
       when is_binary(stage) and is_binary(status) do
    authoritative = event["outcome_version"] == 1 and event["authoritative"] == true
    [outcome(event, stage, status, authoritative, "task_outcome")]
  end

  defp normalize_outcome(%{"event" => "quality_outcome", "outcome" => legacy} = event) do
    case Map.get(@legacy_outcomes, legacy) do
      {stage, status, authoritative} ->
        [outcome(event, stage, status, authoritative, "quality_outcome")]

      nil ->
        []
    end
  end

  defp normalize_outcome(_event), do: []

  defp outcome(event, stage, status, verified, source) do
    %{
      identity: event_identity(event),
      delivery_identity: delivery_identity(event),
      run_id: present(event["run_id"]),
      issue_id: present(event["issue_id"]),
      issue_identifier: present(event["issue_identifier"]) || present(event["identifier"]),
      stage: stage,
      status: status,
      authoritative: verified,
      source: source,
      ts: present(event["ts"]),
      candidate_sha: present(event["candidate_sha"]),
      exact_sha: present(event["exact_sha"]),
      reviewed_sha: present(event["reviewed_sha"]),
      head_sha: present(event["head_sha"])
    }
  end

  defp matches_filters?(_event, filters, _manifests) when map_size(filters) == 0, do: true

  defp matches_filters?(event, filters, manifests) do
    Enum.all?(filters, fn {key, expected} -> dimension(event, key, manifests) == expected end)
  end

  defp filter_options(events, manifests) do
    Map.new(@filter_keys, fn key ->
      values =
        events
        |> Enum.map(&dimension(&1, key, manifests))
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.take(100)

      {key, values}
    end)
  end

  defp normalize_filters(filters) when is_map(filters) do
    Enum.reduce(@filter_keys, %{}, fn key, acc ->
      value = present(filters[key] || filters[Atom.to_string(key)])
      if value, do: Map.put(acc, key, value), else: acc
    end)
  end

  defp normalize_filters(_filters), do: %{}

  defp dimension(event, :repository, manifests),
    do:
      scalar(event["repository"]) || nested(event, ["repository", "id"]) ||
        nested(event_manifest(event, manifests), ["repository", "id"])

  defp dimension(event, :task_family, manifests),
    do:
      present(event["task_type"]) || nested(event, ["task", "type"]) ||
        nested(event_manifest(event, manifests), ["task", "type"])

  defp dimension(event, :model, manifests),
    do:
      present(event["model"]) || nested(event, ["agent", "model"]) ||
        nested(event_manifest(event, manifests), ["agent", "model"])

  defp dimension(event, :prompt_version, manifests),
    do: prompt_version(event) || prompt_version(event_manifest(event, manifests))

  defp dimension(event, :config_digest, manifests),
    do: present(event["config_digest"]) || present(event_manifest(event, manifests)["config_digest"])

  defp event_manifest(event, manifests) do
    manifests[present(event["run_id"])] || manifests[delivery_identity(event)] || %{}
  end

  defp prompt_version(event) do
    present(event["prompt_version"]) || nested(event, ["prompt", "template_sha256"]) ||
      nested(event, ["prompt", "composition_version"])
  end

  defp manifest_index(events) do
    by_run =
      events
      |> Enum.filter(&(&1["event"] == "run_manifest" and is_binary(&1["run_id"])))
      |> Map.new(&{&1["run_id"], &1})

    Enum.reduce(events, by_run, fn event, acc ->
      case by_run[present(event["run_id"])] do
        nil -> acc
        manifest -> index_delivery_manifest(acc, event, manifest)
      end
    end)
  end

  defp index_delivery_manifest(index, event, manifest) do
    Enum.reduce(delivery_shas(event), index, fn sha, acc ->
      Map.put_new(acc, "delivery:#{sha}", manifest)
    end)
  end

  defp handoff_attempt_count(events) do
    events
    |> Enum.filter(fn event ->
      event["event"] == "gate" and event["subtype"] == "before_handoff" and
        event["outcome"] in @terminal_gate_outcomes
    end)
    |> Enum.map(&event_identity/1)
    |> Enum.uniq()
    |> length()
  end

  defp outcome_identity_count(outcomes, stage, status),
    do: outcomes |> outcome_keys(stage, status) |> MapSet.size()

  defp outcome_keys(outcomes, stage, status) do
    outcomes
    |> Enum.filter(&(countable_outcome?(&1) and &1.stage == stage and &1.status == status))
    |> MapSet.new(&outcome_count_identity/1)
  end

  defp countable_outcome?(%{stage: "legacy_handoff"}), do: true
  defp countable_outcome?(outcome), do: outcome.authoritative

  defp outcome_count_identity(%{stage: stage, delivery_identity: identity})
       when stage in ~w(exact_head_handoff legacy_handoff),
       do: identity

  defp outcome_count_identity(outcome), do: outcome.identity

  defp explicit_cost(events) do
    costs =
      events
      |> Enum.flat_map(fn event ->
        value =
          cond do
            is_number(event["cumulative_cost_usd"]) -> event["cumulative_cost_usd"]
            event["event"] == "run_end" and is_number(event["cost_usd"]) -> event["cost_usd"]
            true -> nil
          end

        if is_number(value) and value >= 0, do: [{event_identity(event), value}], else: []
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    if map_size(costs) == 0 do
      nil
    else
      Enum.reduce(costs, 0.0, fn {_identity, values}, total -> total + Enum.max(values) end)
    end
  end

  defp run_tokens(events) do
    events
    |> Enum.filter(&(&1["event"] == "token_high_water"))
    |> Enum.group_by(&thread_identity/1, &nested(&1, ["cumulative", "total_tokens"]))
    |> Enum.reduce(0, fn {_thread, values}, total ->
      total + (values |> Enum.filter(&is_number/1) |> Enum.max(fn -> 0 end))
    end)
  end

  defp thread_identity(event), do: present(event["thread_id"]) || present(event["session_id"]) || "unreported"

  defp event_identity(event) do
    present(event["run_id"]) ||
      "legacy:#{present(event["issue_identifier"]) || present(event["issue_id"]) || "unknown"}:#{event_date(event)}"
  end

  defp delivery_identity(event) do
    case List.first(delivery_shas(event)) do
      nil -> event_identity(event)
      sha -> "delivery:#{sha}"
    end
  end

  defp delivery_shas(event) do
    [
      present(event["exact_sha"]),
      present(event["candidate_sha"]),
      present(event["reviewed_sha"]),
      present(event["head_sha"]),
      nested(event, ["repository", "head_sha"])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp event_date(event), do: event["ts"] |> present() |> to_string() |> String.slice(0, 10)

  defp event_timestamp(events, event_name, position) do
    timestamps = events |> Enum.filter(&(&1["event"] == event_name)) |> Enum.map(&present(&1["ts"])) |> Enum.filter(&is_binary/1)
    if position == :first, do: List.first(timestamps), else: List.last(timestamps)
  end

  defp run_id(events), do: Enum.find_value(events, &present(&1["run_id"]))

  defp extreme_run?(events) do
    Enum.any?(events, fn event ->
      event["event"] == "budget_transition" and nested(event, ["transition", "level"]) == "extreme"
    end)
  end

  defp historical_status(timeline, latest_run) do
    Enum.find_value(timeline, &historical_outcome_status/1) || historical_worker_status(latest_run)
  end

  defp historical_outcome_status(%{authoritative: true, stage: "pull_request", status: status}), do: status
  defp historical_outcome_status(%{authoritative: true, stage: "exact_head_handoff"}), do: "handoff accepted"
  defp historical_outcome_status(%{authoritative: true, stage: "material_progress"}), do: "progress recorded"
  defp historical_outcome_status(%{authoritative: true, stage: "ci", status: status}), do: "ci #{status}"
  defp historical_outcome_status(%{authoritative: true, stage: "human_review", status: status}), do: "human review #{status}"

  defp historical_outcome_status(%{authoritative: true, stage: "automated_review", status: status}),
    do: "automated review #{status}"

  defp historical_outcome_status(%{stage: "legacy_handoff"}), do: "legacy handoff evidence"
  defp historical_outcome_status(_outcome), do: nil

  defp historical_worker_status(%{worker_outcome: "ok"}), do: "worker completed"
  defp historical_worker_status(%{worker_outcome: "error"}), do: "worker failed"
  defp historical_worker_status(_run), do: "historical"

  defp historical_agent(nil), do: %{backend: nil, model: nil, reasoning_effort: nil, profile: nil}

  defp historical_agent(run) do
    %{backend: nil, model: run.model, reasoning_effort: nil, profile: nil}
  end

  defp historical_event(event) do
    Map.take(event, [
      "event",
      "ts",
      "run_id",
      "stage",
      "status",
      "outcome",
      "failure_class",
      "session_id",
      "thread_id",
      "turn_id"
    ])
  end

  defp issue_matches?(event, identifier) do
    identifier in [event["issue_identifier"], event["identifier"], event["issue_id"]]
  end

  defp issue_identifier(events, fallback) do
    latest_present(events, "issue_identifier") || latest_present(events, "identifier") || fallback
  end

  defp latest_present(events, key), do: events |> Enum.reverse() |> Enum.find_value(&present(&1[key]))

  defp nested(value, []), do: present(value)
  defp nested(map, [key | rest]) when is_map(map), do: nested(map[key], rest)
  defp nested(_value, _path), do: nil

  defp scalar(value) when is_binary(value), do: present(value)
  defp scalar(_value), do: nil

  defp present(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp present(_value), do: nil

  defp numeric(value) when is_number(value), do: value
  defp numeric(_value), do: nil

  defp rate(_numerator, 0), do: nil
  defp rate(numerator, denominator), do: numerator / denominator

  defp divide(nil, _denominator), do: nil
  defp divide(_numerator, 0), do: nil
  defp divide(numerator, denominator), do: numerator / denominator

  defp safe_report(events) do
    events
    |> Enum.map(&sanitize_report_event/1)
    |> Report.build()
  rescue
    _malformed -> Report.build([])
  end

  defp sanitize_report_event(%{"event" => "base_drift"} = event) do
    Map.update(event, "gates_avoided", 0, fn
      value when is_number(value) -> value
      _invalid -> 0
    end)
  end

  defp sanitize_report_event(%{"event" => "budget_transition"} = event) do
    Map.update(event, "transition", %{}, fn
      value when is_map(value) -> value
      _invalid -> %{}
    end)
  end

  defp sanitize_report_event(%{"event" => "scheduling"} = event) do
    Map.update(event, "overlap_score", 0, fn
      value when is_number(value) -> value
      _invalid -> 0
    end)
  end

  defp sanitize_report_event(%{"event" => kind} = event) when kind in ["gate", "review"] do
    event
    |> ensure_map_field("attestation_report")
    |> ensure_map_field("attestations")
    |> ensure_map_field("severity_counts")
  end

  defp sanitize_report_event(event), do: event

  defp ensure_map_field(event, key) do
    Map.update(event, key, %{}, fn
      value when is_map(value) -> value
      _invalid -> %{}
    end)
  end

  defp telemetry_retention_days do
    Telemetry.observability().telemetry_retention_days
  end

  defp valid_event?(%{"event" => event}) when is_binary(event), do: true
  defp valid_event?(_event), do: false
end
