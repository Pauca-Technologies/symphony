defmodule SymphonyElixir.WarningFloodGuardTest do
  @moduledoc """
  Regression coverage for the routing/cardinality/version warning flood
  that exhausted Linear's hourly API budget and blocked dispatch for
  every issue (a compliant issue was selected each poll but its
  pre-dispatch revalidation read got rate-limited).

  The guard has two layers: the persistent `symphony:routing-warned`
  label, and an in-memory per-issue cooldown for when that label write
  itself fails. The marker is stamped BEFORE the comment so a partial
  failure never leaves an un-suppressed comment that re-fires next poll.
  """
  use SymphonyElixir.TestSupport

  @marker_label "symphony:routing-warned"

  defp memory_workflow! do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Canceled"]
    )
  end

  defp repo_config do
    %{
      source: :file,
      repos: [
        %{
          id: "demo",
          label: "repo:demo",
          repo_url: "git@example.com:demo.git",
          workflow_path: "WORKFLOW.md",
          base_branch: "main",
          max_concurrent: 1
        }
      ],
      linear: %{team_id: "UDPE", filter_label: nil},
      defaults: %{cardinality_enforced_from: nil}
    }
  end

  defp base_state do
    %Orchestrator.State{poll_interval_ms: 30_000, max_concurrent_agents: 10}
  end

  describe "gate decisions" do
    test "clean, routable issue passes both gates" do
      issue = %Issue{
        id: "clean",
        identifier: "MT-1",
        title: "Clean",
        state: "Todo",
        labels: ["repo:demo"],
        attachment_urls: ["https://github.com/o/r/pull/1"]
      }

      assert :pass =
               Orchestrator.gate_routing_and_cardinality_for_test(
                 issue,
                 repo_config(),
                 MapSet.new(["todo"])
               )
    end

    test "cardinality violation returns a warn decision with telemetry meta" do
      issue = %Issue{
        id: "multi-pr",
        identifier: "MT-2",
        title: "Two PRs",
        state: "Todo",
        labels: ["repo:demo"],
        attachment_urls: [
          "https://github.com/o/r/pull/1",
          "https://github.com/o/r/pull/2"
        ]
      }

      assert {:skip_warn, body, {:cardinality_skip, meta}} =
               Orchestrator.gate_routing_and_cardinality_for_test(
                 issue,
                 repo_config(),
                 MapSet.new(["todo"])
               )

      assert body =~ "cardinality"
      assert meta.violations == ["multiple_prs"]
      assert meta.identifier == "MT-2"
    end

    test "an issue with no configured repo label skips silently" do
      issue = %Issue{
        id: "no-repo",
        identifier: "MT-3",
        title: "Unlabeled",
        state: "Todo",
        labels: ["misc"]
      }

      assert :skip_silent =
               Orchestrator.gate_routing_and_cardinality_for_test(
                 issue,
                 repo_config(),
                 MapSet.new(["todo"])
               )
    end
  end

  describe "emit_issue_warning flood guard" do
    setup do
      memory_workflow!()
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :memory_tracker_available_labels)
        Application.delete_env(:symphony_elixir, :warn_retry_cooldown_ms)
      end)

      :ok
    end

    test "stamps the marker before the comment and records the attempt" do
      issue = %Issue{id: "abc", identifier: "MT-10", title: "x", labels: []}

      state =
        Orchestrator.emit_issue_warning_for_test(
          base_state(),
          issue,
          "warning body",
          {:cardinality_skip, %{issue_id: "abc", identifier: "MT-10", violations: ["multiple_prs"]}}
        )

      assert_receive {:memory_tracker_add_label, "abc", @marker_label}
      assert_receive {:memory_tracker_comment, "abc", "warning body"}
      assert Map.has_key?(state.warned_at, "abc")
    end

    test "does not re-emit within the cooldown" do
      Application.put_env(:symphony_elixir, :warn_retry_cooldown_ms, 3_600_000)
      issue = %Issue{id: "abc", identifier: "MT-11", title: "x", labels: []}
      telemetry = {:cardinality_skip, %{issue_id: "abc"}}

      state = Orchestrator.emit_issue_warning_for_test(base_state(), issue, "body", telemetry)
      assert_receive {:memory_tracker_add_label, "abc", @marker_label}
      assert_receive {:memory_tracker_comment, "abc", "body"}

      # Second attempt in the same window must be a no-op — no writes.
      ^state = Orchestrator.emit_issue_warning_for_test(state, issue, "body", telemetry)
      refute_receive {:memory_tracker_add_label, "abc", _}
      refute_receive {:memory_tracker_comment, "abc", _}
    end

    test "a failed marker write posts no comment and is not retried next poll (the incident)" do
      # Label writes fail (mirrors Linear rate-limiting the marker mutation).
      Application.put_env(:symphony_elixir, :memory_tracker_available_labels, [])
      Application.put_env(:symphony_elixir, :warn_retry_cooldown_ms, 3_600_000)
      issue = %Issue{id: "abc", identifier: "MT-12", title: "x", labels: []}
      telemetry = {:cardinality_skip, %{issue_id: "abc"}}

      state = Orchestrator.emit_issue_warning_for_test(base_state(), issue, "body", telemetry)

      # Marker-first: the label write was attempted and failed, so NO comment
      # was posted — the orphan comment that used to re-fire every poll.
      assert_receive {:memory_tracker_add_label_missing, "abc", @marker_label}
      refute_receive {:memory_tracker_comment, "abc", _}
      # The attempt is recorded, so the cooldown suppresses the next poll.
      assert Map.has_key?(state.warned_at, "abc")

      ^state = Orchestrator.emit_issue_warning_for_test(state, issue, "body", telemetry)
      refute_receive {:memory_tracker_add_label_missing, "abc", _}
      refute_receive {:memory_tracker_comment, "abc", _}
    end

    test "an already-warned issue emits nothing" do
      issue = %Issue{id: "abc", identifier: "MT-13", title: "x", labels: [@marker_label]}

      state =
        Orchestrator.emit_issue_warning_for_test(
          base_state(),
          issue,
          "body",
          {:cardinality_skip, %{issue_id: "abc"}}
        )

      refute_receive {:memory_tracker_add_label, "abc", _}
      refute_receive {:memory_tracker_comment, "abc", _}
      refute Map.has_key?(state.warned_at, "abc")
    end
  end

  describe "poll backoff" do
    test "a fresh state uses the normal interval" do
      assert Orchestrator.poll_delay_ms_for_test(base_state()) == 30_000
    end

    test "honors a Retry-After within the clamp bounds" do
      armed = Orchestrator.arm_poll_backoff_for_test(base_state(), 120_000)
      delay = Orchestrator.poll_delay_ms_for_test(armed)
      assert delay > 30_000
      assert delay <= 120_000
    end

    test "clamps a tiny Retry-After up to the default floor" do
      armed = Orchestrator.arm_poll_backoff_for_test(base_state(), 2_000)
      delay = Orchestrator.poll_delay_ms_for_test(armed)
      assert delay > 30_000
      assert delay <= 60_000
    end

    test "falls back to the default backoff when Retry-After is unknown" do
      armed = Orchestrator.arm_poll_backoff_for_test(base_state(), nil)
      delay = Orchestrator.poll_delay_ms_for_test(armed)
      assert delay > 30_000
      assert delay <= 60_000
    end
  end

  describe "linear client rate-limit classification" do
    test "a RATELIMITED body maps to {:rate_limited, retry_after_ms}" do
      log =
        capture_log(fn ->
          assert {:error, {:rate_limited, 30_000}} =
                   Client.graphql(
                     "query Viewer { viewer { id } }",
                     %{},
                     request_fun: fn _payload, _headers ->
                       {:ok,
                        %{
                          status: 400,
                          headers: %{"retry-after" => ["30"]},
                          body: %{
                            "errors" => [
                              %{
                                "message" => "Rate limit exceeded",
                                "extensions" => %{"code" => "RATELIMITED"}
                              }
                            ]
                          }
                        }}
                     end
                   )
        end)

      assert log =~ "rate-limited"
    end

    test "rate-limit with no Retry-After header yields a nil hint" do
      assert {:error, {:rate_limited, nil}} =
               Client.graphql(
                 "query Viewer { viewer { id } }",
                 %{},
                 request_fun: fn _payload, _headers ->
                   {:ok,
                    %{
                      status: 429,
                      body: %{"errors" => [%{"extensions" => %{"type" => "ratelimited"}}]}
                    }}
                 end
               )
    end

    test "a non-rate-limit 400 stays a generic api-status error" do
      assert {:error, {:linear_api_status, 400}} =
               Client.graphql(
                 "query Viewer { viewer { id } }",
                 %{},
                 request_fun: fn _payload, _headers ->
                   {:ok,
                    %{
                      status: 400,
                      body: %{"errors" => [%{"extensions" => %{"code" => "BAD_USER_INPUT"}}]}
                    }}
                 end
               )
    end
  end
end
