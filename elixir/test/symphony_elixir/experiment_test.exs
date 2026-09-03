defmodule SymphonyElixir.ExperimentTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Experiment, as: ExperimentConfig
  alias SymphonyElixir.Experiment

  test "assigns stable bounded ids and weighted arms independent of input ordering" do
    manifest = manifest()

    assignments =
      for index <- 1..300 do
        context = context(issue_id: "issue-#{index}")
        assert {:assigned, assignment} = Experiment.assign(manifest, context)
        assert {:assigned, ^assignment} = Experiment.assign(manifest, context)
        assignment
      end

    assert assignments |> Enum.map(& &1["arm_id"]) |> Enum.uniq() |> Enum.sort() ==
             ~w(control low medium)

    assert Enum.count(assignments, &(&1["arm_id"] == "medium")) >
             Enum.count(assignments, &(&1["arm_id"] == "low"))

    Enum.each(assignments, fn assignment ->
      assert assignment["unit_id"] =~ ~r/\Aexu-[0-9a-f]{32}\z/
      assert assignment["assignment_id"] =~ ~r/\Aexa-[0-9a-f]{32}\z/
      assert assignment["assignment_digest"] =~ ~r/\A[0-9a-f]{64}\z/
      assert assignment["last_exposure_id"] == nil
      assert assignment["suspension_id"] == nil
      assert Map.keys(assignment) |> length() == 19
    end)
  end

  test "requires a fresh opted-in Codex task with exact repository family and baseline" do
    manifest = manifest()

    invalid = [
      {context(fresh_task: false), :not_fresh},
      {context(mode: :off), :disabled},
      {context(mode: :unexpected), :disabled},
      {context(backend: "acp"), :backend_ineligible},
      {context(repository_id: "other"), :repository_ineligible},
      {context(task_family: "ui"), :task_family_ineligible},
      {context(labels: ["experiment:other"]), :label_ineligible},
      {context(baseline_reasoning_effort: "high"), :baseline_mismatch},
      {context(issue_id: nil), :invalid_issue_id},
      {context(issue_id: self()), :invalid_issue_id},
      {context(issue_id: String.duplicate("a", 129)), :invalid_issue_id},
      {context(issue_id: "unsafe/path"), :invalid_issue_id}
    ]

    Enum.each(invalid, fn {input, reason} ->
      assert {:skip, ^reason} = Experiment.assign(manifest, input)
    end)

    assert {:skip, :no_manifest} = Experiment.assign(nil, context())
    assert {:skip, :not_fresh} = Experiment.assign(nil, context(fresh_task: false))

    assert {:skip, :disabled} = Experiment.assign(manifest, context(mode: :off))

    assert {:skip, :not_fresh} =
             Experiment.assign(manifest, context(mode: :apply, fresh_task: false))
  end

  test "restores authoritative assignment without rechecking mutable eligibility" do
    manifest = manifest()
    {:assigned, assignment} = Experiment.assign(manifest, context())

    changed =
      context(
        fresh_task: false,
        mode: :off,
        labels: [],
        task_family: "ui",
        previous_assignment: assignment
      )

    assert {:restored, ^assignment} = Experiment.assign(manifest, changed)
  end

  test "restore recomputes task identity and every selected arm field" do
    manifest = manifest()
    {:assigned, assignment} = Experiment.assign(manifest, context())

    {:assigned, copied} =
      Experiment.assign(manifest, context(issue_id: "issue-from-another-task"))

    assert {:suspended, _, "identity_mismatch"} =
             Experiment.assign(manifest, context(fresh_task: false, previous_assignment: copied))

    mutations = [
      {"unit_id", "exu-" <> String.duplicate("0", 32)},
      {"assignment_id", "exa-" <> String.duplicate("0", 32)},
      {"arm_id", "nonexistent"},
      {"arm_role", if(assignment["arm_role"] == "control", do: "variant", else: "control")},
      {"reasoning_effort", alternate_effort(assignment["reasoning_effort"])},
      {"arm_config_digest", String.duplicate("0", 64)},
      {"baseline_reasoning_effort", "high"},
      {"control_config_digest", String.duplicate("f", 64)}
    ]

    Enum.each(mutations, fn {field, value} ->
      tampered = assignment |> Map.put(field, value) |> resign()

      assert {:suspended, _, "identity_mismatch"} =
               Experiment.assign(
                 manifest,
                 context(fresh_task: false, previous_assignment: tampered)
               )
    end)
  end

  test "manifest revision or digest mismatch suspends and never reassigns the task" do
    original = manifest()
    {:assigned, assignment} = Experiment.assign(original, context())
    changed = manifest(revision: original.revision + 1)

    assert {:suspended, suspended, "manifest_mismatch"} =
             Experiment.assign(changed, context(fresh_task: false, previous_assignment: assignment))

    assert suspended["state"] == "suspended"
    assert suspended["contaminated"]
    assert suspended["suspension_id"] =~ ~r/\Aexs-[0-9a-f]{32}\z/
    assert suspended["assignment_id"] == assignment["assignment_id"]

    assert {:restored, ^suspended} =
             Experiment.assign(changed, context(fresh_task: false, previous_assignment: suspended))

    digest_changed = %{original | manifest_digest: String.duplicate("f", 64)}

    assert {:suspended, _, "manifest_mismatch"} =
             Experiment.assign(digest_changed, context(fresh_task: false, previous_assignment: assignment))

    assert {:suspended, _, "manifest_unavailable"} =
             Experiment.assign(nil, context(fresh_task: false, previous_assignment: assignment))
  end

  test "route drift suspends a restored assignment" do
    manifest = manifest()
    {:assigned, assignment} = Experiment.assign(manifest, context())

    assert {:suspended, suspended, "route_mismatch"} =
             Experiment.assign(
               manifest,
               context(
                 fresh_task: false,
                 backend: "acp",
                 previous_assignment: assignment
               )
             )

    assert suspended["reasoning_effort"] == assignment["reasoning_effort"]
    assert suspended["baseline_reasoning_effort"] == "xhigh"
  end

  test "off permanently suspends before the next turn and re-enable cannot resume" do
    {:assigned, assignment} = Experiment.assign(manifest(), context())

    first = Experiment.turn(assignment, %{mode: :apply, run_id: "run-1"})
    assert first.action == "experiment"
    assert first.emit_exposure
    assert first.exposure_id =~ ~r/\Aexe-[0-9a-f]{32}\z/
    refute first.emit_suspension
    assert first.reasoning_effort == assignment["reasoning_effort"]
    assert first.assignment["ever_exposed"]
    assert first.assignment["last_exposure_id"] == first.exposure_id

    assert {:restored, restored} =
             Experiment.assign(
               manifest(),
               context(fresh_task: false, previous_assignment: first.assignment)
             )

    continued = Experiment.turn(restored, %{mode: "apply", run_id: "run-1"})
    refute continued.emit_exposure
    assert continued.exposure_id == first.exposure_id

    retry = Experiment.turn(continued.assignment, %{mode: :apply, run_id: "run-2"})
    assert retry.emit_exposure
    assert retry.exposure_id != first.exposure_id

    crash_replay = Experiment.turn(assignment, %{mode: :apply, run_id: "run-1"})
    assert crash_replay.emit_exposure
    assert crash_replay.exposure_id == first.exposure_id

    stopped = Experiment.turn(retry.assignment, %{mode: :off, run_id: "run-2"})
    assert stopped.action == "baseline"
    assert stopped.reasoning_effort == "xhigh"
    assert stopped.emit_suspension
    assert stopped.assignment["state"] == "suspended"
    assert stopped.assignment["suspension_reason"] == "kill_switch"
    assert stopped.assignment["suspension_id"] =~ ~r/\Aexs-[0-9a-f]{32}\z/
    assert stopped.assignment["contaminated"]

    reenabling = Experiment.turn(stopped.assignment, %{mode: :apply, run_id: "run-3"})
    assert reenabling.action == "baseline"
    refute reenabling.emit_exposure
    refute reenabling.emit_suspension
    assert reenabling.assignment == stopped.assignment
  end

  test "an unexposed assignment is closed by off and can never expose later" do
    {:assigned, assignment} = Experiment.assign(manifest(), context())
    stopped = Experiment.turn(assignment, %{mode: :invalid, run_id: "run-1"})

    assert stopped.emit_suspension
    refute stopped.assignment["ever_exposed"]
    assert stopped.assignment["contaminated"]

    later = Experiment.turn(stopped.assignment, %{mode: :apply, run_id: "run-1"})
    assert later.action == "baseline"
    refute later.emit_exposure
  end

  test "compact assignment hashes task scope and excludes issue content and opt-in label" do
    poison = "BEGIN PROMPT\nBearer secret raw issue body"

    {:assigned, assignment} =
      Experiment.assign(
        manifest(),
        context(
          issue_id: "issue-secret-id",
          labels: ["experiment:effort-ablation", poison],
          title: poison,
          description: poison,
          repository_id: "symphony"
        )
      )

    encoded = Jason.encode!(assignment)
    refute encoded =~ poison
    refute encoded =~ "issue-secret-id"
    refute encoded =~ "experiment:effort-ablation"
    refute encoded =~ "symphony"
    refute encoded =~ "title"
    refute encoded =~ "description"
  end

  test "malformed persisted assignments and turn inputs fail closed without raising" do
    manifest = manifest()
    {:assigned, assignment} = Experiment.assign(manifest, context())

    malformed = [
      "bad",
      [],
      %{},
      Map.put(assignment, "assignment_version", 2),
      Map.put(assignment, "assignment_digest", "bad"),
      Map.put(assignment, "state", "active\nmalicious"),
      Map.put(assignment, "suspension_reason", "kill_switch"),
      assignment |> Map.put("last_exposure_id", "exe-bad") |> resign(),
      assignment
      |> Map.merge(%{
        "state" => "suspended",
        "suspension_reason" => "kill_switch",
        "contaminated" => false
      })
      |> resign(),
      Map.put(assignment, {:unknown, :key}, self())
    ]

    Enum.each(malformed, fn previous ->
      assert {:skip, :invalid_previous_assignment} =
               Experiment.assign(manifest, context(fresh_task: false, previous_assignment: previous))

      decision = Experiment.turn(previous, %{mode: :apply, run_id: "run-1"})
      assert decision.action == "baseline"
      assert decision.assignment == nil
      refute decision.emit_exposure
    end)

    Enum.each([nil, self(), "", "unsafe/run", String.duplicate("r", 129)], fn run_id ->
      decision = Experiment.turn(assignment, %{mode: :apply, run_id: run_id})
      assert decision.action == "baseline"
      assert decision.suspension_reason == "invalid_run_id"
      refute decision.emit_exposure
      assert decision.assignment == assignment
    end)
  end

  defp manifest(overrides \\ []) do
    raw = %{
      "agent" => %{
        "experiment" => %{
          "schema_version" => 1,
          "id" => "effort-ablation",
          "revision" => Keyword.get(overrides, :revision, 3),
          "opt_in_label" => "experiment:effort-ablation",
          "backend" => "codex",
          "repositories" => ["symphony"],
          "task_families" => ["concurrency_liveness"],
          "variable" => "reasoning_effort",
          "control" => %{"id" => "control", "weight" => 2, "value" => "xhigh"},
          "variants" => [
            %{"id" => "medium", "weight" => 3, "value" => "medium"},
            %{"id" => "low", "weight" => 1, "value" => "low"}
          ]
        }
      }
    }

    {:ok, manifest} = ExperimentConfig.parse(raw)
    manifest
  end

  defp context(overrides \\ []) do
    Map.merge(
      %{
        fresh_task: true,
        mode: :apply,
        previous_assignment: nil,
        issue_id: "issue-1",
        labels: ["experiment:effort-ablation"],
        repository_id: "symphony",
        task_family: "concurrency_liveness",
        backend: "codex",
        baseline_reasoning_effort: "xhigh"
      },
      Map.new(overrides)
    )
  end

  defp resign(assignment) do
    core = Map.delete(assignment, "assignment_digest")

    digest =
      core
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, value} -> [key, value] end)
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    Map.put(core, "assignment_digest", digest)
  end

  defp alternate_effort("high"), do: "low"
  defp alternate_effort(_effort), do: "high"
end
