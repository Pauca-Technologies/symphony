defmodule SymphonyElixir.TokenAccountingTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TokenAccounting

  test "accepts cumulative high-water deltas once per actual thread" do
    first = usage_update("parent", 100, 20, 120)
    repeated = usage_update("parent", 100, 20, 120)
    delegated = usage_update("delegated", 40, 10, 50)

    {waters, first_observation} = TokenAccounting.observe(%{}, first, "fallback")
    {waters, repeated_observation} = TokenAccounting.observe(waters, repeated, "fallback")
    {waters, delegated_observation} = TokenAccounting.observe(waters, delegated, "fallback")

    assert first_observation.accepted_delta.total_tokens == 120
    assert repeated_observation.accepted_delta.total_tokens == 0
    assert delegated_observation.accepted_delta.total_tokens == 50
    assert waters["parent"].total_tokens == 120
    assert waters["delegated"].total_tokens == 50
  end

  test "retains latest interrupted-thread totals and distinct cached/reasoning semantics" do
    update = %{
      thread_id: "interrupted-thread",
      usage: %{
        "input_tokens" => 200,
        "cached_input_tokens" => 150,
        "output_tokens" => 80,
        "reasoning_tokens" => 60,
        "total_tokens" => 280,
        "context_window" => 200_000
      }
    }

    {waters, observation} = TokenAccounting.observe(%{}, update, nil)

    assert observation.cumulative == %{
             input_tokens: 200,
             cached_input_tokens: 150,
             output_tokens: 80,
             reasoning_tokens: 60,
             total_tokens: 280,
             context_window: 200_000
           }

    # No completion event is required to retain the last valid cumulative use.
    assert waters["interrupted-thread"].total_tokens == 280

    refute observation.cumulative.total_tokens ==
             observation.cumulative.input_tokens + observation.cumulative.cached_input_tokens +
               observation.cumulative.output_tokens + observation.cumulative.reasoning_tokens
  end

  test "ignores out-of-order lower snapshots without losing the high water" do
    {waters, _observation} = TokenAccounting.observe(%{}, usage_update("thread", 100, 50, 150), nil)
    {waters, observation} = TokenAccounting.observe(waters, usage_update("thread", 80, 30, 110), nil)

    assert observation.accepted_delta.total_tokens == 0
    assert waters["thread"].total_tokens == 150
  end

  defp usage_update(thread_id, input, output, total) do
    %{
      payload: %{
        "method" => "thread/tokenUsage/updated",
        "params" => %{
          "threadId" => thread_id,
          "tokenUsage" => %{
            "total" => %{
              "inputTokens" => input,
              "outputTokens" => output,
              "totalTokens" => total
            }
          }
        }
      }
    }
  end
end
