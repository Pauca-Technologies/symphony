defmodule SymphonyElixir.PersistentWorker.Registry do
  @moduledoc """
  Durable discovery records for detached agent-run worker processes.

  A worker keeps its live session and replay checkpoint in its own BEAM. The
  registry only contains the information a replacement orchestrator needs to
  find and authenticate to that worker after a restart.
  """

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RepoConfig
  alias SymphonyElixir.Workflow

  @version 1
  @manifest_filename "manifest.json"
  @spec_filename "run.term"

  @type manifest :: %{
          version: pos_integer(),
          worker_id: String.t(),
          issue_id: String.t(),
          issue_identifier: String.t(),
          attempt: pos_integer(),
          worker_host: String.t() | nil,
          auth_token: String.t(),
          port: non_neg_integer() | nil,
          os_pid: pos_integer() | nil,
          status: String.t(),
          started_at: String.t(),
          run_dir: Path.t(),
          manifest_path: Path.t(),
          spec_path: Path.t(),
          log_path: Path.t()
        }

  @type run_spec :: %{
          version: pos_integer(),
          worker_id: String.t(),
          issue: Issue.t(),
          attempt: pos_integer(),
          worker_host: String.t() | nil,
          runner_opts: keyword(),
          auth_token: String.t(),
          workflow_path: Path.t(),
          repo_config_path: Path.t(),
          log_path: Path.t(),
          manifest_path: Path.t(),
          run_dir: Path.t()
        }

  @doc "Return the persistent-worker registry root."
  @spec root() :: Path.t()
  def root do
    Application.get_env(:symphony_elixir, :persistent_worker_registry_root) ||
      Path.join([System.user_home!(), ".symphony", "workers"])
  end

  @doc "Create one exclusive run record for an issue."
  @spec prepare(Issue.t(), integer() | nil, String.t() | nil) ::
          {:ok, manifest()} | {:existing, manifest()} | {:error, term()}
  @spec prepare(Issue.t(), integer() | nil, String.t() | nil, keyword()) ::
          {:ok, manifest()} | {:existing, manifest()} | {:error, term()}
  def prepare(%Issue{id: issue_id, identifier: identifier} = issue, attempt, worker_host, runner_opts \\ [])
      when is_binary(issue_id) and is_binary(identifier) and is_list(runner_opts) do
    run_dir = run_dir(issue_id)

    with :ok <- ensure_roots(),
         :ok <- create_run_dir(run_dir) do
      do_prepare(run_dir, issue, normalize_attempt(attempt), worker_host, safe_runner_opts(runner_opts))
    else
      {:error, :eexist} ->
        prepare_from_existing(
          run_dir,
          issue,
          attempt,
          worker_host,
          runner_opts
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Load all valid worker manifests, ignoring corrupt partial records."
  @spec list() :: [manifest()]
  def list do
    case File.ls(root()) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.flat_map(&load_listed_manifest/1)

      {:error, _reason} ->
        []
    end
  end

  @doc "Read and validate a worker manifest."
  @spec load_manifest(Path.t()) :: {:ok, manifest()} | {:error, term()}
  def load_manifest(path) when is_binary(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents) do
      decode_manifest(decoded, path)
    end
  end

  @doc "Read the immutable run specification associated with a manifest."
  @spec load_spec(manifest()) :: {:ok, run_spec()} | {:error, term()}
  def load_spec(%{spec_path: path}), do: load_spec_path(path)

  @doc false
  @spec load_spec_path(Path.t()) :: {:ok, run_spec()} | {:error, term()}
  def load_spec_path(path) when is_binary(path) do
    with {:ok, contents} <- File.read(path) do
      try do
        # The spec is a 0600 file inside a 0700 run directory created by this
        # module. A fresh worker VM has not loaded every atom present in the
        # Issue struct yet, so `[:safe]` would reject the valid handoff before
        # Application startup.
        case :erlang.binary_to_term(contents) do
          %{version: @version, worker_id: worker_id, issue: %Issue{}} = spec
          when is_binary(worker_id) ->
            {:ok, spec}

          _other ->
            {:error, :invalid_worker_spec}
        end
      rescue
        ArgumentError -> {:error, :invalid_worker_spec}
      end
    end
  end

  @doc "Merge worker-owned readiness/status fields into a manifest atomically."
  @spec update(manifest() | Path.t(), map()) :: {:ok, manifest()} | {:error, term()}
  def update(%{manifest_path: path}, changes), do: update(path, changes)

  def update(path, changes) when is_binary(path) and is_map(changes) do
    with {:ok, manifest} <- load_manifest(path),
         updated <- Map.merge(manifest, Map.take(changes, [:port, :os_pid, :status])),
         :ok <- write_manifest(path, updated) do
      {:ok, updated}
    end
  end

  @doc "Remove a completed registry record when the worker id still matches."
  @spec cleanup(manifest() | Path.t(), String.t()) :: :ok | {:error, term()}
  def cleanup(%{manifest_path: path}, worker_id), do: cleanup(path, worker_id)

  def cleanup(path, worker_id) when is_binary(path) and is_binary(worker_id) do
    case load_manifest(path) do
      {:ok, %{worker_id: ^worker_id, run_dir: run_dir, spec_path: spec_path}} ->
        remove_registry_record(path, spec_path, run_dir)

      {:ok, _other} ->
        {:error, :worker_id_mismatch}

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Best-effort check that the recorded worker OS process still owns this run."
  @spec worker_alive?(manifest()) :: boolean()
  def worker_alive?(%{os_pid: pid, spec_path: spec_path}) when is_integer(pid) and pid > 0 do
    proc_cmdline = "/proc/#{pid}/cmdline"

    case File.read(proc_cmdline) do
      {:ok, command_line} ->
        String.contains?(command_line, spec_path) and
          String.contains?(command_line, "__persistent_worker__")

      {:error, _reason} ->
        process_exists_fallback?(pid)
    end
  end

  def worker_alive?(_manifest), do: false

  defp do_prepare(run_dir, issue, attempt, worker_host, runner_opts) do
    worker_id = random_token()
    auth_token = random_token()
    manifest_path = Path.join(run_dir, @manifest_filename)
    spec_path = Path.join(run_dir, @spec_filename)
    log_path = Path.join(log_root(), worker_id <> ".log")
    started_at = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

    manifest = %{
      version: @version,
      worker_id: worker_id,
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      attempt: attempt,
      worker_host: worker_host,
      auth_token: auth_token,
      port: nil,
      os_pid: nil,
      status: "starting",
      started_at: started_at,
      run_dir: run_dir,
      manifest_path: manifest_path,
      spec_path: spec_path,
      log_path: log_path
    }

    spec = %{
      version: @version,
      worker_id: worker_id,
      issue: issue,
      attempt: attempt,
      worker_host: worker_host,
      runner_opts: runner_opts,
      auth_token: auth_token,
      workflow_path: Workflow.workflow_file_path(),
      repo_config_path: RepoConfig.path(),
      log_path: log_path,
      manifest_path: manifest_path,
      run_dir: run_dir
    }

    with :ok <- write_private(spec_path, :erlang.term_to_binary(spec, [:compressed])),
         :ok <- write_manifest(manifest_path, manifest) do
      {:ok, manifest}
    else
      {:error, reason} ->
        _ = File.rm(spec_path)
        _ = File.rm(manifest_path)
        _ = File.rmdir(run_dir)
        {:error, reason}
    end
  end

  defp existing_manifest(run_dir) do
    case load_manifest(Path.join(run_dir, @manifest_filename)) do
      {:ok, manifest} -> {:existing, manifest}
      {:error, reason} -> {:error, {:existing_worker_record_invalid, reason}}
    end
  end

  defp prepare_from_existing(run_dir, issue, attempt, worker_host, runner_opts) do
    case existing_manifest(run_dir) do
      {:existing, %{status: "completed"} = manifest} ->
        replace_terminal_manifest(manifest, issue, attempt, worker_host, runner_opts)

      {:existing, %{status: "stopping"} = manifest} ->
        prepare_from_stopping(manifest, issue, attempt, worker_host, runner_opts)

      result ->
        result
    end
  end

  defp prepare_from_stopping(manifest, issue, attempt, worker_host, runner_opts) do
    if worker_alive?(manifest) do
      {:existing, manifest}
    else
      replace_terminal_manifest(manifest, issue, attempt, worker_host, runner_opts)
    end
  end

  defp replace_terminal_manifest(manifest, issue, attempt, worker_host, runner_opts) do
    with :ok <- cleanup(manifest, manifest.worker_id) do
      prepare(issue, attempt, worker_host, runner_opts)
    end
  end

  defp load_listed_manifest(entry) do
    manifest_path = Path.join([root(), entry, @manifest_filename])

    case load_manifest(manifest_path) do
      {:ok, manifest} -> [manifest]
      {:error, _reason} -> []
    end
  end

  defp remove_registry_record(manifest_path, spec_path, run_dir) do
    _ = File.rm(spec_path)
    _ = File.rm(manifest_path)

    case File.rmdir(run_dir) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_roots do
    with :ok <- File.mkdir_p(root()),
         :ok <- File.mkdir_p(log_root()),
         :ok <- File.chmod(root(), 0o700) do
      File.chmod(log_root(), 0o700)
    end
  end

  defp create_run_dir(run_dir) do
    case File.mkdir(run_dir) do
      :ok -> File.chmod(run_dir, 0o700)
      other -> other
    end
  end

  defp write_manifest(path, manifest) do
    payload =
      manifest
      |> Map.take([
        :version,
        :worker_id,
        :issue_id,
        :issue_identifier,
        :attempt,
        :worker_host,
        :auth_token,
        :port,
        :os_pid,
        :status,
        :started_at,
        :spec_path,
        :log_path
      ])
      |> Jason.encode!()

    atomic_private_write(path, payload)
  end

  defp atomic_private_write(path, payload) do
    temporary = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- write_private(temporary, payload),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temporary)
        {:error, reason}
    end
  end

  defp write_private(path, payload) do
    with :ok <- File.write(path, payload, [:binary]) do
      File.chmod(path, 0o600)
    end
  end

  defp decode_manifest(
         %{
           "version" => @version,
           "worker_id" => worker_id,
           "issue_id" => issue_id,
           "issue_identifier" => identifier,
           "attempt" => attempt,
           "auth_token" => auth_token,
           "status" => status,
           "started_at" => started_at,
           "spec_path" => spec_path,
           "log_path" => log_path
         } = decoded,
         path
       )
       when is_binary(worker_id) and is_binary(issue_id) and is_binary(identifier) and
              is_integer(attempt) and is_binary(auth_token) and is_binary(status) and
              is_binary(started_at) and is_binary(spec_path) and is_binary(log_path) do
    {:ok,
     %{
       version: @version,
       worker_id: worker_id,
       issue_id: issue_id,
       issue_identifier: identifier,
       attempt: attempt,
       worker_host: Map.get(decoded, "worker_host"),
       auth_token: auth_token,
       port: Map.get(decoded, "port"),
       os_pid: Map.get(decoded, "os_pid"),
       status: status,
       started_at: started_at,
       run_dir: Path.dirname(path),
       manifest_path: path,
       spec_path: spec_path,
       log_path: log_path
     }}
  end

  defp decode_manifest(_decoded, _path), do: {:error, :invalid_worker_manifest}

  defp run_dir(issue_id) do
    digest = :crypto.hash(:sha256, issue_id) |> Base.url_encode64(padding: false)
    Path.join(root(), digest)
  end

  defp log_root do
    Application.get_env(:symphony_elixir, :persistent_worker_log_root) ||
      Path.join([System.user_home!(), ".symphony", "worker-logs"])
  end

  defp random_token do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp normalize_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_attempt(_attempt), do: 1

  defp safe_runner_opts(opts) do
    Keyword.take(opts, [:wait_resume_prompt])
  end

  defp process_exists_fallback?(pid) do
    case System.find_executable("kill") do
      nil -> false
      executable -> match?({_output, 0}, System.cmd(executable, ["-0", Integer.to_string(pid)]))
    end
  rescue
    _error -> false
  end
end
