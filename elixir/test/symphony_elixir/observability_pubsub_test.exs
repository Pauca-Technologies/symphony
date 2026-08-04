defmodule SymphonyElixir.ObservabilityPubSubTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixirWeb.ObservabilityPubSub

  test "subscribe and broadcast_update deliver dashboard updates" do
    assert :ok = ObservabilityPubSub.subscribe()
    assert :ok = ObservabilityPubSub.broadcast_update()
    assert_receive :observability_updated, 500
  end

  test "a burst of updates is coalesced into one broadcast" do
    server = Module.concat(__MODULE__, :BurstCoalescer)

    start_supervised!({ObservabilityPubSub, name: server, coalesce_window_ms: 25})

    assert :ok = ObservabilityPubSub.subscribe()

    for _index <- 1..100 do
      assert :ok = ObservabilityPubSub.broadcast_update(server)
    end

    assert_receive :observability_updated, 250
    refute_receive :observability_updated, 75
  end

  test "broadcast_update is a no-op when pubsub is unavailable" do
    pubsub_child_id = Phoenix.PubSub.Supervisor

    on_exit(fn ->
      if Process.whereis(SymphonyElixir.PubSub) == nil do
        assert {:ok, _pid} =
                 Supervisor.restart_child(SymphonyElixir.Supervisor, pubsub_child_id)
      end
    end)

    assert is_pid(Process.whereis(SymphonyElixir.PubSub))
    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, pubsub_child_id)
    refute Process.whereis(SymphonyElixir.PubSub)

    assert :ok = ObservabilityPubSub.broadcast_update()
  end
end
