defmodule SymphonyElixir.PersistentWorker do
  @moduledoc """
  Launches and reconnects detached per-issue worker BEAMs.

  The orchestrator only owns a lightweight relay client. The detached worker
  owns `AgentRunner` and its backend port, so stopping the orchestrator closes
  the relay but leaves the live agent session intact for the next instance.
  """

  require Logger

  alias SymphonyElixir.{Linear.Issue, OSProcess}
  alias SymphonyElixir.PersistentWorker.{Client, Launcher, Registry}

  @type attachment :: %{
          pid: pid(),
          manifest: Registry.manifest(),
          spec: Registry.run_spec(),
          launched?: boolean()
        }

  @type termination_target :: %{manifest: Registry.manifest(), identities: [OSProcess.identity()]}

  @doc "Whether detached workers are enabled for dispatch and restart adoption."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:symphony_elixir, :persistent_workers_enabled, true) == true
  end

  @doc "Launch (or reuse) an issue worker and attach a relay client."
  @spec start(Issue.t(), integer() | nil, String.t() | nil, pid()) ::
          {:ok, attachment()} | {:error, term()}
  @spec start(Issue.t(), integer() | nil, String.t() | nil, pid(), keyword()) ::
          {:ok, attachment()} | {:error, term()}
  def start(%Issue{} = issue, attempt, worker_host, orchestrator, runner_opts \\ [])
      when is_pid(orchestrator) and is_list(runner_opts) do
    case Registry.prepare(issue, attempt, worker_host, runner_opts) do
      {:ok, manifest} ->
        launch_prepared_worker(manifest, orchestrator)

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
    reap_unregistered_workers()

    Registry.list()
    |> Enum.reject(&MapSet.member?(tracked_worker_ids, &1.worker_id))
    |> Enum.flat_map(&attach_discovered_manifest(&1, orchestrator))
  end

  @doc "Request a tracked worker to stop cleanly."
  @spec stop(pid()) :: :ok
  def stop(client_pid) when is_pid(client_pid), do: Client.stop(client_pid)

  @doc "Snapshot every registered worker process tree before shutdown begins."
  @spec termination_targets() :: [termination_target()]
  def termination_targets do
    Enum.map(Registry.list(), fn manifest ->
      identities = if Registry.worker_alive?(manifest), do: OSProcess.snapshot_tree(manifest.os_pid), else: []
      %{manifest: manifest, identities: identities}
    end)
  end

  @doc "Terminate captured and newly registered worker process trees."
  @spec terminate_all([termination_target()]) :: :ok | {:error, term()}
  def terminate_all(targets \\ termination_targets()) when is_list(targets) do
    if targets != [] or Registry.list() != [], do: Process.sleep(shutdown_grace_ms())

    failures =
      (targets ++ termination_targets())
      |> merge_termination_targets()
      |> Enum.flat_map(&terminate_registered_worker/1)

    case failures do
      [] -> :ok
      _ -> {:error, {:persistent_workers_still_running, failures}}
    end
  end

  defp attach_manifest(manifest, orchestrator, launched?) do
    with {:ok, spec} <- Registry.load_spec(manifest),
         {:ok, pid} <- start_client(manifest, orchestrator) do
      {:ok, %{pid: pid, manifest: manifest, spec: spec, launched?: launched?}}
    end
  end

  defp launch_prepared_worker(manifest, orchestrator) do
    case launch_worker(manifest) do
      :ok ->
        attach_launched_worker(manifest, orchestrator)

      {:error, reason} ->
        _ = Registry.cleanup(manifest, manifest.worker_id)
        {:error, reason}
    end
  end

  defp attach_launched_worker(manifest, orchestrator) do
    case attach_manifest(manifest, orchestrator, true) do
      {:ok, attachment} ->
        {:ok, attachment}

      {:error, reason} ->
        Logger.warning(
          "Persistent worker launched but its relay could not attach; preserving discovery record " <>
            "worker_id=#{manifest.worker_id} issue_id=#{manifest.issue_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp attach_discovered_manifest(%{status: "stopping"} = manifest, _orchestrator) do
    retire_stopping_manifest(manifest)
    []
  end

  defp attach_discovered_manifest(manifest, orchestrator) do
    if registered_worker_alive?(manifest) do
      case attach_manifest(manifest, orchestrator, false) do
        {:ok, attachment} ->
          [attachment]

        {:error, reason} ->
          Logger.warning("Unable to reconnect persistent worker worker_id=#{manifest.worker_id} issue_id=#{manifest.issue_id}: #{inspect(reason)}")

          []
      end
    else
      Logger.warning("Removing dead persistent worker record worker_id=#{manifest.worker_id} issue_id=#{manifest.issue_id}")
      _ = Registry.cleanup(manifest, manifest.worker_id)
      []
    end
  end

  defp registered_worker_alive?(manifest) do
    case Application.get_env(:symphony_elixir, :persistent_worker_liveness_check) do
      check when is_function(check, 1) -> check.(manifest)
      _other -> Registry.worker_alive?(manifest)
    end
  end

  defp reap_unregistered_workers do
    orphaned =
      case Application.get_env(:symphony_elixir, :persistent_worker_orphan_scanner) do
        scanner when is_function(scanner, 0) -> scanner.()
        _other -> Registry.unregistered_workers()
      end

    Enum.each(orphaned, &reap_unregistered_worker/1)
  end

  defp reap_unregistered_worker(%{pid: pid, spec_path: spec_path}) do
    case snapshot_worker_tree(pid) do
      [] ->
        Logger.warning("Unable to snapshot unregistered persistent worker pid=#{pid} spec_path=#{spec_path}; leaving it untouched")

      identities ->
        log_unregistered_worker_termination(pid, spec_path, terminate_worker_identities(identities))
    end
  end

  defp log_unregistered_worker_termination(pid, spec_path, :ok) do
    Logger.info("Terminated unregistered persistent worker pid=#{pid} spec_path=#{spec_path}")
  end

  defp log_unregistered_worker_termination(pid, spec_path, {:error, reason}) do
    Logger.warning("Unable to terminate unregistered persistent worker pid=#{pid} spec_path=#{spec_path}: #{inspect(reason)}")
  end

  defp retire_stopping_manifest(manifest) do
    if registered_worker_alive?(manifest) do
      identities = snapshot_worker_tree(manifest.os_pid)
      result = terminate_worker_identities(identities)

      if registered_worker_alive?(manifest) do
        Logger.warning(
          "Stopping persistent worker remains alive; preserving discovery record " <>
            "worker_id=#{manifest.worker_id} issue_id=#{manifest.issue_id} result=#{inspect(result)}"
        )
      else
        _ = Registry.cleanup(manifest, manifest.worker_id)
      end
    else
      _ = Registry.cleanup(manifest, manifest.worker_id)
    end
  end

  defp snapshot_worker_tree(pid) when is_integer(pid) and pid > 0 do
    case Application.get_env(:symphony_elixir, :persistent_worker_process_snapshotter) do
      snapshotter when is_function(snapshotter, 1) -> snapshotter.(pid)
      _other -> OSProcess.snapshot_tree(pid)
    end
  end

  defp snapshot_worker_tree(_pid), do: []

  defp terminate_worker_identities(identities) do
    case Application.get_env(:symphony_elixir, :persistent_worker_identity_terminator) do
      terminator when is_function(terminator, 2) -> terminator.(identities, shutdown_force_timeout_ms())
      _other -> OSProcess.terminate_identities(identities, shutdown_force_timeout_ms())
    end
  end

  defp start_client(manifest, orchestrator) do
    case Application.get_env(:symphony_elixir, :persistent_worker_client_starter) do
      starter when is_function(starter, 2) ->
        starter.(manifest, orchestrator)

      _other ->
        Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
          Client.run(manifest, orchestrator)
        end)
    end
  end

  defp launch_worker(manifest) do
    case Application.get_env(:symphony_elixir, :persistent_worker_launcher) do
      launcher when is_function(launcher, 1) -> launcher.(manifest)
      _other -> Launcher.launch(manifest)
    end
  end

  defp terminate_registered_worker(%{manifest: manifest, identities: identities}) do
    result = OSProcess.terminate_identities(identities, shutdown_force_timeout_ms())
    worker_alive? = Registry.worker_alive?(manifest)

    if not worker_alive? do
      _ = Registry.cleanup(manifest, manifest.worker_id)
    end

    case {result, worker_alive?} do
      {:ok, false} ->
        []

      {:ok, true} ->
        [%{worker_id: manifest.worker_id, issue_id: manifest.issue_id, reason: :worker_still_running}]

      {{:error, reason}, _worker_alive?} ->
        [%{worker_id: manifest.worker_id, issue_id: manifest.issue_id, reason: reason}]
    end
  end

  defp merge_termination_targets(targets) do
    targets
    |> Enum.reduce(%{}, fn target, merged ->
      worker_id = target.manifest.worker_id

      Map.update(merged, worker_id, target, fn existing ->
        identities =
          (existing.identities ++ target.identities)
          |> Enum.uniq_by(&{&1.pid, &1.start_time})

        %{target | identities: identities}
      end)
    end)
    |> Map.values()
  end

  defp shutdown_grace_ms do
    Application.get_env(:symphony_elixir, :worker_shutdown_grace_ms, 1_500)
  end

  defp shutdown_force_timeout_ms do
    Application.get_env(:symphony_elixir, :worker_shutdown_force_timeout_ms, 2_000)
  end
end
