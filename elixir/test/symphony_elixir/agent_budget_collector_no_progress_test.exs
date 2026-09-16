defmodule SymphonyElixir.AgentBudgetCollectorNoProgressTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{AgentBudgetCollector, ToolAttempt}
  alias SymphonyElixir.Config.AgentEfficiency
  alias SymphonyElixir.Linear.Issue

  test "uses the existing table and barrier without changing budget snapshot keys" do
    collector = start_collector()

    try do
      ref = AgentBudgetCollector.ref(collector)
      initial_size = :ets.info(ref.table, :size)
      assert initial_size == 130

      :ok = AgentBudgetCollector.start_turn(collector, "prompt", 100)
      :ok = AgentBudgetCollector.observe(ref, usage("parent", 20))
      budget = AgentBudgetCollector.finish_turn(collector, 110)

      assert Map.keys(budget) |> Enum.sort() == [:metrics, :transitions]
      assert budget.metrics.total_tokens == 20
      assert :ets.info(ref.table, :size) > initial_size
    after
      AgentBudgetCollector.stop(collector)
    end
  end

  test "stores only fixed-slot safe signals and preserves detector state across turns" do
    collector = start_collector(%{error_repeat_threshold: 2})

    try do
      ref = AgentBudgetCollector.ref(collector)
      initial_size = :ets.info(ref.table, :size)
      failure = terminal(:tool_call_failed, "CALL-ID-SECRET", %{"token" => "ARG-SECRET"}, "OUTPUT-SECRET")

      AgentBudgetCollector.observe(ref, failure)
      AgentBudgetCollector.observe(ref, failure)

      assert :ets.info(ref.table, :size) == initial_size
      retained = inspect(:ets.tab2list(ref.table))
      refute retained =~ "CALL-ID-SECRET"
      refute retained =~ "ARG-SECRET"
      refute retained =~ "OUTPUT-SECRET"

      first = AgentBudgetCollector.assess_no_progress(collector, %{repository: :unchanged})
      assert first.decision == :alert
      assert first.warning.operation == "read"
      assert first.summary.completed_attempts == 2
      assert first.summary.active_warning_count == 1
      assert first.checkpoint.latched_fingerprints == [first.warning.fingerprint]
      assert :ets.info(ref.table, :size) == initial_size

      second = AgentBudgetCollector.assess_no_progress(collector, %{repository: :unchanged})
      assert second.decision == :none
      assert second.summary.turn_completed_attempts == 0
      assert second.summary.active_warning_count == 1
      assert second.checkpoint == first.checkpoint
    after
      AgentBudgetCollector.stop(collector)
    end
  end

  test "reports exact evictions while bounding a turn to 128 safe signals" do
    collector = start_collector(%{error_repeat_threshold: 2})

    try do
      ref = AgentBudgetCollector.ref(collector)
      initial_size = :ets.info(ref.table, :size)

      Enum.each(1..140, fn index ->
        AgentBudgetCollector.observe(ref, terminal(:tool_call_failed, "call-#{index}", %{"path" => "same"}, "ignored"))
      end)

      result = AgentBudgetCollector.assess_no_progress(collector, %{repository: :unchanged})
      assert result.decision == :alert
      assert result.summary.turn_completed_attempts == 128
      assert result.summary.turn_omissions == %{"signal_evicted" => 12}
      assert result.summary.signal_evictions == 12
      assert :ets.info(ref.table, :size) == initial_size
    after
      AgentBudgetCollector.stop(collector)
    end
  end

  test "ignored streaming callbacks cannot evict a correlated start" do
    collector = start_collector()

    try do
      ref = AgentBudgetCollector.ref(collector)
      AgentBudgetCollector.observe(ref, start("claude-call", "README.md"))

      Enum.each(1..200, fn index ->
        AgentBudgetCollector.observe(ref, stream("claude-call", "RAW-STREAM-#{index}"))
      end)

      AgentBudgetCollector.observe(ref, claude_terminal("claude-call", "RAW-TERMINAL"))
      result = AgentBudgetCollector.assess_no_progress(collector, %{repository: :unchanged})

      assert result.summary.turn_completed_attempts == 1
      assert result.summary.turn_omissions == %{}
      assert result.summary.signal_evictions == 0
    after
      AgentBudgetCollector.stop(collector)
    end
  end

  test "assessment barrier includes callbacks submitted concurrently" do
    collector = start_collector(%{success_repeat_threshold: 1_000})

    try do
      ref = AgentBudgetCollector.ref(collector)
      parent = self()

      tasks =
        Enum.map(1..80, fn index ->
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> AgentBudgetCollector.observe(ref, terminal(:tool_call_completed, "call-#{index}", %{"path" => index}, "raw"))
            end
          end)
        end)

      pids =
        Enum.map(1..80, fn _ ->
          assert_receive {:ready, pid}
          pid
        end)

      Enum.each(pids, &send(&1, :go))
      wait_until(fn -> :atomics.get(ref.counters, 1) == 80 end)

      result = AgentBudgetCollector.assess_no_progress(collector, %{repository: :unchanged})
      assert result.summary.turn_completed_attempts == 80
      Enum.each(tasks, &Task.await(&1, 1_000))
    after
      AgentBudgetCollector.stop(collector)
    end
  end

  test "an older delayed slot write cannot replace a newer generation" do
    collector = start_collector()

    try do
      ref = AgentBudgetCollector.ref(collector)
      {:ok, newer} = ToolAttempt.normalize(terminal(:tool_call_completed, "newer", %{"path" => "new"}, "raw"))
      key = {:no_progress_signal, 0}
      :ets.insert(ref.table, {key, 129, 129, newer})

      AgentBudgetCollector.observe(ref, terminal(:tool_call_completed, "older", %{"path" => "old"}, "raw"))
      assert [{^key, 129, 129, ^newer}] = :ets.lookup(ref.table, key)

      result = AgentBudgetCollector.assess_no_progress(collector, %{repository: :unchanged})
      assert result.summary.turn_completed_attempts == 0
      assert result.summary.turn_omissions == %{"signal_evicted" => 1}
    after
      AgentBudgetCollector.stop(collector)
    end
  end

  test "assessment checkpoint never exceeds the configured fingerprint cap" do
    collector = start_collector(%{max_fingerprints: 1})

    try do
      a = String.duplicate("a", 64)
      b = String.duplicate("b", 64)
      assert :ok = AgentBudgetCollector.restore_no_progress_latches(collector, [a, b])

      result = AgentBudgetCollector.assess_no_progress(collector, %{repository: :unchanged})
      assert length(result.checkpoint.latched_fingerprints) == 1
      assert result.checkpoint.latched_fingerprints == [b]
    after
      AgentBudgetCollector.stop(collector)
    end
  end

  test "malformed safe rows and observation after stop are non-blocking" do
    collector = start_collector()
    ref = AgentBudgetCollector.ref(collector)

    AgentBudgetCollector.observe(ref, stream("ignored", "raw"))
    :ets.insert(ref.table, {{:no_progress_signal, 0}, 1, 1, %{raw: "UNSAFE"}})

    result = AgentBudgetCollector.assess_no_progress(collector, %{repository: :unchanged})
    assert result.summary.turn_omissions == %{"invalid_signal" => 1}

    AgentBudgetCollector.stop(collector)
    assert AgentBudgetCollector.observe(ref, terminal(:tool_call_completed, "late", %{}, "raw")) == :ok
  end

  defp start_collector(no_progress_config \\ %{}) do
    {:ok, collector} =
      AgentBudgetCollector.start_link(decision(), issue(), %{}, no_progress_config)

    collector
  end

  defp decision do
    {:ok, settings} = AgentEfficiency.parse(%{})

    %{
      mode: "shadow",
      task_type: "simple_direct",
      confidence: 1.0,
      classification: %{},
      budget_profile: "high_risk",
      budget: settings.profiles["high_risk"],
      override: nil,
      capsule_max_bytes: 1_000,
      extreme_multiplier: 3.0,
      enforced_actions: [],
      enforced: false
    }
  end

  defp issue do
    %Issue{
      id: "issue-no-progress",
      identifier: "UDPE-7503",
      title: "Detect loops",
      state: "In Progress",
      labels: [],
      blocked_by: [],
      children: []
    }
  end

  defp usage(thread_id, total) do
    %{
      event: :token_usage,
      thread_id: thread_id,
      usage: %{input_tokens: total, cached_input_tokens: 0, output_tokens: 0, total_tokens: total}
    }
  end

  defp terminal(event, call_id, arguments, output) do
    %{
      event: event,
      thread_id: "thread-1",
      payload: %{
        "method" => "item/tool/call",
        "params" => %{"callId" => call_id, "name" => "Read", "arguments" => arguments}
      },
      details: %{result: %{"success" => event == :tool_call_completed, "output" => output}}
    }
  end

  defp start(call_id, path) do
    %{
      event: :notification,
      thread_id: "thread-1",
      payload: %{
        "method" => "item/tool/call",
        "params" => %{"callId" => call_id, "name" => "Read", "arguments" => %{"file_path" => path}}
      }
    }
  end

  defp stream(call_id, output) do
    %{
      event: :notification,
      thread_id: "thread-1",
      payload: %{
        "method" => "item/commandExecution/outputDelta",
        "params" => %{"callId" => call_id, "terminal" => false, "output" => output}
      }
    }
  end

  defp claude_terminal(call_id, output) do
    %{
      event: :notification,
      thread_id: "thread-1",
      payload: %{
        "method" => "item/commandExecution/outputDelta",
        "params" => %{"callId" => call_id, "terminal" => true, "status" => "completed", "output" => output}
      }
    }
  end

  defp wait_until(fun, attempts \\ 100)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(1)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("condition was not met")
end
