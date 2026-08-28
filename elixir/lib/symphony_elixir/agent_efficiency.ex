defmodule SymphonyElixir.AgentEfficiency do
  @moduledoc """
  Resolves an inspectable soft-budget and review-routing decision for one run.

  Decisions are repository-owned, may be overridden with one exact
  `budget:<profile>` issue label, and default to shadow mode. Security, tenant,
  schema, concurrency, and broad-architecture work fail toward the high-risk
  budget. A budget is never an approval signal or completion criterion.
  """

  alias SymphonyElixir.{Config, Telemetry}
  alias SymphonyElixir.Linear.Issue

  @high_risk_types ~w(security_tenant data_schema concurrency_liveness broad_architecture)
  @security_terms ~w(auth authorization authz tenant permission security access-control isolation secret credential)
  @schema_terms ~w(schema migration database sql ecto backfill index data)
  @concurrency_terms ~w(concurrency concurrent race deadlock lease retry liveness lock worker orchestration)
  @ui_terms ~w(ui dashboard frontend css html liveview react component layout)
  @architecture_terms ~w(architecture cross-cutting platform fleet distributed redesign refactor)

  @type classification :: %{
          task_type: String.t(),
          confidence: float(),
          risk: String.t(),
          complexity: String.t(),
          ambiguity: String.t(),
          reasons: [String.t()],
          inputs: map()
        }

  @type decision :: %{
          mode: String.t(),
          task_type: String.t(),
          confidence: float(),
          classification: classification(),
          budget_profile: String.t(),
          selection_reason: String.t(),
          budget: map(),
          override: map() | nil,
          capsule_max_bytes: pos_integer(),
          extreme_multiplier: float(),
          enforced_actions: [String.t()],
          enforced: boolean()
        }

  @doc "Build and emit the run's routing/budget decision."
  @spec decide(Issue.t(), map(), map() | nil) :: {:ok, decision()} | {:error, term()}
  def decide(%Issue{} = issue, route, repo_workflow) when is_map(route) do
    with {:ok, settings} <- Config.agent_efficiency_settings(repo_workflow) do
      classification = classification(issue, route)

      {budget_profile, override, selection_reason} =
        budget_profile(issue, classification, settings)

      budget = Map.fetch!(settings.profiles, budget_profile)

      decision = %{
        mode: settings.mode,
        task_type: classification.task_type,
        confidence: classification.confidence,
        classification: classification,
        budget_profile: budget_profile,
        selection_reason: selection_reason,
        budget: budget,
        override: override,
        capsule_max_bytes: settings.capsule_max_bytes,
        extreme_multiplier: settings.extreme_multiplier,
        enforced_actions: settings.enforced_actions,
        enforced: settings.mode == "enforce"
      }

      emit_decision(issue, route, decision)
      {:ok, decision}
    end
  end

  @doc "Apply an enforced efficiency decision to safe reviewer settings."
  @spec review_settings(map(), decision() | nil) :: map()
  def review_settings(
        settings,
        %{enforced: true, budget: budget, task_type: task_type, budget_profile: budget_profile}
      )
      when is_map(settings) and is_map(budget) do
    high_risk? = task_type in @high_risk_types or budget_profile == "high_risk"

    reviewer_model =
      if task_type in @high_risk_types and budget_profile != "high_risk",
        do: nil,
        else: budget.reviewer_model

    settings
    |> maybe_put(:model, reviewer_model)
    |> maybe_put(
      :reasoning_effort,
      safe_review_effort(settings[:reasoning_effort], budget.reviewer_reasoning_effort, high_risk?)
    )
    |> Map.update!(:max_iterations, fn current ->
      if high_risk?, do: max(current, budget.review_iterations), else: min(current, budget.review_iterations)
    end)
    |> Map.update!(:packet_max_bytes, fn current ->
      if high_risk?, do: current, else: min(current, budget.review_packet_bytes)
    end)
  end

  def review_settings(settings, _decision), do: settings

  @doc "Requested lens names for the decision; packet construction adds mandatory risk lenses."
  @spec review_lenses(decision() | nil) :: [String.t()] | nil
  def review_lenses(%{enforced: true, budget: budget} = decision) do
    selected = Enum.take(budget.review_lenses, budget.reviewer_lenses)

    if high_risk?(decision) do
      Enum.uniq(selected ++ ["correctness", "regression", "test_evidence", "security_tenant_auth", "structure"])
    else
      selected
    end
  end

  def review_lenses(_decision), do: nil

  @doc "Return true when task risk forbids reducing the packet's normal lens set."
  @spec high_risk?(decision() | nil) :: boolean()
  def high_risk?(%{task_type: task_type, budget_profile: budget_profile}),
    do: task_type in @high_risk_types or budget_profile == "high_risk"

  def high_risk?(_decision), do: false

  defp classification(issue, %{classification: %{} = result}) do
    %{
      task_type: valid_task_type(result[:task_type]) || heuristic_task_type(issue),
      confidence: confidence(result[:confidence]),
      risk: level(result[:risk], "high"),
      complexity: level(result[:complexity], "high"),
      ambiguity: level(result[:ambiguity], "high"),
      reasons: List.wrap(result[:reasons]) |> Enum.filter(&is_binary/1) |> Enum.take(4),
      inputs: classifier_inputs(issue)
    }
  end

  defp classification(issue, _route) do
    task_type = heuristic_task_type(issue)

    %{
      task_type: task_type,
      confidence: 0.35,
      risk: if(task_type in @high_risk_types, do: "high", else: "medium"),
      complexity: if(task_type == "simple_direct", do: "low", else: "medium"),
      ambiguity: "medium",
      reasons: ["deterministic metadata fallback; classifier result unavailable"],
      inputs: classifier_inputs(issue)
    }
  end

  defp budget_profile(%Issue{labels: labels}, classification, settings) do
    budget_labels =
      labels
      |> List.wrap()
      |> Enum.flat_map(fn
        "budget:" <> profile -> [{"budget:#{profile}", profile}]
        _label -> []
      end)

    {valid, invalid} =
      Enum.split_with(budget_labels, fn {_label, profile} ->
        Map.has_key?(settings.profiles, profile)
      end)

    valid_profiles = valid |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    cond do
      invalid != [] ->
        labels = Enum.map(budget_labels, &elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
        {"high_risk", %{source: "invalid_budget_labels", labels: labels}, "invalid_budget_override_quality_fallback"}

      length(valid_profiles) > 1 ->
        labels = Enum.map(valid, &elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
        {"high_risk", %{source: "ambiguous_budget_labels", labels: labels}, "ambiguous_budget_override_quality_fallback"}

      match?([_profile], valid_profiles) ->
        [profile] = valid_profiles
        {profile, %{source: "issue_label", label: "budget:#{profile}"}, "explicit_budget_override"}

      conservative_classification?(classification) ->
        {"high_risk", nil, "classifier_quality_fallback"}

      true ->
        {Map.fetch!(settings.task_profiles, classification.task_type), nil, "task_profile"}
    end
  end

  defp emit_decision(issue, route, decision) do
    Telemetry.emit(:routing_decision, %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      repository: repository(issue.labels),
      source: route.source,
      execution_profile: route.profile,
      model: route.overrides[:model],
      reasoning_effort: route.overrides[:reasoning_effort],
      classifier_inputs: decision.classification.inputs,
      classifier_result: Map.drop(decision.classification, [:inputs]),
      classifier_confidence: decision.confidence,
      task_type: decision.task_type,
      budget_profile: decision.budget_profile,
      budget_selection_reason: decision.selection_reason,
      budget_mode: decision.mode,
      enforced: decision.enforced,
      enforced_actions: decision.enforced_actions,
      allow_overage: decision.budget.allow_overage,
      override: decision.override
    })
  end

  defp heuristic_task_type(issue) do
    text = String.downcase(Enum.join([issue.title, issue.description, Enum.join(issue.labels || [], " ")], " "))

    cond do
      contains_any?(text, @security_terms) -> "security_tenant"
      contains_any?(text, @concurrency_terms) -> "concurrency_liveness"
      contains_any?(text, @schema_terms) -> "data_schema"
      contains_any?(text, @architecture_terms) -> "broad_architecture"
      contains_any?(text, @ui_terms) -> "ui"
      true -> "simple_direct"
    end
  end

  defp classifier_inputs(issue) do
    %{
      priority: issue.priority,
      labels: Enum.sort(issue.labels || []),
      blocked_by_count: length(issue.blocked_by || []),
      child_count: length(issue.children || []),
      title_bytes: byte_size(issue.title || ""),
      description_bytes: byte_size(issue.description || "")
    }
  end

  defp conservative_classification?(classification) do
    classification.confidence < 0.55 or
      "high" in [classification.risk, classification.complexity, classification.ambiguity]
  end

  defp confidence(value) when is_number(value), do: value |> max(0.0) |> min(1.0) |> Float.round(3)
  defp confidence(_value), do: 0.5

  defp valid_task_type(task_type) when is_binary(task_type) do
    if task_type in Config.AgentEfficiency.task_types(), do: task_type
  end

  defp valid_task_type(_task_type), do: nil
  defp level(value, _default) when value in ~w(low medium high), do: value
  defp level(_value, default), do: default
  defp contains_any?(text, terms), do: Enum.any?(terms, &String.contains?(text, &1))

  defp repository(labels) do
    Enum.find_value(labels || [], fn
      "repo:" <> name -> name
      _label -> nil
    end) || "default"
  end

  defp maybe_put(settings, _key, nil), do: settings
  defp maybe_put(settings, key, value), do: Map.put(settings, key, value)

  defp safe_review_effort(current, proposed, true) do
    if effort_rank(current) >= effort_rank(proposed), do: current, else: proposed
  end

  defp safe_review_effort(_current, proposed, false), do: proposed

  defp effort_rank(effort), do: Enum.find_index(~w(none low medium high xhigh max), &(&1 == effort)) || -1
end
