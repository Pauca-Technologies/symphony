defmodule SymphonyElixir.Experiment do
  @moduledoc "Pure deterministic assignment and permanent suspension policy for v1 experiments."

  alias SymphonyElixir.Config.Experiment, as: ExperimentConfig

  @assignment_version 1
  @digest ~r/\A[0-9a-f]{64}\z/
  @short_id ~r/\A(?:exa|exu)-[0-9a-f]{32}\z/
  @exposure_id ~r/\Aexe-[0-9a-f]{32}\z/
  @suspension_id ~r/\Aexs-[0-9a-f]{32}\z/
  @safe_id ~r/\A[a-z0-9][a-z0-9._-]*\z/
  @stable_context_id ~r/\A[A-Za-z0-9][A-Za-z0-9:._-]*\z/
  @reasoning_efforts ~w(none low medium high xhigh max)
  @states ~w(active suspended)
  @suspension_reasons ~w(identity_mismatch kill_switch manifest_mismatch manifest_unavailable route_mismatch)
  @assignment_keys ~w(
    assignment_version experiment_id revision experiment_manifest_digest unit_id assignment_id
    arm_id arm_role reasoning_effort baseline_reasoning_effort arm_config_digest
    control_config_digest state suspension_reason suspension_id ever_exposed last_exposure_id
    contaminated assignment_digest
  )

  @type assignment :: %{required(String.t()) => term()}
  @type assign_result ::
          {:assigned, assignment()}
          | {:restored, assignment()}
          | {:suspended, assignment(), String.t()}
          | {:skip, atom()}

  @doc "Create a fresh deterministic assignment or restore the persisted task assignment."
  @spec assign(ExperimentConfig.t() | nil, map()) :: assign_result()
  def assign(manifest, context) when is_map(context) do
    case context_value(context, :previous_assignment) do
      nil -> assign_fresh(manifest, context)
      previous -> restore(manifest, previous, context)
    end
  end

  @doc "Choose the effective effort for one turn and permanently suspend when the host is off."
  @spec turn(term(), map()) :: map()
  def turn(assignment, context) when is_map(context) do
    case normalize_assignment(assignment) do
      {:ok, %{"state" => "active"} = current} -> active_turn(current, context)
      {:ok, current} -> baseline_decision(current, "already_suspended", false)
      :error -> invalid_decision()
    end
  end

  defp assign_fresh(manifest, context) do
    cond do
      context_value(context, :fresh_task) != true ->
        {:skip, :not_fresh}

      normalize_mode(context_value(context, :mode)) != :apply ->
        {:skip, :disabled}

      not is_map(manifest) ->
        {:skip, :no_manifest}

      true ->
        create_if_eligible(manifest, context)
    end
  end

  defp create_if_eligible(manifest, context) do
    with :ok <- eligible_backend(manifest, context),
         :ok <- eligible_repository(manifest, context),
         :ok <- eligible_task_family(manifest, context),
         :ok <- eligible_label(manifest, context),
         :ok <- eligible_baseline(manifest, context),
         :ok <- eligible_issue_identity(context) do
      {:assigned, build_assignment(manifest, context)}
    else
      {:skip, reason} -> {:skip, reason}
    end
  end

  defp restore(manifest, previous, context) do
    case normalize_assignment(previous) do
      {:ok, assignment} -> restore_valid(manifest, assignment, context)
      :error -> {:skip, :invalid_previous_assignment}
    end
  end

  defp restore_valid(manifest, assignment, context) do
    cond do
      assignment["state"] == "suspended" ->
        {:restored, assignment}

      not is_map(manifest) ->
        suspend_result(assignment, "manifest_unavailable")

      manifest_identity(manifest) != assignment_identity(assignment) ->
        suspend_result(assignment, "manifest_mismatch")

      not restored_identity_matches?(manifest, assignment, context) ->
        suspend_result(assignment, "identity_mismatch")

      not restored_route_matches?(assignment, context) ->
        suspend_result(assignment, "route_mismatch")

      true ->
        {:restored, assignment}
    end
  end

  defp active_turn(assignment, context) do
    if normalize_mode(context_value(context, :mode)) == :apply do
      experiment_turn(assignment, context_value(context, :run_id))
    else
      suspended = suspend(assignment, "kill_switch")
      baseline_decision(suspended, "kill_switch", true)
    end
  end

  defp experiment_turn(assignment, run_id) do
    if stable_context_id?(run_id) do
      exposure_id = exposure_id(assignment, run_id)

      updated =
        update_assignment(assignment, %{
          "ever_exposed" => true,
          "last_exposure_id" => exposure_id
        })

      %{
        action: "experiment",
        reasoning_effort: assignment["reasoning_effort"],
        exposure_id: exposure_id,
        emit_exposure: assignment["last_exposure_id"] != exposure_id,
        emit_suspension: false,
        suspension_reason: nil,
        assignment: updated
      }
    else
      baseline_decision(assignment, "invalid_run_id", false)
    end
  end

  defp baseline_decision(assignment, reason, emit_suspension) do
    %{
      action: "baseline",
      reasoning_effort: assignment["baseline_reasoning_effort"],
      exposure_id: nil,
      emit_exposure: false,
      emit_suspension: emit_suspension,
      suspension_reason: reason,
      assignment: assignment
    }
  end

  defp invalid_decision do
    %{
      action: "baseline",
      reasoning_effort: nil,
      exposure_id: nil,
      emit_exposure: false,
      emit_suspension: false,
      suspension_reason: "invalid_assignment",
      assignment: nil
    }
  end

  defp build_assignment(manifest, context) do
    repository_id = context_value(context, :repository_id)
    issue_id = context_value(context, :issue_id)
    unit_id = unit_id(repository_id, issue_id)
    arm = select_arm(manifest, unit_id)
    assignment_id = assignment_id(manifest, unit_id, arm)

    %{
      "assignment_version" => @assignment_version,
      "experiment_id" => manifest.id,
      "revision" => manifest.revision,
      "experiment_manifest_digest" => manifest.manifest_digest,
      "unit_id" => unit_id,
      "assignment_id" => assignment_id,
      "arm_id" => arm.id,
      "arm_role" => Atom.to_string(arm.role),
      "reasoning_effort" => arm.value,
      "baseline_reasoning_effort" => manifest.control.value,
      "arm_config_digest" => arm.config_digest,
      "control_config_digest" => manifest.control.config_digest,
      "state" => "active",
      "suspension_reason" => nil,
      "suspension_id" => nil,
      "ever_exposed" => false,
      "last_exposure_id" => nil,
      "contaminated" => false
    }
    |> put_assignment_digest()
  end

  defp select_arm(manifest, unit_id) do
    arms = [manifest.control | manifest.variants]
    total = Enum.sum(Enum.map(arms, & &1.weight))
    bucket = digest_number([manifest.manifest_digest, unit_id]) |> rem(total)

    {_remaining, selected} =
      Enum.reduce_while(arms, {bucket, manifest.control}, fn arm, {remaining, _selected} ->
        if remaining < arm.weight,
          do: {:halt, {remaining, arm}},
          else: {:cont, {remaining - arm.weight, arm}}
      end)

    selected
  end

  defp eligible_backend(manifest, context) do
    if context_value(context, :backend) in [:codex, "codex"] and manifest.backend == :codex,
      do: :ok,
      else: {:skip, :backend_ineligible}
  end

  defp eligible_repository(manifest, context) do
    if context_value(context, :repository_id) in manifest.repositories,
      do: :ok,
      else: {:skip, :repository_ineligible}
  end

  defp eligible_task_family(manifest, context) do
    if context_value(context, :task_family) in manifest.task_families,
      do: :ok,
      else: {:skip, :task_family_ineligible}
  end

  defp eligible_label(manifest, context) do
    labels = context_value(context, :labels)

    if is_list(labels) and manifest.opt_in_label in labels,
      do: :ok,
      else: {:skip, :label_ineligible}
  end

  defp eligible_baseline(manifest, context) do
    if context_value(context, :baseline_reasoning_effort) == manifest.control.value,
      do: :ok,
      else: {:skip, :baseline_mismatch}
  end

  defp eligible_issue_identity(context) do
    if stable_context_id?(context_value(context, :issue_id)),
      do: :ok,
      else: {:skip, :invalid_issue_id}
  end

  defp restored_identity_matches?(manifest, assignment, context) do
    repository_id = context_value(context, :repository_id)
    issue_id = context_value(context, :issue_id)

    if stable_context_id?(repository_id) and stable_context_id?(issue_id) do
      expected_unit_id = unit_id(repository_id, issue_id)
      expected_arm = select_arm(manifest, expected_unit_id)

      assignment["unit_id"] == expected_unit_id and
        assignment["assignment_id"] == assignment_id(manifest, expected_unit_id, expected_arm) and
        assignment_arm_matches?(assignment, expected_arm, manifest.control)
    else
      false
    end
  end

  defp assignment_arm_matches?(assignment, arm, control) do
    assignment["arm_id"] == arm.id and assignment["arm_role"] == Atom.to_string(arm.role) and
      assignment["reasoning_effort"] == arm.value and
      assignment["arm_config_digest"] == arm.config_digest and
      assignment["baseline_reasoning_effort"] == control.value and
      assignment["control_config_digest"] == control.config_digest
  end

  defp restored_route_matches?(assignment, context) do
    context_value(context, :backend) in [:codex, "codex"] and
      context_value(context, :baseline_reasoning_effort) == assignment["baseline_reasoning_effort"]
  end

  defp manifest_identity(manifest), do: {manifest.id, manifest.revision, manifest.manifest_digest}

  defp unit_id(repository_id, issue_id) do
    unit_digest = digest(["unit/v1", repository_id, issue_id])
    "exu-" <> binary_part(unit_digest, 0, 32)
  end

  defp assignment_id(manifest, unit_id, arm) do
    "exa-" <> binary_part(digest([manifest.manifest_digest, unit_id, arm.id]), 0, 32)
  end

  defp exposure_id(assignment, run_id) do
    "exe-" <> binary_part(digest(["exposure/v1", assignment["assignment_id"], run_id]), 0, 32)
  end

  defp suspension_id(assignment, reason) do
    "exs-" <> binary_part(digest(["suspension/v1", assignment["assignment_id"], reason]), 0, 32)
  end

  defp assignment_identity(assignment) do
    {
      assignment["experiment_id"],
      assignment["revision"],
      assignment["experiment_manifest_digest"]
    }
  end

  defp suspend_result(assignment, reason), do: {:suspended, suspend(assignment, reason), reason}

  defp suspend(assignment, reason) do
    update_assignment(assignment, %{
      "state" => "suspended",
      "suspension_reason" => reason,
      "suspension_id" => suspension_id(assignment, reason),
      "contaminated" => true
    })
  end

  defp update_assignment(assignment, changes) do
    assignment
    |> Map.merge(changes)
    |> Map.delete("assignment_digest")
    |> put_assignment_digest()
  end

  defp normalize_assignment(assignment) when is_map(assignment) do
    normalized = stringify_known_keys(assignment)

    if valid_assignment?(normalized), do: {:ok, normalized}, else: :error
  end

  defp normalize_assignment(_assignment), do: :error

  defp valid_assignment?(assignment) do
    exact_keys?(assignment) and valid_identity?(assignment) and valid_arm?(assignment) and
      valid_lifecycle?(assignment) and valid_assignment_digest?(assignment)
  end

  defp valid_identity?(assignment) do
    assignment["assignment_version"] == @assignment_version and
      safe_id?(assignment["experiment_id"], 64) and valid_revision?(assignment["revision"]) and
      digest?(assignment["experiment_manifest_digest"]) and short_id?(assignment["unit_id"]) and
      short_id?(assignment["assignment_id"])
  end

  defp valid_arm?(assignment) do
    safe_id?(assignment["arm_id"], 32) and assignment["arm_role"] in ~w(control variant) and
      assignment["reasoning_effort"] in @reasoning_efforts and
      assignment["baseline_reasoning_effort"] in @reasoning_efforts and
      digest?(assignment["arm_config_digest"]) and digest?(assignment["control_config_digest"])
  end

  defp valid_lifecycle?(assignment) do
    assignment["state"] in @states and valid_suspension?(assignment) and
      is_boolean(assignment["ever_exposed"]) and valid_exposure?(assignment) and
      is_boolean(assignment["contaminated"])
  end

  defp valid_exposure?(%{"ever_exposed" => false, "last_exposure_id" => nil}), do: true

  defp valid_exposure?(%{"ever_exposed" => true, "last_exposure_id" => exposure_id}),
    do: is_binary(exposure_id) and Regex.match?(@exposure_id, exposure_id)

  defp valid_exposure?(_assignment), do: false

  defp valid_assignment_digest?(assignment) do
    digest_value = assignment["assignment_digest"]
    digest?(digest_value) and assignment_digest(assignment) == digest_value
  end

  defp valid_suspension?(%{
         "state" => "active",
         "suspension_reason" => nil,
         "suspension_id" => nil,
         "contaminated" => false
       }),
       do: true

  defp valid_suspension?(
         %{
           "state" => "suspended",
           "suspension_reason" => reason,
           "suspension_id" => suspension_id,
           "contaminated" => true
         } = assignment
       )
       when reason in @suspension_reasons,
       do:
         is_binary(suspension_id) and Regex.match?(@suspension_id, suspension_id) and
           suspension_id == suspension_id(assignment, reason)

  defp valid_suspension?(_assignment), do: false

  defp stringify_known_keys(map) do
    Map.new(map, fn {key, value} ->
      normalized = if is_atom(key), do: Atom.to_string(key), else: key
      {normalized, value}
    end)
  end

  defp exact_keys?(assignment), do: Enum.sort(Map.keys(assignment)) == Enum.sort(@assignment_keys)
  defp valid_revision?(revision), do: is_integer(revision) and revision in 1..1_000_000

  defp safe_id?(value, cap),
    do: is_binary(value) and byte_size(value) <= cap and Regex.match?(@safe_id, value)

  defp stable_context_id?(value),
    do: is_binary(value) and byte_size(value) <= 128 and Regex.match?(@stable_context_id, value)

  defp digest?(value), do: is_binary(value) and Regex.match?(@digest, value)
  defp short_id?(value), do: is_binary(value) and Regex.match?(@short_id, value)

  defp put_assignment_digest(assignment),
    do: Map.put(assignment, "assignment_digest", assignment_digest(assignment))

  defp assignment_digest(assignment), do: assignment |> Map.delete("assignment_digest") |> canonical() |> digest()
  defp canonical(map), do: map |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {key, value} -> [key, value] end)

  defp digest_number(value) do
    value
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> binary_part(0, 8)
    |> :binary.decode_unsigned()
  end

  defp digest(value), do: :crypto.hash(:sha256, Jason.encode!(value)) |> Base.encode16(case: :lower)

  defp normalize_mode(:apply), do: :apply
  defp normalize_mode("apply"), do: :apply
  defp normalize_mode(_off_or_invalid), do: :off

  defp context_value(context, key) do
    Map.get(context, key, Map.get(context, Atom.to_string(key)))
  end
end
