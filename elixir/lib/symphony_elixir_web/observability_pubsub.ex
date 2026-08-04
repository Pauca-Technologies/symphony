defmodule SymphonyElixirWeb.ObservabilityPubSub do
  @moduledoc """
  Coalesces and broadcasts observability dashboard updates.

  Protocol streams can produce hundreds of events per second. The dashboard only
  needs a prompt signal that state changed, so a short trailing-edge window turns
  each event burst into one PubSub message.
  """

  use GenServer

  @pubsub SymphonyElixir.PubSub
  @topic "observability:dashboard"
  @update_message :observability_updated
  @default_coalesce_window_ms 250

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @spec broadcast_update() :: :ok
  def broadcast_update do
    broadcast_update(__MODULE__)
  end

  @spec broadcast_update(GenServer.server()) :: :ok
  def broadcast_update(server) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> GenServer.cast(pid, :broadcast_update)
      _ -> :ok
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       coalesce_window_ms: Keyword.get(opts, :coalesce_window_ms, @default_coalesce_window_ms),
       timer: nil
     }}
  end

  @impl true
  def handle_cast(:broadcast_update, %{timer: nil} = state) do
    timer = Process.send_after(self(), :flush_update, state.coalesce_window_ms)
    {:noreply, %{state | timer: timer}}
  end

  def handle_cast(:broadcast_update, state), do: {:noreply, state}

  @impl true
  def handle_info(:flush_update, state) do
    broadcast_now()
    {:noreply, %{state | timer: nil}}
  end

  defp broadcast_now do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) -> Phoenix.PubSub.broadcast(@pubsub, @topic, @update_message)
      _ -> :ok
    end
  end
end
