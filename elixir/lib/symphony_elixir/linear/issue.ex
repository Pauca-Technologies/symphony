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
          children: [child_summary()],
          attachment_urls: [String.t()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end
end
