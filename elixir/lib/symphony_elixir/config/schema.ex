defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.PathSafety

  @primary_key false

  @type t :: %__MODULE__{}

  defmodule StringOrMap do
    @moduledoc false
    @behaviour Ecto.Type

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, String.t() | map()} | :error
    def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def cast(_value), do: :error

    @spec load(term()) :: {:ok, String.t() | map()} | :error
    def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, String.t() | map()} | :error
    def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:kind, :string)
      field(:endpoint, :string, default: "https://api.linear.app/graphql")
      field(:api_key, :string)
      field(:project_slug, :string)
      field(:assignee, :string)
      field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])
      field(:terminal_states, {:array, :string}, default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:kind, :endpoint, :api_key, :project_slug, :assignee, :active_states, :terminal_states],
        empty_values: []
      )
    end
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      # No compile-time default: `System.tmp_dir!()` is resolved at runtime in
      # `Schema.finalize_settings/1` so the default tracks the current
      # environment's tmp dir, not whatever TMPDIR was set during compilation.
      field(:root, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root], empty_values: [])
    end
  end

  defmodule Worker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:ssh_hosts, {:array, :string}, default: [])
      field(:max_concurrent_agents_per_host, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:ssh_hosts, :max_concurrent_agents_per_host], empty_values: [])
      |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
    end
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @backend_names ["codex", "acp", "claude_code"]

    defmodule LabelPreset do
      @moduledoc """
      One entry in `agent.label_presets`: maps a Linear label name to a
      per-task backend (and optional model) override. See
      `SymphonyElixir.AgentBackend.resolve_for_issue/1` and §15 of
      `docs/acp-support-plan.md`. Presets are matched positionally — the first
      preset whose `label` is present on the issue wins.
      """
      use Ecto.Schema
      import Ecto.Changeset

      @backend_names ["codex", "acp", "claude_code"]

      @primary_key false
      embedded_schema do
        # Linear label name, matched exactly (case-sensitive, as Linear stores it).
        field(:label, :string)
        # Backend to use for issues carrying `label` (one of @backend_names).
        field(:backend, :string)
        # Optional per-task model. Interpreted by the chosen backend: Codex →
        # thread/start; ACP/OpenCode → OPENCODE_CONFIG_CONTENT; Claude Code →
        # --model.
        field(:model, :string)
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(attrs, [:label, :backend, :model], empty_values: [])
        |> validate_required([:label, :backend])
        |> validate_inclusion(:backend, @backend_names)
        |> validate_change(:label, fn :label, value ->
          if is_binary(value) and String.trim(value) != "", do: [], else: [label: "must not be blank"]
        end)
      end
    end

    @primary_key false
    embedded_schema do
      field(:max_concurrent_agents, :integer, default: 10)
      # Bounds test-runner fan-out inside each agent process. This is independent
      # of (and must not alter) Symphony's agent-slot concurrency.
      field(:test_worker_limit, :integer, default: 2)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      # Threshold for consecutive failed/stalled agent runs. Human-actionable
      # configuration failures are marked Blocked beyond it; operational
      # failures remain active and retry at `max_retry_backoff_ms`. Reset when
      # the issue completes a turn normally.
      field(:max_retries, :integer, default: 10)
      field(:max_concurrent_agents_by_state, :map, default: %{})
      # Selects the coding-agent backend. "codex" = Codex app-server (default,
      # unchanged behavior); "acp" = Agent Client Protocol; "claude_code" =
      # native Claude Code `claude -p` stream-json. See AgentBackend.
      field(:backend, :string, default: "codex")
      # Optional shell snippet run (joined with `&&`) in the launch shell before
      # every backend's agent process, in the workspace cwd — e.g. sourcing a
      # per-worktree GitHub-session env file: ". .artifacts/.../session.env".
      # Backend-agnostic; unset ⇒ launches are byte-for-byte unchanged. See
      # AgentTransport.with_pre_command/2.
      field(:pre_command, :string)
      # Ordered per-task backend+model overrides keyed on Linear label name;
      # first match wins, falls through to `backend` for unmatched issues.
      embeds_many(:label_presets, LabelPreset, on_replace: :delete)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :max_concurrent_agents,
          :test_worker_limit,
          :max_turns,
          :max_retry_backoff_ms,
          :max_retries,
          :max_concurrent_agents_by_state,
          :backend,
          :pre_command
        ],
        empty_values: []
      )
      |> cast_embed(:label_presets, with: &LabelPreset.changeset/2)
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:test_worker_limit, greater_than: 0, less_than_or_equal_to: 32)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> validate_number(:max_retries, greater_than: 0)
      |> validate_inclusion(:backend, @backend_names)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
    end
  end

  defmodule Codex do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "codex app-server")

      field(:approval_policy, StringOrMap,
        default: %{
          "reject" => %{
            "sandbox_approval" => true,
            "rules" => true,
            "mcp_elicitations" => true
          }
        }
      )

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
      # Load-bearing safety property (§5.5/§14.3), same as the ACP/ClaudeCode
      # paths: never expose Linear credentials to the agent process; the gated
      # dynamic tool holds the token server-side.
      field(:withhold_linear_credentials, :boolean, default: true)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :approval_policy,
          :thread_sandbox,
          :turn_sandbox_policy,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms,
          :withhold_linear_credentials
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule Acp do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      # Command that launches the ACP agent over stdio (e.g. "opencode acp").
      field(:command, :string, default: "opencode acp")
      # Optional model id (e.g. "opencode/north-mini-code-free"). OpenCode-only:
      # surfaced to the agent via OPENCODE_CONFIG_CONTENT, since `opencode acp`
      # rejects a `--model` flag and ignores OPENCODE_MODEL. Other ACP agents
      # select their model through their own config and ignore this field.
      field(:model, :string)
      # Mirrors Codex `approval_policy == "never"`: auto-approve permission
      # requests instead of blocking the turn.
      field(:auto_approve, :boolean, default: true)
      field(:protocol_version, :integer, default: 1)
      # Load-bearing safety property (§5.5): never expose Linear credentials to
      # the agent process; the gated MCP tool holds the token server-side.
      field(:withhold_linear_credentials, :boolean, default: true)
      # Phase 2 advertises both false so the agent uses its own file/exec tools.
      field(:advertise_fs, :boolean, default: false)
      field(:advertise_terminal, :boolean, default: false)
      field(:prompt_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
      # Some ACP agents (notably opencode) don't report a model-stream failure
      # over ACP — a rate-limited turn just goes silent until `stall_timeout_ms`.
      # While a turn is idle, emit a "still waiting" heartbeat every
      # `heartbeat_ms` so the silence is visible instead of dead air. 0 disables.
      field(:heartbeat_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :model,
          :auto_approve,
          :protocol_version,
          :withhold_linear_credentials,
          :advertise_fs,
          :advertise_terminal,
          :prompt_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms,
          :heartbeat_ms
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_number(:protocol_version, greater_than: 0)
      |> validate_number(:prompt_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
      |> validate_number(:heartbeat_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule ClaudeCode do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    # Claude Code's `--permission-mode` choices (verified against claude 2.1.178).
    @permission_modes ~w(default acceptEdits bypassPermissions auto dontAsk plan)

    @primary_key false
    embedded_schema do
      # Base launch command; the backend appends the stream-json / mcp-config
      # flags. Just the binary by default (e.g. "claude").
      field(:command, :string, default: "claude")
      # Optional model alias/name passed as `--model` (e.g. "opus",
      # "claude-fable-5"). Unlike OpenCode, Claude Code takes the model as a
      # native flag; unset ⇒ Claude Code's own resolution.
      field(:model, :string)
      # Maps to `--permission-mode`. Default `bypassPermissions` mirrors Codex
      # `approval_policy: never` / ACP `auto_approve` for non-interactive runs.
      field(:permission_mode, :string, default: "bypassPermissions")
      # Extra raw CLI args appended verbatim (e.g. ["--append-system-prompt", ...]).
      field(:extra_args, {:array, :string}, default: [])
      field(:prompt_timeout_ms, :integer, default: 3_600_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
      # Load-bearing safety property (§5.5/§14.3), same as the ACP path: never
      # expose Linear credentials to the agent process; the gated MCP tool holds
      # the token server-side.
      field(:withhold_linear_credentials, :boolean, default: true)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :model,
          :permission_mode,
          :extra_args,
          :prompt_timeout_ms,
          :stall_timeout_ms,
          :withhold_linear_credentials
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_inclusion(:permission_mode, @permission_modes)
      |> validate_number(:prompt_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:after_create, :string)
      field(:session_start, :string)
      field(:before_run, :string)
      field(:before_handoff, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 60_000)
      field(:before_handoff_timeout_ms, :integer)
      field(:before_handoff_stale_ms, :integer, default: 120_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      hook_fields = [
        :after_create,
        :session_start,
        :before_run,
        :before_handoff,
        :after_run,
        :before_remove,
        :timeout_ms,
        :before_handoff_timeout_ms,
        :before_handoff_stale_ms
      ]

      schema
      |> cast(attrs, hook_fields, empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
      |> validate_number(:before_handoff_timeout_ms, greater_than: 0)
      |> validate_number(:before_handoff_stale_ms, greater_than: 0)
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
      # Compact fleet events are the durable 30-day analytics source. Raw
      # protocol traces are intentionally shorter-lived and retained only for
      # failures, sampled successes, or an explicit incident-debug override.
      field(:telemetry_retention_days, :integer, default: 30)
      field(:session_retention_days, :integer, default: 30)
      field(:raw_trace_retention_days, :integer, default: 7)
      field(:raw_trace_policy, :string, default: "failures")
      field(:raw_trace_sample_rate, :float, default: 0.01)
      field(:raw_trace_debug, :boolean, default: false)
      field(:session_compaction_enabled, :boolean, default: true)
      field(:benign_notification_debug, :boolean, default: false)
      field(:prompt_debug, :boolean, default: false)
      field(:prompt_debug_max_bytes, :integer, default: 32_000)

      field(:redact_fields, {:array, :string},
        default: [
          "authorization",
          "api_key",
          "token",
          "access_token",
          "refresh_token",
          "cookie",
          "set-cookie",
          "password",
          "secret",
          "client_secret",
          "private_key",
          "x-api-key"
        ]
      )
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :dashboard_enabled,
          :refresh_ms,
          :render_interval_ms,
          :telemetry_retention_days,
          :session_retention_days,
          :raw_trace_retention_days,
          :raw_trace_policy,
          :raw_trace_sample_rate,
          :raw_trace_debug,
          :session_compaction_enabled,
          :benign_notification_debug,
          :prompt_debug,
          :prompt_debug_max_bytes,
          :redact_fields
        ],
        empty_values: []
      )
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
      |> validate_number(:telemetry_retention_days, greater_than_or_equal_to: 30)
      |> validate_number(:session_retention_days, greater_than_or_equal_to: 7)
      |> validate_number(:raw_trace_retention_days, greater_than_or_equal_to: 7)
      |> validate_number(:raw_trace_sample_rate, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
      |> validate_number(:prompt_debug_max_bytes, greater_than: 0, less_than_or_equal_to: 256_000)
      |> validate_inclusion(:raw_trace_policy, ["none", "failures", "sampled", "all"])
    end
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  defmodule LinearGithubMapping do
    @moduledoc """
    One entry in `linear_to_github`: maps a Linear user (by email — Linear's
    User type does not expose a GitHub handle anywhere) to the GitHub login
    that should be requested as PR reviewer on issues owned by that user.
    """
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:linear_email, :string)
      field(:github_login, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:linear_email, :github_login], empty_values: [])
      |> validate_required([:linear_email, :github_login])
    end
  end

  defmodule Gc do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      # Lookback window (in days) for the issue-state-driven worktree
      # GC (T28). On each pass Symphony asks Linear for issues that
      # transitioned to a terminal state (Done/Cancelled) within this
      # window and reaps their worktrees. Default of 7 covers the
      # nominal daily cadence with a one-week safety margin in case the
      # orchestrator is offline for a stretch.
      field(:lookback_days, :integer, default: 7)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:lookback_days], empty_values: [])
      |> validate_number(:lookback_days, greater_than: 0)
    end
  end

  embedded_schema do
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    embeds_one(:acp, Acp, on_replace: :update, defaults_to_struct: true)
    embeds_one(:claude_code, ClaudeCode, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
    embeds_one(:gc, Gc, on_replace: :update, defaults_to_struct: true)
    embeds_many(:linear_to_github, LinearGithubMapping, on_replace: :delete)
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    config
    |> normalize_keys()
    |> drop_nil_values()
    |> changeset()
    |> apply_action(:validate)
    |> case do
      {:ok, settings} ->
        {:ok, finalize_settings(settings)}

      {:error, changeset} ->
        {:error, {:invalid_workflow_config, format_errors(changeset)}}
    end
  end

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map()
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        policy

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> expand_local_workspace_root()
        |> default_turn_sandbox_policy()
    end
  end

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil, opts \\ []) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        {:ok, policy}

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> default_runtime_turn_sandbox_policy(opts)
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(state_name)
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          to_string(state_name) == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [])
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:codex, with: &Codex.changeset/2)
    |> cast_embed(:acp, with: &Acp.changeset/2)
    |> cast_embed(:claude_code, with: &ClaudeCode.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
    |> cast_embed(:gc, with: &Gc.changeset/2)
    |> cast_embed(:linear_to_github, with: &LinearGithubMapping.changeset/2)
  end

  defp finalize_settings(settings) do
    tracker = %{
      settings.tracker
      | api_key: resolve_secret_setting(settings.tracker.api_key, System.get_env("LINEAR_API_KEY")),
        project_slug:
          resolve_secret_setting(
            settings.tracker.project_slug,
            System.get_env("LINEAR_PROJECT_SLUG")
          ),
        assignee: resolve_secret_setting(settings.tracker.assignee, System.get_env("LINEAR_ASSIGNEE"))
    }

    workspace = %{
      settings.workspace
      | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "symphony_workspaces"))
    }

    codex = %{
      settings.codex
      | approval_policy: normalize_keys(settings.codex.approval_policy),
        turn_sandbox_policy: normalize_optional_map(settings.codex.turn_sandbox_policy)
    }

    %{settings | tracker: tracker, workspace: workspace, codex: codex}
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(value) when is_map(value), do: normalize_keys(value)

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_path_value(nil, default), do: default

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      "" ->
        default

      path ->
        path
    end
  end

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp default_turn_sandbox_policy(workspace) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [workspace],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, opts) when is_binary(workspace_root) do
    if Keyword.get(opts, :remote, false) do
      {:ok, default_turn_sandbox_policy(workspace_root)}
    else
      with expanded_workspace_root <- expand_local_workspace_root(workspace_root),
           {:ok, canonical_workspace_root} <- PathSafety.canonicalize(expanded_workspace_root) do
        {:ok, default_turn_sandbox_policy(canonical_workspace_root)}
      end
    end
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, _opts) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp default_workspace_root(workspace, _fallback) when is_binary(workspace) and workspace != "",
    do: workspace

  defp default_workspace_root(nil, fallback), do: fallback
  defp default_workspace_root("", fallback), do: fallback
  defp default_workspace_root(workspace, _fallback), do: workspace

  defp expand_local_workspace_root(workspace_root)
       when is_binary(workspace_root) and workspace_root != "" do
    Path.expand(workspace_root)
  end

  defp expand_local_workspace_root(_workspace_root) do
    Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))
  end

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    # A field's errors are a list of message strings; an `embeds_many` field's
    # errors are a list of per-element maps (empty map when that element is
    # clean). Recurse into the maps so nested validation errors flatten too.
    Enum.flat_map(errors, fn
      message when is_binary(message) -> [prefix <> " " <> message]
      nested -> flatten_errors(nested, prefix)
    end)
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end
