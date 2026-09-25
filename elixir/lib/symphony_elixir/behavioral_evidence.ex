defmodule SymphonyElixir.BehavioralEvidence do
  @moduledoc "Task-sized behavioral proof guidance shared by implementation and review."

  alias SymphonyElixir.PromptSection

  @doc "Add a compact, reusable behavioral-evidence contract to implementation turns."
  @spec prompt_section(map() | nil) :: PromptSection.t()
  def prompt_section(decision) do
    task_type = if is_map(decision), do: decision[:task_type], else: nil

    PromptSection.new(
      id: "symphony.behavioral_evidence",
      type: :behavioral_evidence,
      source: "symphony:behavioral_evidence",
      version: "behavioral-evidence/v1",
      ownership: :symphony,
      reusable: true,
      content: """
      ## Behavioral evidence

      When changing behavior, map each acceptance criterion to a concrete observable result and
      the focused check that proves it. For a bug fix, reproduce the reported failure before the
      fix when practical; explain when that cannot be done. A large passing suite alone does not
      prove a missing interaction. Keep the map in the existing workpad, not a new required artifact.
      #{task_guidance(task_type)}
      Resolve the preserved in-scope review findings and verify their failure cases. Separate optional
      scope expansion from defects in the requested behavior. On delivery-only resumes, reuse valid
      evidence and perform only checks invalidated by the changed candidate, policy, or external state.
      """
    )
  end

  @doc "Focused final-review guidance that does not substitute test counts for acceptance proof."
  @spec review_guidance() :: String.t()
  def review_guidance do
    """
    Reconcile each acceptance criterion with concrete behavioral evidence. Inspect combinations the
    tests omit, not just the number of passing tests. For concurrency-sensitive changes, trace every
    entry point (including bootstrap, reload/resume, stale clients and cancellation where applicable)
    against the authoritative state and relevant interleavings. For UI changes, verify normal,
    loading/error and accessibility states relevant to the task. For workflow changes, check
    production-shaped ownership and boundary cases. Preserve the identity and failure scenario of
    unresolved findings; distinguish new in-scope defects from optional follow-up work.
    """
  end

  defp task_guidance("concurrency_liveness") do
    "Inventory readers, writers, authoritative state and guards across all applicable entry points, including bootstrap, reload/resume, cancellation and stale clients. Cover the combined states and interleavings that can violate the invariant."
  end

  defp task_guidance("ui") do
    "Cover the task's normal, loading, error and accessibility states, including reduced motion when animation is affected."
  end

  defp task_guidance(_task_type) do
    "Use production-shaped boundary cases for workflow or validation changes; for stateful work, include the relevant combined states and alternate entry points."
  end
end
