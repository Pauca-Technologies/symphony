defmodule SymphonyElixir.TaskOutcome do
  @moduledoc """
  Emits explicit, versioned task-delivery outcomes.

  Worker transport completion remains a `run_end` concern. These events are
  reserved for task evidence observed at an authoritative Symphony boundary.
  """

  alias SymphonyElixir.Telemetry

  @outcome_version 1

  @type stage :: :material_progress | :exact_head_handoff | :ci | :human_review | :pull_request
  @type status :: :recorded | :accepted | :passed | :failed | :merged | :reopened | :reverted

  @doc "Emit one authoritative task-outcome observation for the current run."
  @spec emit(stage(), status(), map()) :: :ok
  def emit(stage, status, attrs \\ %{}) when is_atom(stage) and is_atom(status) and is_map(attrs) do
    Telemetry.emit(
      :task_outcome,
      Map.merge(attrs, %{
        outcome_version: @outcome_version,
        stage: Atom.to_string(stage),
        status: Atom.to_string(status),
        authoritative: true
      })
    )
  end
end
