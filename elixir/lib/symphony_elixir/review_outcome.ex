defmodule SymphonyElixir.ReviewOutcome do
  @moduledoc """
  Evidence carried by every terminal automated-review outcome.

  Review approval is intentionally represented separately from handoff
  success. A caller may apply a deferred tracker mutation only when an
  `:approved` outcome is authoritative for the pinned candidate SHA and that
  SHA is still current.
  """

  @type name ::
          :approved
          | :request_changes
          | :automation_inconclusive
          | :infrastructure_unavailable
          | :budget_exhausted_with_findings

  @enforce_keys [:outcome, :iteration, :max_iterations, :resume_condition]
  defstruct [
    :outcome,
    :iteration,
    :max_iterations,
    :reviewed_sha,
    :summary,
    :failure_reason,
    :resume_condition,
    :review_effort,
    :attempts,
    authoritative: false,
    findings: [],
    severity_counts: %{}
  ]

  @type t :: %__MODULE__{
          outcome: name(),
          iteration: non_neg_integer(),
          max_iterations: pos_integer(),
          reviewed_sha: String.t() | nil,
          summary: String.t() | nil,
          failure_reason: term() | nil,
          resume_condition: String.t(),
          review_effort: SymphonyElixir.ReviewGate.review_effort() | nil,
          attempts: pos_integer() | nil,
          authoritative: boolean(),
          findings: [map()],
          severity_counts: %{optional(String.t()) => non_neg_integer()}
        }

  @doc "Return a dashboard- and JSON-safe map for an automated-review outcome."
  @spec to_map(t() | nil) :: map() | nil
  def to_map(nil), do: nil

  def to_map(%__MODULE__{} = outcome) do
    %{
      outcome: Atom.to_string(outcome.outcome),
      iteration: outcome.iteration,
      max_iterations: outcome.max_iterations,
      reviewed_sha: outcome.reviewed_sha,
      summary: outcome.summary,
      failure_reason: format_reason(outcome.failure_reason),
      resume_condition: outcome.resume_condition,
      review_effort: atom_to_string(outcome.review_effort),
      attempts: outcome.attempts,
      authoritative: outcome.authoritative,
      findings: outcome.findings,
      severity_counts: outcome.severity_counts
    }
  end

  defp format_reason(nil), do: nil
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason, limit: 30, printable_limit: 1_000)

  defp atom_to_string(nil), do: nil
  defp atom_to_string(value) when is_atom(value), do: Atom.to_string(value)
end
