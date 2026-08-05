defmodule SymphonyElixir.PersistentWorker do
  @moduledoc """
  Launches and reconnects detached per-issue worker BEAMs.

  The orchestrator only owns a lightweight relay client. The detached worker
  owns `AgentRunner` and its backend port, so stopping the orchestrator closes
  the relay but leaves the live agent session intact for the next instance.
  """

  require Logger

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PersistentWorker.{Client, Launcher, Registry}

  @type attachment :: %{
          pid: pid(),
          manifest: Registry.manifest(),
          spec: Registry.run_spec(),
          launched?: boolean()
        }

  @doc "Whether detached workers are enabled for dispatch and restart adoption."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:symphony_elixir, :persistent_workers_enabled, true) == true
  end

  @doc "Launch (or reuse) an issue worker and attach a relay client."
  @spec start(Issue.t(), integer() | nil, String.t() | nil, pid()) ::
          {:ok, attachment()} | {:error, term()}
  def start(%Issue{} = issue, attempt, worker_host, orchestrator) when is_pid(orchestrator) do
    case Registry.prepare(issue, attempt, worker_host) do
      {:ok, manifest} ->
        with :ok <- Launcher.launch(manifest),
             {:ok, spec} <- Registry.load_spec(manifest),
             {:ok, pid} <- start_client(manifest, orchestrator) do
          {:ok, %{pid: pid, manifest: manifest, spec: spec, launched?: true}}
        else
          {:error, reason} ->
            _ = Registry.cleanup(manifest, manifest.worker_id)
            {:error, reason}
        end

      {:existing, manifest} ->
        attach_manifest(manifest, orchestrator, false)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Attach relay clients to every discoverable worker not already tracked."
  @spec attach_all(pid(), MapSet.t(String.t())) :: [attachment()]
  def attach_all(orchestrator, tracked_worker_ids \\ MapSet.new())
      when is_pid(orchestrator) do
    Registry.list()
    |> Enum.reject(&MapSet.member?(tracked_worker_ids, &1.worker_id))
    |> Enum.flat_map(fn manifest ->
      case attach_manifest(manifest, orchestrator, false) do
        {:ok, attachment} ->
          [attachment]

        {:error, reason} ->
          Logger.warning("Unable to reconnect persistent worker worker_id=#{manifest.worker_id} issue_id=#{manifest.issue_id}: #{inspect(reason)}")

          []
      end
    end)
  end

  @doc "Request a tracked worker to stop cleanly."
  @spec stop(pid()) :: :ok
  def stop(client_pid) when is_pid(client_pid), do: Client.stop(client_pid)

  defp attach_manifest(manifest, orchestrator, launched?) do
    with {:ok, spec} <- Registry.load_spec(manifest),
         {:ok, pid} <- start_client(manifest, orchestrator) do
      {:ok, %{pid: pid, manifest: manifest, spec: spec, launched?: launched?}}
    end
  end

  defp start_client(manifest, orchestrator) do
    Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
      Client.run(manifest, orchestrator)
    end)
  end
end
