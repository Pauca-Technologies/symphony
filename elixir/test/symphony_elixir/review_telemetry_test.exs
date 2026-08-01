defmodule SymphonyElixir.ReviewTelemetryTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Linear.Issue, ReviewTelemetry}

  setup do
    handler_id = "review-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        ReviewTelemetry.event(),
        fn event, measurements, metadata, _config ->
          send(test_pid, {:review_telemetry, event, measurements, metadata})
        end,
        nil
      )

    previous_enabled = Application.get_env(:symphony_elixir, :telemetry_enabled)
    Application.put_env(:symphony_elixir, :telemetry_enabled, false)

    on_exit(fn ->
      :telemetry.detach(handler_id)

      if is_nil(previous_enabled) do
        Application.delete_env(:symphony_elixir, :telemetry_enabled)
      else
        Application.put_env(:symphony_elixir, :telemetry_enabled, previous_enabled)
      end
    end)

    :ok
  end

  test "attributes tokens, duration, model, reasoning, and findings to parent and lens threads" do
    issue = %Issue{id: "issue-1", identifier: "UDPE-7158"}
    packet = %{packet_id: "review-packet-v1-abc", candidate: %{head_sha: "head-1"}}
    test_pid = self()

    {handle, callback} =
      ReviewTelemetry.start(issue, packet, fn message -> send(test_pid, {:heartbeat, message.event}) end)

    callback.(%{
      event: :session_started,
      thread_id: "parent-thread",
      model: "gpt-review",
      reasoning_effort: "high"
    })

    # Real app-server notification shape: cumulative usage lives below
    # payload.params.tokenUsage.total, not in top-level message metadata.
    callback.(%{
      event: :notification,
      payload: %{
        "method" => "thread/tokenUsage/updated",
        "params" => %{
          "thread_id" => "parent-thread",
          "tokenUsage" => %{
            "total" => %{"inputTokens" => 100, "outputTokens" => 30, "totalTokens" => 130}
          }
        }
      }
    })

    # A newer absolute counter replaces the older one; it must not be added to
    # it. Atom-key variants are emitted by some injected/backend fixtures.
    callback.(%{
      event: :notification,
      payload: %{
        method: "thread/tokenUsage/updated",
        params: %{
          thread_id: "parent-thread",
          tokenUsage: %{total: %{input_tokens: 140, output_tokens: 40, total_tokens: 180}}
        }
      }
    })

    # Delegated lens event using the legacy Codex token_count msg payload. The
    # first absolute map omits total, so ReviewTelemetry synthesizes input+output.
    callback.(%{
      event: :notification,
      payload: %{
        "method" => "codex/event/token_count",
        "params" => %{
          "threadId" => "lens-security",
          "msg" => %{
            "payload" => %{
              "info" => %{
                "total_token_usage" => %{"input_tokens" => "45", "output_tokens" => 10}
              }
            }
          }
        }
      },
      model: "gpt-lens",
      reasoning_effort: "medium",
      findings: [%{severity: "major"}]
    })

    callback.(%{
      event: :notification,
      payload: %{
        "method" => "thread/tokenUsage/updated",
        "params" => %{
          "threadId" => "lens-security",
          "tokenUsage" => %{
            "total" => %{"inputTokens" => 60, "outputTokens" => 15, "totalTokens" => 75}
          }
        }
      }
    })

    ReviewTelemetry.finish(handle, :request_changes, %{comments: [%{}, %{}]})

    assert_receive {:heartbeat, :session_started}

    events =
      for _index <- 1..2, into: %{} do
        assert_receive {:review_telemetry, _, measurements, metadata}
        {metadata.role, {measurements, metadata}}
      end

    {parent_measurements, parent} = Map.fetch!(events, "parent_reviewer")

    assert parent_measurements.tokens == 180
    assert parent_measurements.findings == 2
    assert is_integer(parent_measurements.duration_ms)
    assert parent.model == "gpt-review"
    assert parent.reasoning_effort == "high"
    assert parent.reviewed_sha == "head-1"

    {lens_measurements, lens} = Map.fetch!(events, "lens")

    assert lens_measurements.tokens == 75
    assert lens_measurements.findings == 1
    assert lens.model == "gpt-lens"
    assert lens.reasoning_effort == "medium"
    refute_receive {:review_telemetry, _, _, _}
  end

  test "retains flat backend usage and synthesizes a missing total" do
    issue = %Issue{id: "issue-flat", identifier: "UDPE-FLAT"}
    packet = %{packet_id: "review-packet-v1-flat", candidate: %{head_sha: "head-flat"}}
    {handle, callback} = ReviewTelemetry.start(issue, packet, nil)

    callback.(%{
      event: :session_started,
      thread_id: "flat-parent",
      model: "acp-model",
      usage: %{"input_tokens" => 7, "output_tokens" => 5}
    })

    ReviewTelemetry.finish(handle, :approved, %{comments: []})

    assert_receive {:review_telemetry, _, %{tokens: 12}, %{thread_id: "flat-parent", role: "parent_reviewer", model: "acp-model"}}
  end
end
