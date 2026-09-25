defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.{Config, RepoConfig, Router}
  alias SymphonyElixir.Linear.{Client, Comment, Issue}

  @follow_up_context_query """
  query SymphonyFollowUpContext($issueId: String!) {
    issue(id: $issueId) {
      id
      identifier
      url
      project { id }
      team {
        id
        states(filter: {name: {eq: "Backlog"}}, first: 1) {
          nodes { id }
        }
      }
    }
  }
  """

  @dependencies_query """
  query SymphonyIssueDependencies($issueId: String!) {
    issue(id: $issueId) {
      id state { name }
      inverseRelations(first: 100) {
        nodes {
          type
          issue {
            id identifier title url state { name }
            assignee { displayName }
            labels(first: 100) {
              nodes { name parent { name } }
              pageInfo { hasNextPage }
            }
          }
        }
        pageInfo { hasNextPage }
      }
    }
  }
  """

  @create_follow_up_mutation """
  mutation SymphonyCreateFollowUp($input: IssueCreateInput!) {
    issueCreate(input: $input) {
      success
      issue { id identifier title url state { id name type } labels { nodes { id } } }
    }
  }
  """

  @follow_up_lookup_query """
  query SymphonyFollowUpById($issueId: String!) {
    issue(id: $issueId) { id identifier title url state { id name type } labels { nodes { id } } }
  }
  """

  @prerequisite_context_query """
  query SymphonyPrerequisiteContext($issueId: String!) {
    issue(id: $issueId) {
      id identifier url project { id }
      labels(first: 100) {
        nodes { id name parent { name } }
        pageInfo { hasNextPage }
      }
      team {
        id
        states(filter: {name: {in: ["Backlog", "Todo"]}}, first: 3) {
          nodes { id name }
        }
      }
    }
  }
  """

  @schedule_prerequisite_mutation """
  mutation SymphonySchedulePrerequisite($issueId: String!, $input: IssueUpdateInput!) {
    issueUpdate(id: $issueId, input: $input) {
      success
      issue { id identifier title url state { id name type } labels { nodes { id } } }
    }
  }
  """

  @create_follow_up_relation_mutation """
  mutation SymphonyCreateFollowUpRelation($input: IssueRelationCreateInput!) {
    issueRelationCreate(input: $input) {
      success
      issueRelation { id }
    }
  }
  """

  @follow_up_relation_lookup_query """
  query SymphonyFollowUpRelationById($relationId: String!) {
    issueRelation(id: $relationId) { id type issue { id } relatedIssue { id } }
  }
  """

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @update_comment_mutation """
  mutation SymphonyUpdateWorkpad($commentId: String!, $body: String!) {
    commentUpdate(id: $commentId, input: {body: $body}) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @label_lookup_query """
  query SymphonyResolveLabelId($issueId: String!, $labelName: String!) {
    issue(id: $issueId) {
      team {
        id
        labels(filter: {name: {eq: $labelName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @create_label_mutation """
  mutation SymphonyCreateLabel($name: String!, $teamId: String!) {
    issueLabelCreate(input: {name: $name, teamId: $teamId}) {
      success
      issueLabel {
        id
      }
    }
  }
  """

  @add_label_mutation """
  mutation SymphonyAddLabel($issueId: String!, $labelId: String!) {
    issueAddLabel(id: $issueId, labelId: $labelId) {
      success
    }
  }
  """

  @remove_label_mutation """
  mutation SymphonyRemoveLabel($issueId: String!, $labelId: String!) {
    issueRemoveLabel(id: $issueId, labelId: $labelId) {
      success
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec fetch_issue_comments(String.t()) ::
          {:ok, %{comments: [term()], truncated: boolean()}} | {:error, term()}
  def fetch_issue_comments(issue_id), do: client_module().fetch_issue_comments(issue_id)

  @spec fetch_issue_dependencies(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_issue_dependencies(issue_id) do
    with {:ok, response} <- client_module().graphql(@dependencies_query, %{issueId: issue_id}) do
      SymphonyElixir.DependencyStatus.from_linear(response, issue_id)
    end
  end

  @spec recently_terminal_issues(pos_integer()) :: {:ok, [term()]} | {:error, term()}
  def recently_terminal_issues(lookback_days),
    do: client_module().recently_terminal_issues(lookback_days)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec create_follow_up(Issue.t(), map()) :: {:ok, map()} | {:error, term()}
  def create_follow_up(%Issue{id: issue_id} = source, attributes)
      when is_binary(issue_id) and is_map(attributes) do
    with :ok <- validate_follow_up_direction(attributes),
         {:ok, context} <- follow_up_context(issue_id, attributes),
         {:ok, follow_up, deduplicated?} <- create_or_fetch_follow_up(source, context, attributes),
         :ok <- ensure_follow_up_relation(source, follow_up, attributes),
         {:ok, follow_up} <- maybe_schedule_prerequisite(follow_up, context) do
      {:ok, Map.put(follow_up, :deduplicated, deduplicated?)}
    end
  end

  @spec update_workpad(String.t(), String.t()) :: :ok | {:error, term()}
  def update_workpad(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, %{comments: comments}} <- fetch_issue_comments(issue_id) do
      case Enum.find(comments, &workpad_comment?/1) do
        %Comment{id: comment_id} when is_binary(comment_id) ->
          update_comment(comment_id, body)

        _missing ->
          create_comment(issue_id, body)
      end
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec add_label(String.t(), String.t()) :: :ok | {:error, :label_missing} | {:error, term()}
  def add_label(issue_id, label_name)
      when is_binary(issue_id) and is_binary(label_name) do
    case ensure_label_id(issue_id, label_name) do
      {:ok, label_id} ->
        with {:ok, response} <-
               client_module().graphql(@add_label_mutation, %{issueId: issue_id, labelId: label_id}),
             true <- get_in(response, ["data", "issueAddLabel", "success"]) == true do
          :ok
        else
          false -> {:error, :add_label_failed}
          {:error, reason} -> {:error, reason}
          _ -> {:error, :add_label_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec remove_label(String.t(), String.t()) ::
          :ok | {:error, :label_missing} | {:error, term()}
  def remove_label(issue_id, label_name)
      when is_binary(issue_id) and is_binary(label_name) do
    with {:ok, label_id} <- resolve_existing_label_id(issue_id, label_name),
         {:ok, response} <-
           client_module().graphql(@remove_label_mutation, %{
             issueId: issue_id,
             labelId: label_id
           }),
         true <- get_in(response, ["data", "issueRemoveLabel", "success"]) == true do
      :ok
    else
      false -> {:error, :remove_label_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :remove_label_failed}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp validate_follow_up_direction(attributes) do
    flags = Enum.map([:depends_on_current, :blocks_current], &attribute(attributes, &1))

    cond do
      Enum.any?(flags, &(&1 not in [nil, false, true])) -> {:error, {:follow_up_configuration, :invalid_dependency_direction}}
      flags == [true, true] -> {:error, {:follow_up_configuration, :cyclic_dependency}}
      true -> :ok
    end
  end

  defp follow_up_context(issue_id, attributes) do
    if truthy_attribute?(attributes, :blocks_current),
      do: prerequisite_context(issue_id),
      else: optional_follow_up_context(issue_id)
  end

  defp optional_follow_up_context(issue_id) do
    with {:ok, response} <- follow_up_graphql(@follow_up_context_query, %{issueId: issue_id}),
         {:ok, issue} <- follow_up_source(get_in(response, ["data", "issue"])),
         {:ok, team_id} <- follow_up_required_id(get_in(issue, ["team", "id"]), :team_missing),
         {:ok, state_id} <-
           follow_up_required_id(
             get_in(issue, ["team", "states", "nodes", Access.at(0), "id"]),
             :backlog_state_missing
           ) do
      {:ok,
       %{
         source_id: issue["id"],
         source_identifier: issue["identifier"],
         source_url: issue["url"],
         team_id: team_id,
         project_id: get_in(issue, ["project", "id"]),
         state_id: state_id
       }}
    end
  end

  defp prerequisite_context(issue_id) do
    with {:ok, response} <- follow_up_graphql(@prerequisite_context_query, %{issueId: issue_id}),
         {:ok, issue} <- follow_up_source(get_in(response, ["data", "issue"])),
         {:ok, team_id} <- follow_up_required_id(get_in(issue, ["team", "id"]), :team_missing),
         {:ok, backlog_id} <- prerequisite_state(issue, "Backlog", :backlog_state_missing),
         {:ok, todo_id} <- prerequisite_state(issue, "Todo", :todo_state_missing),
         :ok <- prerequisite_dispatch_states(),
         {:ok, label_ids} <- prerequisite_label_ids(issue) do
      {:ok,
       %{
         source_id: issue["id"],
         source_identifier: issue["identifier"],
         source_url: issue["url"],
         team_id: team_id,
         project_id: get_in(issue, ["project", "id"]),
         state_id: backlog_id,
         todo_id: todo_id,
         prerequisite_label_ids: label_ids
       }}
    end
  end

  defp prerequisite_state(issue, name, reason) do
    issue
    |> get_in(["team", "states", "nodes"])
    |> List.wrap()
    |> Enum.find_value(fn state -> if state["name"] == name, do: state["id"] end)
    |> follow_up_required_id(reason)
  end

  defp prerequisite_dispatch_states do
    active = Enum.map(Config.settings!().tracker.active_states, &String.downcase/1)

    if "todo" in active and "backlog" not in active,
      do: :ok,
      else: {:error, {:follow_up_configuration, :prerequisite_dispatch_states}}
  end

  defp prerequisite_label_ids(issue) do
    with true <- get_in(issue, ["labels", "pageInfo", "hasNextPage"]) == false,
         {:ok, config} <- RepoConfig.load(),
         labels = get_in(issue, ["labels", "nodes"]) || [],
         {:ok, repo} <- Router.route(%Issue{labels: Enum.map(labels, &qualified_label_name/1)}, config),
         {:ok, routing_id} <- source_label_id(labels, repo.label, :repository_label_missing),
         {:ok, pickup_id} <- source_label_id(labels, config.linear.filter_label, :automation_label_missing) do
      {:ok, Enum.uniq([routing_id, pickup_id])}
    else
      false -> {:error, {:follow_up_configuration, :source_labels_incomplete}}
      {:skip, _, _} -> {:error, {:follow_up_configuration, :source_repository_unresolved}}
      {:skip, _} -> {:error, {:follow_up_configuration, :source_repository_unresolved}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp source_label_id(labels, name, reason) when is_binary(name) and name != "" do
    labels
    |> Enum.find_value(fn label ->
      if String.downcase(qualified_label_name(label)) == String.downcase(name), do: label["id"]
    end)
    |> follow_up_required_id(reason)
  end

  defp source_label_id(_labels, _name, reason), do: {:error, {:follow_up_configuration, reason}}

  defp qualified_label_name(%{"name" => name, "parent" => %{"name" => parent}}), do: "#{parent}:#{name}"
  defp qualified_label_name(%{"name" => name}), do: name
  defp qualified_label_name(_label), do: ""

  defp maybe_schedule_prerequisite(follow_up, %{prerequisite_label_ids: label_ids} = context) do
    with state when is_map(state) <- follow_up[:state],
         type when type in ["backlog", "unstarted", "started", "completed", "canceled"] <- state["type"] do
      schedule_prerequisite(follow_up, context, label_ids, type)
    else
      _ -> {:error, {:follow_up_configuration, :prerequisite_state_unavailable}}
    end
  end

  defp maybe_schedule_prerequisite(follow_up, _context), do: {:ok, follow_up}

  defp schedule_prerequisite(follow_up, _context, _label_ids, type) when type in ["completed", "canceled"],
    do: {:ok, follow_up}

  defp schedule_prerequisite(follow_up, context, label_ids, type) do
    # Publish pickup labels only after the blocking relation is confirmed. A
    # retry may add missing labels, but never rewinds active or terminal work.
    missing_labels = label_ids -- Map.get(follow_up, :label_ids, [])
    input = %{addedLabelIds: missing_labels}
    input = if type == "backlog", do: Map.put(input, :stateId, context.todo_id), else: input

    if missing_labels == [] and type != "backlog" do
      {:ok, follow_up}
    else
      case follow_up_graphql(@schedule_prerequisite_mutation, %{issueId: follow_up.id, input: input}) do
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true, "issue" => issue}}}} ->
          verify_scheduled_prerequisite(issue, follow_up.id, label_ids)

        _ ->
          {:error, :prerequisite_schedule_failed}
      end
    end
  end

  defp verify_scheduled_prerequisite(issue, issue_id, label_ids) do
    scheduled = normalize_follow_up(issue)

    if scheduled.id == issue_id and Enum.all?(label_ids, &(&1 in scheduled.label_ids)) and
         get_in(issue, ["state", "type"]) in ["unstarted", "started", "completed", "canceled"],
       do: {:ok, scheduled},
       else: {:error, :prerequisite_schedule_failed}
  end

  defp follow_up_graphql(query, variables) do
    case client_module().graphql(query, variables) do
      {:ok, %{"errors" => errors}} -> {:error, {:linear_graphql_errors, errors}}
      result -> result
    end
  end

  defp follow_up_source(%{"id" => id} = issue) when is_binary(id) and id != "", do: {:ok, issue}
  defp follow_up_source(_issue), do: {:error, {:follow_up_configuration, :source_issue_missing}}

  defp follow_up_required_id(id, _reason) when is_binary(id) and id != "", do: {:ok, id}
  defp follow_up_required_id(_id, reason), do: {:error, {:follow_up_configuration, reason}}

  defp create_or_fetch_follow_up(source, context, attributes) do
    title = attribute(attributes, :title)
    issue_id = deterministic_uuid("follow-up", context.source_id, title)

    input = %{
      id: issue_id,
      teamId: context.team_id,
      stateId: context.state_id,
      title: title,
      description: follow_up_description(source, attributes)
    }

    input = if is_binary(context.project_id), do: Map.put(input, :projectId, context.project_id), else: input

    case follow_up_graphql(@create_follow_up_mutation, %{input: input}) do
      {:ok, response} ->
        case get_in(response, ["data", "issueCreate"]) do
          %{"success" => true, "issue" => issue} -> {:ok, normalize_follow_up(issue), false}
          _ -> fetch_follow_up(issue_id)
        end

      {:error, _reason} ->
        fetch_follow_up(issue_id)
    end
  end

  defp fetch_follow_up(issue_id) do
    with {:ok, response} <- follow_up_graphql(@follow_up_lookup_query, %{issueId: issue_id}),
         %{"id" => _id} = issue <- get_in(response, ["data", "issue"]) do
      {:ok, normalize_follow_up(issue), true}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :follow_up_create_failed}
    end
  end

  defp ensure_follow_up_relation(%Issue{id: source_id}, %{id: follow_up_id}, attributes) do
    {issue_id, related_id, relation_type} = follow_up_relation(source_id, follow_up_id, attributes)
    relation_id = deterministic_uuid("follow-up-relation:#{relation_type}", issue_id, related_id)

    input = %{
      id: relation_id,
      issueId: issue_id,
      relatedIssueId: related_id,
      type: relation_type
    }

    case follow_up_graphql(@create_follow_up_relation_mutation, %{input: input}) do
      {:ok, response} ->
        if get_in(response, ["data", "issueRelationCreate", "success"]) == true,
          do: :ok,
          else: follow_up_relation_exists?(input)

      {:error, _reason} ->
        follow_up_relation_exists?(input)
    end
  end

  defp follow_up_relation(source_id, follow_up_id, attributes) do
    cond do
      truthy_attribute?(attributes, :blocks_current) -> {follow_up_id, source_id, "blocks"}
      truthy_attribute?(attributes, :depends_on_current) -> {source_id, follow_up_id, "blocks"}
      true -> {source_id, follow_up_id, "related"}
    end
  end

  defp follow_up_relation_exists?(input) do
    with {:ok, response} <-
           follow_up_graphql(@follow_up_relation_lookup_query, %{relationId: input.id}),
         %{"type" => type, "issue" => %{"id" => source}, "relatedIssue" => %{"id" => target}} <-
           get_in(response, ["data", "issueRelation"]),
         true <- type == input.type and source == input.issueId and target == input.relatedIssueId do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :follow_up_relation_create_failed}
    end
  end

  defp follow_up_description(source, attributes) do
    acceptance_criteria = attribute(attributes, :acceptance_criteria)
    evidence = attribute(attributes, :evidence)

    """
    #{attribute(attributes, :description)}

    ## Acceptance criteria

    #{acceptance_criteria}

    ## Discovery evidence

    #{evidence}

    Discovered while working on [#{source.identifier}](#{source.url}). Kept separate to preserve the source ticket's scope.
    """
    |> String.trim()
  end

  defp normalize_follow_up(issue) do
    %{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      url: issue["url"],
      state: issue["state"],
      label_ids: (get_in(issue, ["labels", "nodes"]) || []) |> Enum.map(& &1["id"])
    }
  end

  defp attribute(attributes, key) do
    Map.get(attributes, key) || Map.get(attributes, Atom.to_string(key))
  end

  defp truthy_attribute?(attributes, key), do: attribute(attributes, key) == true

  defp deterministic_uuid(namespace, source_id, discriminator) do
    <<prefix::48, _version::4, middle::12, _variant::2, suffix::62, _rest::binary>> =
      :crypto.hash(:sha256, Enum.join([namespace, source_id, discriminator], "\0"))

    <<prefix::48, 4::4, middle::12, 2::2, suffix::62>>
    |> Base.encode16(case: :lower)
    |> then(fn <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4), e::binary>> ->
      Enum.join([a, b, c, d, e], "-")
    end)
  end

  defp update_comment(comment_id, body) do
    with {:ok, response} <-
           client_module().graphql(@update_comment_mutation, %{
             commentId: comment_id,
             body: body
           }),
         true <- get_in(response, ["data", "commentUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_update_failed}
    end
  end

  defp workpad_comment?(%Comment{body: body}) when is_binary(body) do
    body |> String.trim_leading() |> String.starts_with?("## Codex Workpad")
  end

  defp workpad_comment?(_comment), do: false

  defp resolve_existing_label_id(issue_id, label_name) do
    with {:ok, response} <-
           client_module().graphql(@label_lookup_query, %{
             issueId: issue_id,
             labelName: label_name
           }),
         label_id when is_binary(label_id) <-
           get_in(response, ["data", "issue", "team", "labels", "nodes", Access.at(0), "id"]) do
      {:ok, label_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :label_missing}
    end
  end

  # Resolve the id of `label_name` on the issue's team, creating the label
  # when it does not yet exist. Symphony's marker labels (e.g.
  # `symphony:routing-warned`) are not seeded in the workspace, so a plain
  # lookup returns `:label_missing` and the best-effort `add_label` call at
  # the call site silently no-ops — leaving no idempotency marker and causing
  # warning comments to be re-posted on every poll. Creating the label on
  # first use makes the marker actually land so the warning fires once.
  defp ensure_label_id(issue_id, label_name) do
    with {:ok, response} <-
           client_module().graphql(@label_lookup_query, %{issueId: issue_id, labelName: label_name}) do
      label_id =
        get_in(response, ["data", "issue", "team", "labels", "nodes", Access.at(0), "id"])

      team_id = get_in(response, ["data", "issue", "team", "id"])

      case {label_id, team_id} do
        {label_id, _team_id} when is_binary(label_id) ->
          {:ok, label_id}

        {_label_id, team_id} when is_binary(team_id) ->
          create_label(team_id, label_name)

        _missing_ids ->
          {:error, :label_missing}
      end
    end
  end

  defp create_label(team_id, label_name) do
    with {:ok, response} <-
           client_module().graphql(@create_label_mutation, %{name: label_name, teamId: team_id}),
         label_id when is_binary(label_id) <-
           get_in(response, ["data", "issueLabelCreate", "issueLabel", "id"]) do
      {:ok, label_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :label_create_failed}
    end
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end
end
