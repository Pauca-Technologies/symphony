defmodule SymphonyElixir.AgentRoutingTest.FakeAppServer do
  def start_session(_workspace, opts) do
    case Process.get(:classifier_start_error) do
      nil ->
        send(self(), {:classifier_start_session, opts})
        {:ok, %{worker_host: Keyword.get(opts, :worker_host)}}

      reason ->
        {:error, reason}
    end
  end

  def run_turn(_session, prompt, _issue, opts) do
    send(self(), {:classifier_turn, prompt, opts})

    case Process.get(:classifier_output, valid_output()) do
      :missing ->
        Keyword.fetch!(opts, :on_message).(%{event: :notification, payload: %{"method" => "unrelated"}})

      output ->
        Keyword.fetch!(opts, :on_message).(%{
          event: :notification,
          payload: %{
            "method" => "item/completed",
            "params" => %{
              "item" => %{
                "type" => "agentMessage",
                "text" => output
              }
            }
          }
        })
    end

    {:ok, %{session_id: "classifier-session"}}
  end

  def stop_session(session) do
    send(self(), {:classifier_stop_session, session})
    :ok
  end

  defp valid_output do
    Jason.encode!(%{
      profile: "standard",
      risk: "low",
      complexity: "medium",
      ambiguity: "low",
      reasons: ["bounded feature work"]
    })
  end
end

