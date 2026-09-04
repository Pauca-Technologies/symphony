defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

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

  @create_follow_up_mutation """
  mutation SymphonyCreateFollowUp($input: IssueCreateInput!) {
    issueCreate(input: $input) {
      success
      issue { id identifier title url }
    }
  }
  """

  @follow_up_lookup_query """
  query SymphonyFollowUpById($issueId: String!) {
    issue(id: $issueId) { id identifier title url }
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
    issueRelation(id: $relationId) { id }
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
    with {:ok, context} <- follow_up_context(issue_id),
         {:ok, follow_up, deduplicated?} <- create_or_fetch_follow_up(source, context, attributes),
         :ok <- ensure_follow_up_relation(source, follow_up, attributes) do
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

  defp follow_up_context(issue_id) do
    with {:ok, response} <- client_module().graphql(@follow_up_context_query, %{issueId: issue_id}),
         %{"id" => source_id, "team" => %{"id" => team_id}} = issue <-
           get_in(response, ["data", "issue"]),
         project_id when is_binary(project_id) <- get_in(issue, ["project", "id"]),
         state_id when is_binary(state_id) <-
           get_in(issue, ["team", "states", "nodes", Access.at(0), "id"]) do
      {:ok,
       %{
         source_id: source_id,
         source_identifier: issue["identifier"],
         source_url: issue["url"],
         team_id: team_id,
         project_id: project_id,
         state_id: state_id
       }}
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :follow_up_context_missing}
      _ -> {:error, :follow_up_context_missing}
    end
  end

  defp create_or_fetch_follow_up(source, context, attributes) do
    title = attribute(attributes, :title)
    issue_id = deterministic_uuid("follow-up", context.source_id, title)

    input = %{
      id: issue_id,
      teamId: context.team_id,
      projectId: context.project_id,
      stateId: context.state_id,
      title: title,
      description: follow_up_description(source, attributes)
    }

    case client_module().graphql(@create_follow_up_mutation, %{input: input}) do
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
    with {:ok, response} <- client_module().graphql(@follow_up_lookup_query, %{issueId: issue_id}),
         %{"id" => _id} = issue <- get_in(response, ["data", "issue"]) do
      {:ok, normalize_follow_up(issue), true}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :follow_up_create_failed}
    end
  end

  defp ensure_follow_up_relation(%Issue{id: source_id}, %{id: follow_up_id}, attributes) do
    relation_type = if truthy_attribute?(attributes, :depends_on_current), do: "blocks", else: "related"
    relation_id = deterministic_uuid("follow-up-relation:#{relation_type}", source_id, follow_up_id)

    input = %{
      id: relation_id,
      issueId: source_id,
      relatedIssueId: follow_up_id,
      type: relation_type
    }

    case client_module().graphql(@create_follow_up_relation_mutation, %{input: input}) do
      {:ok, response} ->
        if get_in(response, ["data", "issueRelationCreate", "success"]) == true,
          do: :ok,
          else: follow_up_relation_exists?(relation_id)

      {:error, _reason} ->
        follow_up_relation_exists?(relation_id)
    end
  end

  defp follow_up_relation_exists?(relation_id) do
    with {:ok, response} <-
           client_module().graphql(@follow_up_relation_lookup_query, %{relationId: relation_id}),
         relation when is_map(relation) <- get_in(response, ["data", "issueRelation"]) do
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
      url: issue["url"]
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
