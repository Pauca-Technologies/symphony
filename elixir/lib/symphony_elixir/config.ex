defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.{AgentRouting, Schema}
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @type acp_runtime_settings :: %{
          command: String.t(),
          model: String.t() | nil,
          auto_approve: boolean(),
          protocol_version: integer(),
          withhold_linear_credentials: boolean(),
          advertise_fs: boolean(),
          advertise_terminal: boolean(),
          prompt_timeout_ms: integer(),
          read_timeout_ms: integer(),
          stall_timeout_ms: integer(),
          heartbeat_ms: integer()
        }

  @type claude_code_runtime_settings :: %{
          command: String.t(),
          model: String.t() | nil,
          permission_mode: String.t(),
          extra_args: [String.t()],
          prompt_timeout_ms: integer(),
          stall_timeout_ms: integer(),
          withhold_linear_credentials: boolean()
        }

  @type review_settings :: %{
          max_iterations: pos_integer(),
          verdict_path: Path.t(),
          packet_path: Path.t(),
          packet_max_bytes: pos_integer(),
          context_budget_tokens: pos_integer(),
          turn_budget: pos_integer(),
          turn_timeout_ms: pos_integer(),
          tool_output_max_bytes: pos_integer(),
          model: String.t() | nil,
          reasoning_effort: String.t() | nil,
          require_pr: boolean(),
          pr_section_enabled: boolean(),
          section_heading: String.t()
        }

  @default_review_settings %{
    max_iterations: 3,
    verdict_path: ".artifacts/symphony-review/verdict.json",
    packet_path: ".artifacts/symphony-review/packet.v1.json",
    packet_max_bytes: 48_000,
    context_budget_tokens: 12_000,
    turn_budget: 1,
    turn_timeout_ms: 900_000,
    tool_output_max_bytes: 4_000,
    model: nil,
    reasoning_effort: nil,
    require_pr: true,
    pr_section_enabled: true,
    section_heading: "## 🤖 How to review this PR"
  }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    # T27 follow-up: host-level Symphony config lives in
    # `~/.symphony/config.yml` (or `repos.yaml` legacy alias). When that
    # file is present and carries any host-level block (tracker/codex/
    # polling/etc.), parse host settings from there. The host file does
    # NOT have any hooks or prompt — those come per-repo from each
    # consumer's own WORKFLOW.md, loaded by AgentRunner at dispatch.
    #
    # Falls back to WORKFLOW.md only for the legacy single-repo setup
    # (no `~/.symphony/config.yml` and no host blocks in repos.yaml).
    case SymphonyElixir.RepoConfig.load_yaml() do
      {:ok, yaml} when is_map(yaml) ->
        if SymphonyElixir.RepoConfig.host_config?(yaml) do
          Schema.parse(yaml)
        else
          settings_from_workflow_md()
        end

      {:ok, nil} ->
        settings_from_workflow_md()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp settings_from_workflow_md do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @doc """
  Human-readable description of a `settings/0` error `reason`, identical to
  the message `settings!/0` would raise. Lets callers that deliberately take
  the non-raising `settings/0` path — e.g. the orchestrator poll loop, which
  must tolerate a transiently-invalid config instead of crashing (UDPE-6990)
  — log the same detail without triggering the crash.
  """
  @spec describe_error(term()) :: String.t()
  def describe_error(reason), do: format_config_error(reason)

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @doc """
  Parse the optional repository-owned agent-routing block from a loaded
  workflow. Host runtime settings remain in the ordinary `Config` schema;
  routing profiles are deliberately read from the routed repository workflow.
  """
  @spec agent_routing_settings(Workflow.loaded_workflow() | nil) ::
          {:ok, AgentRouting.t() | nil} | {:error, term()}
  def agent_routing_settings(%{config: config}) when is_map(config),
    do: AgentRouting.parse(config)

  def agent_routing_settings(nil), do: {:ok, nil}

  def agent_routing_settings(_workflow),
    do: {:error, {:invalid_agent_routing, "repository workflow must contain a config map"}}

  @doc """
  Resolve repository-owned automated-review settings from `WORKFLOW_REVIEW.md`.

  Review configuration is deliberately separate from host runtime settings: the
  repository owns its review evidence contract and budgets, while Symphony
  enforces safe minima and the one-turn fresh-thread contract.
  """
  @spec review_settings(Workflow.loaded_workflow() | nil) :: review_settings()
  def review_settings(%{config: config}) when is_map(config) do
    raw = Map.get(config, "review", %{}) || %{}

    @default_review_settings
    |> Map.put(:max_iterations, bounded_integer(raw, "max_iterations", 1, 20, 3))
    |> Map.put(:verdict_path, non_blank(raw, "verdict_path", @default_review_settings.verdict_path))
    |> Map.put(:packet_path, non_blank(raw, "packet_path", @default_review_settings.packet_path))
    |> Map.put(:packet_max_bytes, bounded_integer(raw, "packet_max_bytes", 8_192, 262_144, 48_000))
    |> Map.put(
      :context_budget_tokens,
      bounded_integer(raw, "context_budget_tokens", 6_144, 65_536, 12_000)
    )
    |> Map.put(:turn_budget, 1)
    |> Map.put(:turn_timeout_ms, bounded_integer(raw, "turn_timeout_ms", 30_000, 3_600_000, 900_000))
    |> Map.put(
      :tool_output_max_bytes,
      bounded_integer(raw, "tool_output_max_bytes", 512, 32_768, 4_000)
    )
    |> Map.put(:model, optional_non_blank(raw, "model"))
    |> Map.put(:reasoning_effort, optional_non_blank(raw, "reasoning_effort"))
    |> Map.put(:require_pr, boolean_value(raw, "require_pr", true))
    |> Map.put(:pr_section_enabled, boolean_value(raw, "pr_section_enabled", true))
    |> Map.put(
      :section_heading,
      non_blank(raw, "section_heading", @default_review_settings.section_heading)
    )
  end

  def review_settings(_workflow), do: @default_review_settings

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  @doc """
  Resolve the ACP backend's runtime settings from the `acp` config block as a
  plain map (see `SymphonyElixir.Acp.Client`).
  """
  @spec acp_runtime_settings() :: {:ok, acp_runtime_settings()} | {:error, term()}
  def acp_runtime_settings do
    with {:ok, settings} <- settings() do
      acp = settings.acp

      {:ok,
       %{
         command: acp.command,
         model: acp.model,
         auto_approve: acp.auto_approve,
         protocol_version: acp.protocol_version,
         withhold_linear_credentials: acp.withhold_linear_credentials,
         advertise_fs: acp.advertise_fs,
         advertise_terminal: acp.advertise_terminal,
         prompt_timeout_ms: acp.prompt_timeout_ms,
         read_timeout_ms: acp.read_timeout_ms,
         stall_timeout_ms: acp.stall_timeout_ms,
         heartbeat_ms: acp.heartbeat_ms
       }}
    end
  end

  @doc """
  Resolve the native Claude Code backend's runtime settings from the
  `claude_code` config block as a plain map (see
  `SymphonyElixir.ClaudeCode.Client`).
  """
  @spec claude_code_runtime_settings() ::
          {:ok, claude_code_runtime_settings()} | {:error, term()}
  def claude_code_runtime_settings do
    with {:ok, settings} <- settings() do
      claude_code = settings.claude_code

      {:ok,
       %{
         command: claude_code.command,
         model: claude_code.model,
         permission_mode: claude_code.permission_mode,
         extra_args: claude_code.extra_args,
         prompt_timeout_ms: claude_code.prompt_timeout_ms,
         stall_timeout_ms: claude_code.stall_timeout_ms,
         withhold_linear_credentials: claude_code.withhold_linear_credentials
       }}
    end
  end

  @doc """
  Resolve the stall timeout (ms) for the RUNNING backend named `backend`
  (UDPE-6952).

  Stall/turn/review timeouts were historically codex-namespaced but governed
  every backend. Resolve them from the running backend's own config namespace
  instead, falling back to the codex value only where the backend has none.
  `nil`/unknown backend names are treated as codex.
  """
  @spec backend_stall_timeout_ms(String.t() | nil) :: integer()
  def backend_stall_timeout_ms(backend),
    do: resolve_backend_stall_timeout_ms(settings!(), backend)

  @doc """
  Resolve the turn timeout (ms) for the RUNNING backend named `backend`
  (UDPE-6952).

  ACP and Claude Code expose the turn-timeout equivalent as `prompt_timeout_ms`;
  codex uses `turn_timeout_ms`. `nil`/unknown backend names fall back to the
  codex `turn_timeout_ms`.
  """
  @spec backend_turn_timeout_ms(String.t() | nil) :: integer()
  def backend_turn_timeout_ms(backend),
    do: resolve_backend_turn_timeout_ms(settings!(), backend)

  @doc """
  Resolve the deferred-review timeout (ms) for the RUNNING backend named
  `backend` (UDPE-6952).

  Mirrors the codex-only rule, but per backend: use the backend's stall timeout
  when positive, otherwise its turn timeout. `nil`/unknown backend names fall
  back to codex. Both timeouts come from a single `settings!/0` read.
  """
  @spec backend_review_timeout_ms(String.t() | nil) :: integer()
  def backend_review_timeout_ms(backend) do
    settings = settings!()
    stall = resolve_backend_stall_timeout_ms(settings, backend)

    if stall > 0 do
      stall
    else
      resolve_backend_turn_timeout_ms(settings, backend)
    end
  end

  defp resolve_backend_stall_timeout_ms(settings, "codex"), do: settings.codex.stall_timeout_ms
  defp resolve_backend_stall_timeout_ms(settings, "acp"), do: settings.acp.stall_timeout_ms

  defp resolve_backend_stall_timeout_ms(settings, "claude_code"),
    do: settings.claude_code.stall_timeout_ms

  defp resolve_backend_stall_timeout_ms(settings, _backend), do: settings.codex.stall_timeout_ms

  defp resolve_backend_turn_timeout_ms(settings, "codex"), do: settings.codex.turn_timeout_ms
  defp resolve_backend_turn_timeout_ms(settings, "acp"), do: settings.acp.prompt_timeout_ms

  defp resolve_backend_turn_timeout_ms(settings, "claude_code"),
    do: settings.claude_code.prompt_timeout_ms

  defp resolve_backend_turn_timeout_ms(settings, _backend), do: settings.codex.turn_timeout_ms

  defp validate_semantics(settings) do
    with :ok <- validate_agent_backend(settings) do
      validate_tracker_semantics(settings)
    end
  end

  defp validate_agent_backend(settings) do
    cond do
      settings.agent.backend == "acp" and blank?(settings.acp.command) ->
        {:error, :missing_acp_command}

      settings.agent.backend == "claude_code" and blank?(settings.claude_code.command) ->
        {:error, :missing_claude_code_command}

      true ->
        :ok
    end
  end

  defp validate_tracker_semantics(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["linear", "memory"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) ->
        {:error, :missing_linear_api_token}

      # project_slug is only required for legacy single-repo polling. When
      # `linear.team_id` is set in ~/.symphony/repos.yaml, Symphony uses the
      # team-scoped poll path (Linear.Client) and never reads project_slug;
      # the legacy validation here would otherwise block the dispatch loop
      # on a config field the running code no longer consumes.
      settings.tracker.kind == "linear" and not is_binary(settings.tracker.project_slug) and
          not multi_repo_configured?() ->
        {:error, :missing_linear_project_slug}

      true ->
        :ok
    end
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true

  defp multi_repo_configured? do
    case SymphonyElixir.RepoConfig.load() do
      {:ok, %{linear: %{team_id: team_id}}} when is_binary(team_id) -> true
      _ -> false
    end
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end

  defp bounded_integer(map, key, min, max, default) do
    case Map.get(map, key) do
      value when is_integer(value) -> value |> Kernel.max(min) |> Kernel.min(max)
      _value -> default
    end
  end

  defp non_blank(map, key, default) do
    case Map.get(map, key) do
      value when is_binary(value) -> if String.trim(value) == "", do: default, else: value
      _value -> default
    end
  end

  defp optional_non_blank(map, key) do
    case non_blank(map, key, nil) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end

  defp boolean_value(map, key, default) do
    case Map.get(map, key) do
      value when is_boolean(value) -> value
      _value -> default
    end
  end
end