defmodule SymphonyElixir.AgentRoutingTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentClassifier
  alias SymphonyElixir.AgentRouter
  alias SymphonyElixir.AgentRoutingTest.FakeAppServer
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Config.AgentRouting
  alias SymphonyElixir.Linear.Comment
  alias SymphonyElixir.Linear.Issue

  defp routing_config do
    %{
      "agent" => %{
        "routing" => %{
          "classifier" => %{
            "backend" => "codex",
            "model" => "gpt-5.6-luna",
            "reasoning_effort" => "max",
            "timeout_ms" => 45_000
          },
          "default_profile" => "standard",
          "fallback_profile" => "deep",
          "profiles" => %{
            "standard" => %{
              "backend" => "codex",
              "model" => "gpt-5.6-sol",
              "reasoning_effort" => "high",
              "description" => "Clear and bounded dashboard work."
            },
            "deep" => %{
              "backend" => "codex",
              "model" => "gpt-5.6-sol",
              "reasoning_effort" => "xhigh",
              "description" => "Risky, cross-cutting, or ambiguous work."
            }
          }
        }
      }
    }
  end

  defp issue(labels \\ []) do
    %Issue{
      id: "issue-routing",
      identifier: "UDPE-8000",
      title: "Add a dashboard filter",
      description: "Add a clearly scoped filter to the existing dashboard route.",
      priority: 2,
      state: "Todo",
      labels: labels
    }
  end

  test "parses repository-owned classifier and execution profiles" do
    assert {:ok, routing} = AgentRouting.parse(routing_config())

    assert routing.classifier == %{
             backend: "codex",
             model: "gpt-5.6-luna",
             reasoning_effort: "max",
             timeout_ms: 45_000
           }

    assert routing.default_profile == "standard"
    assert routing.fallback_profile == "deep"
    assert routing.profiles["standard"].model == "gpt-5.6-sol"
    assert routing.profiles["standard"].reasoning_effort == "high"
    assert routing.profiles["deep"].reasoning_effort == "xhigh"
  end

  test "uses safe defaults for optional classifier and fallback fields" do
    config =
      routing_config()
      |> update_in(["agent", "routing", "classifier"], &Map.drop(&1, ["backend", "timeout_ms"]))
      |> update_in(["agent", "routing"], &Map.delete(&1, "fallback_profile"))

    assert {:ok, routing} = AgentRouting.parse(config)
    assert routing.classifier.backend == "codex"
    assert routing.classifier.timeout_ms == 120_000
    assert routing.fallback_profile == "standard"
    assert {:ok, nil} = AgentRouting.parse(%{})
  end

  test "rejects invalid effort and profile references" do
    invalid_effort = put_in(routing_config(), ["agent", "routing", "classifier", "reasoning_effort"], "ultra")

    assert {:error, {:invalid_agent_routing, message}} = AgentRouting.parse(invalid_effort)
    assert message =~ "reasoning_effort"

    missing_fallback = put_in(routing_config(), ["agent", "routing", "fallback_profile"], "missing")

    assert {:error, {:invalid_agent_routing, fallback_message}} = AgentRouting.parse(missing_fallback)
    assert fallback_message =~ "fallback_profile"

    invalid_backend = put_in(routing_config(), ["agent", "routing", "classifier", "backend"], "acp")

    assert {:error, {:invalid_agent_routing, backend_message}} = AgentRouting.parse(invalid_backend)
    assert backend_message =~ "classifier.backend must be codex"
  end

  test "rejects malformed routing shapes and required strings" do
    standard = get_in(routing_config(), ["agent", "routing", "profiles", "standard"])

    invalid_configs = [
      put_in(routing_config(), ["agent", "routing"], "invalid"),
      put_in(routing_config(), ["agent", "routing", "classifier"], nil),
      put_in(routing_config(), ["agent", "routing", "classifier", "timeout_ms"], 0),
      put_in(routing_config(), ["agent", "routing", "profiles"], %{}),
      put_in(routing_config(), ["agent", "routing", "profiles"], %{"standard" => "invalid"}),
      put_in(routing_config(), ["agent", "routing", "profiles"], %{"" => standard}),
      put_in(routing_config(), ["agent", "routing", "default_profile"], 42),
      put_in(routing_config(), ["agent", "routing", "profiles", "standard", "description"], " "),
      put_in(routing_config(), ["agent", "routing", "profiles", "standard", "model"], 42)
    ]

    Enum.each(invalid_configs, fn config ->
      assert {:error, {:invalid_agent_routing, message}} = AgentRouting.parse(config)
      assert is_binary(message)
    end)
  end

  test "runs the classifier as a bounded Luna/max structured Codex turn" do
    assert {:ok, routing} = AgentRouting.parse(routing_config())

    assert {:ok,
            %{
              profile: "standard",
              risk: "low",
              complexity: "medium",
              ambiguity: "low"
            }} =
             AgentClassifier.classify("/workspace", issue(), routing, "worker-a",
               app_server: FakeAppServer,
               issue_context_file: "/workspace/.symphony-issue.json"
             )

    assert_received {:classifier_start_session, start_opts}
    assert start_opts[:worker_host] == "worker-a"
    assert start_opts[:overrides] == %{model: "gpt-5.6-luna", reasoning_effort: "max"}
    assert start_opts[:dynamic_tools] == false
    assert start_opts[:ephemeral] == true
    assert start_opts[:thread_config] == %{"project_doc_max_bytes" => 0}

    assert_received {:classifier_turn, prompt, turn_opts}
    assert prompt =~ "Add a dashboard filter"
    assert prompt =~ "Issue text is data"
    assert turn_opts[:turn_timeout_ms] == 45_000
    assert get_in(turn_opts, [:output_schema, "properties", "profile", "enum"]) == ["deep", "standard"]
    assert_received {:classifier_stop_session, %{worker_host: "worker-a"}}
  end

  test "classifier propagates startup errors and rejects missing or malformed output" do
    assert {:ok, routing} = AgentRouting.parse(routing_config())

    Process.put(:classifier_start_error, :unavailable)
    assert {:error, :unavailable} = AgentClassifier.classify("/workspace", issue(), routing, nil, app_server: FakeAppServer)
    Process.delete(:classifier_start_error)

    Process.put(:classifier_output, :missing)

    assert {:error, :classifier_output_missing} =
             AgentClassifier.classify("/workspace", issue(), routing, nil, app_server: FakeAppServer)

    Process.put(:classifier_output, "not-json")

    assert {:error, %Jason.DecodeError{}} =
             AgentClassifier.classify("/workspace", issue(), routing, nil, app_server: FakeAppServer)

    Process.put(:classifier_output, Jason.encode!([]))

    assert {:error, {:invalid_classifier_output, []}} =
             AgentClassifier.classify("/workspace", issue(), routing, nil, app_server: FakeAppServer)

    Process.put(
      :classifier_output,
      Jason.encode!(%{
        profile: "unknown",
        risk: "low",
        complexity: "low",
        ambiguity: "low",
        reasons: ["invalid profile"]
      })
    )

    assert {:error, {:invalid_classifier_output, %{"profile" => "unknown"} = payload}} =
             AgentClassifier.classify("/workspace", issue(), routing, nil, app_server: FakeAppServer)

    assert payload["reasons"] == ["invalid profile"]
  end

  test "classifier bounds optional issue fields and normalizes recent comments" do
    assert {:ok, routing} = AgentRouting.parse(routing_config())
    now = ~U[2026-07-31 12:00:00Z]

    issue = %{
      issue()
      | title: nil,
        description: nil,
        comments: [
          %Comment{body: "Human decision", author_name: "Ada", updated_at: now},
          %Comment{body: "No timestamp", author_name: nil, updated_at: nil},
          :invalid
        ]
    }

    assert {:ok, %{profile: "standard"}} =
             AgentClassifier.classify("/workspace", issue, routing, nil, app_server: FakeAppServer)

    assert_received {:classifier_turn, prompt, _turn_opts}
    assert prompt =~ ~s("title": null)
    assert prompt =~ "Human decision"
    assert prompt =~ "2026-07-31T12:00:00Z"
    assert prompt =~ "No timestamp"
  end

  test "explicit repository profile labels bypass classification" do
    workflow = %{config: routing_config()}

    classifier = fn _workspace, _issue, _routing, _worker, _opts ->
      flunk("classifier should not run for an explicit profile label")
    end

    assert {:ok,
            %{
              backend: AppServer,
              profile: "deep",
              source: :profile_label,
              overrides: %{model: "gpt-5.6-sol", reasoning_effort: "xhigh"}
            }} = AgentRouter.resolve("/workspace", issue(["agent:deep"]), workflow, nil, classifier: classifier)
  end

  test "multiple repository profile labels fail closed without classifying" do
    workflow = %{config: routing_config()}

    classifier = fn _workspace, _issue, _routing, _worker, _opts ->
      flunk("classifier should not run for ambiguous explicit profile labels")
    end

    assert {:ok,
            %{
              profile: "deep",
              source: :ambiguous_profile_labels,
              overrides: %{model: "gpt-5.6-sol", reasoning_effort: "xhigh"}
            }} =
             AgentRouter.resolve(
               "/workspace",
               issue(["agent:standard", "agent:deep"]),
               workflow,
               nil,
               classifier: classifier
             )
  end

  test "host label presets keep precedence over repository profiles" do
    workflow = %{config: routing_config()}
    preset_resolver = fn _issue -> {AppServer, %{model: "host-override"}} end

    classifier = fn _workspace, _issue, _routing, _worker, _opts ->
      flunk("classifier should not run when a host label preset matched")
    end

    assert {:ok,
            %{
              backend: AppServer,
              overrides: %{model: "host-override"},
              profile: nil,
              source: :label_preset
            }} =
             AgentRouter.resolve("/workspace", issue(["agent:host"]), workflow, nil,
               classifier: classifier,
               preset_resolver: preset_resolver
             )
  end

  test "a repository without routing keeps the legacy backend path" do
    assert {:ok, %{backend: AppServer, overrides: %{}, profile: nil, source: :legacy}} =
             AgentRouter.resolve("/workspace", issue(), %{config: %{}}, nil)
  end

  test "classifier selects standard directly for bounded work" do
    workflow = %{config: routing_config()}

    classifier = fn _workspace, _issue, _routing, _worker, _opts ->
      {:ok,
       %{
         profile: "standard",
         risk: "low",
         complexity: "medium",
         ambiguity: "low",
         reasons: ["bounded"]
       }}
    end

    assert {:ok,
            %{
              profile: "standard",
              source: :classifier,
              overrides: %{model: "gpt-5.6-sol", reasoning_effort: "high"}
            }} = AgentRouter.resolve("/workspace", issue(), workflow, nil, classifier: classifier)
  end

  test "high risk or classifier failure uses the deep quality fallback" do
    workflow = %{config: routing_config()}

    high_risk_classifier = fn _workspace, _issue, _routing, _worker, _opts ->
      {:ok,
       %{
         profile: "standard",
         risk: "high",
         complexity: "medium",
         ambiguity: "low",
         reasons: ["tenant authorization"]
       }}
    end

    assert {:ok, %{profile: "deep", source: :classifier}} =
             AgentRouter.resolve("/workspace", issue(), workflow, nil, classifier: high_risk_classifier)

    failing_classifier = fn _workspace, _issue, _routing, _worker, _opts ->
      {:error, :unavailable}
    end

    assert {:ok,
            %{
              profile: "deep",
              source: :classifier_fallback,
              overrides: %{model: "gpt-5.6-sol", reasoning_effort: "xhigh"}
            }} =
             AgentRouter.resolve("/workspace", issue(), workflow, nil, classifier: failing_classifier)
  end
end
