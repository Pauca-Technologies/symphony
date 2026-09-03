defmodule SymphonyElixir.RunManifest do
  @moduledoc """
  Builds the immutable, non-secret provenance record for one worker attempt.

  The manifest deliberately stores hashes and effective policy rather than raw
  prompts, hook commands, environment variables, or credentials.
  """

  alias SymphonyElixir.{AgentBackend, AgentEfficiency, Config, OrchestratorVersion}
  alias SymphonyElixir.Config.Schema

  @manifest_version 1
  @symphony_sha (fn ->
                   try do
                     case System.cmd("git", ["rev-parse", "HEAD"],
                            cd: Path.expand("../..", __DIR__),
                            stderr_to_stdout: true
                          ) do
                       {sha, 0} -> String.trim(sha)
                       _failure -> nil
                     end
                   rescue
                     _error -> nil
                   end
                 end).()

  @doc "Generate an opaque UUID for a run or retry scheduling decision."
  @spec new_id() :: String.t()
  def new_id, do: Ecto.UUID.generate()

  @doc "Create the explicit identity dimensions for a newly launched worker attempt."
  @spec execution_identity(integer() | nil, keyword()) :: map()
  def execution_identity(attempt, opts \\ []) when is_list(opts) do
    %{
      run_id: Keyword.get(opts, :run_id) || new_id(),
      parent_run_id: Keyword.get(opts, :parent_run_id),
      retry_id: Keyword.get(opts, :retry_id),
      retry_attempt: retry_attempt(attempt, opts),
      attempt: attempt
    }
  end

  @doc "Build a versioned run manifest from already-resolved execution state."
  @spec build(map()) :: map()
  def build(
        %{
          identity: identity,
          issue: issue,
          route: route,
          efficiency: efficiency,
          settings: settings,
          workspace: workspace
        } = context
      )
      when is_map(identity) and is_map(issue) and is_map(route) and is_map(efficiency) and
             is_binary(workspace) do
    backend = AgentBackend.backend_name(route.backend) || inspect(route.backend)
    policies = backend_policies(backend, settings, workspace)
    review = review_policy(context, efficiency)
    budget = budget_policy(efficiency)
    repository = Map.get(context, :repository_manifest, %{}) || %{}
    prompt_template = workflow_prompt(Map.get(context, :repo_workflow))
    workflow = workflow_provenance(context, prompt_template)
    no_progress = Config.no_progress_settings(Map.get(context, :repo_workflow))

    prompt = %{
      source: Map.get(context, :workflow_source) || "repository:WORKFLOW.md",
      template_sha256: sha256(prompt_template),
      template_bytes: byte_size(prompt_template),
      composition_version: "prompt-sections/v1",
      section_hashes: %{
        availability: "per_turn",
        event: "prompt_built",
        field: "injected_section_hashes"
      }
    }

    configuration =
      %{
        backend: backend,
        model: route.overrides[:model],
        reasoning_effort: route.overrides[:reasoning_effort],
        execution_profile: route.profile,
        route_source: route.source,
        approval: policies.approval,
        sandbox: policies.sandbox,
        budget: budget,
        no_progress: no_progress,
        review: review,
        workflow: workflow,
        prompt: Map.delete(prompt, :template_bytes)
      }
      |> maybe_put_experiment(Map.get(context, :experiment_assignment))

    identity
    |> Map.merge(%{
      manifest_version: @manifest_version,
      issue_id: Map.get(issue, :id),
      issue_identifier: Map.get(issue, :identifier),
      parent_issue_id: Map.get(issue, :parent_id),
      repository: %{
        id: Map.get(context, :repository_id) || repository_name(issue),
        head_sha: Map.get(repository, :head_sha),
        base_sha: Map.get(repository, :base_sha),
        candidate_base_sha: Map.get(repository, :candidate_base_sha),
        dirty: Map.get(repository, :dirty),
        worktree_status_fingerprint: Map.get(repository, :worktree_status_fingerprint),
        worktree_content_fingerprint: Map.get(repository, :worktree_content_fingerprint),
        worktree_fingerprint_complete: Map.get(repository, :worktree_fingerprint_complete)
      },
      symphony: %{version: OrchestratorVersion.current(), sha: @symphony_sha},
      workflow: workflow,
      prompt: prompt,
      agent: %{
        backend: backend,
        model: route.overrides[:model],
        reasoning_effort: route.overrides[:reasoning_effort],
        execution_profile: route.profile,
        route_source: route.source
      },
      task: %{
        type: efficiency.task_type,
        confidence: efficiency.confidence,
        risk: efficiency.classification.risk,
        complexity: efficiency.classification.complexity,
        ambiguity: efficiency.classification.ambiguity
      },
      budget: budget,
      no_progress: no_progress,
      approval: policies.approval,
      sandbox: policies.sandbox,
      review: review,
      configuration: configuration,
      config_digest: config_digest(configuration)
    })
  end

  @doc "Hash a map using deterministic key ordering and JSON scalar encoding."
  @spec config_digest(map()) :: String.t()
  def config_digest(configuration) when is_map(configuration) do
    configuration
    |> canonical_json()
    |> sha256()
  end

  defp workflow_provenance(context, prompt_template) do
    review_workflow = Map.get(context, :review_workflow)

    %{
      source: Map.get(context, :workflow_source) || "repository:WORKFLOW.md",
      prompt_template_sha256: sha256(prompt_template),
      review_source: Map.get(context, :review_workflow_source),
      review_prompt_template_sha256: workflow_hash(review_workflow)
    }
  end

  defp workflow_prompt(%{prompt_template: prompt}) when is_binary(prompt), do: prompt
  defp workflow_prompt(_workflow), do: Config.workflow_prompt()

  defp workflow_hash(%{prompt_template: prompt}) when is_binary(prompt), do: sha256(prompt)
  defp workflow_hash(_workflow), do: nil

  defp maybe_put_experiment(configuration, assignment) when is_map(assignment) do
    planned =
      Map.take(assignment, ~w(
        assignment_version experiment_id revision experiment_manifest_digest arm_id arm_role
        reasoning_effort baseline_reasoning_effort arm_config_digest control_config_digest state
        suspension_reason contaminated
      ))

    Map.put(configuration, :experiment, planned)
  end

  defp maybe_put_experiment(configuration, _assignment), do: configuration

  defp budget_policy(efficiency) do
    %{
      profile: efficiency.budget_profile,
      mode: efficiency.mode,
      selection_reason: efficiency.selection_reason,
      allow_overage: efficiency.budget.allow_overage,
      thresholds: Map.drop(efficiency.budget, [:reviewer_model, :reviewer_reasoning_effort])
    }
  end

  defp review_policy(context, efficiency) do
    workflow = Map.get(context, :review_workflow)

    settings =
      workflow
      |> Config.review_settings()
      |> AgentEfficiency.review_settings(efficiency)

    settings
    |> Map.take([
      :max_iterations,
      :packet_max_bytes,
      :context_budget_tokens,
      :turn_budget,
      :turn_timeout_ms,
      :tool_output_max_bytes,
      :model,
      :reasoning_effort,
      :require_pr,
      :scope_contract_required,
      :draft_pr_lifecycle
    ])
    |> Map.put(:enabled, is_map(workflow))
  end

  defp backend_policies("codex", settings, workspace) do
    %{
      approval: settings.codex.approval_policy,
      sandbox: %{
        thread: settings.codex.thread_sandbox,
        turn: Schema.resolve_turn_sandbox_policy(settings, workspace)
      }
    }
  end

  defp backend_policies("acp", settings, _workspace) do
    %{
      approval: %{auto_approve: settings.acp.auto_approve},
      sandbox: %{
        advertise_fs: settings.acp.advertise_fs,
        advertise_terminal: settings.acp.advertise_terminal
      }
    }
  end

  defp backend_policies("claude_code", settings, _workspace) do
    %{approval: %{permission_mode: settings.claude_code.permission_mode}, sandbox: nil}
  end

  defp backend_policies(_backend, _settings, _workspace), do: %{approval: nil, sandbox: nil}

  defp repository_name(%{labels: labels}) when is_list(labels) do
    Enum.find_value(labels, "default", fn
      "repo:" <> repository -> repository
      _label -> nil
    end)
  end

  defp repository_name(_issue), do: "default"

  defp normalize_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_attempt(_attempt), do: 0

  defp retry_attempt(attempt, opts) do
    case Keyword.fetch(opts, :retry_attempt) do
      {:ok, retry_attempt} when is_integer(retry_attempt) and retry_attempt >= 0 -> retry_attempt
      _missing_or_invalid -> normalize_attempt(attempt)
    end
  end

  defp canonical_json(%_{} = struct), do: struct |> Map.from_struct() |> canonical_json()

  defp canonical_json(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(",", fn {key, value} -> Jason.encode!(key) <> ":" <> canonical_json(value) end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp canonical_json(list) when is_list(list) do
    list
    |> Enum.map_join(",", &canonical_json/1)
    |> then(&("[" <> &1 <> "]"))
  end

  defp canonical_json(value) when is_atom(value) and not is_nil(value),
    do: value |> Atom.to_string() |> Jason.encode!()

  defp canonical_json(value), do: Jason.encode!(value)

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
