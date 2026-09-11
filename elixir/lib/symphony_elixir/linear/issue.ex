defmodule SymphonyElixir.Linear.Issue do
  @moduledoc """
  Normalized Linear issue representation used by the orchestrator.
  """

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    :assignee_display_name,
    :assignee_email,
    :creator_id,
    :creator_display_name,
    :creator_email,
    :parent_id,
    :team_id,
    blocked_by: [],
    labels: [],
    comments: [],
    comments_truncated: false,
    children: [],
    attachment_urls: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]

  @type child_summary :: %{
          id: String.t() | nil,
          identifier: String.t() | nil,
          state: String.t() | nil,
          labels: [String.t()]
        }

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          assignee_display_name: String.t() | nil,
          assignee_email: String.t() | nil,
          creator_id: String.t() | nil,
          creator_display_name: String.t() | nil,
          creator_email: String.t() | nil,
          parent_id: String.t() | nil,
          team_id: String.t() | nil,
          labels: [String.t()],
          comments: [SymphonyElixir.Linear.Comment.t()],
          comments_truncated: boolean(),
          children: [child_summary()],
          attachment_urls: [String.t()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @type dispatch_priority_rank :: 1 | 2 | 3 | 4 | 5

  @doc "Normalize Linear priority for dispatch ordering; unprioritized and unknown values sort last."
  @spec dispatch_priority_rank(term()) :: dispatch_priority_rank()
  def dispatch_priority_rank(priority) when is_integer(priority) and priority in 1..4,
    do: priority

  def dispatch_priority_rank(_priority), do: 5

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end
end
