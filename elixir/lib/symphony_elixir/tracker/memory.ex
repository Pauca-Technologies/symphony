defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Issue

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    case Application.get_env(:symphony_elixir, :memory_tracker_candidate_issues_result) do
      nil -> {:ok, issue_entries()}
      result -> result
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    # Tests can pin this call's result independently of the configured issue
    # list so the dispatch revalidation (which re-reads states by id) can
    # diverge from `fetch_candidate_issues` — the divergence that strands a
    # claim in the orchestrator retry path. Defaults to filtering the shared
    # issue list by id.
    case Application.get_env(:symphony_elixir, :memory_tracker_states_by_ids_result) do
      nil ->
        wanted_ids = MapSet.new(issue_ids)

        {:ok,
         Enum.filter(issue_entries(), fn %Issue{id: id} ->
           MapSet.member?(wanted_ids, id)
         end)}

      result ->
        result
    end
  end

  @spec fetch_issue_comments(String.t()) ::
          {:ok, %{comments: [term()], truncated: boolean()}} | {:error, term()}
  def fetch_issue_comments(issue_id) do
    comments_by_issue =
      Application.get_env(:symphony_elixir, :memory_tracker_comments_by_issue, %{})

    {:ok,
     Map.get(comments_by_issue, issue_id, %{
       comments: [],
       truncated: false
     })}
  end

  @spec recently_terminal_issues(pos_integer()) :: {:ok, [Issue.t()]} | {:error, term()}
  def recently_terminal_issues(_lookback_days) do
    # Tests configure this list directly under
    # `:memory_tracker_recently_terminal_issues` (defaults to []), so
    # the GC pass under WorkspaceGc gets a deterministic input without
    # the Memory adapter having to model `updatedAt` windows.
    {:ok, Application.get_env(:symphony_elixir, :memory_tracker_recently_terminal_issues, [])}
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    send_event({:memory_tracker_comment, issue_id, body})
    :ok
  end

  @spec update_workpad(String.t(), String.t()) :: :ok | {:error, term()}
  def update_workpad(issue_id, body) do
    send_event({:memory_tracker_workpad, issue_id, body})
    :ok
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    send_event({:memory_tracker_state_update, issue_id, state_name})
    :ok
  end

  @spec add_label(String.t(), String.t()) :: :ok | {:error, :label_missing} | {:error, term()}
  def add_label(issue_id, label_name) do
    available = Application.get_env(:symphony_elixir, :memory_tracker_available_labels, :all)

    cond do
      available == :all ->
        send_event({:memory_tracker_add_label, issue_id, label_name})
        :ok

      is_list(available) and label_name in available ->
        send_event({:memory_tracker_add_label, issue_id, label_name})
        :ok

      is_list(available) ->
        send_event({:memory_tracker_add_label_missing, issue_id, label_name})
        {:error, :label_missing}
    end
  end

  @spec remove_label(String.t(), String.t()) ::
          :ok | {:error, :label_missing} | {:error, term()}
  def remove_label(issue_id, label_name) do
    send_event({:memory_tracker_remove_label, issue_id, label_name})
    :ok
  end

  defp configured_issues do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  defp send_event(message) do
    case Application.get_env(:symphony_elixir, :memory_tracker_recipient) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
