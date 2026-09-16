defmodule SymphonyElixir.Linear.RateLimit do
  @moduledoc """
  Host-wide cooldown for the shared Linear account budget.

  Every Linear caller goes through `Linear.Client`, so one rate-limit response
  can stop polling, agent tools, retries, and comment reads across the main
  orchestrator and its persistent-worker BEAM VMs.

  Each VM publishes an absolute cooldown deadline in its own shard under the
  Symphony runtime directory. Checks use the furthest live deadline. Separate
  shard files avoid lost-update races between independent VMs, while atomic
  renames keep readers from observing partial writes.
  """

  use GenServer
  require Logger

  @default_backoff_ms 60_000

  @type state :: %{until_epoch_ms: integer(), shard_path: Path.t(), state_root: Path.t()}

  @doc "Start the shared Linear cooldown process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Return `:ok` when a request may proceed, or the remaining cooldown."
  @spec check() :: :ok | {:error, {:rate_limited, pos_integer()}}
  def check, do: check(__MODULE__)

  @spec check(GenServer.server()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def check(server) do
    if process_available?(server), do: GenServer.call(server, :check), else: :ok
  end

  @doc "Extend the shared cooldown from a Linear Retry-After hint."
  @spec backoff(pos_integer() | nil) :: :ok
  def backoff(retry_after_ms), do: backoff(__MODULE__, retry_after_ms)

  @spec backoff(GenServer.server(), pos_integer() | nil) :: :ok
  def backoff(server, retry_after_ms) do
    if process_available?(server) do
      GenServer.call(server, {:backoff, normalize_backoff(retry_after_ms)})
    else
      :ok
    end
  end

  @doc false
  @spec reset() :: :ok
  def reset, do: reset(__MODULE__)

  @spec reset(GenServer.server()) :: :ok
  def reset(server) do
    if process_available?(server), do: GenServer.call(server, :reset), else: :ok
  end

  @impl true
  def init(opts) do
    state_root = Keyword.get(opts, :state_root, state_root())

    shard_path =
      Path.join(
        state_root,
        "cooldown-#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}.deadline"
      )

    {:ok, %{until_epoch_ms: epoch_ms(), shard_path: shard_path, state_root: state_root}}
  end

  @impl true
  def handle_call(:check, _from, state) do
    now_epoch_ms = epoch_ms()
    shared_until_epoch_ms = shared_until_epoch_ms(state.state_root, now_epoch_ms)
    until_epoch_ms = max(state.until_epoch_ms, shared_until_epoch_ms)
    remaining_ms = until_epoch_ms - now_epoch_ms

    if remaining_ms > 0 do
      {:reply, {:error, {:rate_limited, remaining_ms}}, %{state | until_epoch_ms: until_epoch_ms}}
    else
      {:reply, :ok, %{state | until_epoch_ms: now_epoch_ms}}
    end
  end

  def handle_call({:backoff, backoff_ms}, _from, state) do
    until_epoch_ms = max(state.until_epoch_ms, epoch_ms() + backoff_ms)

    case persist_deadline(state.shard_path, until_epoch_ms) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Unable to publish host-wide Linear cooldown; retaining VM-local cooldown reason=#{inspect(reason)}")
    end

    {:reply, :ok, %{state | until_epoch_ms: until_epoch_ms}}
  end

  def handle_call(:reset, _from, state) do
    _ = File.rm(state.shard_path)
    {:reply, :ok, %{state | until_epoch_ms: epoch_ms()}}
  end

  defp process_available?(server) when is_atom(server), do: Process.whereis(server) != nil
  defp process_available?(server) when is_pid(server), do: Process.alive?(server)
  defp process_available?(_server), do: true

  defp normalize_backoff(retry_after_ms) when is_integer(retry_after_ms) and retry_after_ms > 0,
    do: max(retry_after_ms, default_backoff_ms())

  defp normalize_backoff(_retry_after_ms), do: default_backoff_ms()

  defp default_backoff_ms do
    Application.get_env(
      :symphony_elixir,
      :linear_rate_limit_default_backoff_ms,
      @default_backoff_ms
    )
  end

  defp state_root do
    Application.get_env(:symphony_elixir, :linear_rate_limit_state_root) ||
      Path.join([System.user_home!(), ".symphony", "linear-rate-limit"])
  end

  defp shared_until_epoch_ms(state_root, now_epoch_ms) do
    state_root
    |> Path.join("*.deadline")
    |> Path.wildcard()
    |> Enum.reduce(now_epoch_ms, fn path, latest ->
      case read_deadline(path) do
        {:ok, deadline} when deadline > now_epoch_ms ->
          max(latest, deadline)

        {:ok, _expired} ->
          _ = File.rm(path)
          latest

        :error ->
          _ = File.rm(path)
          latest
      end
    end)
  end

  defp read_deadline(path) do
    with {:ok, contents} <- File.read(path),
         {deadline, ""} <- contents |> String.trim() |> Integer.parse() do
      {:ok, deadline}
    else
      _ -> :error
    end
  end

  defp persist_deadline(path, until_epoch_ms) do
    directory = Path.dirname(path)
    temporary_path = path <> ".tmp-#{System.unique_integer([:positive, :monotonic])}"

    with :ok <- File.mkdir_p(directory),
         :ok <- File.write(temporary_path, Integer.to_string(until_epoch_ms)),
         :ok <- File.rename(temporary_path, path) do
      :ok
    else
      reason ->
        _ = File.rm(temporary_path)
        {:error, reason}
    end
  end

  defp epoch_ms, do: System.system_time(:millisecond)
end
