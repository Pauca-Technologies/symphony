defmodule SymphonyElixir.AgentEfficiencyTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{AgentBudget, AgentBudgetCollector, AgentEfficiency, FleetEvent}
  alias SymphonyElixir.Config.AgentEfficiency, as: EfficiencyConfig
  alias SymphonyElixir.Linear.Issue

  setup do
    telemetry_dir = Path.join(System.tmp_dir!(), "symphony-efficiency-#{System.unique_integer([:positive])}")
    previous_dir = Application.get_env(:symphony_elixir, :telemetry_dir)
    Application.put_env(:symphony_elixir, :telemetry_dir, telemetry_dir)

    on_exit(fn ->
      if previous_dir,
        do: Application.put_env(:symphony_elixir, :telemetry_dir, previous_dir),
        else: Application.delete_env(:symphony_elixir, :telemetry_dir)

      File.rm_rf(telemetry_dir)
    end)

    :ok
  end

  test "defaults to shadow mode with task-specific percentile seed profiles" do
    assert {:ok, settings} = EfficiencyConfig.parse(%{})
    assert settings.mode == "shadow"
    assert settings.task_profiles["simple_direct"] == "simple"
    assert settings.task_profiles["security_tenant"] == "high_risk"
    assert settings.profiles["simple"].total_tokens < settings.profiles["high_risk"].total_tokens
    assert settings.profiles["high_risk"].allow_overage
  end

  test "parses enforce mode and rejects unsafe references" do
    config = %{
      "agent" => %{
        "efficiency" => %{
          "mode" => "enforce",
          "capsule_max_bytes" => 700,
          "profiles" => %{
            "simple" => %{
              "total_tokens" => 10_000,
              "reviewer_reasoning_effort" => "low",
              "review_lenses" => ["correctness", "test_evidence"]
            }
          }
        }
      }
    }

    assert {:ok, settings} = EfficiencyConfig.parse(config)
    assert settings.mode == "enforce"
    assert settings.capsule_max_bytes == 700
    assert settings.profiles["simple"].total_tokens == 10_000

    invalid = put_in(config, ["agent", "efficiency", "task_profiles"], %{"ui" => "missing"})
    assert {:error, {:invalid_agent_efficiency, message}} = EfficiencyConfig.parse(invalid)
    assert message =~ "budget profiles"

    too_small = put_in(config, ["agent", "efficiency", "capsule_max_bytes"], 100)
    assert {:error, {:invalid_agent_efficiency, capsule_message}} = EfficiencyConfig.parse(too_small)
    assert capsule_message =~ "between 512 and 65536"
  end

  test "records classifier provenance and honors an explicit budget override" do
    route = %{
      source: :classifier,
      profile: "standard",
      overrides: %{model: "gpt", reasoning_effort: "medium"},
      classification: %{
        task_type: "ui",
        confidence: 0.88,
        risk: "medium",
        complexity: "low",
        ambiguity: "low",
        reasons: ["bounded UI diff"]
      }
    }

    assert {:ok, decision} =
             AgentEfficiency.decide(issue(["repo:dashboard", "budget:high_risk"]), route, %{config: %{}})

    assert decision.task_type == "ui"
    assert decision.confidence == 0.88
    assert decision.budget_profile == "high_risk"
    assert decision.override == %{source: "issue_label", label: "budget:high_risk"}

    [event] = telemetry_events()
    assert event["event"] == "routing_decision"
    assert event["classifier_result"]["task_type"] == "ui"
    assert event["override"]["label"] == "budget:high_risk"
  end

  test "missing classifier telemetry falls back conservatively for security work" do
    route = %{source: :legacy, profile: nil, overrides: %{}, classification: nil}
    issue = %{issue() | title: "Fix tenant authorization isolation"}

    assert {:ok, decision} = AgentEfficiency.decide(issue, route, %{config: %{}})
    assert decision.task_type == "security_tenant"
    assert decision.budget_profile == "high_risk"
    assert decision.confidence == 0.35
  end

  test "low-confidence or explicitly uncertain classifier output selects the conservative budget" do
    low_confidence = classified_route("simple_direct", confidence: 0.4)

    assert {:ok, low_confidence_decision} =
             AgentEfficiency.decide(issue(), low_confidence, %{config: %{}})

    assert low_confidence_decision.budget_profile == "high_risk"
    assert low_confidence_decision.selection_reason == "classifier_quality_fallback"

    high_ambiguity = classified_route("ui", ambiguity: "high")

    assert {:ok, high_ambiguity_decision} =
             AgentEfficiency.decide(issue(), high_ambiguity, %{config: %{}})

    assert high_ambiguity_decision.budget_profile == "high_risk"
    assert high_ambiguity_decision.selection_reason == "classifier_quality_fallback"
  end

  test "invalid or ambiguous budget labels fail toward high risk with inspectable provenance" do
    route = classified_route("simple_direct")

    assert {:ok, invalid} = AgentEfficiency.decide(issue(["budget:simpel"]), route, %{config: %{}})
    assert invalid.budget_profile == "high_risk"
    assert invalid.override == %{source: "invalid_budget_labels", labels: ["budget:simpel"]}
    assert invalid.selection_reason == "invalid_budget_override_quality_fallback"

    assert {:ok, ambiguous} =
             AgentEfficiency.decide(issue(["budget:simple", "budget:standard"]), route, %{config: %{}})

    assert ambiguous.budget_profile == "high_risk"

    assert ambiguous.override == %{
             source: "ambiguous_budget_labels",
             labels: ["budget:simple", "budget:standard"]
           }

    assert ambiguous.selection_reason == "ambiguous_budget_override_quality_fallback"
  end

  test "actual parent and delegated high waters survive continuation and transitions latch once" do
    decision = decision("enforce", 100)

    state =
      AgentBudget.new(decision, issue())
      |> AgentBudget.start_turn("first", 0)
      |> AgentBudget.observe(%{event: :session_started, thread_id: "parent"})
      |> AgentBudget.observe(usage("parent", 80, 60, 20))
      |> AgentBudget.observe(usage("lens-1", 40, 30, 10))
      |> AgentBudget.observe(usage("lens-1", 40, 30, 10))
      |> AgentBudget.finish_turn(50)

    first = AgentBudget.snapshot(state)
    assert first.total_tokens == 120
    assert first.parent_tokens == 80
    assert first.delegated_tokens == 40
    assert first.thread_count == 2
    assert MapSet.member?(state.crossed, "soft:total_tokens")

    {capsule, state} = AgentBudget.take_strategy_prompt(state)
    assert capsule =~ "soft-budget resume capsule"
    assert capsule =~ "acceptance criterion"
    assert byte_size(capsule) <= decision.capsule_max_bytes

    state =
      state
      |> AgentBudget.start_turn("continuation", 100)
      |> AgentBudget.observe(usage("parent", 95, 70, 25))
      |> AgentBudget.observe(usage("lens-1", 55, 40, 15))
      |> AgentBudget.finish_turn(180)

    second = AgentBudget.snapshot(state)
    assert second.total_tokens == 150
    assert second.delegated_tokens == 55
    assert second.per_turn_growth_tokens == 30
    assert Enum.count(state.crossed, &(&1 == "soft:total_tokens")) == 1
    assert {nil, _state} = AgentBudget.take_strategy_prompt(state)
  end

  test "late explicit session identity replaces a provisional parent after out-of-order usage" do
    updates = [
      usage("delegated-first", 40, 30, 10),
      %{event: :session_started, thread_id: "actual-parent"},
      usage("actual-parent", 80, 60, 20)
    ]

    direct =
      Enum.reduce(updates, AgentBudget.new(decision("enforce", 10_000), issue()), fn update, state ->
        AgentBudget.observe(state, update)
      end)

    assert direct.parent_thread_id == "actual-parent"
    assert AgentBudget.snapshot(direct).parent_tokens == 80
    assert AgentBudget.snapshot(direct).delegated_tokens == 40

    {:ok, collector} = AgentBudgetCollector.start_link(decision("enforce", 10_000), issue())

    try do
      ref = AgentBudgetCollector.ref(collector)
      Enum.each(updates, &AgentBudgetCollector.observe(ref, &1))
      runtime = AgentBudgetCollector.snapshot(collector)

      assert runtime.metrics.parent_tokens == 80
      assert runtime.metrics.delegated_tokens == 40
    after
      AgentBudgetCollector.stop(collector)
    end
  end

  test "shadow mode reports crossings without injecting a strategy prompt" do
    state =
      decision("shadow", 10)
      |> AgentBudget.new(issue())
      |> AgentBudget.observe(usage("parent", 20, 15, 5))

    assert MapSet.member?(state.crossed, "soft:total_tokens")
    assert {nil, cleared} = AgentBudget.take_strategy_prompt(state)
    assert cleared.pending == []
  end

  test "off mode keeps metrics but does not propose transitions" do
    state =
      decision("off", 10)
      |> AgentBudget.new(issue())
      |> AgentBudget.observe(usage("parent", 20, 15, 5))

    assert AgentBudget.snapshot(state).total_tokens == 20
    assert MapSet.size(state.crossed) == 0
    assert state.pending == []
  end

  test "terminal tool output is counted once while streaming protocol updates are ignored" do
    codex_stream = protocol_update("item/commandExecution/outputDelta", %{"output" => "codex stream"})

    codex_terminal =
      protocol_update("item/completed", %{
        "item" => %{
          "id" => "codex-command",
          "type" => "commandExecution",
          "aggregatedOutput" => "codex terminal"
        }
      })

    acp_stream =
      protocol_update("session/update", %{
        "update" => %{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => "acp-command",
          "status" => "in_progress",
          "content" => "acp stream"
        }
      })

    acp_terminal =
      protocol_update("session/update", %{
        "update" => %{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => "acp-command",
          "status" => "completed",
          "content" => "acp terminal"
        }
      })

    claude_stream =
      protocol_update("item/commandExecution/outputDelta", %{
        "callId" => "claude-command",
        "terminal" => false,
        "output" => "claude stream"
      })

    claude_terminal =
      protocol_update("item/commandExecution/outputDelta", %{
        "callId" => "claude-command",
        "terminal" => true,
        "output" => "claude terminal"
      })

    streams = [codex_stream, acp_stream, claude_stream]
    terminals = [codex_terminal, acp_terminal, claude_terminal]

    assert Enum.all?(streams, &(FleetEvent.terminal_tool_output_bytes(&1) == 0))
    assert Enum.all?(terminals, &(FleetEvent.terminal_tool_output_bytes(&1) > 0))

    state =
      Enum.reduce(streams ++ terminals, AgentBudget.new(decision("enforce", 100_000), issue()), fn update, state ->
        AgentBudget.observe(state, update)
      end)

    expected_bytes = Enum.sum(Enum.map(terminals, &FleetEvent.terminal_tool_output_bytes/1))
    assert AgentBudget.snapshot(state).tool_output_bytes == expected_bytes
  end

  test "high-risk review routing can exceed budget without lowering the quality profile" do
    base = %{
      model: "review-base",
      reasoning_effort: "xhigh",
      max_iterations: 3,
      packet_max_bytes: 48_000
    }

    decision = decision("enforce", 100) |> Map.put(:task_type, "security_tenant")
    routed = AgentEfficiency.review_settings(base, decision)

    assert routed.max_iterations >= base.max_iterations
    assert routed.packet_max_bytes == base.packet_max_bytes
    assert routed.reasoning_effort == "xhigh"
    assert AgentEfficiency.high_risk?(decision)
    assert "security_tenant_auth" in AgentEfficiency.review_lenses(decision)
  end

  test "a simple budget override cannot remove mandatory high-risk review settings or lenses" do
    route = classified_route("security_tenant", risk: "high", complexity: "high")
    workflow = %{config: %{"agent" => %{"efficiency" => %{"mode" => "enforce"}}}}

    assert {:ok, decision} =
             AgentEfficiency.decide(issue(["budget:simple"]), route, workflow)

    assert decision.task_type == "security_tenant"
    assert decision.budget_profile == "simple"
    assert AgentEfficiency.high_risk?(decision)

    base = %{
      model: "review-base",
      reasoning_effort: "xhigh",
      max_iterations: 3,
      packet_max_bytes: 48_000
    }

    routed = AgentEfficiency.review_settings(base, decision)
    assert routed.model == "review-base"
    assert routed.reasoning_effort == "xhigh"
    assert routed.max_iterations >= base.max_iterations
    assert routed.packet_max_bytes == base.packet_max_bytes

    lenses = AgentEfficiency.review_lenses(decision)
    assert "correctness" in lenses
    assert "regression" in lenses
    assert "test_evidence" in lenses
    assert "security_tenant_auth" in lenses
    assert "structure" in lenses
  end

  test "conservative high-risk budget fallback restores every mandatory review lens" do
    workflow = %{
      config: %{
        "agent" => %{
          "efficiency" => %{
            "mode" => "enforce",
            "profiles" => %{
              "high_risk" => %{
                "reviewer_lenses" => 1,
                "review_lenses" => ["correctness"]
              }
            }
          }
        }
      }
    }

    assert {:ok, decision} =
             AgentEfficiency.decide(issue(), classified_route("simple_direct", confidence: 0.2), workflow)

    assert decision.task_type == "simple_direct"
    assert decision.budget_profile == "high_risk"
    assert decision.selection_reason == "classifier_quality_fallback"

    lenses = AgentEfficiency.review_lenses(decision)
    assert "correctness" in lenses
    assert "regression" in lenses
    assert "test_evidence" in lenses
    assert "security_tenant_auth" in lenses
    assert "structure" in lenses
  end

  defp decision(mode, total_threshold) do
    {:ok, settings} = EfficiencyConfig.parse(%{})

    budget =
      settings.profiles["high_risk"]
      |> Map.new(fn
        {key, _value}
        when key in [
               :total_tokens,
               :delegated_tokens,
               :per_thread_tokens,
               :per_turn_growth_tokens,
               :uncached_input_tokens,
               :cached_input_tokens,
               :tool_output_bytes,
               :elapsed_phase_ms
             ] ->
          {key, if(key == :total_tokens, do: total_threshold, else: 10_000)}

        pair ->
          pair
      end)

    %{
      mode: mode,
      task_type: "security_tenant",
      confidence: 0.9,
      classification: %{},
      budget_profile: "high_risk",
      budget: budget,
      override: nil,
      capsule_max_bytes: 1_000,
      extreme_multiplier: 3.0,
      enforced: mode == "enforce"
    }
  end

  defp usage(thread_id, total, input, cached) do
    %{
      event: :token_usage,
      thread_id: thread_id,
      usage: %{
        input_tokens: input,
        cached_input_tokens: cached,
        output_tokens: max(total - input, 0),
        total_tokens: total
      }
    }
  end

  defp classified_route(task_type, overrides \\ []) do
    %{
      source: :classifier,
      profile: "standard",
      overrides: %{model: "gpt", reasoning_effort: "medium"},
      classification: %{
        task_type: task_type,
        confidence: Keyword.get(overrides, :confidence, 0.9),
        risk: Keyword.get(overrides, :risk, "low"),
        complexity: Keyword.get(overrides, :complexity, "low"),
        ambiguity: Keyword.get(overrides, :ambiguity, "low"),
        reasons: ["test classification"]
      }
    }
  end

  defp protocol_update(method, params) do
    %{
      event: :notification,
      payload: %{"method" => method, "params" => params}
    }
  end

  defp issue(labels \\ []) do
    %Issue{
      id: "issue-efficiency",
      identifier: "UDPE-9000",
      title: "Small direct change",
      description: "Update one bounded behavior.",
      state: "Todo",
      priority: 3,
      labels: labels,
      blocked_by: [],
      children: []
    }
  end

  defp telemetry_events do
    :timer.sleep(2)

    Application.fetch_env!(:symphony_elixir, :telemetry_dir)
    |> File.ls!()
    |> Enum.flat_map(fn filename ->
      Application.fetch_env!(:symphony_elixir, :telemetry_dir)
      |> Path.join(filename)
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
    end)
  end
end
