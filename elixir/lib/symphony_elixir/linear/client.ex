defmodule SymphonyElixir.Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Comment, Linear.Issue, Linear.RateLimit, Utf8}

  @issue_page_size 50
  @issue_comment_limit 50
  @max_error_body_log_bytes 1_000

  @query """
  query SymphonyLinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
          displayName
          email
        }
        creator {
          id
          displayName
          email
        }
        team {
          id
        }
        parent {
          id
        }
        children(first: $relationFirst) {
          nodes {
            id
            identifier
            state {
              name
            }
            labels {
              nodes {
                name
                parent {
                  name
                }
              }
            }
          }
        }
        attachments(first: $relationFirst) {
          nodes {
            url
          }
        }
        labels {
          nodes {
            name
            parent {
              name
            }
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_by_team """
  query SymphonyLinearPollByTeam($teamId: ID!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {team: {id: {eq: $teamId}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
          displayName
          email
        }
        creator {
          id
          displayName
          email
        }
        team {
          id
        }
        parent {
          id
        }
        children(first: $relationFirst) {
          nodes {
            id
            identifier
            state {
              name
            }
            labels {
              nodes {
                name
                parent {
                  name
                }
              }
            }
          }
        }
        attachments(first: $relationFirst) {
          nodes {
            url
          }
        }
        labels {
          nodes {
            name
            parent {
              name
            }
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  # Sibling of `@query_by_team` that filters by the team's short key (e.g.
  # "UDPE") instead of the GraphQL ID. Linear's TeamFilter supports both
  # `id: IDComparator` and `key: StringComparator`, and team keys are unique
  # within a workspace — so this is the operator-friendly path. `RepoConfig`
  # auto-detects which to use based on the configured value's shape.
  @query_by_team_key """
  query SymphonyLinearPollByTeamKey($teamKey: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {team: {key: {eq: $teamKey}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
          displayName
          email
        }
        creator {
          id
          displayName
          email
        }
        team {
          id
        }
        parent {
          id
        }
        children(first: $relationFirst) {
          nodes {
            id
            identifier
            state {
              name
            }
            labels {
              nodes {
                name
                parent {
                  name
                }
              }
            }
          }
        }
        attachments(first: $relationFirst) {
          nodes {
            url
          }
        }
        labels {
          nodes {
            name
            parent {
              name
            }
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  # Variants of `@query_by_team` and `@query_by_team_key` that add a
  # `labels: {some: {name: {eq: $filterLabel}}}` filter so the poll only
  # surfaces issues carrying the operator-configured opt-in label
  # (`linear.filter_label` in repos.yaml — e.g. "udpagent"). Two queries
  # rather than one parameterized query because Linear's GraphQL IssueFilter
  # treats `labels: null` ambiguously between "no constraint" and "match
  # nothing" depending on schema version; using two queries removes the
  # ambiguity.
  @query_by_team_with_label """
  query SymphonyLinearPollByTeamWithLabel($teamId: ID!, $stateNames: [String!]!, $filterLabel: String!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {team: {id: {eq: $teamId}}, state: {name: {in: $stateNames}}, labels: {some: {name: {eq: $filterLabel}}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
          displayName
          email
        }
        creator {
          id
          displayName
          email
        }
        team {
          id
        }
        parent {
          id
        }
        children(first: $relationFirst) {
          nodes {
            id
            identifier
            state {
              name
            }
            labels {
              nodes {
                name
                parent {
                  name
                }
              }
            }
          }
        }
        attachments(first: $relationFirst) {
          nodes {
            url
          }
        }
        labels {
          nodes {
            name
            parent {
              name
            }
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_by_team_key_with_label """
  query SymphonyLinearPollByTeamKeyWithLabel($teamKey: String!, $stateNames: [String!]!, $filterLabel: String!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {team: {key: {eq: $teamKey}}, state: {name: {in: $stateNames}}, labels: {some: {name: {eq: $filterLabel}}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
          displayName
          email
        }
        creator {
          id
          displayName
          email
        }
        team {
          id
        }
        parent {
          id
        }
        children(first: $relationFirst) {
          nodes {
            id
            identifier
            state {
              name
            }
            labels {
              nodes {
                name
                parent {
                  name
                }
              }
            }
          }
        }
        attachments(first: $relationFirst) {
          nodes {
            url
          }
        }
        labels {
          nodes {
            name
            parent {
              name
            }
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_by_ids """
  query SymphonyLinearIssuesById($ids: [ID!]!, $first: Int!, $relationFirst: Int!) {
    issues(filter: {id: {in: $ids}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
          displayName
          email
        }
        creator {
          id
          displayName
          email
        }
        team {
          id
        }
        parent {
          id
        }
        children(first: $relationFirst) {
          nodes {
            id
            identifier
            state {
              name
            }
            labels {
              nodes {
                name
                parent {
                  name
                }
              }
            }
          }
        }
        attachments(first: $relationFirst) {
          nodes {
            url
          }
        }
        labels {
          nodes {
            name
            parent {
              name
            }
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @issue_comments_query """
  query SymphonyLinearIssueComments($issueId: String!, $first: Int!) {
    issue(id: $issueId) {
      comments(first: $first, orderBy: updatedAt) {
        nodes {
          id
          body
          createdAt
          updatedAt
          user {
            id
            name
          }
        }
        pageInfo {
          hasNextPage
        }
      }
    }
  }
  """

  @viewer_query """
  query SymphonyLinearViewer {
    viewer {
      id
    }
  }
  """

  # Issue-state-driven worktree GC (T28). Returns terminal-state issues
  # within a lookback window so we can reap their worktrees. NOTE: we do
  # NOT apply `linear.filter_label` here — the dispatcher uses it to
  # decide what to PICK UP, but the GC needs to find worktrees Symphony
  # may have left behind, including for issues whose label was removed
  # after dispatch. Over-fetch is harmless; missing a worktree would
  # leak disk.
  @query_terminal_by_team_since """
  query SymphonyLinearTerminalByTeamSince($teamId: ID!, $stateNames: [String!]!, $since: DateTimeOrDuration!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {team: {id: {eq: $teamId}}, state: {name: {in: $stateNames}}, updatedAt: {gte: $since}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        state {
          name
        }
        team {
          id
        }
        labels {
          nodes {
            name
            parent {
              name
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_terminal_by_team_key_since """
  query SymphonyLinearTerminalByTeamKeySince($teamKey: String!, $stateNames: [String!]!, $since: DateTimeOrDuration!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {team: {key: {eq: $teamKey}}, state: {name: {in: $stateNames}}, updatedAt: {gte: $since}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        state {
          name
        }
        team {
          id
        }
        labels {
          nodes {
            name
            parent {
              name
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker
    team_identifier = configured_team_id()
    filter_label = configured_filter_label()
    project_slug = tracker.project_slug

    cond do
      is_nil(tracker.api_key) ->
        {:error, :missing_linear_api_token}

      # Audit §9.4 multi-repo Symphony: prefer team-scoped polling when a
      # team_id is configured in ~/.symphony/repos.yaml. The value can be a
      # Linear team UUID OR a team key (e.g. "UDPE") — auto-detected by
      # shape. An optional `linear.filter_label` further narrows the poll
      # so Symphony only sees issues that opt in to its scope (e.g. tagged
      # "udpagent"). Falls back to project-slug polling for legacy
      # single-repo deployments.
      is_binary(team_identifier) ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          dispatch_team_fetch(team_identifier, filter_label, tracker.active_states, assignee_filter)
        end

      is_nil(project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_by_states(project_slug, tracker.active_states, assignee_filter)
        end
    end
  end

  # team_identifier may be a Linear team UUID or a team key (e.g. "UDPE"),
  # auto-detected by shape; filter_label optionally narrows the poll.
  defp dispatch_team_fetch(team_identifier, filter_label, active_states, assignee_filter) do
    case {uuid_shaped?(team_identifier), filter_label} do
      {true, nil} ->
        do_fetch_by_team(team_identifier, active_states, assignee_filter)

      {true, label} when is_binary(label) ->
        do_fetch_by_team_with_label(team_identifier, active_states, label, assignee_filter)

      {false, nil} ->
        do_fetch_by_team_key(team_identifier, active_states, assignee_filter)

      {false, label} when is_binary(label) ->
        do_fetch_by_team_key_with_label(team_identifier, active_states, label, assignee_filter)
    end
  end

  defp configured_team_id do
    case SymphonyElixir.RepoConfig.load() do
      {:ok, %{linear: %{team_id: team_id}}} when is_binary(team_id) -> team_id
      _ -> nil
    end
  end

  defp configured_filter_label do
    case SymphonyElixir.RepoConfig.load() do
      {:ok, %{linear: %{filter_label: label}}} when is_binary(label) -> label
      _ -> nil
    end
  end

  # Linear team UUIDs look like "9cfb482a-…" (32 hex digits + 4 dashes).
  # Anything else is treated as a team key (uppercase short identifier like
  # "UDPE") and routed to the `team.key.eq` variant of the poll query.
  defp uuid_shaped?(value) when is_binary(value) do
    Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, value)
  end

  defp uuid_shaped?(_value), do: false

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker
      project_slug = tracker.project_slug

      cond do
        is_nil(tracker.api_key) ->
          {:error, :missing_linear_api_token}

        is_nil(project_slug) ->
          {:error, :missing_linear_project_slug}

        true ->
          do_fetch_by_states(project_slug, normalized_states, nil)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_issue_states(ids, assignee_filter)
        end
    end
  end

  @spec fetch_issue_comments(String.t()) ::
          {:ok, %{comments: [Comment.t()], truncated: boolean()}} | {:error, term()}
  def fetch_issue_comments(issue_id) when is_binary(issue_id) do
    do_fetch_issue_comments(issue_id, &graphql/2)
  end

  @doc """
  Return terminal-state issues that transitioned within the last
  `lookback_days` days. Backs the issue-state-driven worktree GC
  (T28); see `SymphonyElixir.WorkspaceGc`.

  Requires a `linear.team_id` in `~/.symphony/config.yml` (the GC is a
  multi-repo feature — legacy single-repo deployments don't need it
  because their startup cleanup path still works). Returns
  `{:error, :missing_linear_team_id}` if no team is configured.
  """
  @spec recently_terminal_issues(pos_integer()) :: {:ok, [Issue.t()]} | {:error, term()}
  def recently_terminal_issues(lookback_days)
      when is_integer(lookback_days) and lookback_days > 0 do
    tracker = Config.settings!().tracker
    team_identifier = configured_team_id()

    cond do
      is_nil(tracker.api_key) ->
        {:error, :missing_linear_api_token}

      is_nil(team_identifier) ->
        {:error, :missing_linear_team_id}

      true ->
        since = DateTime.utc_now() |> DateTime.add(-lookback_days * 86_400, :second) |> DateTime.to_iso8601()

        if uuid_shaped?(team_identifier) do
          do_fetch_terminal_by_team(team_identifier, tracker.terminal_states, since)
        else
          do_fetch_terminal_by_team_key(team_identifier, tracker.terminal_states, since)
        end
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    request_fun = Keyword.get(opts, :request_fun, &post_graphql_request/2)
    rate_limit_gate? = Keyword.get(opts, :rate_limit_gate, !Keyword.has_key?(opts, :request_fun))

    with :ok <- check_rate_limit(rate_limit_gate?),
         {:ok, headers} <- graphql_headers(),
         {:ok, %{status: 200, body: body}} <- request_fun.(payload, headers) do
      {:ok, body}
    else
      {:ok, response} ->
        case rate_limit_retry_after_ms(response) do
          {:rate_limited, retry_after_ms} ->
            record_rate_limit(rate_limit_gate?, retry_after_ms)

            Logger.warning(
              "Linear GraphQL request rate-limited status=#{response.status} retry_after_ms=#{inspect(retry_after_ms)}" <>
                linear_error_context(payload, response)
            )

            {:error, {:rate_limited, retry_after_ms}}

          :not_rate_limited ->
            Logger.error(
              "Linear GraphQL request failed status=#{response.status}" <>
                linear_error_context(payload, response)
            )

            linear_status_error(response)
        end

      {:error, reason} ->
        Logger.error("Linear GraphQL request failed: #{inspect(reason)}")
        {:error, {:linear_api_request, reason}}
    end
  end

  defp check_rate_limit(true), do: RateLimit.check()
  defp check_rate_limit(false), do: :ok

  defp record_rate_limit(true, retry_after_ms), do: RateLimit.backoff(retry_after_ms)
  defp record_rate_limit(false, _retry_after_ms), do: :ok

  defp linear_status_error(response) do
    case sanitized_graphql_errors(response) do
      [] -> {:error, {:linear_api_status, response.status}}
      errors -> {:error, {:linear_api_status, response.status, errors}}
    end
  end

  # Linear surfaces rate limiting as an HTTP 400 (occasionally 429) whose body
  # carries an `extensions.code == "RATELIMITED"` (or `type == "ratelimited"`)
  # error. Detect it so callers can back off deliberately instead of treating
  # it as a generic API failure and hammering the next poll — the failure mode
  # that let a warning-comment loop pin the account at its hourly ceiling and
  # starve dispatch. `Retry-After` (seconds) is read from the response headers
  # when present; otherwise the caller applies its own default backoff.
  defp rate_limit_retry_after_ms(%{body: body} = response) do
    if rate_limited_body?(body) do
      {:rate_limited, retry_after_header_ms(response)}
    else
      :not_rate_limited
    end
  end

  defp rate_limit_retry_after_ms(_response), do: :not_rate_limited

  defp rate_limited_body?(%{"errors" => errors}) when is_list(errors) do
    Enum.any?(errors, fn
      %{"extensions" => %{"code" => "RATELIMITED"}} -> true
      %{"extensions" => %{"type" => "ratelimited"}} -> true
      _ -> false
    end)
  end

  defp rate_limited_body?(_body), do: false

  defp sanitized_graphql_errors(%{body: %{"errors" => errors}}) when is_list(errors) do
    errors
    |> Enum.take(3)
    |> Enum.map(&sanitize_graphql_error/1)
    |> Enum.reject(&(&1 == %{}))
  end

  defp sanitized_graphql_errors(_response), do: []

  defp sanitize_graphql_error(error) when is_map(error) do
    extensions = Map.get(error, "extensions", %{})

    %{}
    |> put_bounded_error_value("message", Map.get(error, "message"), 500)
    |> put_error_path(Map.get(error, "path"))
    |> put_bounded_error_value("code", Map.get(extensions, "code"), 100)
    |> put_bounded_error_value("type", Map.get(extensions, "type"), 100)
  end

  defp sanitize_graphql_error(_error), do: %{}

  defp put_bounded_error_value(target, key, value, max_bytes) when is_binary(value) do
    Map.put(target, key, Utf8.safe_byte_prefix(value, max_bytes))
  end

  defp put_bounded_error_value(target, _key, _value, _max_bytes), do: target

  defp put_error_path(target, path) when is_list(path) do
    safe_path =
      path
      |> Enum.take(12)
      |> Enum.filter(&(is_binary(&1) or is_integer(&1)))

    if safe_path == [], do: target, else: Map.put(target, "path", safe_path)
  end

  defp put_error_path(target, _path), do: target

  defp retry_after_header_ms(%{headers: headers}) when is_map(headers) do
    headers
    |> header_value("retry-after")
    |> parse_retry_after_seconds()
  end

  defp retry_after_header_ms(_response), do: nil

  defp header_value(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      [value | _] when is_binary(value) -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp parse_retry_after_seconds(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, _rest} when seconds > 0 -> seconds * 1000
      _ -> nil
    end
  end

  defp parse_retry_after_seconds(_value), do: nil

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue, nil)
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, assignee) when is_map(issue) do
    assignee_filter =
      case assignee do
        value when is_binary(value) ->
          case build_assignee_filter(value) do
            {:ok, filter} -> filter
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end

    normalize_issue(issue, assignee_filter)
  end

  @doc false
  @spec next_page_cursor_for_test(map()) :: {:ok, String.t()} | :done | {:error, term()}
  def next_page_cursor_for_test(page_info) when is_map(page_info), do: next_page_cursor(page_info)

  @doc false
  @spec merge_issue_pages_for_test([[Issue.t()]]) :: [Issue.t()]
  def merge_issue_pages_for_test(issue_pages) when is_list(issue_pages) do
    issue_pages
    |> Enum.reduce([], &prepend_page_issues/2)
    |> finalize_paginated_issues()
  end

  @doc false
  @spec fetch_issue_states_by_ids_for_test([String.t()], (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)
      when is_list(issue_ids) and is_function(graphql_fun, 2) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        do_fetch_issue_states(ids, nil, graphql_fun)
    end
  end

  @doc false
  @spec fetch_issue_comments_for_test(String.t(), (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, %{comments: [Comment.t()], truncated: boolean()}} | {:error, term()}
  def fetch_issue_comments_for_test(issue_id, graphql_fun)
      when is_binary(issue_id) and is_function(graphql_fun, 2) do
    do_fetch_issue_comments(issue_id, graphql_fun)
  end

  defp do_fetch_by_states(project_slug, state_names, assignee_filter) do
    do_fetch_by_states_page(project_slug, state_names, assignee_filter, nil, [])
  end

  defp do_fetch_by_team(team_id, state_names, assignee_filter) do
    do_fetch_by_team_page(team_id, state_names, assignee_filter, nil, [])
  end

  defp do_fetch_by_team_page(team_id, state_names, assignee_filter, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql(@query_by_team, %{
             teamId: team_id,
             stateNames: state_names,
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_team_page(team_id, state_names, assignee_filter, next_cursor, updated_acc)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp do_fetch_by_team_key(team_key, state_names, assignee_filter) do
    do_fetch_by_team_key_page(team_key, state_names, assignee_filter, nil, [])
  end

  defp do_fetch_by_team_key_page(team_key, state_names, assignee_filter, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql(@query_by_team_key, %{
             teamKey: team_key,
             stateNames: state_names,
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_team_key_page(team_key, state_names, assignee_filter, next_cursor, updated_acc)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp do_fetch_by_team_with_label(team_id, state_names, filter_label, assignee_filter) do
    do_fetch_by_team_with_label_page(team_id, state_names, filter_label, assignee_filter, nil, [])
  end

  defp do_fetch_by_team_with_label_page(team_id, state_names, filter_label, assignee_filter, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql(@query_by_team_with_label, %{
             teamId: team_id,
             stateNames: state_names,
             filterLabel: filter_label,
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_team_with_label_page(team_id, state_names, filter_label, assignee_filter, next_cursor, updated_acc)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp do_fetch_by_team_key_with_label(team_key, state_names, filter_label, assignee_filter) do
    do_fetch_by_team_key_with_label_page(team_key, state_names, filter_label, assignee_filter, nil, [])
  end

  defp do_fetch_by_team_key_with_label_page(team_key, state_names, filter_label, assignee_filter, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql(@query_by_team_key_with_label, %{
             teamKey: team_key,
             stateNames: state_names,
             filterLabel: filter_label,
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_team_key_with_label_page(team_key, state_names, filter_label, assignee_filter, next_cursor, updated_acc)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp do_fetch_terminal_by_team(team_id, state_names, since) do
    do_fetch_terminal_by_team_page(team_id, state_names, since, nil, [])
  end

  defp do_fetch_terminal_by_team_page(team_id, state_names, since, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql(@query_terminal_by_team_since, %{
             teamId: team_id,
             stateNames: state_names,
             since: since,
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_linear_page_response(body, nil) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_terminal_by_team_page(team_id, state_names, since, next_cursor, updated_acc)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp do_fetch_terminal_by_team_key(team_key, state_names, since) do
    do_fetch_terminal_by_team_key_page(team_key, state_names, since, nil, [])
  end

  defp do_fetch_terminal_by_team_key_page(team_key, state_names, since, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql(@query_terminal_by_team_key_since, %{
             teamKey: team_key,
             stateNames: state_names,
             since: since,
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_linear_page_response(body, nil) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_terminal_by_team_key_page(team_key, state_names, since, next_cursor, updated_acc)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp do_fetch_by_states_page(project_slug, state_names, assignee_filter, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql(@query, %{
             projectSlug: project_slug,
             stateNames: state_names,
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_states_page(project_slug, state_names, assignee_filter, next_cursor, updated_acc)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  defp do_fetch_issue_states(ids, assignee_filter) do
    do_fetch_issue_states(ids, assignee_filter, &graphql/2)
  end

  defp do_fetch_issue_comments(issue_id, graphql_fun)
       when is_binary(issue_id) and is_function(graphql_fun, 2) do
    with {:ok, body} <-
           graphql_fun.(@issue_comments_query, %{issueId: issue_id, first: @issue_comment_limit}),
         {:ok, comments, truncated?} <- decode_issue_comments_response(body) do
      {:ok, %{comments: comments, truncated: truncated?}}
    end
  end

  defp decode_issue_comments_response(%{
         "data" => %{
           "issue" => %{
             "comments" => %{
               "nodes" => comments,
               "pageInfo" => %{"hasNextPage" => has_next_page}
             }
           }
         }
       })
       when is_list(comments) do
    case normalize_comments(comments) do
      {:ok, normalized_comments} ->
        {:ok, Enum.sort_by(normalized_comments, &comment_sort_key/1), has_next_page == true}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_issue_comments_response(%{"data" => %{"issue" => nil}}),
    do: {:error, :linear_issue_not_found}

  defp decode_issue_comments_response(_response), do: {:error, :linear_invalid_comments_payload}

  defp normalize_comment(%{"body" => body} = comment) when is_binary(body) do
    author = Map.get(comment, "user")

    %Comment{
      id: Map.get(comment, "id"),
      body: body,
      author_id: user_field(author, "id"),
      author_name: user_field(author, "name"),
      created_at: parse_datetime(Map.get(comment, "createdAt")),
      updated_at: parse_datetime(Map.get(comment, "updatedAt"))
    }
  end

  defp normalize_comment(_comment), do: nil

  defp normalize_comments(comments) when is_list(comments) do
    Enum.reduce_while(comments, {:ok, []}, fn comment, {:ok, normalized} ->
      case normalize_comment(comment) do
        %Comment{} = value -> {:cont, {:ok, [value | normalized]}}
        nil -> {:halt, {:error, :linear_invalid_comment}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp comment_sort_key(%Comment{} = comment) do
    {
      encode_sort_datetime(comment.updated_at || comment.created_at),
      encode_sort_datetime(comment.created_at),
      comment.id || ""
    }
  end

  defp encode_sort_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_sort_datetime(_value), do: ""

  defp do_fetch_issue_states(ids, assignee_filter, graphql_fun)
       when is_list(ids) and is_function(graphql_fun, 2) do
    issue_order_index = issue_order_index(ids)
    do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, [], issue_order_index)
  end

  defp do_fetch_issue_states_page([], _assignee_filter, _graphql_fun, acc_issues, issue_order_index) do
    acc_issues
    |> finalize_paginated_issues()
    |> sort_issues_by_requested_ids(issue_order_index)
    |> then(&{:ok, &1})
  end

  defp do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, acc_issues, issue_order_index) do
    {batch_ids, rest_ids} = Enum.split(ids, @issue_page_size)

    case graphql_fun.(@query_by_ids, %{
           ids: batch_ids,
           first: length(batch_ids),
           relationFirst: @issue_page_size
         }) do
      {:ok, body} ->
        with {:ok, issues} <- decode_linear_response(body, assignee_filter) do
          updated_acc = prepend_page_issues(issues, acc_issues)
          do_fetch_issue_states_page(rest_ids, assignee_filter, graphql_fun, updated_acc, issue_order_index)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_order_index(ids) when is_list(ids) do
    ids
    |> Enum.with_index()
    |> Map.new()
  end

  defp sort_issues_by_requested_ids(issues, issue_order_index)
       when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp linear_error_context(payload, response) when is_map(payload) do
    operation_name =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    body =
      response
      |> Map.get(:body)
      |> summarize_error_body()

    operation_name <> " body=" <> body
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp graphql_headers do
    case Config.settings!().tracker.api_key do
      nil ->
        {:error, :missing_linear_api_token}

      token ->
        {:ok,
         [
           {"Authorization", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp post_graphql_request(payload, headers) do
    Req.post(Config.settings!().tracker.endpoint,
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
    issues =
      nodes
      |> Enum.map(&normalize_issue(&1, assignee_filter))
      |> Enum.reject(&is_nil(&1))

    {:ok, issues}
  end

  defp decode_linear_response(%{"errors" => errors}, _assignee_filter) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_linear_response(_unknown, _assignee_filter) do
    {:error, :linear_unknown_payload}
  end

  defp decode_linear_page_response(
         %{
           "data" => %{
             "issues" => %{
               "nodes" => nodes,
               "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
             }
           }
         },
         assignee_filter
       ) do
    with {:ok, issues} <- decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
      {:ok, issues, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
    end
  end

  defp decode_linear_page_response(response, assignee_filter), do: decode_linear_response(response, assignee_filter)

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :linear_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp normalize_issue(issue, assignee_filter) when is_map(issue) do
    assignee = issue["assignee"]
    creator = issue["creator"]

    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      priority: parse_priority(issue["priority"]),
      state: get_in(issue, ["state", "name"]),
      branch_name: issue["branchName"],
      url: issue["url"],
      assignee_id: user_field(assignee, "id"),
      assignee_display_name: user_field(assignee, "displayName"),
      assignee_email: user_field(assignee, "email"),
      creator_id: user_field(creator, "id"),
      creator_display_name: user_field(creator, "displayName"),
      creator_email: user_field(creator, "email"),
      team_id: get_in(issue, ["team", "id"]),
      parent_id: get_in(issue, ["parent", "id"]),
      blocked_by: extract_blockers(issue),
      labels: extract_labels(issue),
      children: extract_children(issue),
      attachment_urls: extract_attachment_urls(issue),
      assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
  end

  defp normalize_issue(_issue, _assignee_filter), do: nil

  defp user_field(%{} = user, field) when is_binary(field) do
    case user[field] do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp user_field(_user, _field), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    assignee
    |> assignee_id()
    |> then(fn
      nil -> false
      assignee_id -> MapSet.member?(match_values, assignee_id)
    end)
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_id(%{} = assignee), do: normalize_assignee_match_value(assignee["id"])

  defp routing_assignee_filter do
    case Config.settings!().tracker.assignee do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter()

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp resolve_viewer_assignee_filter do
    case graphql(@viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        case assignee_id(viewer) do
          nil ->
            {:error, :missing_linear_viewer_identity}

          viewer_id ->
            {:ok, %{configured_assignee: "me", match_values: MapSet.new([viewer_id])}}
        end

      {:ok, _body} ->
        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(&label_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp extract_labels(_), do: []

  # A label nested in a Linear label *group* carries the group on `parent`;
  # Linear's `name` is only the leaf. Flatten grouped labels to "<group>:<leaf>"
  # so they match the convention used by repo routing (`repo:<name>`) and
  # `agent.label_presets` (`agent:<name>`) — e.g. the "agent" group's
  # "opencode:kimi2.7" leaf becomes "agent:opencode:kimi2.7". Ungrouped labels
  # keep their bare name. (`Enum.uniq` above collapses a grouped label and a
  # legacy flat label of the same qualified name to one entry.)
  defp label_name(%{"name" => name, "parent" => %{"name" => parent}})
       when is_binary(name) and is_binary(parent) do
    "#{parent}:#{name}"
  end

  defp label_name(%{"name" => name}) when is_binary(name), do: name
  defp label_name(_node), do: nil

  defp extract_children(%{"children" => %{"nodes" => children}}) when is_list(children) do
    Enum.map(children, fn child ->
      %{
        id: child["id"],
        identifier: child["identifier"],
        state: get_in(child, ["state", "name"]),
        labels: extract_labels(child)
      }
    end)
  end

  defp extract_children(_), do: []

  defp extract_attachment_urls(%{"attachments" => %{"nodes" => nodes}}) when is_list(nodes) do
    nodes
    |> Enum.map(& &1["url"])
    |> Enum.reject(&is_nil/1)
  end

  defp extract_attachment_urls(_), do: []

  defp extract_blockers(%{"inverseRelations" => %{"nodes" => inverse_relations}})
       when is_list(inverse_relations) do
    inverse_relations
    |> Enum.flat_map(fn
      %{"type" => relation_type, "issue" => blocker_issue}
      when is_binary(relation_type) and is_map(blocker_issue) ->
        if String.downcase(String.trim(relation_type)) == "blocks" do
          [
            %{
              id: blocker_issue["id"],
              identifier: blocker_issue["identifier"],
              state: get_in(blocker_issue, ["state", "name"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil
end
