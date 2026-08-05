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
    server = Module.concat(__MODULE__, :MissingPubSubCoalescer)
    missing_pubsub = Module.concat(__MODULE__, :MissingPubSub)

    start_supervised!({ObservabilityPubSub, name: server, pubsub: missing_pubsub, coalesce_window_ms: 10_000})

    assert :ok = ObservabilityPubSub.broadcast_update(server)
    send(Process.whereis(server), :flush_update)

    assert %{timer: nil} = :sys.get_state(server)
  end
end
