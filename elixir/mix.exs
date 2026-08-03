defmodule SymphonyElixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :symphony_elixir,
      version: "0.1.0",
      elixir: "~> 1.19",
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      test_coverage: [
        summary: [
          threshold: 100
        ],
        ignore_modules: [
          # These established udp modules still have partial focused coverage.
          # Grandfather that explicit baseline while keeping the 100% threshold
          # strict for every unlisted module as the debt is retired incrementally.
          SymphonyElixir.Acp.Client,
          SymphonyElixir.Acp.LinearGate,
          SymphonyElixir.Acp.LinearGate.McpPlug,
          SymphonyElixir.AgentBackend,
          SymphonyElixir.AgentBudget,
          SymphonyElixir.AgentBudgetCollector,
          SymphonyElixir.AgentEfficiency,
          SymphonyElixir.AgentFailure,
          SymphonyElixir.AgentTransport,
          SymphonyElixir.BaseDrift,
          SymphonyElixir.ClaudeCode.Client,
          SymphonyElixir.Codex.InterruptionClassifier,
          SymphonyElixir.CodexSessionLogRenderer,
          SymphonyElixir.Config,
          SymphonyElixir.Config.AgentEfficiency,
          SymphonyElixir.FleetEvent,
          SymphonyElixir.Github.PrReviewSection,
          SymphonyElixir.Linear.Client,
          SymphonyElixir.Linear.Adapter,
          SymphonyElixir.PromptBuilder,
          SymphonyElixir.PromptComposer,
          SymphonyElixir.QuotaCircuitStore,
          SymphonyElixir.RepoConfig,
          SymphonyElixir.RepositoryScheduler,
          SymphonyElixir.ReviewOutcome,
          SymphonyElixir.ReviewPacket,
          SymphonyElixir.ReviewTelemetry,
          SymphonyElixir.SessionStartHook,
          SymphonyElixir.SessionTranscript,
          SymphonyElixir.SpecsCheck,
          SymphonyElixir.TaskContextPrompt,
          SymphonyElixir.Telemetry.Report,
          SymphonyElixir.TokenAccounting,
          SymphonyElixir.Utf8,
          SymphonyElixir.Orchestrator,
          SymphonyElixir.Orchestrator.State,
          SymphonyElixir.AgentRunner,
          SymphonyElixir.ReviewGate,
          SymphonyElixir.CLI,
          SymphonyElixir.Codex.AppServer,
          SymphonyElixir.Codex.DynamicTool,
          SymphonyElixir.HttpServer,
          SymphonyElixir.StatusDashboard,
          SymphonyElixir.LogFile,
          SymphonyElixir.Workspace,
          SymphonyElixir.BareClone,
          SymphonyElixir.Telemetry,
          SymphonyElixir.OrchestratorVersion,
          Mix.Tasks.Symphony.Cardinality,
          Mix.Tasks.Telemetry.Report,
          SymphonyElixirWeb.DashboardLive,
          SymphonyElixirWeb.Endpoint,
          SymphonyElixirWeb.ErrorHTML,
          SymphonyElixirWeb.ErrorJSON,
          SymphonyElixirWeb.Layouts,
          SymphonyElixirWeb.ObservabilityApiController,
          SymphonyElixirWeb.Presenter,
          SymphonyElixirWeb.StaticAssetController,
          SymphonyElixirWeb.StaticAssets,
          SymphonyElixirWeb.Router,
          SymphonyElixirWeb.Router.Helpers
        ]
      ],
      test_ignore_filters: [
        "test/support/snapshot_support.exs",
        "test/support/test_support.exs"
      ],
      dialyzer: [
        plt_add_apps: [:mix]
      ],
      escript: escript(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {SymphonyElixir.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.8"},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix, "~> 1.8.0"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.1.0"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      {:solid, "~> 1.2"},
      {:ecto, "~> 3.13"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      build: ["escript.build"],
      lint: ["specs.check", "credo --strict"]
    ]
  end

  defp escript do
    [
      app: nil,
      main_module: SymphonyElixir.CLI,
      name: "symphony",
      path: "bin/symphony"
    ]
  end
end
