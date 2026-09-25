defmodule SymphonyElixir.DependencyStatus do
  @moduledoc "Complete dependency snapshots and their dispatch visibility, without model calls."

  alias SymphonyElixir.{Config, Linear.Issue, RepoConfig, Router}

  @doc "Decode a bounded Linear relation snapshot; incomplete data cannot release a wait."
  @spec from_linear(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def from_linear(%{"errors" => errors}, _issue_id), do: {:error, {:linear_graphql_errors, errors}}

  def from_linear(
        %{"data" => %{"issue" => %{"id" => id, "state" => %{"name" => state}, "inverseRelations" => connection}}},
        issue_id
      )
      when id == issue_id and is_binary(state) do
    with {:ok, relations} <- complete_nodes(connection),
         {:ok, blockers} <- decode_blockers(relations) do
      {:ok, %{issue_state: state, blockers: blockers}}
    end
  end

  def from_linear(_response, _issue_id), do: {:error, :dependency_source_unavailable}

  @doc "Describe which explicit blockers are finished and which can be picked up."
  @spec observation(map()) :: {:ok, map()} | {:error, term()}
  def observation(snapshot) do
    with {:ok, settings} <- Config.settings(),
         {:ok, repos} <- RepoConfig.load() do
      observation(snapshot, settings.tracker, repos)
    end
  end

  @spec observation(map(), map(), RepoConfig.t()) :: {:ok, map()} | {:error, term()}
  def observation(%{issue_state: state, blockers: blockers}, tracker, repos)
      when is_binary(state) and is_list(blockers) do
    if Enum.all?(blockers, &valid_blocker?/1) do
      dependencies =
        blockers
        |> Enum.map(&describe(&1, tracker, repos))
        |> Enum.sort_by(& &1["issue_id"])

      {:ok,
       %{
         "issue_state" => state,
         "dependencies" => dependencies,
         "resolved" => Enum.all?(dependencies, & &1["terminal"])
       }}
    else
      {:error, :dependency_snapshot_incomplete}
    end
  end

  def observation(_snapshot, _tracker, _repos), do: {:error, :dependency_snapshot_incomplete}

  defp complete_nodes(%{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}}) when is_list(nodes),
    do: {:ok, nodes}

  defp complete_nodes(_connection), do: {:error, :dependency_snapshot_incomplete}

  defp decode_blockers(relations) do
    Enum.reduce_while(relations, {:ok, []}, fn
      %{"type" => "blocks", "issue" => issue}, {:ok, blockers} ->
        case decode_blocker(issue) do
          {:ok, blocker} -> {:cont, {:ok, [blocker | blockers]}}
          error -> {:halt, error}
        end

      %{"type" => type}, acc when is_binary(type) ->
        {:cont, acc}

      _, _acc ->
        {:halt, {:error, :dependency_snapshot_incomplete}}
    end)
  end

  defp decode_blocker(%{"id" => id, "state" => %{"name" => state}, "labels" => labels} = issue)
       when is_binary(id) and id != "" and is_binary(state) and state != "" do
    with {:ok, nodes} <- complete_nodes(labels) do
      {:ok,
       %{
         id: id,
         identifier: issue["identifier"],
         title: issue["title"],
         url: issue["url"],
         state: state,
         assignee: get_in(issue, ["assignee", "displayName"]),
         labels: Enum.map(nodes, &label_name/1)
       }}
    end
  end

  defp decode_blocker(_issue), do: {:error, :dependency_snapshot_incomplete}

  defp valid_blocker?(%{id: id, state: state}),
    do: is_binary(id) and id != "" and is_binary(state) and state != ""

  defp valid_blocker?(_blocker), do: false

  defp describe(blocker, tracker, repos) do
    labels = Map.get(blocker, :labels, [])
    terminal = member?(tracker.terminal_states, blocker.state)
    route = Router.route(%Issue{labels: labels}, repos)
    filter_label = repos.linear.filter_label
    missing_labels = if is_binary(filter_label) and not member?(labels, filter_label), do: [filter_label], else: []
    {repository, routing_problem} = describe_route(route)

    status =
      cond do
        terminal -> "finished"
        not member?(tracker.active_states, blocker.state) -> "not_queued"
        missing_labels != [] -> "missing_automation_label"
        routing_problem -> routing_problem
        true -> "eligible_for_pickup"
      end

    %{
      "issue_id" => blocker.id,
      "identifier" => Map.get(blocker, :identifier),
      "title" => Map.get(blocker, :title),
      "url" => Map.get(blocker, :url),
      "state" => blocker.state,
      "assignee" => Map.get(blocker, :assignee),
      "repository" => repository,
      "terminal" => terminal,
      "dispatch_status" => status,
      "missing_labels" => missing_labels
    }
  end

  defp describe_route({:ok, repo}), do: {repo.id, nil}
  defp describe_route({:skip, :legacy_mode}), do: {nil, nil}
  defp describe_route({:skip, :ambiguous, _}), do: {nil, "ambiguous_repository"}
  defp describe_route({:skip, :no_match, _}), do: {nil, "missing_repository_label"}

  defp member?(values, value), do: Enum.any?(values, &(String.downcase(&1) == String.downcase(value)))
  defp label_name(%{"name" => name, "parent" => %{"name" => parent}}), do: "#{parent}:#{name}"
  defp label_name(%{"name" => name}), do: name
  defp label_name(_label), do: ""
end
