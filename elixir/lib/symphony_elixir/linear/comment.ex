defmodule SymphonyElixir.Linear.Comment do
  @moduledoc """
  Normalized Linear issue comment included in trusted agent context.
  """

  defstruct [:id, :body, :author_id, :author_name, :created_at, :updated_at]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          body: String.t(),
          author_id: String.t() | nil,
          author_name: String.t() | nil,
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }
end
