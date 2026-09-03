defmodule SymphonyElixir.Linear.RateLimitTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.Linear.RateLimit

  test "one response cooldown is shared and only extends forward" do
    state_root = temporary_state_root()
    name = Module.concat(__MODULE__, :SharedCooldown)
    start_supervised!({RateLimit, name: name, state_root: state_root})

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

  test "independent VM-local servers share a host cooldown through deadline shards" do
    state_root = temporary_state_root()
    first = Module.concat(__MODULE__, :FirstVmCooldown)
    second = Module.concat(__MODULE__, :SecondVmCooldown)

    start_supervised!(%{
      id: first,
      start: {RateLimit, :start_link, [[name: first, state_root: state_root]]}
    })

    start_supervised!(%{
      id: second,
      start: {RateLimit, :start_link, [[name: second, state_root: state_root]]}
    })

    assert :ok = RateLimit.check(second)
    assert :ok = RateLimit.backoff(first, 100)
    assert {:error, {:rate_limited, remaining_ms}} = RateLimit.check(second)
    assert remaining_ms > 0

    assert :ok = RateLimit.reset(first)
    assert :ok = RateLimit.reset(second)
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

  test "checks prune expired and malformed shared deadline shards" do
    state_root = temporary_state_root()
    name = Module.concat(__MODULE__, :PruningCooldown)
    start_supervised!({RateLimit, name: name, state_root: state_root})
    File.mkdir_p!(state_root)

    expired = Path.join(state_root, "expired.deadline")
    malformed = Path.join(state_root, "malformed.deadline")
    File.write!(expired, "0")
    File.write!(malformed, "not-a-deadline")

    assert :ok = RateLimit.check(name)
    refute File.exists?(expired)
    refute File.exists?(malformed)
  end

  test "a shard write failure retains a VM-local cooldown and logs the degraded scope" do
    name = Module.concat(__MODULE__, :UnwritableCooldown)
    start_supervised!({RateLimit, name: name, state_root: "/proc/symphony-linear-rate-limit-test"})

    log = capture_log(fn -> assert :ok = RateLimit.backoff(name, 1_000) end)

    assert log =~ "Unable to publish host-wide Linear cooldown"
    assert {:error, {:rate_limited, remaining_ms}} = RateLimit.check(name)
    assert remaining_ms > 0
    assert :ok = RateLimit.reset(name)
  end

  test "default state root resolves when no override is configured" do
    previous = Application.get_env(:symphony_elixir, :linear_rate_limit_state_root)
    Application.delete_env(:symphony_elixir, :linear_rate_limit_state_root)
    on_exit(fn -> Application.put_env(:symphony_elixir, :linear_rate_limit_state_root, previous) end)

    name = Module.concat(__MODULE__, :DefaultStateRoot)
    start_supervised!({RateLimit, name: name})
  end

  defp temporary_state_root do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-linear-rate-limit-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    root
  end
end
