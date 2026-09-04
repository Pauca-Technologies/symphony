defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()

    children =
      if persistent_worker_mode?() do
        [SymphonyElixir.Linear.RateLimit]
      else
        [
          {Phoenix.PubSub, name: SymphonyElixir.PubSub},
          SymphonyElixirWeb.ObservabilityPubSub,
          {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
          SymphonyElixir.Linear.RateLimit,
          SymphonyElixir.WorkflowStore,
          SymphonyElixir.WaitWatcher,
          SymphonyElixir.Orchestrator,
          SymphonyElixir.HttpServer,
          SymphonyElixir.StatusDashboard
        ]
      end

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SymphonyElixir.Supervisor
    )
  end

  @impl true
  def prep_stop(state) do
    unless persistent_worker_mode?() do
      SymphonyElixir.Shutdown.prepare()
    end

    state
  end

  @impl true
  def stop(_state) do
    unless persistent_worker_mode?() do
      SymphonyElixir.StatusDashboard.render_offline_status()
    end

    :ok
  end

  defp persistent_worker_mode? do
    System.get_env("SYMPHONY_PERSISTENT_WORKER") == "1" or
      Application.get_env(:symphony_elixir, :persistent_worker_mode, false) == true
  end
end
