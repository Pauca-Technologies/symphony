defmodule SymphonyElixir.AgentFailureTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentFailure

  test "trusts only the exact Codex usage-limit code and extracts an ISO reset" do
    reset_at = DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.truncate(:second)

    reason =
      {:turn_completed_abnormally,
       %{
         "turn" => %{
           "status" => "failed",
           "error" => %{
             "codexErrorInfo" => "usageLimitExceeded",
             "message" => "You've hit your usage limit.",
             "resetAt" => DateTime.to_iso8601(reset_at)
           }
         }
       }}

    assert %AgentFailure{
             class: :usage_quota_limit,
             backend: "codex",
             scope: :backend_account,
             trusted: true,
             reset_at: ^reset_at
           } = AgentFailure.classify(reason, backend: "codex")

    assert %AgentFailure{class: :agent_protocol_failure, trusted: false} =
             AgentFailure.classify(reason, backend: "acp")
  end

  test "parses the authoritative English Codex reset hint" do
    reason = %{
      "codexErrorInfo" => "usageLimitExceeded",
      "message" => "You've hit your usage limit. Purchase more credits or try again at August 5th, 2026 6:06 PM."
    }

    assert %AgentFailure{reset_at: reset_at} = AgentFailure.classify(reason, backend: "codex")
    assert reset_at == ~U[2026-08-05 18:06:00Z]
  end

  test "classifies stable issue-local failure categories" do
    assert AgentFailure.classify(:response_timeout, backend: "codex").class ==
             :response_timeout_or_stall

    assert AgentFailure.classify({:invalid_api_key, :missing}, backend: "codex").class ==
             :authentication_configuration

    assert AgentFailure.classify({:review_timeout, 60_000}, backend: "codex").class ==
             :handoff_reviewer_gate

    assert AgentFailure.classify({:handoff_gate_infrastructure, "invalid report"}, backend: "codex").class ==
             :transient_infrastructure

    assert AgentFailure.classify({:review_gate_infrastructure, "packet unavailable"}, backend: "codex").class ==
             :transient_infrastructure

    assert AgentFailure.classify(
             {:review_gate_infrastructure, %{review: %{failure_reason: "{:packet_bound_unachievable, 17417, 17267}"}}},
             backend: "codex"
           ).class == :handoff_reviewer_gate

    assert %AgentFailure{class: :rate_limited, retry_after_ms: 30_000, scope: :issue} =
             AgentFailure.classify({:rate_limited, 30_000}, backend: "codex")

    assert AgentFailure.classify({:mystery, "usage limit"}, backend: "codex").class ==
             :agent_protocol_failure
  end

  test "requires positive rate-limit evidence before declaring recovery" do
    refute AgentFailure.recovered_rate_limits?(%{
             "credits" => %{"hasCredits" => false, "unlimited" => false},
             "primary" => nil
           })

    assert AgentFailure.recovered_rate_limits?(%{"primary" => %{"usedPercent" => 80}})
    assert AgentFailure.recovered_rate_limits?(%{"credits" => %{"unlimited" => true}})
  end
end
