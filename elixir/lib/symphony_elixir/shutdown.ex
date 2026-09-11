defmodule SymphonyElixir.Shutdown do
  @moduledoc """
  Applies the persisted live-worker policy before the main application exits.
  """

  require Logger

  alias SymphonyElixir.{Orchestrator, PersistentWorker, ShutdownPolicyStore}

  @type deps :: %{
          load_policy: (-> ShutdownPolicyStore.policy()),
          termination_targets: (-> [PersistentWorker.termination_target()]),
          stop_all_workers: (-> {:ok, non_neg_integer()} | :unavailable),
          terminate_all: ([PersistentWorker.termination_target()] -> :ok | {:error, term()})
        }

  @doc "Apply the persisted shutdown policy."
  @spec prepare() :: :ok
  def prepare do
    prepare(runtime_deps())
  end

  @doc false
  @spec prepare(deps()) :: :ok
  def prepare(deps) when is_map(deps) do
    case deps.load_policy.() do
      :preserve_workers ->
        Logger.info("Symphony shutdown is preserving detached workers for reconnection")

      :terminate_workers ->
        terminate_workers(deps)
    end

    :ok
  end

  defp terminate_workers(deps) do
    Logger.info("Symphony shutdown is terminating all active workers")
    termination_targets = deps.termination_targets.()

    case deps.stop_all_workers.() do
      {:ok, count} -> Logger.info("Requested shutdown for #{count} tracked worker(s)")
      :unavailable -> Logger.warning("Orchestrator unavailable while terminating workers; using registry fallback")
    end

    case deps.terminate_all.(termination_targets) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Unable to terminate every persistent worker cleanly: #{inspect(reason)}")
    end
  end

  defp runtime_deps do
    %{
      load_policy: &ShutdownPolicyStore.load/0,
      termination_targets: &PersistentWorker.termination_targets/0,
      stop_all_workers: &Orchestrator.stop_all_workers/0,
      terminate_all: &PersistentWorker.terminate_all/1
    }
  end
end
