defmodule SymphonyElixir.Linear.Handoff do
  @moduledoc "Confirms a deferred workflow transition before its worker can finish."

  alias SymphonyElixir.Linear.Issue

  @confirmation_query """
  query SymphonyConfirmHandoff($issueId: String!) {
    issue(id: $issueId) {
      id
      state { name }
    }
  }
  """

  @spec deliver(Issue.t(), String.t(), String.t(), map(), function()) ::
          {:ok, Issue.t()} | {:error, term()}
  def deliver(%Issue{} = issue, target_state, query, variables, client) do
    with {:ok, response} <- client.(query, variables, []),
         :ok <- require_success(response) do
      case get_in(response, ["data", "issueUpdate", "issue"]) do
        nil -> confirm_legacy_transition(issue, target_state, client)
        updated -> confirm_issue(updated, issue, target_state)
      end
    end
  end

  defp require_success(%{"data" => %{"issueUpdate" => %{"success" => true}}} = response) do
    require_no_errors(response)
  end

  defp require_success(_response), do: {:error, :handoff_not_acknowledged}

  defp require_no_errors(response) do
    case Map.get(response, "errors", []) do
      [] -> :ok
      nil -> :ok
      errors -> {:error, {:handoff_graphql_errors, errors}}
    end
  end

  # Older durable requests only selected `success`. Confirm their target with
  # a read; an unavailable or stale result leaves delivery pending for the
  # existing infrastructure retry, without returning to the implementor.
  defp confirm_legacy_transition(issue, target_state, client) do
    with {:ok, response} when is_map(response) <- client.(@confirmation_query, %{"issueId" => issue.id}, []),
         :ok <- require_no_errors(response) do
      confirm_issue(get_in(response, ["data", "issue"]), issue, target_state)
    else
      {:ok, _invalid} -> {:error, :handoff_confirmation_unavailable}
      {:error, _reason} = error -> error
    end
  end

  defp confirm_issue(%{"id" => id, "state" => %{"name" => state}}, %Issue{id: id} = issue, target_state)
       when is_binary(state) do
    if normalize(state) == normalize(target_state) do
      {:ok, %{issue | state: state}}
    else
      {:error, {:handoff_state_mismatch, target_state, state}}
    end
  end

  defp confirm_issue(_updated, _issue, _target_state), do: {:error, :handoff_confirmation_unavailable}

  defp normalize(state), do: state |> String.trim() |> String.downcase()
end
