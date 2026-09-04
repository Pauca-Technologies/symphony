defmodule SymphonyElixir.QuotaCircuitStore do
  @moduledoc """
  Best-effort persistence for provider quota circuits.

  The snapshot is intentionally small and contains only outage deadlines and
  serializable parked-retry metadata. It is not a general orchestrator-state
  checkpoint; its purpose is to prevent a restart from immediately recreating
  a provider-wide retry storm.
  """

  require Logger

  alias SymphonyElixir.ResumePacket

  @default_filename "quota-circuits.json"
  @failure_classes [
    :agent_protocol_failure,
    :response_timeout_or_stall,
    :transient_infrastructure,
    :authentication_configuration,
    :usage_quota_limit,
    :rate_limited,
    :review_configuration,
    :handoff_reviewer_gate
  ]

  @doc "Load persisted circuits, returning an empty map on missing or invalid state."
  @spec load() :: map()
  def load do
    with {:ok, contents} <- File.read(path()),
         {:ok, payload} <- Jason.decode(contents),
         %{"circuits" => circuits} when is_map(circuits) <- payload do
      deserialize_circuits(circuits)
    else
      {:error, :enoent} -> %{}
      {:error, reason} -> log_load_failure(reason)
      _ -> log_load_failure(:invalid_payload)
    end
  rescue
    error -> log_load_failure(error)
  end

  @doc "Atomically persist serializable quota circuit state."
  @spec save(map()) :: :ok
  def save(circuits) when is_map(circuits) do
    destination = path()
    temporary = destination <> ".tmp"
    payload = Jason.encode!(%{version: 1, circuits: serialize_circuits(circuits)})

    with :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- File.write(temporary, payload),
         :ok <- File.rename(temporary, destination) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to persist quota circuit state: #{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("Failed to persist quota circuit state: #{Exception.message(error)}")
      :ok
  end

  @doc "Resolve the circuit snapshot path."
  @spec path() :: Path.t()
  def path do
    Application.get_env(:symphony_elixir, :quota_circuit_state_path) ||
      Path.join([System.user_home!(), ".symphony", @default_filename])
  end

  defp serialize_circuits(circuits) do
    Map.new(circuits, fn {circuit_key, circuit} ->
      {circuit_key,
       circuit
       |> Map.take([
         :backend,
         :account_scope,
         :worker_host,
         :provider_limit_id,
         :status,
         :reason,
         :opened_at,
         :reset_at,
         :next_probe_at,
         :probe_issue_id,
         :parked
       ])
       |> stringify_timestamps()
       |> Map.update(:status, "open", &to_string/1)
       |> stringify_keys()}
    end)
  end

  defp deserialize_circuits(circuits) do
    Enum.reduce(circuits, %{}, fn {persisted_key, circuit}, acc ->
      case deserialize_circuit(persisted_key, circuit) do
        nil -> acc
        {circuit_key, parsed} -> Map.put(acc, circuit_key, parsed)
      end
    end)
  end

  defp deserialize_circuit(persisted_key, circuit)
       when is_binary(persisted_key) and is_map(circuit) do
    next_probe_at = parse_datetime(circuit["next_probe_at"])

    if is_struct(next_probe_at, DateTime) do
      backend = circuit["backend"] || backend_from_key(persisted_key)
      worker_host = circuit["worker_host"]
      account_scope = account_scope(worker_host)
      circuit_key = normalize_circuit_key(persisted_key)

      {circuit_key,
       %{
         backend: backend,
         account_scope: account_scope,
         worker_host: worker_host,
         provider_limit_id: circuit["provider_limit_id"],
         status: :open,
         reason: circuit["reason"] || "restored provider quota circuit",
         opened_at: parse_datetime(circuit["opened_at"]) || DateTime.utc_now(),
         reset_at: parse_datetime(circuit["reset_at"]),
         next_probe_at: next_probe_at,
         probe_issue_id: nil,
         parked: deserialize_parked(circuit["parked"]),
         timer_ref: nil,
         timer_token: nil
       }}
    end
  end

  defp deserialize_circuit(_persisted_key, _circuit), do: nil

  defp normalize_circuit_key(persisted_key) when is_binary(persisted_key) do
    if String.contains?(persisted_key, "::") do
      persisted_key
    else
      persisted_key <> "::local"
    end
  end

  defp backend_from_key(persisted_key) do
    persisted_key
    |> String.split("::", parts: 2)
    |> hd()
  end

  defp account_scope(worker_host) when is_binary(worker_host), do: "worker:#{worker_host}"
  defp account_scope(_worker_host), do: "local"

  defp deserialize_parked(parked) when is_list(parked) do
    Enum.flat_map(parked, fn
      %{"issue_id" => issue_id} = entry when is_binary(issue_id) ->
        [
          %{
            issue_id: issue_id,
            identifier: entry["identifier"],
            title: entry["title"],
            attempt: entry["attempt"],
            retry_id: entry["retry_id"],
            previous_retry_id: entry["previous_retry_id"],
            parent_run_id: entry["parent_run_id"],
            error: entry["error"],
            backend: entry["backend"],
            failure_class: deserialize_failure_class(entry["failure_class"]),
            worker_host: entry["worker_host"],
            workspace_path: entry["workspace_path"],
            resume_packet_ref: ResumePacket.normalize_reference(entry["resume_packet_ref"]),
            parked_at: parse_datetime(entry["parked_at"]) || DateTime.utc_now()
          }
        ]

      _ ->
        []
    end)
  end

  defp deserialize_parked(_parked), do: []

  defp stringify_timestamps(circuit) do
    circuit
    |> Map.update(:opened_at, nil, &iso8601/1)
    |> Map.update(:reset_at, nil, &iso8601/1)
    |> Map.update(:next_probe_at, nil, &iso8601/1)
    |> Map.update(:parked, [], fn parked ->
      Enum.map(parked, fn entry ->
        entry
        |> Map.take([
          :issue_id,
          :identifier,
          :title,
          :attempt,
          :retry_id,
          :previous_retry_id,
          :parent_run_id,
          :error,
          :backend,
          :failure_class,
          :worker_host,
          :workspace_path,
          :resume_packet_ref,
          :parked_at
        ])
        |> Map.update(:parked_at, nil, &iso8601/1)
        |> stringify_keys()
      end)
    end)
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(_datetime), do: nil

  defp deserialize_failure_class(value) when is_binary(value) do
    Enum.find(@failure_classes, &(Atom.to_string(&1) == value))
  end

  defp deserialize_failure_class(_value), do: nil

  defp log_load_failure(reason) do
    Logger.warning("Ignoring invalid quota circuit state: #{inspect(reason)}")
    %{}
  end
end
