defmodule SymphonyElixir.PrerequisiteTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.RepoConfig

  defmodule FakeClient do
    def fetch_candidate_issues, do: {:ok, []}
    def fetch_issues_by_states(_states), do: {:ok, []}
    def fetch_issue_states_by_ids(_ids), do: {:ok, []}
    def recently_terminal_issues(_days), do: {:ok, []}

    def graphql(query, variables) do
      send(self(), {:graphql, query, variables})

      case Process.get(:prerequisite_responses) do
        [response | rest] ->
          Process.put(:prerequisite_responses, rest)
          response

        _ ->
          {:error, :test_unconfigured}
      end
    end
  end

  setup do
    previous = Application.get_env(:symphony_elixir, :linear_client_module)
    Application.put_env(:symphony_elixir, :linear_client_module, FakeClient)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :linear_client_module, previous),
        else: Application.delete_env(:symphony_elixir, :linear_client_module)
    end)

    File.write!(RepoConfig.path(), """
    linear:
      filter_label: udpagent
    repos:
      - id: dashboard
        label: repo:dashboard
    """)

    :ok
  end

  test "a prerequisite becomes runnable only after its correctly directed blocking relation" do
    responses([context(), created(), related(), scheduled()])
    assert {:ok, %{identifier: "UDPE-2", deduplicated: false}} = Adapter.create_follow_up(source(), attributes())

    assert_receive {:graphql, context_query, %{issueId: "source"}}
    assert context_query =~ "Todo"
    assert_receive {:graphql, create_query, %{input: create}}
    assert create_query =~ "issueCreate"
    assert create.stateId == "backlog"
    refute Map.has_key?(create, :labelIds)
    refute Map.has_key?(create, :assigneeId)
    assert create.projectId == "project"

    assert_receive {:graphql, relation_query, %{input: relation}}
    assert relation_query =~ "issueRelationCreate"
    assert relation.issueId == "prerequisite"
    assert relation.relatedIssueId == "source"
    assert relation.type == "blocks"

    assert_receive {:graphql, schedule_query, %{issueId: "prerequisite", input: input}}
    assert schedule_query =~ "issueUpdate"
    assert input == %{stateId: "todo", addedLabelIds: ["repo-label", "pickup-label"]}
    refute_received {:graphql, _, _}
  end

  test "a relation failure leaves the new issue in Backlog without pickup labels" do
    responses([context(), created(), {:error, :timeout}, {:ok, %{"data" => %{"issueRelation" => nil}}}])
    assert {:error, :follow_up_relation_create_failed} = Adapter.create_follow_up(source(), attributes())
    assert_receive {:graphql, _, %{input: %{stateId: "backlog"}}}
    refute_received {:graphql, _, %{issueId: "prerequisite", input: _}}
  end

  test "delivery retry reuses the issue and confirmed relation before scheduling" do
    responses([
      context(),
      {:error, :duplicate},
      found(),
      {:error, :duplicate},
      {:ok, %{"data" => %{"issueRelation" => %{"type" => "blocks", "issue" => %{"id" => "prerequisite"}, "relatedIssue" => %{"id" => "source"}}}}},
      scheduled()
    ])

    assert {:ok, %{deduplicated: true}} = Adapter.create_follow_up(source(), attributes())
    assert_receive {:graphql, _, %{input: %{id: first_id, stateId: "backlog"}}}
    assert_receive {:graphql, _, %{issueId: ^first_id}}
    assert_receive {:graphql, _, %{input: %{id: relation_id, issueId: "prerequisite", relatedIssueId: "source"}}}
    assert_receive {:graphql, _, %{relationId: ^relation_id}}
    assert_receive {:graphql, _, %{issueId: "prerequisite", input: %{stateId: "todo"}}}
  end

  test "an existing relation with reversed direction is not accepted" do
    responses([
      context(),
      created(),
      {:error, :duplicate},
      {:ok, %{"data" => %{"issueRelation" => %{"type" => "blocks", "issue" => %{"id" => "source"}, "relatedIssue" => %{"id" => "prerequisite"}}}}}
    ])

    assert {:error, :follow_up_relation_create_failed} = Adapter.create_follow_up(source(), attributes())
    refute_received {:graphql, _, %{issueId: "prerequisite", input: _}}
  end

  test "scheduling retries do not rewind active or terminal issues and preserve unrelated labels" do
    for type <- ["unstarted", "started", "completed", "canceled"] do
      responses([context(), {:error, :duplicate}, found(type, ["other-label", "repo-label", "pickup-label"]), related()])
      assert {:ok, %{deduplicated: true}} = Adapter.create_follow_up(source(), attributes())
      refute_received {:graphql, _, %{issueId: "prerequisite", input: _}}
    end

    responses([context(), {:error, :duplicate}, found("started", ["other-label", "repo-label"]), related(), scheduled("started")])
    assert {:ok, _} = Adapter.create_follow_up(source(), attributes())
    assert_receive {:graphql, _, %{issueId: "prerequisite", input: %{addedLabelIds: ["pickup-label"]} = input}}
    refute Map.has_key?(input, :stateId)
    refute Map.has_key?(input, :labelIds)
  end

  test "a failed schedule is retryable and missing state data never rewinds an issue" do
    responses([context(), created(), related(), {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}])
    assert {:error, :prerequisite_schedule_failed} = Adapter.create_follow_up(source(), attributes())

    responses([context(), created(nil), related()])
    assert {:error, {:follow_up_configuration, :prerequisite_state_unavailable}} = Adapter.create_follow_up(source(), attributes())
  end

  test "missing Todo or source routing labels fails before creating an issue" do
    fixtures = [
      {update_in(context(), [Access.elem(1), "data", "issue", "team", "states", "nodes"], &Enum.reject(&1, fn s -> s["name"] == "Todo" end)), :todo_state_missing},
      {put_in(context(), [Access.elem(1), "data", "issue", "labels", "pageInfo", "hasNextPage"], true), :source_labels_incomplete},
      {update_in(context(), [Access.elem(1), "data", "issue", "labels", "nodes"], &Enum.reject(&1, fn l -> l["id"] == "pickup-label" end)), :automation_label_missing},
      {update_in(context(), [Access.elem(1), "data", "issue", "labels", "nodes"], &Enum.reject(&1, fn l -> l["id"] == "repo-label" end)), :source_repository_unresolved}
    ]

    for {fixture, reason} <- fixtures do
      responses([fixture])
      assert {:error, {:follow_up_configuration, ^reason}} = Adapter.create_follow_up(source(), attributes())
      refute_received {:graphql, _, %{input: _}}
    end
  end

  test "partial GraphQL errors and incomplete scheduling acknowledgements never report success" do
    responses([{:ok, Map.put(elem(context(), 1), "errors", [%{"message" => "partial"}])}])
    assert {:error, {:linear_graphql_errors, _}} = Adapter.create_follow_up(source(), attributes())
    refute_received {:graphql, _, %{input: _}}

    for response <- [
          {:ok, Map.put(elem(scheduled(), 1), "errors", [%{"message" => "partial"}])},
          put_in(scheduled(), [Access.elem(1), "data", "issueUpdate", "issue", "labels", "nodes"], []),
          scheduled("backlog")
        ] do
      responses([context(), created(), related(), response])
      assert {:error, :prerequisite_schedule_failed} = Adapter.create_follow_up(source(), attributes())
    end
  end

  test "invalid directions and cycles are rejected before tracker writes" do
    for flags <- [%{blocks_current: true, depends_on_current: true}, %{blocks_current: "true"}] do
      assert {:error, {:follow_up_configuration, _}} = Adapter.create_follow_up(source(), Map.merge(attributes(), flags))
      refute_received {:graphql, _, _}
    end
  end

  defp source, do: %Issue{id: "source", identifier: "UDPE-1", url: "https://linear.example/UDPE-1"}

  defp attributes,
    do: %{
      title: "Stabilize prerequisite tests",
      description: "Repair the base-owned tests.",
      acceptance_criteria: "Both tests pass reliably.",
      evidence: "Required CI fails in the two tests.",
      blocks_current: true,
      depends_on_current: false
    }

  defp responses(values), do: Process.put(:prerequisite_responses, values)

  defp context do
    {:ok,
     %{
       "data" => %{
         "issue" => %{
           "id" => "source",
           "identifier" => "UDPE-1",
           "url" => "https://linear.example/UDPE-1",
           "project" => %{"id" => "project"},
           "team" => %{"id" => "team", "states" => %{"nodes" => [%{"id" => "backlog", "name" => "Backlog"}, %{"id" => "todo", "name" => "Todo"}]}},
           "labels" => %{
             "nodes" => [%{"id" => "pickup-label", "name" => "udpagent"}, %{"id" => "repo-label", "name" => "dashboard", "parent" => %{"name" => "repo"}}],
             "pageInfo" => %{"hasNextPage" => false}
           }
         }
       }
     }}
  end

  defp issue(type, labels) do
    %{
      "id" => "prerequisite",
      "identifier" => "UDPE-2",
      "title" => "Stabilize prerequisite tests",
      "url" => "https://linear.example/UDPE-2",
      "state" => if(type, do: %{"id" => type, "type" => type, "name" => type}),
      "labels" => %{"nodes" => Enum.map(labels, &%{"id" => &1})}
    }
  end

  defp created(type \\ "backlog"), do: {:ok, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => issue(type, [])}}}}
  defp found(type \\ "backlog", labels \\ []), do: {:ok, %{"data" => %{"issue" => issue(type, labels)}}}
  defp related, do: {:ok, %{"data" => %{"issueRelationCreate" => %{"success" => true}}}}
  defp scheduled(type \\ "unstarted"), do: {:ok, %{"data" => %{"issueUpdate" => %{"success" => true, "issue" => issue(type, ["repo-label", "pickup-label"])}}}}
end
