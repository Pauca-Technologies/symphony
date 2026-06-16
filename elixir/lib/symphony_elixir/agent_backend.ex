defmodule SymphonyElixir.AgentBackend do
  @moduledoc """
  Behaviour for pluggable coding-agent backends.

  Symphony drives a coding agent through a small session lifecycle —
  `start_session/2`, `run_turn/4`, `stop_session/1` — and consumes a fixed
  `on_message` event vocabulary (see `SymphonyElixir.Codex.AppServer`). Each
  backend speaks whatever wire protocol its agent uses (Codex app-server
  JSON-RPC, ACP, ...) but conforms to this behaviour and emits the same events,
  so `AgentRunner` and the observability pipeline stay backend-agnostic.

  The active backend is selected by `agent.backend` config
  ("codex" | "acp" | "claude_code") and resolved via `resolve/0`. See
  `docs/acp-support-plan.md`.
  """

  alias SymphonyElixir.Config

  @callback start_session(workspace :: Path.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback run_turn(session :: map(), prompt :: String.t(), issue :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback stop_session(session :: map()) :: :ok

  @default_backend SymphonyElixir.Codex.AppServer
  @backends %{
    "codex" => SymphonyElixir.Codex.AppServer,
    "acp" => SymphonyElixir.Acp.Client,
    "claude_code" => SymphonyElixir.ClaudeCode.Client
  }

  @doc "Resolve the configured backend module (defaults to the Codex app-server)."
  @spec resolve() :: module()
  def resolve, do: resolve(Config.settings!().agent.backend)

  @spec resolve(String.t() | nil) :: module()
  def resolve(backend) when is_binary(backend), do: Map.get(@backends, backend, @default_backend)
  def resolve(_backend), do: @default_backend
end
