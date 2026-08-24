defmodule SymphonyElixir.WaitStore do
  @moduledoc "Persists parked agent waits across Symphony restarts."

  require Logger

  @default_filename "waits.json"

  @doc "Load persisted wait entries, returning an empty map on invalid state."
  @spec load() :: map()
  def load do
    with {:ok, contents} <- File.read(path()),
         {:ok, %{"entries" => entries}} when is_list(entries) <- Jason.decode(contents) do
      Map.new(entries, fn entry -> {entry["issue_id"], decode_entry(entry)} end)
    else
      {:error, :enoent} -> %{}
      reason -> log_load_failure(reason)
    end
  rescue
    error -> log_load_failure(error)
  end

  @doc "Atomically persist wait entries."
  @spec save(map()) :: :ok
  def save(entries) when is_map(entries) do
    target = path()
    temporary = target <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))
    payload = Jason.encode!(%{version: 1, entries: Enum.map(Map.values(entries), &encode_entry/1)})

    with :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.write(temporary, payload),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, target) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temporary)
        Logger.warning("Failed to persist agent waits: #{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("Failed to persist agent waits: #{Exception.message(error)}")
      :ok
  end

  @doc "Return the configured wait-state path."
  @spec path() :: Path.t()
  def path do
    Application.get_env(:symphony_elixir, :wait_state_path) ||
      Path.join([System.user_home!(), ".symphony", @default_filename])
  end

  defp encode_entry(entry) do
    entry
    |> Map.take([
      :issue_id,
      :identifier,
      :title,
      :backend,
      :worker_host,
      :workspace_path,
      :codex_session_logs,
      :recent_codex_transcript_blocks,
      :priority,
      :created_at,
      :request,
      :status,
      :parked_at,
      :next_probe_at,
      :probe_attempt,
      :last_observation,
      :last_error,
      :resume_prompt
    ])
    |> Map.update(:status, "waiting", &to_string/1)
    |> Map.update(:created_at, nil, &datetime/1)
    |> Map.update(:parked_at, nil, &datetime/1)
    |> Map.update(:next_probe_at, nil, &datetime/1)
  end

  defp decode_entry(entry) do
    last_observation = entry["last_observation"]

    %{
      issue_id: entry["issue_id"],
      identifier: entry["identifier"],
      title: entry["title"],
      backend: entry["backend"],
      worker_host: entry["worker_host"],
      workspace_path: entry["workspace_path"],
      codex_session_logs: entry["codex_session_logs"] || [],
      recent_codex_transcript_blocks: entry["recent_codex_transcript_blocks"] || [],
      priority: entry["priority"],
      created_at: parse_datetime(entry["created_at"]),
      request: atomize_request(entry["request"] || %{}, last_observation),
      status: if(entry["status"] == "ready", do: :ready, else: :waiting),
      parked_at: parse_datetime(entry["parked_at"]) || DateTime.utc_now(),
      next_probe_at: parse_datetime(entry["next_probe_at"]) || DateTime.utc_now(),
      probe_attempt: entry["probe_attempt"] || 0,
      last_observation: last_observation,
      last_error: entry["last_error"],
      resume_prompt: entry["resume_prompt"]
    }
  end

  defp atomize_request(request, last_observation) do
    %{
      condition: request["condition"] || %{},
      condition_key: request["condition_key"],
      baseline: request["baseline"] || last_observation,
      reason: request["reason"],
      min_poll_ms: request["min_poll_ms"] || 60_000,
      max_poll_ms: request["max_poll_ms"] || 1_800_000
    }
  end

  defp datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime(value), do: value

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp log_load_failure(reason) do
    Logger.warning("Failed to load persisted agent waits: #{inspect(reason)}")
    %{}
  end
end
