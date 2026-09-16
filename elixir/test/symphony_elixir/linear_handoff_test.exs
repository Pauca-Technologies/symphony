defmodule SymphonyElixir.LinearHandoffTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.{Handoff, Issue}

  @issue %Issue{id: "issue-1", identifier: "UDPE-1", state: "In Progress"}
  @query "mutation Move { issueUpdate { success issue { id state { name } } } }"

  test "requires positive acknowledgement and the requested issue and state" do
    client = fn @query, %{}, [] -> {:ok, acknowledgement("issue-1", "In Review")} end
    assert {:ok, %Issue{state: "In Review"}} = Handoff.deliver(@issue, "In Review", @query, %{}, client)
    client = fn @query, %{}, [] -> {:ok, Map.put(acknowledgement("issue-1", "In Review"), "errors", nil)} end
    assert {:ok, %Issue{state: "In Review"}} = Handoff.deliver(@issue, "In Review", @query, %{}, client)

    for response <- [
          %{},
          %{"data" => %{}},
          %{"data" => %{"issueUpdate" => %{"success" => false}}},
          %{"data" => %{"issueUpdate" => %{"success" => nil}}},
          acknowledgement("another-issue", "In Review"),
          acknowledgement("issue-1", "In Progress"),
          Map.put(acknowledgement("issue-1", "In Review"), "errors", [%{"message" => "partial failure"}])
        ] do
      client = fn @query, %{}, [] -> {:ok, response} end
      assert {:error, _} = Handoff.deliver(@issue, "In Review", @query, %{}, client)
    end
  end

  test "confirms old durable mutations that only selected success" do
    client = fn
      @query, %{}, [] ->
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}

      query, %{"issueId" => "issue-1"}, [] ->
        assert query =~ "query SymphonyConfirmHandoff"
        {:ok, %{"data" => %{"issue" => %{"id" => "issue-1", "state" => %{"name" => "Human Review"}}}}}
    end

    assert {:ok, %Issue{state: "Human Review"}} = Handoff.deliver(@issue, "Human Review", @query, %{}, client)
  end

  test "stale or unavailable confirmation keeps delivery pending" do
    for confirmation <- [
          {:error, :timeout},
          {:ok, nil},
          {:ok, %{"data" => %{"issue" => nil}}},
          {:ok, %{"data" => %{"issue" => %{"id" => "issue-1", "state" => %{"name" => "In Progress"}}}}},
          {:ok, %{"errors" => [%{"message" => "unavailable"}], "data" => %{}}}
        ] do
      client = fn
        @query, %{}, [] -> {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
        _query, %{"issueId" => "issue-1"}, [] -> confirmation
      end

      assert {:error, _} = Handoff.deliver(@issue, "In Review", @query, %{}, client)
    end
  end

  test "transport failures do not trigger a confirmation read" do
    client = fn @query, %{}, [] -> {:error, :timeout} end
    assert {:error, :timeout} = Handoff.deliver(@issue, "In Review", @query, %{}, client)
  end

  defp acknowledgement(id, state) do
    %{"data" => %{"issueUpdate" => %{"success" => true, "issue" => %{"id" => id, "state" => %{"name" => state}}}}}
  end
end
