defmodule SymphonyElixir.DrainStore do
  @moduledoc """
  Persists reversible orchestrator drain mode across process restarts.
  """

  require Logger

  @default_filename "drain-state.json"

  @type state :: %{enabled: boolean(), started_at: DateTime.t() | nil}

  @doc "Load the persisted drain flag, defaulting safely to normal operation."
  @spec load() :: state()
  def load do
    with {:ok, contents} <- File.read(path()),
         {:ok, decoded} <- Jason.decode(contents),
         {:ok, state} <- decode(decoded) do
      state
    else
      {:error, :enoent} ->
        %{enabled: false, started_at: nil}

      {:error, reason} ->
        Logger.warning("Failed to load drain state: #{inspect(reason)}")
        %{enabled: false, started_at: nil}
    end
  end

  @doc "Persist enabled or normal scheduling mode atomically."
  @spec persist(boolean(), DateTime.t() | nil) :: :ok | {:error, term()}
  def persist(enabled, started_at) when is_boolean(enabled) do
    payload = %{
      "enabled" => enabled,
      "started_at" => started_at && DateTime.to_iso8601(started_at)
    }

    target = path()
    temporary = target <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.write(temporary, Jason.encode!(payload)),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, target) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temporary)
        {:error, reason}
    end
  end

  @doc "Return the configured drain-state path."
  @spec path() :: Path.t()
  def path do
    Application.get_env(:symphony_elixir, :drain_state_path) ||
      Path.join([System.user_home!(), ".symphony", @default_filename])
  end

  defp decode(%{"enabled" => enabled, "started_at" => started_at}) when is_boolean(enabled) do
    with {:ok, parsed_started_at} <- parse_started_at(started_at) do
      {:ok, %{enabled: enabled, started_at: if(enabled, do: parsed_started_at, else: nil)}}
    end
  end

  defp decode(_decoded), do: {:error, :invalid_drain_state}

  defp parse_started_at(nil), do: {:ok, nil}

  defp parse_started_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _other -> {:error, :invalid_drain_started_at}
    end
  end

  defp parse_started_at(_value), do: {:error, :invalid_drain_started_at}
end
