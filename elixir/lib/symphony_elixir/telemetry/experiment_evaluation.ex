defmodule SymphonyElixir.Telemetry.ExperimentEvaluation do
  @moduledoc "Builds bounded descriptive experiment cohorts from compact, manifest-joined telemetry."

  alias SymphonyElixir.Telemetry.Report

  @schema_version 1
  @max_events 50_000
  @max_experiments 20
  @max_arms 4
  @max_arm_rows 80
  @max_number 1_000_000_000_000
  @safe_id ~r/\A[a-z0-9][a-z0-9._-]*\z/
  @run_id ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  @digest ~r/\A[0-9a-f]{64}\z/
  @short_ids %{
    exposure_id: ~r/\Aexe-[0-9a-f]{32}\z/,
    suspension_id: ~r/\Aexs-[0-9a-f]{32}\z/,
    unit_id: ~r/\Aexu-[0-9a-f]{32}\z/,
    assignment_id: ~r/\Aexa-[0-9a-f]{32}\z/
  }
  @efforts ~w(none low medium high xhigh max)
  @roles ~w(control variant)
  @task_families ~w(simple_direct ui security_tenant data_schema concurrency_liveness broad_architecture)
  @cost_event_kinds ~w(run_end token_high_water tool)
  @suspension_reasons ~w(
    identity_mismatch kill_switch manifest_mismatch manifest_unavailable route_mismatch
  )
  @delivery_modes ~w(initial replay)
  @comparison_metrics [
    worker_completion_rate: {[:metrics, :worker_runs, :completion_rate], [:metrics, :worker_runs, :denominator]},
    exact_head_acceptance_rate: {[:metrics, :task_outcomes, :exact_head_acceptance_rate], [:metrics, :task_outcomes, :run_denominator]},
    post_handoff_reliability_rate: {[:metrics, :post_handoff, :reliability_rate], [:metrics, :post_handoff, :evaluated]},
    duration_ms_p50: {[:metrics, :duration_ms, :p50], [:metrics, :duration_ms, :samples]},
    tokens_p50: {[:metrics, :tokens, :p50], [:metrics, :tokens, :samples]},
    explicit_cost_usd_p50: {[:metrics, :explicit_cost_usd, :p50], [:metrics, :explicit_cost_usd, :samples]}
  ]
  @outcomes MapSet.new([
              {"material_progress", "recorded"},
              {"exact_head_handoff", "accepted"},
              {"ci", "passed"},
              {"ci", "failed"},
              {"human_review", "passed"},
              {"human_review", "failed"},
              {"pull_request", "merged"},
              {"pull_request", "reopened"},
              {"pull_request", "reverted"}
            ])
  @positive_downstream MapSet.new([
                         {"ci", "passed"},
                         {"human_review", "passed"},
                         {"pull_request", "merged"}
                       ])
  @negative_downstream MapSet.new([
                         {"ci", "failed"},
                         {"human_review", "failed"},
                         {"pull_request", "reopened"},
                         {"pull_request", "reverted"}
                       ])
  @doc "Build a strict, bounded experiment projection from compact telemetry rows."
  @spec build([map()], keyword()) :: map()
  def build(events, opts \\ []) when is_list(events) and is_list(opts) do
    input_count = length(events)
    events = Enum.take(events, -@max_events)
    {filters, invalid_filters} = filters(opts)
    manifests = normalize_manifests(events)

    {exposures, exposure_conflicts} =
      events
      |> Enum.flat_map(&normalize_exposure/1)
      |> Enum.map(&attach_manifest(&1, manifests))
      |> deduplicate(:exposure_id, &exposure_core/1)

    {suspensions, suspension_conflicts} =
      events
      |> Enum.flat_map(&normalize_suspension/1)
      |> Enum.map(&attach_manifest(&1, manifests))
      |> deduplicate(:suspension_id, &suspension_core/1)

    units =
      (exposures ++ suspensions)
      |> reconcile_strata()
      |> Enum.group_by(&unit_scope/1)
      |> Enum.map(fn {scope, rows} ->
        build_unit(scope, rows, exposure_conflicts, suspension_conflicts)
      end)

    experiment_groups =
      units
      |> Enum.filter(&matches_filters?(&1, filters, invalid_filters))
      |> Enum.group_by(&{&1.experiment_key, &1.repository, &1.task_family})
      |> Enum.sort_by(&elem(&1, 0))

    selected_groups = Enum.take(experiment_groups, @max_experiments)
    run_ends = normalize_run_ends(events)
    outcomes = normalize_outcomes(events)
    token_totals = token_totals(events)
    costs = run_costs(events)

    experiments =
      Enum.map(selected_groups, fn {key, experiment_units} ->
        experiment_view(
          key,
          enforce_cohort_config_consistency(experiment_units),
          run_ends,
          outcomes,
          token_totals,
          costs
        )
      end)

    %{
      schema_version: @schema_version,
      mode: "descriptive_only",
      window: window(opts),
      filters: filters,
      experiments: experiments,
      diagnostics: %{
        input_events: min(input_count, @max_number),
        events_considered: length(events),
        events_omitted: max(input_count - @max_events, 0),
        valid_exposures: length(exposures),
        valid_suspensions: length(suspensions),
        invalid_experiment_events: invalid_experiment_events(events),
        invalid_filters: invalid_filters,
        experiments_omitted: max(length(experiment_groups) - @max_experiments, 0)
      },
      limits: %{
        events: @max_events,
        experiments: @max_experiments,
        arms_per_experiment: @max_arms,
        arm_rows: @max_arm_rows
      }
    }
  end

  defp normalize_exposure(
         %{
           "schema_version" => 1,
           "event" => "experiment_exposure",
           "experiment_event_version" => 1,
           "assignment_reason" => "deterministic_opt_in",
           "mode" => "apply"
         } = event
       ) do
    with {:ok, common} <- common_observation(event),
         {:ok, exposure_id} <- short_id(event["exposure_id"], :exposure_id),
         effort when effort in @efforts <- event["reasoning_effort"],
         baseline when baseline in @efforts <- event["baseline_reasoning_effort"],
         :ok <- arm_invariant(common.arm_role, effort, baseline),
         delivery when delivery in @delivery_modes <- event["delivery"],
         {:ok, retry_attempt} <- non_negative_integer(event["retry_attempt"], 1_000_000) do
      [
        common
        |> Map.merge(%{
          type: :exposure,
          exposure_id: exposure_id,
          reasoning_effort: effort,
          baseline_reasoning_effort: baseline,
          delivery: delivery,
          retry_attempt: retry_attempt
        })
      ]
    else
      _invalid -> []
    end
  end

  defp normalize_exposure(_event), do: []

  defp normalize_suspension(
         %{
           "schema_version" => 1,
           "event" => "experiment_suspended",
           "experiment_event_version" => 1,
           "mode" => "baseline",
           "contaminated" => true
         } = event
       ) do
    with {:ok, common} <- common_observation(event),
         {:ok, suspension_id} <- short_id(event["suspension_id"], :suspension_id),
         reason when reason in @suspension_reasons <- event["reason"],
         exposed when is_boolean(exposed) <- event["ever_exposed"],
         delivery when delivery in @delivery_modes <- event["delivery"] do
      [
        common
        |> Map.merge(%{
          type: :suspension,
          suspension_id: suspension_id,
          suspension_reason: reason,
          ever_exposed: exposed,
          delivery: delivery
        })
      ]
    else
      _invalid -> []
    end
  end

  defp normalize_suspension(_event), do: []

  defp common_observation(event) do
    with {:ok, experiment_id} <- safe_id(event["experiment_id"], 64),
         {:ok, revision} <- positive_integer(event["experiment_revision"], 1_000_000),
         {:ok, manifest_digest} <- digest(event["experiment_manifest_digest"]),
         {:ok, unit_id} <- short_id(event["unit_id"], :unit_id),
         {:ok, assignment_id} <- short_id(event["assignment_id"], :assignment_id),
         {:ok, arm_id} <- safe_id(event["arm_id"], 32),
         role when role in @roles <- event["arm_role"],
         {:ok, arm_digest} <- digest(event["arm_config_digest"]),
         {:ok, control_digest} <- digest(event["control_config_digest"]),
         :ok <- arm_identity_invariant(role, arm_id, arm_digest, control_digest),
         {:ok, run_id} <- run_id(event["run_id"]) do
      {:ok,
       %{
         experiment_id: experiment_id,
         revision: revision,
         manifest_digest: manifest_digest,
         experiment_key: {experiment_id, revision, manifest_digest},
         unit_id: unit_id,
         assignment_id: assignment_id,
         arm_id: arm_id,
         arm_role: role,
         arm_config_digest: arm_digest,
         control_config_digest: control_digest,
         run_id: run_id
       }}
    else
      _invalid -> :error
    end
  end

  defp normalize_manifests(events) do
    events
    |> Enum.flat_map(&normalize_manifest/1)
    |> Enum.group_by(& &1.run_id)
  end

  defp normalize_manifest(
         %{
           "schema_version" => 1,
           "event" => "run_manifest",
           "manifest_version" => 1,
           "configuration" => %{"experiment" => experiment},
           "agent" => %{"backend" => "codex"},
           "repository" => %{"id" => repository},
           "task" => %{"type" => task_family}
         } = event
       )
       when is_map(experiment) do
    with {:ok, run_id} <- run_id(event["run_id"]),
         {:ok, config_digest} <- digest(event["config_digest"]),
         {:ok, repository} <- safe_id(repository, 64),
         true <- task_family in @task_families,
         1 <- experiment["assignment_version"],
         {:ok, experiment_id} <- safe_id(experiment["experiment_id"], 64),
         {:ok, revision} <- positive_integer(experiment["revision"], 1_000_000),
         {:ok, manifest_digest} <- digest(experiment["experiment_manifest_digest"]),
         {:ok, arm_id} <- safe_id(experiment["arm_id"], 32),
         role when role in @roles <- experiment["arm_role"],
         effort when effort in @efforts <- experiment["reasoning_effort"],
         baseline when baseline in @efforts <- experiment["baseline_reasoning_effort"],
         {:ok, arm_digest} <- digest(experiment["arm_config_digest"]),
         {:ok, control_digest} <- digest(experiment["control_config_digest"]),
         :ok <-
           arm_identity_invariant(role, arm_id, arm_digest, control_digest),
         :ok <-
           arm_invariant(role, effort, baseline) do
      [
        %{
          run_id: run_id,
          config_digest: config_digest,
          repository: repository,
          task_family: task_family,
          experiment_id: experiment_id,
          revision: revision,
          manifest_digest: manifest_digest,
          arm_id: arm_id,
          arm_role: role,
          reasoning_effort: effort,
          baseline_reasoning_effort: baseline,
          arm_config_digest: arm_digest,
          control_config_digest: control_digest
        }
      ]
    else
      _invalid -> []
    end
  end

  defp normalize_manifest(_event), do: []

  defp attach_manifest(observation, manifests) do
    candidates = Map.get(manifests, observation.run_id, [])
    unique = Enum.uniq_by(candidates, &manifest_core/1)

    case unique do
      [] -> unavailable_manifest(observation, "missing_run_manifest")
      [manifest] -> attach_matching_manifest(observation, manifest)
      _conflicting -> unavailable_manifest(observation, "conflicting_run_manifest")
    end
  end

  defp attach_matching_manifest(observation, manifest) do
    observation =
      observation
      |> Map.put(:repository, manifest.repository)
      |> Map.put(:task_family, manifest.task_family)

    if manifest_matches?(observation, manifest) do
      observation
      |> Map.put(:run_config_digest, manifest.config_digest)
      |> Map.put_new(:reasoning_effort, manifest.reasoning_effort)
      |> Map.put_new(:baseline_reasoning_effort, manifest.baseline_reasoning_effort)
    else
      Map.put(observation, :manifest_error, "manifest_mismatch")
    end
  end

  defp unavailable_manifest(observation, reason) do
    observation
    |> Map.put(:repository, "unknown")
    |> Map.put(:task_family, "unknown")
    |> Map.put(:manifest_error, reason)
  end

  defp reconcile_strata(rows) do
    rows
    |> Enum.group_by(&unit_identity/1)
    |> Enum.flat_map(fn {_identity, unit_rows} -> reconcile_unit_strata(unit_rows) end)
  end

  defp reconcile_unit_strata(rows) do
    known =
      rows
      |> Enum.reject(&(&1.repository == "unknown" or &1.task_family == "unknown"))
      |> Enum.map(&{&1.repository, &1.task_family})
      |> Enum.uniq()

    case known do
      [{repository, task_family}] ->
        Enum.map(rows, fn
          %{repository: "unknown", task_family: "unknown"} = row ->
            %{row | repository: repository, task_family: task_family}

          row ->
            row
        end)

      [] ->
        rows

      _conflicting ->
        Enum.map(rows, &Map.put(&1, :stratum_error, "stratum_conflict"))
    end
  end

  defp manifest_matches?(observation, manifest) do
    Enum.all?(
      ~w(experiment_id revision manifest_digest arm_id arm_role arm_config_digest control_config_digest)a,
      &(Map.get(observation, &1) == Map.get(manifest, &1))
    ) and
      case observation do
        %{type: :exposure} ->
          observation.reasoning_effort == manifest.reasoning_effort and
            observation.baseline_reasoning_effort == manifest.baseline_reasoning_effort

        _suspension ->
          true
      end
  end

  defp build_unit({experiment_key, repository, task_family, unit_id}, rows, exposure_conflicts, suspension_conflicts) do
    exposures = Enum.filter(rows, &(&1.type == :exposure))

    reasons =
      []
      |> add_reasons(Enum.flat_map(rows, &[Map.get(&1, :manifest_error), Map.get(&1, :stratum_error)]))
      |> add_reason(any_conflict?(rows, exposure_conflicts), "conflicting_exposure")
      |> add_reason(any_conflict?(rows, suspension_conflicts), "conflicting_suspension")
      |> add_reason(Enum.any?(rows, &(&1.type == :suspension)), "suspended")
      |> add_distinct_reason(rows, :arm_id, "cross_arm")
      |> add_distinct_reason(rows, :assignment_id, "multiple_assignments")
      |> add_reason(multiple_exposures_per_run?(exposures), "multiple_exposures_per_run")
      |> Enum.uniq()
      |> Enum.sort()

    %{
      experiment_key: experiment_key,
      repository: repository,
      task_family: task_family,
      unit_id: unit_id,
      observations: rows,
      exposures: exposures,
      reasons: reasons
    }
  end

  defp enforce_cohort_config_consistency(grouped_units) do
    rows = Enum.flat_map(grouped_units, & &1.observations)

    reasons =
      []
      |> add_reason(distinct_count(rows, :control_config_digest) > 1, "multiple_control_config_digests")
      |> add_reason(per_arm_inconsistent?(rows, :arm_config_digest), "multiple_arm_config_digests")
      |> add_reason(per_arm_inconsistent?(rows, :run_config_digest), "multiple_run_config_digests")

    Enum.map(grouped_units, fn group ->
      %{group | reasons: Enum.sort(Enum.uniq(group.reasons ++ reasons))}
    end)
  end

  defp per_arm_inconsistent?(rows, field) do
    rows
    |> Enum.group_by(& &1.arm_id)
    |> Enum.any?(fn {_arm_id, arm_rows} -> distinct_count(arm_rows, field) > 1 end)
  end

  defp distinct_count(rows, field),
    do: rows |> Enum.map(&Map.get(&1, field)) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length()

  defp experiment_view(
         {{experiment_id, revision, manifest_digest}, repository, task_family},
         grouped_units,
         run_ends,
         outcomes,
         token_totals,
         costs
       ) do
    observations = Enum.flat_map(grouped_units, & &1.observations)
    arms = observations |> Enum.group_by(& &1.arm_id) |> Enum.sort_by(&elem(&1, 0)) |> Enum.take(@max_arms)

    arm_views =
      Enum.map(arms, fn {arm_id, rows} ->
        arm_view(arm_id, rows, grouped_units, run_ends, outcomes, token_totals, costs)
      end)

    contamination =
      grouped_units
      |> Enum.flat_map(& &1.reasons)
      |> Enum.frequencies()

    %{
      experiment_id: experiment_id,
      revision: revision,
      manifest_digest: manifest_digest,
      repository: repository,
      task_family: task_family,
      units: %{
        observed: length(grouped_units),
        comparable: Enum.count(grouped_units, &(&1.reasons == [] and &1.exposures != [])),
        contaminated: Enum.count(grouped_units, &(&1.reasons != []))
      },
      contamination: contamination,
      arms: arm_views,
      comparisons: comparisons(arm_views),
      repeated_trial_metrics: %{
        pairing: unavailable_protocol(),
        pass_at_k: unavailable_protocol(),
        pass_power_k: unavailable_protocol()
      }
    }
  end

  defp arm_view(arm_id, rows, grouped_units, run_ends, outcomes, token_totals, costs) do
    clean_units =
      grouped_units
      |> Enum.filter(fn group ->
        group.reasons == [] and Enum.any?(group.observations, &(&1.arm_id == arm_id))
      end)

    exposures =
      clean_units
      |> Enum.flat_map(& &1.exposures)
      |> Enum.filter(&(&1.arm_id == arm_id))
      |> Enum.uniq_by(& &1.exposure_id)

    run_ids = exposures |> Enum.map(& &1.run_id) |> Enum.uniq()
    metrics = arm_metrics(run_ids, run_ends, outcomes, token_totals, costs)
    representative = Enum.min_by(rows, &observation_core/1)

    %{
      arm_id: arm_id,
      role: representative.arm_role,
      reasoning_effort: Map.get(representative, :reasoning_effort),
      arm_config_digest: representative.arm_config_digest,
      control_config_digest: representative.control_config_digest,
      units_observed: rows |> Enum.map(& &1.unit_id) |> Enum.uniq() |> length(),
      units_comparable: length(clean_units),
      exposures: %{
        observed: Enum.count(rows, &(&1.type == :exposure)),
        comparable: length(exposures),
        initial_runs: Enum.count(exposures, &(&1.retry_attempt == 0)),
        retry_runs: Enum.count(exposures, &(&1.retry_attempt > 0))
      },
      metrics: metrics
    }
  end

  defp arm_metrics(run_ids, run_ends, outcomes, token_totals, costs) do
    ends = Enum.flat_map(run_ids, &List.wrap(run_ends[&1]))
    normal = Enum.count(ends, &(&1.outcome == "ok"))
    failed = Enum.count(ends, &(&1.outcome == "error"))
    durations = Enum.flat_map(ends, &List.wrap(&1.duration_ms))
    cohort_outcomes = cohort_outcomes(outcomes, run_ids)
    accepted = accepted_handoffs(cohort_outcomes, run_ids)
    post_handoff = post_handoff(accepted, cohort_outcomes)
    per_run_tokens = Enum.flat_map(run_ids, &List.wrap(token_totals[&1]))
    per_run_costs = Enum.flat_map(run_ids, &List.wrap(costs[&1]))
    denominator = length(run_ids)

    %{
      worker_runs: %{
        denominator: denominator,
        ended: length(ends),
        completed_normally: normal,
        failed: failed,
        completion_rate: rate(length(ends), denominator),
        normal_completion_rate: rate(normal, denominator)
      },
      task_outcomes: %{
        run_denominator: denominator,
        runs_with_authoritative_outcome: cohort_outcomes |> Enum.map(& &1.run_id) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length(),
        material_progress_runs: outcome_run_count(cohort_outcomes, "material_progress", "recorded"),
        exact_head_accepted_runs: accepted |> Enum.map(& &1.run_id) |> Enum.uniq() |> length(),
        exact_head_acceptance_rate: rate(accepted |> Enum.map(& &1.run_id) |> Enum.uniq() |> length(), denominator),
        by_stage: outcome_breakdown(cohort_outcomes)
      },
      post_handoff: post_handoff,
      duration_ms: distribution(durations),
      tokens: distribution(per_run_tokens) |> Map.put(:total, Enum.sum(per_run_tokens)),
      explicit_cost_usd:
        distribution(per_run_costs)
        |> Map.put(:total, if(per_run_costs == [], do: nil, else: Enum.sum(per_run_costs)))
    }
  end

  defp comparisons(arm_views) do
    case Enum.find(arm_views, &(&1.role == "control")) do
      nil -> []
      control -> Enum.filter(arm_views, &(&1.role == "variant")) |> Enum.map(&comparison(control, &1))
    end
  end

  defp comparison(control, treatment) do
    %{
      control_arm_id: control.arm_id,
      treatment_arm_id: treatment.arm_id,
      descriptive_only: true,
      deltas:
        Map.new(@comparison_metrics, fn {metric, {value_path, count_path}} ->
          {metric, comparison_delta(control, treatment, value_path, count_path)}
        end)
    }
  end

  defp comparison_delta(control, treatment, value_path, count_path) do
    metric_delta(
      get_in(control, value_path),
      get_in(treatment, value_path),
      get_in(control, count_path),
      get_in(treatment, count_path)
    )
  end

  defp metric_delta(_control, _treatment, 0, _treatment_n),
    do: %{available: false, reason: "insufficient_control_sample"}

  defp metric_delta(_control, _treatment, _control_n, 0),
    do: %{available: false, reason: "insufficient_treatment_sample"}

  defp metric_delta(control, treatment, _control_n, _treatment_n) do
    %{available: true, control: control, treatment: treatment, delta: treatment - control}
  end

  defp normalize_run_ends(events) do
    events
    |> Enum.flat_map(&normalize_run_end/1)
    |> Enum.group_by(& &1.run_id)
    |> Map.new(fn {run_id, rows} -> {run_id, Enum.max_by(rows, &{&1.ts, &1.outcome, &1.duration_ms})} end)
  end

  defp normalize_run_end(%{"schema_version" => 1, "event" => "run_end", "outcome" => outcome} = event)
       when outcome in ~w(ok error) do
    with {:ok, run_id} <- run_id(event["run_id"]),
         {:ok, duration} <- optional_number(event["duration_ms"]) do
      [%{run_id: run_id, outcome: outcome, duration_ms: duration, ts: timestamp(event["ts"])}]
    else
      _invalid -> []
    end
  end

  defp normalize_run_end(_event), do: []

  defp normalize_outcomes(events) do
    events
    |> Enum.flat_map(&normalize_outcome/1)
    |> Enum.uniq_by(&{&1.run_id, &1.sha, &1.stage, &1.status})
  end

  defp normalize_outcome(
         %{
           "schema_version" => 1,
           "event" => "task_outcome",
           "outcome_version" => 1,
           "authoritative" => true,
           "stage" => stage,
           "status" => status
         } = event
       ) do
    pair = {stage, status}
    run_id = optional_run_id(event["run_id"])
    sha = outcome_sha(event)

    if MapSet.member?(@outcomes, pair) and (is_binary(run_id) or is_binary(sha)) and
         (stage != "exact_head_handoff" or is_binary(sha)) do
      [%{run_id: run_id, sha: sha, stage: stage, status: status}]
    else
      []
    end
  end

  defp normalize_outcome(_event), do: []

  defp cohort_outcomes(outcomes, run_ids) do
    direct = Enum.filter(outcomes, &(&1.run_id in run_ids))

    accepted_shas =
      direct
      |> Enum.filter(&(&1.stage == "exact_head_handoff" and &1.status == "accepted"))
      |> Enum.map(& &1.sha)
      |> MapSet.new()

    outcomes
    |> Enum.filter(&(&1.run_id in run_ids or (is_binary(&1.sha) and MapSet.member?(accepted_shas, &1.sha))))
    |> Enum.uniq_by(&{&1.run_id, &1.sha, &1.stage, &1.status})
  end

  defp accepted_handoffs(outcomes, run_ids) do
    outcomes
    |> Enum.filter(&(&1.run_id in run_ids and &1.stage == "exact_head_handoff" and &1.status == "accepted"))
    |> Enum.uniq_by(&{&1.run_id, &1.sha})
  end

  defp post_handoff(accepted, outcomes) do
    evaluations =
      Enum.map(accepted, fn handoff ->
        downstream =
          Enum.filter(outcomes, fn outcome ->
            outcome.stage in ~w(ci human_review pull_request) and
              (outcome.run_id == handoff.run_id or outcome.sha == handoff.sha)
          end)

        pairs = MapSet.new(downstream, &{&1.stage, &1.status})

        cond do
          not MapSet.disjoint?(pairs, @negative_downstream) -> :negative
          not MapSet.disjoint?(pairs, @positive_downstream) -> :reliable
          true -> :unknown
        end
      end)

    evaluated = Enum.count(evaluations, &(&1 in [:reliable, :negative]))
    reliable = Enum.count(evaluations, &(&1 == :reliable))

    %{
      accepted_handoff_denominator: length(accepted),
      evaluated: evaluated,
      reliable: reliable,
      negative: Enum.count(evaluations, &(&1 == :negative)),
      unknown: Enum.count(evaluations, &(&1 == :unknown)),
      reliability_rate: rate(reliable, evaluated)
    }
  end

  defp outcome_run_count(outcomes, stage, status) do
    outcomes
    |> Enum.filter(&(&1.stage == stage and &1.status == status and is_binary(&1.run_id)))
    |> Enum.map(& &1.run_id)
    |> Enum.uniq()
    |> length()
  end

  defp outcome_breakdown(outcomes) do
    outcomes
    |> Enum.group_by(& &1.stage)
    |> Map.new(fn {stage, rows} -> {stage, Enum.frequencies_by(rows, & &1.status)} end)
  end

  defp token_totals(events) do
    events
    |> Enum.flat_map(&normalize_token/1)
    |> Enum.group_by(&{&1.run_id, &1.thread_id})
    |> Enum.map(fn {{run_id, _thread_id}, rows} -> {run_id, rows |> Enum.map(& &1.total) |> Enum.max()} end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {run_id, totals} -> {run_id, Enum.sum(totals)} end)
  end

  defp normalize_token(%{"schema_version" => 1, "event" => "token_high_water", "cumulative" => cumulative} = event)
       when is_map(cumulative) do
    with {:ok, run_id} <- run_id(event["run_id"]),
         {:ok, thread_id} <- bounded_identity(event["thread_id"] || event["session_id"]),
         {:ok, total} <- non_negative_number(cumulative["total_tokens"], @max_number) do
      [%{run_id: run_id, thread_id: thread_id, total: total}]
    else
      _invalid -> []
    end
  end

  defp normalize_token(_event), do: []

  defp run_costs(events) do
    events
    |> Enum.flat_map(&normalize_cost/1)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {run_id, values} -> {run_id, Enum.max(values)} end)
  end

  defp normalize_cost(%{"schema_version" => 1, "event" => kind} = event)
       when kind in @cost_event_kinds do
    value =
      cond do
        is_number(event["cumulative_cost_usd"]) -> event["cumulative_cost_usd"]
        event["event"] == "run_end" and is_number(event["cost_usd"]) -> event["cost_usd"]
        true -> nil
      end

    with {:ok, run_id} <- run_id(event["run_id"]),
         {:ok, cost} <- non_negative_number(value, @max_number) do
      [{run_id, cost}]
    else
      _invalid -> []
    end
  end

  defp normalize_cost(_event), do: []

  defp deduplicate(rows, key, core_fun) do
    rows
    |> Enum.group_by(&Map.fetch!(&1, key))
    |> Enum.reduce({[], MapSet.new()}, fn {_id, duplicates}, {kept, conflicts} ->
      unique =
        duplicates
        |> Enum.sort_by(fn row ->
          {Map.has_key?(row, :manifest_error), core_fun.(row), observation_core(row)}
        end)
        |> Enum.uniq_by(core_fun)

      conflicts =
        if length(unique) > 1,
          do: Enum.reduce(unique, conflicts, &MapSet.put(&2, unit_identity(&1))),
          else: conflicts

      {unique ++ kept, conflicts}
    end)
    |> then(fn {kept, conflicts} -> {Enum.sort_by(kept, core_fun), conflicts} end)
  end

  defp exposure_core(row) do
    observation_core(row) ++
      [row.exposure_id, row.reasoning_effort, row.baseline_reasoning_effort, row.retry_attempt]
  end

  defp suspension_core(row) do
    Enum.map(
      ~w(experiment_id revision manifest_digest unit_id assignment_id arm_id arm_role arm_config_digest control_config_digest)a,
      &Map.get(row, &1)
    ) ++ [row.suspension_id, row.suspension_reason, row.ever_exposed]
  end

  defp observation_core(row) do
    Enum.map(
      ~w(experiment_id revision manifest_digest repository task_family unit_id assignment_id arm_id arm_role arm_config_digest control_config_digest run_id)a,
      &Map.get(row, &1)
    )
  end

  defp manifest_core(manifest) do
    Enum.map(
      ~w(config_digest repository task_family experiment_id revision manifest_digest arm_id arm_role reasoning_effort baseline_reasoning_effort arm_config_digest control_config_digest)a,
      &Map.get(manifest, &1)
    )
  end

  defp any_conflict?(rows, conflicts), do: Enum.any?(rows, &MapSet.member?(conflicts, unit_identity(&1)))

  defp unit_identity(row), do: {row.experiment_key, row.unit_id}

  defp unit_scope(row),
    do: {row.experiment_key, row.repository, row.task_family, row.unit_id}

  defp add_reason(reasons, true, reason), do: [reason | reasons]
  defp add_reason(reasons, false, _reason), do: reasons

  defp add_reasons(reasons, additions),
    do: Enum.reduce(additions, reasons, fn reason, acc -> if is_binary(reason), do: [reason | acc], else: acc end)

  defp add_distinct_reason(reasons, rows, key, reason) do
    values = rows |> Enum.map(&Map.get(&1, key)) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    add_reason(reasons, length(values) > 1, reason)
  end

  defp multiple_exposures_per_run?(exposures) do
    exposures
    |> Enum.group_by(& &1.run_id)
    |> Enum.any?(fn {_run_id, rows} -> length(Enum.uniq_by(rows, & &1.exposure_id)) > 1 end)
  end

  defp matches_filters?(_unit, _filters, [_invalid | _rest]), do: false

  defp matches_filters?(%{experiment_key: {id, revision, _digest}} = unit, filters, []) do
    (is_nil(filters.experiment_id) or filters.experiment_id == id) and
      (is_nil(filters.revision) or filters.revision == revision) and
      (is_nil(filters.repository) or filters.repository == unit.repository) and
      (is_nil(filters.task_family) or filters.task_family == unit.task_family)
  end

  defp filters(opts) do
    experiment = filter_id(Keyword.get(opts, :experiment_id), :experiment_id)
    repository = filter_id(Keyword.get(opts, :repository), :repository)
    task_family = filter_task(Keyword.get(opts, :task_family))
    revision = filter_revision(Keyword.get(opts, :revision))
    values = %{experiment_id: elem(experiment, 0), repository: elem(repository, 0), task_family: elem(task_family, 0), revision: elem(revision, 0)}

    invalid =
      [experiment, repository, task_family, revision]
      |> Enum.flat_map(fn {_value, error} -> List.wrap(error) end)

    {values, invalid}
  end

  defp filter_id(nil, _field), do: {nil, nil}

  defp filter_id(value, field) do
    case safe_id(value, 64) do
      {:ok, id} -> {id, nil}
      :error -> {nil, Atom.to_string(field)}
    end
  end

  defp filter_task(nil), do: {nil, nil}
  defp filter_task(value) when value in @task_families, do: {value, nil}
  defp filter_task(_value), do: {nil, "task_family"}
  defp filter_revision(nil), do: {nil, nil}

  defp filter_revision(value) when is_integer(value) and value >= 1 and value <= 1_000_000,
    do: {value, nil}

  defp filter_revision(_value), do: {nil, "revision"}

  defp window(opts) do
    days = if Keyword.get(opts, :window_days) == 30, do: 30, else: 7
    through = Keyword.get(opts, :through)

    if match?(%Date{}, through) do
      %{days: days, from: through |> Date.add(1 - days) |> Date.to_iso8601(), to: Date.to_iso8601(through)}
    else
      %{days: days, from: nil, to: nil}
    end
  end

  defp invalid_experiment_events(events) do
    Enum.count(events, fn
      %{"event" => "experiment_exposure"} = event -> normalize_exposure(event) == []
      %{"event" => "experiment_suspended"} = event -> normalize_suspension(event) == []
      _event -> false
    end)
  end

  defp distribution(values) do
    %{samples: length(values), p50: Report.percentile(values, 0.5), p90: Report.percentile(values, 0.9)}
  end

  defp rate(_numerator, 0), do: nil
  defp rate(numerator, denominator), do: numerator / denominator
  defp unavailable_protocol, do: %{available: false, reason: "no_repeated_trial_protocol"}

  defp outcome_sha(event) do
    Enum.find_value(~w(exact_sha candidate_sha reviewed_sha head_sha), fn key -> valid_sha(event[key]) end)
  end

  defp valid_sha(value) when is_binary(value) and byte_size(value) in [40, 64] do
    if Regex.match?(~r/\A[0-9a-f]+\z/, value), do: value
  end

  defp valid_sha(_value), do: nil

  defp arm_identity_invariant("control", "control", digest, digest), do: :ok

  defp arm_identity_invariant("variant", arm_id, arm_digest, control_digest)
       when arm_id != "control" and arm_digest != control_digest,
       do: :ok

  defp arm_identity_invariant(_role, _arm_id, _arm_digest, _control_digest), do: :error

  defp arm_invariant("control", effort, effort), do: :ok

  defp arm_invariant("variant", effort, baseline) when effort != baseline,
    do: :ok

  defp arm_invariant(_arm, _effort, _baseline), do: :error

  defp timestamp(value) when is_binary(value) and byte_size(value) <= 40 do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> DateTime.to_iso8601(timestamp)
      _invalid -> ""
    end
  end

  defp timestamp(_value), do: ""

  defp safe_id(value, cap) when is_binary(value) and byte_size(value) <= cap do
    if Regex.match?(@safe_id, value), do: {:ok, value}, else: :error
  end

  defp safe_id(_value, _cap), do: :error

  defp run_id(value) when is_binary(value) do
    if Regex.match?(@run_id, value), do: {:ok, value}, else: :error
  end

  defp run_id(_value), do: :error

  defp optional_run_id(nil), do: nil

  defp optional_run_id(value) do
    case run_id(value) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp bounded_identity(value) when is_binary(value) and byte_size(value) in 1..128,
    do: {:ok, value}

  defp bounded_identity(_value), do: :error

  defp short_id(value, kind) when is_binary(value) do
    if Regex.match?(Map.fetch!(@short_ids, kind), value), do: {:ok, value}, else: :error
  end

  defp short_id(_value, _kind), do: :error

  defp digest(value) when is_binary(value) do
    if Regex.match?(@digest, value), do: {:ok, value}, else: :error
  end

  defp digest(_value), do: :error

  defp positive_integer(value, maximum)
       when is_integer(value) and value >= 1 and value <= maximum,
       do: {:ok, value}

  defp positive_integer(_value, _maximum), do: :error

  defp non_negative_integer(value, maximum)
       when is_integer(value) and value >= 0 and value <= maximum,
       do: {:ok, value}

  defp non_negative_integer(_value, _maximum), do: :error

  defp optional_number(nil), do: {:ok, nil}
  defp optional_number(value), do: non_negative_number(value, @max_number)

  defp non_negative_number(value, maximum)
       when is_number(value) and value >= 0 and value <= maximum,
       do: {:ok, value}

  defp non_negative_number(_value, _maximum), do: :error
end
