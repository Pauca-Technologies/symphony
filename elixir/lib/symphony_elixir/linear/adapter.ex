defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Client

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
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

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
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
