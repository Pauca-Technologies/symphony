defmodule SymphonyElixir.DependencyStatusTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DependencyStatus, RepoConfig, WaitCondition, WaitStore}

  test "only complete, correctly addressed Linear snapshots can resolve dependencies" do
    blocker = %{
      "id" => "b",
      "identifier" => "UDPE-2",
      "state" => %{"name" => "Done"},
      "labels" => connection([%{"name" => "dashboard", "parent" => %{"name" => "repo"}}, %{"name" => "udpagent"}, %{}])
    }

    response = response([%{"type" => "blocks", "issue" => blocker}, %{"type" => "related"}])
    assert {:ok, %{blockers: [decoded]} = snapshot} = DependencyStatus.from_linear(response, "source")
    assert decoded.labels == ["repo:dashboard", "udpagent", ""]
    assert {:ok, %{"resolved" => true}} = DependencyStatus.observation(snapshot, tracker(), repos())
    assert {:error, :dependency_source_unavailable} = DependencyStatus.from_linear(response, "different")
    assert {:error, {:linear_graphql_errors, [_]}} = DependencyStatus.from_linear(Map.put(response, "errors", ["partial"]), "source")

    for invalid <- [
          nil,
          %{},
          connection([%{}]),
          connection([%{"type" => "blocks", "issue" => %{}}]),
          Map.put(connection([]), "pageInfo", %{"hasNextPage" => true}),
          connection([%{"type" => "blocks", "issue" => Map.put(blocker, "labels", %{})}])
        ] do
      assert {:error, :dependency_snapshot_incomplete} = DependencyStatus.from_linear(put_in(response, ["data", "issue", "inverseRelations"], invalid), "source")
    end
  end

  test "dispatch visibility explains every routing and queue outcome" do
    cases = [
      {"Done", [], "finished"},
      {"Backlog", [], "not_queued"},
      {"Todo", ["repo:dashboard"], "missing_automation_label"},
      {"Todo", ["udpagent"], "missing_repository_label"},
      {"Todo", ["udpagent", "repo:dashboard", "repo:other"], "ambiguous_repository"},
      {"tOdO", ["UDPAGENT", "repo:dashboard"], "eligible_for_pickup"}
    ]

    for {state, labels, expected} <- cases do
      snapshot = %{issue_state: "In Progress", blockers: [%{id: "b", state: state, labels: labels, assignee: "Alex"}]}
      assert {:ok, %{"dependencies" => [dependency]}} = DependencyStatus.observation(snapshot, tracker(), repos())
      assert dependency["dispatch_status"] == expected
      assert dependency["assignee"] == "Alex"
    end

    assert {:ok, %{"resolved" => true}} = DependencyStatus.observation(%{issue_state: "Todo", blockers: []}, tracker(), repos())

    assert {:ok, %{"dependencies" => [%{"dispatch_status" => "eligible_for_pickup"}]}} =
             DependencyStatus.observation(%{issue_state: "Todo", blockers: [%{id: "b", state: "Todo"}]}, tracker(), %{source: :default, linear: %{filter_label: nil}})

    for snapshot <- [%{}, %{issue_state: "Todo", blockers: [%{}]}, %{issue_state: "Todo", blockers: [%{id: "", state: "Todo"}]}] do
      assert {:error, :dependency_snapshot_incomplete} = DependencyStatus.observation(snapshot, tracker(), repos())
    end
  end

  test "dependency waits ignore progress, survive storage, and resume only after blockers resolve" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%Issue{id: "source", state: "In Progress", blocked_by: [%{id: "b", state: "Todo"}]}])
    args = %{"reason" => "await prerequisite", "condition" => %{"type" => "linear_dependencies_resolved"}}
    assert {:ok, request} = WaitCondition.normalize(args, %{issue: %{id: "source"}})
    assert {:error, :cross_issue_linear_wait_not_allowed} = WaitCondition.normalize(put_in(args, ["condition", "issue_id"], "b"), %{issue: %{id: "source"}})
    assert {:ok, request} = WaitCondition.capture_baseline(request)
    assert {:unchanged, _} = WaitCondition.probe(request)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%Issue{id: "source", state: "In Progress", blocked_by: [%{id: "b", state: "In Progress"}]}])
    assert {:unchanged, observation} = WaitCondition.probe(request)
    refute observation["resolved"]

    path = Path.join(Path.dirname(Workflow.workflow_file_path()), "waits.json")
    previous = Application.get_env(:symphony_elixir, :wait_state_path)
    Application.put_env(:symphony_elixir, :wait_state_path, path)
    on_exit(fn -> if previous, do: Application.put_env(:symphony_elixir, :wait_state_path, previous), else: Application.delete_env(:symphony_elixir, :wait_state_path) end)
    entry = Map.merge(%{request: request}, %{issue_id: "source", issue_identifier: "UDPE-1", workflow_policy: %{"status" => "stale"}, last_observation: observation})
    assert :ok = WaitStore.save(%{"source" => entry})
    assert %{"source" => restored} = WaitStore.load()
    assert restored.workflow_policy == %{"status" => "stale"}
    assert restored.last_observation == observation
    assert {:unchanged, _} = WaitCondition.probe(restored.request)

    for blockers <- [[%{id: "b", state: "Done"}], []] do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [%Issue{id: "source", state: "In Progress", blocked_by: blockers}])
      assert {:changed, %{"resolved" => true}} = WaitCondition.probe(restored.request)
      assert {:error, {:condition_already_satisfied, _}} = WaitCondition.capture_baseline(request)
    end

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    assert {:error, :dependency_source_missing} = WaitCondition.probe(restored.request)
    Application.put_env(:symphony_elixir, :memory_tracker_states_by_ids_result, {:error, :offline})
    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_states_by_ids_result) end)
    assert {:error, :offline} = WaitCondition.probe(restored.request)
    File.write!(RepoConfig.path(), "repos: invalid")
    assert {:error, _} = DependencyStatus.observation(%{issue_state: "Todo", blockers: []})
  end

  defp connection(nodes), do: %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}}
  defp response(relations), do: %{"data" => %{"issue" => %{"id" => "source", "state" => %{"name" => "In Progress"}, "inverseRelations" => connection(relations)}}}
  defp tracker, do: %{active_states: ["Todo", "In Progress"], terminal_states: ["Done", "Canceled"]}
  defp repos, do: %{source: :file, linear: %{filter_label: "udpagent"}, repos: [%{id: "dashboard", label: "repo:dashboard"}, %{id: "other", label: "repo:other"}]}
end
