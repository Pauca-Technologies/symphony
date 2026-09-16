defmodule SymphonyElixir.RepositorySchedulerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.RepositoryScheduler

  test "overlapping actual paths serialize while disjoint work uses repository capacity" do
    config = repo_config(max_concurrent: 3)

    running = %{
      "one" => reservation("one", "UDPE-1", ["lib/accounts/user.ex"], "actual")
    }

    overlapping = issue("two", "UDPE-2", ["path:lib/accounts/user.ex"])
    disjoint = issue("three", "UDPE-3", ["path:assets/app.css"])

    assert {:queue, decision} = RepositoryScheduler.decide(overlapping, config, running)
    assert decision.reason == "path_overlap"
    assert decision.overlap_paths == ["lib/accounts/user.ex"]
    assert decision.suggested_order == ["UDPE-1", "UDPE-2"]

    assert {:allow, %{reason: "disjoint_or_unknown"}} =
             RepositoryScheduler.decide(disjoint, config, running)
  end

  test "actual manifests replace weaker predictions for overlap decisions" do
    config = repo_config(max_concurrent: 3)

    running = %{
      "one" => reservation("one", "UDPE-1", ["lib/billing/invoice.ex"], "actual")
    }

    stale_plan_overlap = issue("two", "UDPE-2", ["path:assets/app.css"])

    assert {:allow, _decision} =
             RepositoryScheduler.decide(stale_plan_overlap, config, running)

    running = put_in(running, ["one", :scheduling_paths], ["assets/app.css"])

    assert {:queue, %{reason: "path_overlap"}} =
             RepositoryScheduler.decide(stale_plan_overlap, config, running)
  end

  test "metadata and plan paths cover early no-PR work" do
    config = repo_config(path_hints: %{"area:auth" => ["lib/auth/**"]})
    issue = issue("one", "UDPE-1", ["area:auth"])

    assert RepositoryScheduler.predicted_paths(issue, hd(config.repos)) == ["lib/auth/**"]

    update = %{
      event: "plan_updated",
      payload: %{"method" => "turn/plan/updated", "params" => %{"plan" => [%{"step" => "Edit lib/auth/policy.ex and test/auth/policy_test.exs"}]}}
    }

    assert RepositoryScheduler.plan_paths(update) == ["lib/auth/policy.ex", "test/auth/policy_test.exs"]

    entry = RepositoryScheduler.observe_plan(%{scheduling_path_source: "metadata"}, update)
    assert entry.scheduling_path_source == "plan"
    assert entry.scheduling_paths == ["lib/auth/policy.ex", "test/auth/policy_test.exs"]
  end

  test "repository ceiling remains authoritative and overlap override is visible" do
    ceiling_config = repo_config(max_concurrent: 1)
    running = %{"one" => reservation("one", "UDPE-1", ["lib/a.ex"], "actual")}

    assert {:queue, %{reason: "repository_ceiling", override: true}} =
             RepositoryScheduler.decide(
               issue("two", "UDPE-2", ["path:lib/b.ex", "symphony:overlap-override"]),
               ceiling_config,
               running
             )

    overlap_config = repo_config(max_concurrent: 2)

    assert {:allow, %{reason: "operator_override"}} =
             RepositoryScheduler.decide(
               issue("two", "UDPE-2", ["path:lib/a.ex", "symphony:overlap-override"]),
               overlap_config,
               running
             )
  end

  test "handoff reservations preserve path serialization without consuming implementation capacity" do
    config = repo_config(max_concurrent: 1)

    handoff =
      reservation("one", "UDPE-1", ["lib/accounts/user.ex"], "actual")
      |> Map.put(:lifecycle_state, :handoff_pending_gate)

    running = %{"one" => handoff}

    assert {:allow, %{reason: "disjoint_or_unknown"}} =
             RepositoryScheduler.decide(
               issue("two", "UDPE-2", ["path:lib/billing/invoice.ex"]),
               config,
               running
             )

    assert {:queue, %{reason: "path_overlap"}} =
             RepositoryScheduler.decide(
               issue("three", "UDPE-3", ["path:lib/accounts/user.ex"]),
               config,
               running
             )
  end

  test "restart recovery has no stale reservations or deadlock" do
    config = repo_config(max_concurrent: 1)
    issue = issue("two", "UDPE-2", ["path:lib/a.ex"])

    assert {:queue, %{reason: "repository_ceiling"}} =
             RepositoryScheduler.decide(
               issue,
               config,
               %{"stale" => reservation("stale", "UDPE-OLD", ["lib/a.ex"], "actual")}
             )

    assert {:allow, %{reason: "disjoint_or_unknown"}} =
             RepositoryScheduler.decide(issue, config, %{})
  end

  test "overlap evidence is compact and reports omitted paths" do
    paths = Enum.map(1..40, &"lib/generated/file_#{&1}.ex")
    overlap = RepositoryScheduler.overlap(paths, paths)

    assert length(overlap.paths) == 20
    assert overlap.omitted == 20
    assert overlap.score == 1.0
  end

  test "repository-ceiling suggested order is bounded with an omitted count" do
    config = repo_config(max_concurrent: 25)

    running =
      Map.new(1..30, fn index ->
        id = "running-#{index}"
        {id, reservation(id, "UDPE-#{index}", ["lib/file_#{index}.ex"], "actual")}
      end)

    assert {:queue, decision} =
             RepositoryScheduler.decide(
               issue("queued", "UDPE-QUEUED", []),
               config,
               running
             )

    assert length(decision.suggested_order) == 20
    assert decision.suggested_order_omitted == 11
  end

  test "dependency order precedes human priority and all ties are deterministic" do
    dependency = %{issue("dep", "UDPE-10", []) | priority: 4, created_at: ~U[2026-01-02 00:00:00Z]}

    dependent = %{
      issue("child", "UDPE-11", [])
      | priority: 1,
        created_at: ~U[2026-01-01 00:00:00Z],
        blocked_by: [%{id: "dep", identifier: "UDPE-10", state: "In Progress"}]
    }

    unrelated = %{issue("other", "UDPE-12", []) | priority: 2, created_at: ~U[2026-01-03 00:00:00Z]}

    assert Enum.map(
             Orchestrator.sort_issues_for_dispatch_for_test([dependent, unrelated, dependency]),
             & &1.identifier
           ) == ["UDPE-12", "UDPE-10", "UDPE-11"]
  end

  defp repo_config(opts) do
    repo = %{
      id: "symphony",
      label: "repo:symphony",
      max_concurrent: Keyword.get(opts, :max_concurrent, 2),
      overlap_policy: "serialize",
      overlap_threshold: 0.5,
      scheduling_override_label: "symphony:overlap-override",
      path_hints: Keyword.get(opts, :path_hints, %{})
    }

    %{source: :file, repos: [repo]}
  end

  defp issue(id, identifier, labels) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Work #{identifier}",
      state: "Todo",
      labels: ["repo:symphony" | labels]
    }
  end

  defp reservation(id, identifier, paths, source) do
    %{
      issue_id: id,
      identifier: identifier,
      repository_id: "symphony",
      scheduling_paths: paths,
      scheduling_path_source: source,
      issue: %Issue{id: id, identifier: identifier, priority: 2, created_at: ~U[2026-01-01 00:00:00Z]}
    }
  end
end
