defmodule SymphonyElixir.Linear.RateLimit do
  @moduledoc """
  Process-wide cooldown for the shared Linear account budget.

  Every Linear caller goes through `Linear.Client`, so one rate-limit response
  can stop polling, agent tools, retries, and comment reads from independently
  spending the same exhausted account budget.
  """

  use GenServer

  @default_backoff_ms 60_000

  @type state :: %{until_ms: integer()}

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
  def init(_opts), do: {:ok, %{until_ms: now_ms()}}

  @impl true
  def handle_call(:check, _from, state) do
    remaining_ms = state.until_ms - now_ms()

    if remaining_ms > 0 do
      {:reply, {:error, {:rate_limited, remaining_ms}}, state}
    else
      {:reply, :ok, %{state | until_ms: now_ms()}}
    end
  end

  def handle_call({:backoff, backoff_ms}, _from, state) do
    until_ms = max(state.until_ms, now_ms() + backoff_ms)
    {:reply, :ok, %{state | until_ms: until_ms}}
  end

  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{until_ms: now_ms()}}

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

  defp now_ms, do: System.monotonic_time(:millisecond)
end
