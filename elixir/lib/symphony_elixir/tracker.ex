defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.{Config, Linear.Issue}

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_comments(String.t()) ::
              {:ok, %{comments: [term()], truncated: boolean()}} | {:error, term()}
  @callback recently_terminal_issues(pos_integer()) :: {:ok, [term()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback create_follow_up(Issue.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback update_workpad(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  @callback add_label(String.t(), String.t()) :: :ok | {:error, :label_missing} | {:error, term()}
  @callback remove_label(String.t(), String.t()) :: :ok | {:error, :label_missing} | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @doc """
  Return tracker issues that transitioned to a terminal state within
  the last `lookback_days` days. Backs the issue-state-driven worktree
  GC (T28); see `SymphonyElixir.WorkspaceGc`.
  """
  @spec recently_terminal_issues(pos_integer()) :: {:ok, [term()]} | {:error, term()}
  def recently_terminal_issues(lookback_days)
      when is_integer(lookback_days) and lookback_days > 0 do
    adapter().recently_terminal_issues(lookback_days)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec fetch_issue_comments(String.t()) ::
          {:ok, %{comments: [term()], truncated: boolean()}} | {:error, term()}
  def fetch_issue_comments(issue_id) do
    adapter().fetch_issue_comments(issue_id)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @doc "Create or return a deterministic same-project follow-up for the current issue."
  @spec create_follow_up(Issue.t(), map()) :: {:ok, map()} | {:error, term()}
  def create_follow_up(%Issue{} = issue, attributes) when is_map(attributes) do
    adapter().create_follow_up(issue, attributes)
  end

  @spec update_workpad(String.t(), String.t()) :: :ok | {:error, term()}
  def update_workpad(issue_id, body) do
    adapter().update_workpad(issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @spec add_label(String.t(), String.t()) :: :ok | {:error, :label_missing} | {:error, term()}
  def add_label(issue_id, label_name) do
    adapter().add_label(issue_id, label_name)
  end

  @spec remove_label(String.t(), String.t()) ::
          :ok | {:error, :label_missing} | {:error, term()}
  def remove_label(issue_id, label_name) do
    adapter().remove_label(issue_id, label_name)
  end

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().tracker.kind do
      "memory" -> SymphonyElixir.Tracker.Memory
      _ -> SymphonyElixir.Linear.Adapter
    end
  end
end
