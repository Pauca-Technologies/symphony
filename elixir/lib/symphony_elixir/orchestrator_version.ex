defmodule SymphonyElixir.OrchestratorVersion do
  @moduledoc """
  Implements the `orchestrator_version_required` WORKFLOW.md gate
  (audit §9.4 / implementation plan T24 sub-step 7).

  Consumer repos can pin a minimum Symphony version by adding a
  top-level `orchestrator_version_required: ">= 0.2.0"` key to their
  WORKFLOW.md frontmatter. Symphony reads this on each dispatch tick
  and, if its own version does not satisfy the requirement, posts one
  Linear comment and skips the issue. The same `symphony:routing-warned`
  label gates duplicate comments.

  Requirement format: any string accepted by `Version.match?/2` (e.g.
  `~> 0.1`, `>= 0.2.0`).
  """

  alias SymphonyElixir.Workflow

  @doc """
  Read the requirement string from WORKFLOW.md frontmatter, or `nil` if
  not configured.
  """
  @spec required() :: String.t() | nil
  def required do
    case Workflow.current() do
      {:ok, %{config: %{} = config}} ->
        case Map.get(config, "orchestrator_version_required") do
          value when is_binary(value) and value != "" -> value
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Symphony's own running version (from `mix.exs`).
  """
  @spec current() :: String.t()
  def current do
    case :application.get_key(:symphony_elixir, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _ -> "0.0.0"
    end
  end

  @doc """
  Check the current Symphony version against the WORKFLOW.md requirement.
  Returns `:ok` if no requirement is set or the version satisfies it,
  `{:incompatible, requirement, current}` otherwise.
  """
  @spec check() :: :ok | {:incompatible, String.t(), String.t()} | {:invalid_requirement, String.t()}
  def check do
    case required() do
      nil ->
        :ok

      requirement ->
        try do
          if Version.match?(current(), requirement) do
            :ok
          else
            {:incompatible, requirement, current()}
          end
        rescue
          _ -> {:invalid_requirement, requirement}
        end
    end
  end

  @doc """
  Comment body to post on issues that hit the version gate. Idempotent
  via the cross-condition routing-warned marker.
  """
  @spec incompatibility_comment(String.t(), String.t()) :: String.t()
  def incompatibility_comment(requirement, current_version) do
    """
    <!-- symphony:routing-warned -->
    Symphony version mismatch.

    This repo's `WORKFLOW.md` requires `orchestrator_version_required: \"#{requirement}\"`, \
    but the running Symphony orchestrator is at version `#{current_version}`. The issue \
    has been skipped — bump the orchestrator, or relax the requirement.
    """
  end
end
