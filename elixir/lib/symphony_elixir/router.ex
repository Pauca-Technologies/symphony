defmodule SymphonyElixir.Router do
  @moduledoc """
  Label-based per-issue routing for the multi-repo Symphony driver.

  The audit (§9.4) settles on a single routing key: an explicit
  `repo:<name>` Linear label on every dispatchable issue. Project,
  team prefix, and assignee are NOT routing keys.

  Quiet mode: a routing warning is only posted when the issue is in an
  active state AND (assigned to Symphony OR labeled `symphony:pick-up`).
  This stops noise on backlog issues that don't even want Symphony yet.

  Idempotency: the `symphony:routing-warned` label doubles as the marker
  for both routing and cardinality warnings. Presence of the label
  suppresses future writes.
  """

  alias SymphonyElixir.{Linear.Issue, RepoConfig}

  @routing_warned_label "symphony:routing-warned"
  @pickup_label "symphony:pick-up"
  @routing_marker "<!-- symphony:routing-warned -->"

  @type route_decision ::
          {:ok, RepoConfig.repo_entry()}
          | {:skip, :no_label, [String.t()]}
          | {:skip, :no_match, [String.t()]}
          | {:skip, :ambiguous, [RepoConfig.repo_entry()]}
          | {:skip, :legacy_mode}

  @doc """
  Decide which repo (from the loaded `RepoConfig`) handles a given
  `Issue`. When no repos are configured (`source == :default`), returns
  `{:skip, :legacy_mode}` so the orchestrator falls back to the
  single-repo path.
  """
  @spec route(Issue.t(), RepoConfig.t()) :: route_decision()
  def route(%Issue{} = _issue, %{source: :default}) do
    {:skip, :legacy_mode}
  end

  def route(%Issue{} = _issue, %{repos: []}) do
    {:skip, :legacy_mode}
  end

  def route(%Issue{labels: labels} = _issue, %{} = config) do
    repo_labels = Enum.filter(labels, &repo_label?/1)

    case repo_labels do
      [] ->
        {:skip, :no_label, []}

      [single | _] ->
        matches =
          config.repos
          |> Enum.filter(fn repo ->
            normalize(repo.label) in Enum.map(repo_labels, &normalize/1)
          end)

        case matches do
          [repo] -> {:ok, repo}
          [] -> {:skip, :no_match, [single]}
          [_, _ | _] = list -> {:skip, :ambiguous, list}
        end
    end
  end

  @doc """
  True if the issue is eligible for a routing warning under quiet mode:
  must be in an active state, must be assigned to Symphony OR have the
  `symphony:pick-up` label. Caller passes the active-state set so we
  reuse the orchestrator's normalized active-states config.
  """
  @spec eligible_for_warning?(Issue.t(), MapSet.t()) :: boolean()
  def eligible_for_warning?(%Issue{} = issue, %MapSet{} = active_states) do
    active_issue_state?(issue.state, active_states) and
      not already_warned?(issue) and
      (issue.assigned_to_worker == true or @pickup_label in (issue.labels || []))
  end

  def eligible_for_warning?(_issue, _active_states), do: false

  @doc """
  Already-warned check is the cross-condition idempotency marker — the
  same label is reused for routing, cardinality, and give-up warnings.
  """
  @spec already_warned?(Issue.t()) :: boolean()
  def already_warned?(%Issue{labels: labels}) when is_list(labels) do
    @routing_warned_label in labels
  end

  def already_warned?(_issue), do: false

  @doc """
  Build the routing-warning comment body for the issue. Includes the
  fuzzy-match advisory when one or more `repo:*` labels are present but
  none of them map to a configured repo.
  """
  @spec warning_comment(Issue.t(), route_decision(), RepoConfig.t()) :: String.t()
  def warning_comment(%Issue{} = _issue, decision, %{} = config) do
    body =
      case decision do
        {:skip, :no_label, _} ->
          """
          Symphony cannot route this issue: no `repo:<name>` label is set.

          To dispatch this issue, add one of: #{format_label_list(config.repos)}.
          """

        {:skip, :no_match, [observed]} ->
          suggestions = RepoConfig.fuzzy_suggestions(config, [observed])

          """
          Symphony cannot route this issue: label `#{observed}` does not match any \
          configured repo.

          Did you mean: #{format_label_list_from_strings(Enum.take(suggestions, 3))}?

          Configured repos: #{format_label_list(config.repos)}.
          """

        {:skip, :ambiguous, matches} ->
          labels = Enum.map(matches, & &1.label)

          """
          Symphony cannot route this issue: multiple `repo:<name>` labels matched (#{Enum.join(labels, ", ")}).

          Cardinality requires exactly one routing label per issue. Remove all but one.
          """

        _ ->
          "Symphony cannot route this issue."
      end

    [@routing_marker, "", body |> String.trim_trailing(), ""]
    |> Enum.join("\n")
  end

  @spec routing_warned_label() :: String.t()
  def routing_warned_label, do: @routing_warned_label

  @spec pickup_label() :: String.t()
  def pickup_label, do: @pickup_label

  defp repo_label?(label) when is_binary(label) do
    String.starts_with?(String.downcase(String.trim(label)), "repo:")
  end

  defp repo_label?(_), do: false

  defp normalize(label) when is_binary(label) do
    label |> String.trim() |> String.downcase()
  end

  defp normalize(_), do: ""

  defp active_issue_state?(state_name, %MapSet{} = active_states) when is_binary(state_name) do
    MapSet.member?(active_states, state_name |> String.trim() |> String.downcase())
  end

  defp active_issue_state?(_state, _active), do: false

  defp format_label_list(repos) when is_list(repos) do
    repos
    |> Enum.map(& &1.label)
    |> format_label_list_from_strings()
  end

  defp format_label_list_from_strings([]), do: "(none configured)"

  defp format_label_list_from_strings(labels) when is_list(labels) do
    labels
    |> Enum.map(&"`#{&1}`")
    |> Enum.join(", ")
  end
end
