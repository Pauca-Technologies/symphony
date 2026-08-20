defmodule SymphonyElixir.Linear.RateLimitTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Linear.RateLimit

  test "one response cooldown is shared and only extends forward" do
    name = Module.concat(__MODULE__, :SharedCooldown)
    start_supervised!({RateLimit, name: name})

    assert :ok = RateLimit.check(name)
    assert :ok = RateLimit.backoff(name, 100)
    assert {:error, {:rate_limited, remaining_ms}} = RateLimit.check(name)
    assert remaining_ms > 0

    assert :ok = RateLimit.backoff(name, 10)
    assert {:error, {:rate_limited, extended_ms}} = RateLimit.check(name)
    assert extended_ms >= remaining_ms - 10

    assert :ok = RateLimit.reset(name)
    assert :ok = RateLimit.check(name)
  end

  test "default server helpers fail open when unavailable and accept every GenServer address form" do
    assert {:error, {:already_started, _pid}} = RateLimit.start_link()

    pid = Process.whereis(RateLimit)
    assert is_pid(pid)
    assert :ok = RateLimit.check(pid)
    assert :ok = RateLimit.check({RateLimit, node()})

    missing = Module.concat(__MODULE__, :UnavailableCooldown)
    assert :ok = RateLimit.check(missing)
    assert :ok = RateLimit.backoff(missing, nil)
    assert :ok = RateLimit.reset(missing)

    assert :ok = RateLimit.backoff(nil)
    assert {:error, {:rate_limited, remaining_ms}} = RateLimit.check()
    assert remaining_ms > 0
    assert :ok = RateLimit.reset()
    assert :ok = RateLimit.check()
  end
end
