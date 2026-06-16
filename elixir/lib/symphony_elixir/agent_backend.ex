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
  ("codex" | "acp" | "claude_code") and resolved via `resolve/0`. It can also
  be chosen per task from the issue's Linear labels via `resolve_for_issue/1`
  (see `agent.label_presets` and §15 of `docs/acp-support-plan.md`).
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

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

  @doc """
  Reverse-map a backend module to its config name (e.g.
  `SymphonyElixir.Codex.AppServer` -> `"codex"`).

  Used to label the *actual* backend a run is using in the dashboard. Returns
  `nil` for a module that isn't a registered backend.
  """
  @spec backend_name(module()) :: String.t() | nil
  def backend_name(module) when is_atom(module) do
    Enum.find_value(@backends, fn {name, mod} -> if mod == module, do: name end)
  end

  def backend_name(_module), do: nil

  @doc """
  Resolve the backend module **and per-task overrides** for a given issue.

  The first `agent.label_presets` entry whose `label` is present on the issue
  wins (positional precedence — list order, first match). Its `backend` and
  `model` become the result. An unmatched issue (or empty `label_presets`)
  falls through to the global `agent.backend` with empty overrides, i.e.
  identical to `{resolve(), %{}}`.

  Overrides carry only keys the chosen backend consumes today — `%{model:
  String.t()}` for "acp"/"claude_code", and always `%{}` for "codex" (Codex has
  no per-task model). Empty overrides leave each backend's `start_session/2`
  byte-for-byte unchanged from the global-config path.
  """
  @spec resolve_for_issue(Issue.t() | map() | nil) :: {module(), map()}
  def resolve_for_issue(issue) do
    resolve_for_labels(Config.settings!().agent, issue_labels(issue))
  end

  @doc false
  @spec resolve_for_labels(map(), [String.t()]) :: {module(), map()}
  def resolve_for_labels(agent, labels) when is_list(labels) do
    presets = Map.get(agent, :label_presets) || []

    case Enum.find(presets, fn preset -> preset.label in labels end) do
      nil -> {resolve(agent.backend), %{}}
      preset -> {resolve(preset.backend), overrides_for(preset)}
    end
  end

  defp overrides_for(%{backend: "codex"}), do: %{}

  defp overrides_for(%{model: model}) when is_binary(model) and model != "",
    do: %{model: model}

  defp overrides_for(_preset), do: %{}

  defp issue_labels(%Issue{} = issue), do: Issue.label_names(issue)
  defp issue_labels(%{labels: labels}) when is_list(labels), do: labels
  defp issue_labels(_issue), do: []
end
