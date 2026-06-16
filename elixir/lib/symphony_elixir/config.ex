defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
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
          stall_timeout_ms: integer()
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
         stall_timeout_ms: acp.stall_timeout_ms
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
end
