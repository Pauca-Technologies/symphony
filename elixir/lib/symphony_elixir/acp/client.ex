defmodule SymphonyElixir.Acp.Client do
  @moduledoc """
  ACP (Agent Client Protocol) backend.

  **Phase 1 scaffolding only.** This is an inert placeholder that conforms to
  `SymphonyElixir.AgentBackend` so the backend selector compiles and dispatches.
  The real implementation — initialize/session-new/session-prompt over stdio,
  the in-VM gated `linear_graphql` MCP endpoint, and `session/update`
  normalization — lands in Phase 2. See `docs/acp-support-plan.md`.
  """

  @behaviour SymphonyElixir.AgentBackend

  require Logger

  @impl true
  def start_session(_workspace, _opts) do
    Logger.error("ACP backend selected but not yet implemented (Phase 1 scaffolding). See docs/acp-support-plan.md")
    {:error, :acp_not_implemented}
  end

  @impl true
  def run_turn(_session, _prompt, _issue, _opts), do: {:error, :acp_not_implemented}

  @impl true
  def stop_session(_session), do: :ok
end
