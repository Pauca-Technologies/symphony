defmodule SymphonyElixir.PersistentWorker.Runtime do
  @moduledoc false

  alias SymphonyElixir.PersistentWorker.{Registry, Server}
  alias SymphonyElixir.Workflow

  @doc false
  @spec run(Path.t()) :: :ok | {:error, term()}
  def run(spec_path) when is_binary(spec_path) do
    with {:ok, spec} <- Registry.load_spec_path(spec_path),
         :ok <- configure_worker_runtime(spec),
         {:ok, _apps} <- Application.ensure_all_started(:symphony_elixir),
         {:ok, server} <- Server.start_link(spec) do
      ref = Process.monitor(server)

      receive do
        {:DOWN, ^ref, :process, ^server, :normal} -> :ok
        {:DOWN, ^ref, :process, ^server, reason} -> {:error, reason}
      end
    end
  end

  defp configure_worker_runtime(spec) do
    System.put_env("SYMPHONY_PERSISTENT_WORKER", "1")
    Application.put_env(:symphony_elixir, :persistent_worker_mode, true)
    Application.put_env(:symphony_elixir, :repo_config_path, spec.repo_config_path)
    Application.put_env(:symphony_elixir, :log_file, spec.log_path)

    Workflow.set_workflow_file_path(spec.workflow_path)
  end
end
