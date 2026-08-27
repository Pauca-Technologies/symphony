defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  # Stub `gh` so ReviewGate's PR resolution finds a PR (and accepts the
  # human-review section edit) without shelling real gh.
  defp stub_pr_runner do
    fn
      ["pr", "view" | _], _cwd ->
        {Jason.encode!(%{
           "id" => "PR_7",
           "number" => 7,
           "body" => "Body.",
           "headRefOid" => "head-7"
         }), 0}

      ["api", "graphql" | _], _cwd ->
        {"", 0}
    end
  end

  defp review_workflow(review_config) do
    %{
      config: %{"review" => review_config},
      prompt: "Review {{ issue.identifier }}",
      prompt_template: "Review {{ issue.identifier }}"
    }
  end

  defp write_review_verdict(ctx, verdict) do
    exact =
      Map.merge(
        %{
          "packet_id" => ctx.packet.packet_id,
          "reviewed_sha" => ctx.reviewed_sha,
          "inspected" => ["authoritative full diff"],
          "attestations" => %{"reused" => [], "rerun" => []},
          "full_diff_inspected" => true
        },
        verdict
      )

    File.mkdir_p!(Path.dirname(ctx.verdict_path))
    File.write!(ctx.verdict_path, Jason.encode!(exact))
  end

  test "tool_specs advertises the server-authenticated Linear tool contracts" do
    specs = DynamicTool.tool_specs()

    assert %{
             "description" => typed_description,
             "inputSchema" => %{
               "properties" => %{"operation" => %{"enum" => typed_operations}},
               "required" => ["operation"]
             },
             "name" => "linear_issue"
           } = Enum.find(specs, &(&1["name"] == "linear_issue"))

    assert typed_description =~ "current Linear issue"

    assert typed_operations == [
             "get",
             "update_workpad",
             "add_label",
             "remove_label",
             "transition"
           ]

    assert %{
             "description" => graphql_description,
             "inputSchema" => %{
               "properties" => %{
                 "blocker" => _,
                 "query" => _,
                 "variables" => _
               },
               "required" => ["query"],
               "type" => "object"
             },
             "name" => "linear_graphql"
           } = Enum.find(specs, &(&1["name"] == "linear_graphql"))

    assert graphql_description =~ "before_handoff"

    assert %{"description" => wait_description, "inputSchema" => wait_schema, "name" => "wait_for"} =
             Enum.find(specs, &(&1["name"] == "wait_for"))

    assert wait_description =~ "without consuming an agent slot"
    assert wait_description =~ "Never use this for local CPU"
    assert wait_description =~ "Symphony-owned handoff gate"
    assert "condition" in wait_schema["required"]
    refute "time" in wait_schema["properties"]["condition"]["properties"]["type"]["enum"]
    refute Map.has_key?(wait_schema["properties"]["condition"]["properties"], "resume_at")
    assert Enum.map(specs, & &1["name"]) == ["linear_issue", "linear_graphql", "wait_for"]
  end

  test "linear_issue reads current activity and updates only the current issue" do
    issue = %SymphonyElixir.Linear.Issue{
      id: "issue-typed",
      identifier: "UDPE-typed",
      title: "Use typed Linear operations",
      state: "In Progress",
      labels: ["udpagent"]
    }

    response =
      DynamicTool.execute("linear_issue", %{"operation" => "get"},
        handoff_gate_context: %{issue: issue},
        tracker_fetch_issue: fn ["issue-typed"] -> {:ok, [issue]} end,
        tracker_fetch_comments: fn "issue-typed" ->
          {:ok,
           %{
             comments: [
               %SymphonyElixir.Linear.Comment{
                 id: "comment-workpad",
                 body: "## Codex Workpad\n\nCurrent plan.",
                 author_name: "UDPAgent"
               }
             ],
             truncated: false
           }}
        end
      )

    assert response["success"]
    payload = Jason.decode!(response["output"])
    assert get_in(payload, ["issue", "identifier"]) == "UDPE-typed"
    assert get_in(payload, ["activity", "comments", Access.at(0), "id"]) == "comment-workpad"

    test_pid = self()

    update_response =
      DynamicTool.execute(
        "linear_issue",
        %{"operation" => "update_workpad", "body" => "## Codex Workpad\n\nUpdated."},
        handoff_gate_context: %{issue: issue},
        tracker_update_workpad: fn issue_id, body ->
          send(test_pid, {:updated_workpad, issue_id, body})
          :ok
        end
      )

    assert update_response["success"]
    assert_received {:updated_workpad, "issue-typed", "## Codex Workpad\n\nUpdated."}
  end

  test "linear_issue resolves typed state transitions before using the gated mutation path" do
    issue = %SymphonyElixir.Linear.Issue{
      id: "issue-transition",
      identifier: "UDPE-transition",
      title: "Use a typed transition",
      state: "Todo"
    }

    test_pid = self()

    linear_client = fn query, variables, [] ->
      cond do
        query =~ "SymphonyResolveTypedState" ->
          assert variables == %{
                   "issueId" => "issue-transition",
                   "stateName" => "In Progress"
                 }

          {:ok,
           %{
             "data" => %{
               "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-progress"}]}}}
             }
           }}

        query =~ "SymphonyResolveIssueTransition" ->
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "state" => %{"name" => "Todo"},
                 "team" => %{
                   "states" => %{
                     "nodes" => [%{"id" => "state-progress", "name" => "In Progress"}]
                   }
                 }
               }
             }
           }}

        query =~ "SymphonyTypedIssueTransition" ->
          send(test_pid, {:typed_transition, variables})
          {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      end
    end

    response =
      DynamicTool.execute(
        "linear_issue",
        %{"operation" => "transition", "state" => "In Progress"},
        handoff_gate_context: %{issue: issue, workspace: "/tmp/typed-linear-transition"},
        linear_client: linear_client
      )

    assert response["success"]

    assert_received {:typed_transition, %{"issueId" => "issue-transition", "stateId" => "state-progress"}}
  end

  test "wait_for validates and forwards a typed parked-work request" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "wait_for",
        %{
          "reason" => "GitHub Actions is degraded",
          "condition" => %{
            "type" => "github_actions_recovered",
            "component" => "Actions"
          }
        },
        wait_context: %{},
        wait_observer: fn _request ->
          {:ok,
           %{
             "component" => "Actions",
             "status" => "major_outage",
             "incident_statuses" => ["investigating"],
             "recovery_signal" => "waiting"
           }}
        end,
        wait_callback: fn request ->
          send(test_pid, {:wait_request, request})
          :ok
        end
      )

    assert response["success"]
    assert_receive {:wait_request, request}
    assert request.reason == "GitHub Actions is degraded"
    assert request.condition == %{"component" => "Actions", "type" => "github_actions_recovered"}
    assert request.baseline["recovery_signal"] == "waiting"
    assert request.min_poll_ms == 60_000
    assert is_binary(request.condition_key)
  end

  test "linear_graphql requires structured human evidence for Blocked transitions" do
    issue = %Issue{
      id: "issue-blocked-policy",
      identifier: "UDPE-7201",
      title: "Guard Blocked transitions",
      state: "In Progress"
    }

    linear_client = fn
      query, %{"issueId" => "issue-blocked-policy"}, [] ->
        assert query =~ "SymphonyResolveIssueTransition"

        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "state" => %{"name" => "In Progress"},
               "team" => %{
                 "states" => %{
                   "nodes" => [%{"id" => "state-blocked", "name" => "Blocked"}]
                 }
               }
             }
           }
         }}

      _query, _variables, [] ->
        flunk("unclassified Blocked mutation should not be sent to Linear")
    end

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "mutation Block($issueId: String!, $stateId: String!) { issueUpdate(id: $issueId, input: {stateId: $stateId}) { success } }",
          "variables" => %{
            "issueId" => "issue-blocked-policy",
            "stateId" => "state-blocked"
          }
        },
        handoff_gate_context: %{issue: issue, workspace: System.tmp_dir!(), worker_host: nil},
        linear_client: linear_client
      )

    refute response["success"]
    output = Jason.decode!(response["output"])
    assert get_in(output, ["error", "message"]) =~ "structured human blocker"
    assert "product_decision" in get_in(output, ["error", "requiredArgument", "blocker", "kind"])
  end

  test "linear_graphql allows classified human Blocked transitions" do
    test_pid = self()

    issue = %Issue{
      id: "issue-human-blocker",
      identifier: "UDPE-7202",
      title: "Need a product decision",
      state: "In Progress"
    }

    query =
      "mutation Block($issueId: String!, $stateId: String!) { issueUpdate(id: $issueId, input: {stateId: $stateId}) { success } }"

    variables = %{"issueId" => issue.id, "stateId" => "state-blocked"}

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => query,
          "variables" => variables,
          "blocker" => %{
            "kind" => "product_decision",
            "summary" => "Choose the required compatibility behavior."
          }
        },
        handoff_gate_context: %{issue: issue, workspace: System.tmp_dir!(), worker_host: nil},
        linear_client: fn
          transition_query, %{"issueId" => "issue-human-blocker"}, []
          when transition_query != query ->
            {:ok,
             %{
               "data" => %{
                 "issue" => %{
                   "state" => %{"name" => "In Progress"},
                   "team" => %{
                     "states" => %{
                       "nodes" => [%{"id" => "state-blocked", "name" => "Blocked"}]
                     }
                   }
                 }
               }
             }}

          ^query, ^variables, [] ->
            send(test_pid, :blocked_mutation_applied)
            {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
        end
      )

    assert response["success"]
    assert_received :blocked_mutation_applied
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_issue", "linear_graphql", "wait_for"]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]
  end

  test "linear_graphql blocks In Progress to In Review issueUpdate when before_handoff hook fails" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-before-handoff-tool-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(workspace),
      hook_before_handoff: """
      printf '%s' '{"checks":[{"name":"landable-check","status":"failed","summary":"CI is not green","remediation":"wait for CI"}]}'
      exit 2
      """
    )

    handler_id = "before-handoff-tool-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      SymphonyElixir.HandoffGate.telemetry_event(),
      fn event, measurements, metadata, recipient ->
        send(recipient, {:before_handoff_telemetry, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      File.rm_rf(workspace)
    end)

    issue = %Issue{
      id: "issue-gate",
      identifier: "UDPE-1",
      title: "Gate handoff",
      state: "In Progress"
    }

    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "mutation Move($issueId: String!, $stateId: String!) { issueUpdate(id: $issueId, input: {stateId: $stateId}) { success } }",
          "variables" => %{"issueId" => "issue-gate", "stateId" => "state-review"}
        },
        handoff_gate_context: %{
          issue: issue,
          workspace: workspace,
          worker_host: nil,
          handoff_gate_lifecycle_callback: fn event, metadata ->
            send(test_pid, {:handoff_gate_lifecycle, event, metadata})
          end
        },
        linear_client: fn
          query, %{"issueId" => "issue-gate"}, [] ->
            assert query =~ "SymphonyResolveIssueTransition"

            {:ok,
             %{
               "data" => %{
                 "issue" => %{
                   "state" => %{"name" => "In Progress"},
                   "team" => %{
                     "states" => %{
                       "nodes" => [
                         %{"id" => "state-review", "name" => "In Review"}
                       ]
                     }
                   }
                 }
               }
             }}

          _query, _variables, [] ->
            flunk("blocked handoff mutation should not be sent to Linear")
        end
      )

    assert response["success"] == false

    output = Jason.decode!(response["output"])
    assert get_in(output, ["error", "message"]) =~ "before_handoff hook blocked"
    assert get_in(output, ["error", "remediation"]) =~ "the following gates failed:"
    assert get_in(output, ["error", "remediation"]) =~ "landable-check: CI is not green"

    telemetry_event = [:symphony_elixir, :gate, :before_handoff]

    assert_receive {:before_handoff_telemetry, ^telemetry_event, %{count: 1}, telemetry}
    assert %{event: "gate.before_handoff", outcome: :failed, gates: gates} = telemetry

    assert [%{name: "landable-check", passed: false}] = gates

    assert_receive {:handoff_gate_lifecycle, :started, %{gate_job_id: gate_job_id, gate: %{status: :running}}}

    assert_receive {:handoff_gate_lifecycle, :finished, %{gate_job_id: ^gate_job_id, outcome: :blocked}}
  end

  test "linear_graphql defers a protocol-v1 pending handoff without applying the mutation" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pending-handoff-tool-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.dirname(workspace))
    on_exit(fn -> File.rm_rf(workspace) end)

    issue = %Issue{
      id: "issue-pending-gate",
      identifier: "UDPE-7157",
      title: "Defer handoff",
      state: "In Progress"
    }

    report = %{
      "protocolVersion" => 1,
      "jobId" => "job-7157",
      "status" => "pending",
      "identity" => %{
        "repositoryIdentity" => "repo-7157",
        "worktreeIdentity" => "worktree-7157",
        "prNumber" => "1854",
        "baseRef" => "develop",
        "baseSha" => "base-7157",
        "headSha" => "head-7157",
        "candidateFingerprint" => "fingerprint-7157",
        "gateConfigHash" => "config-7157",
        "mutablePrStateHash" => "mutable-7157",
        "candidateHash" => "candidate-7157",
        "exactHash" => "exact-7157"
      },
      "heartbeatAt" => "2026-08-02T12:00:00Z",
      "heartbeatAgeMs" => 5,
      "nextPollMs" => 1_000,
      "progress" => %{"stage" => "ci", "completed" => 2, "total" => 5}
    }

    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "mutation Move($issueId: String!, $stateId: String!) { issueUpdate(id: $issueId, input: {stateId: $stateId}) { success } }",
          "variables" => %{"issueId" => issue.id, "stateId" => "state-review"}
        },
        handoff_gate_context: %{
          issue: issue,
          workspace: workspace,
          worker_host: nil,
          before_handoff_command: "printf '%s' '#{Jason.encode!(report)}'; exit 3",
          handoff_gate_start_callback: fn request ->
            send(test_pid, {:starting_handoff, request})
            :ok
          end,
          handoff_gate_clear_callback: fn _request ->
            send(test_pid, :starting_handoff_cleared)
            :ok
          end,
          deferred_handoff_gate_callback: fn request ->
            send(test_pid, {:pending_handoff, request})
            :ok
          end
        },
        linear_client: fn
          query, %{"issueId" => "issue-pending-gate"}, [] ->
            assert query =~ "SymphonyResolveIssueTransition"

            {:ok,
             %{
               "data" => %{
                 "issue" => %{
                   "state" => %{"name" => "In Progress"},
                   "team" => %{
                     "states" => %{"nodes" => [%{"id" => "state-review", "name" => "In Review"}]}
                   }
                 }
               }
             }}

          _query, _variables, [] ->
            flunk("pending handoff mutation must not be applied")
        end
      )

    assert response["success"] == true
    output = Jason.decode!(response["output"])
    assert output["status"] == "handoff_gate_pending"
    assert get_in(output, ["gate", "jobId"]) == "job-7157"

    assert_receive {:starting_handoff, %{target_state: "In Review"}}
    assert_receive {:pending_handoff, %{gate: %{job_id: "job-7157"}, target_state: "In Review"}}
    refute_receive :starting_handoff_cleared
  end

  test "linear_graphql reports protocol infrastructure failures to the runner" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-infrastructure-handoff-tool-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.dirname(workspace))
    on_exit(fn -> File.rm_rf(workspace) end)

    issue = %Issue{
      id: "issue-infrastructure-gate",
      identifier: "UDPE-7007",
      title: "Back off after protocol failure",
      state: "In Progress"
    }

    report = %{
      "protocolVersion" => 1,
      "jobId" => "job-infrastructure",
      "status" => "infrastructure_error",
      "identity" => %{
        "repositoryIdentity" => "repo-infrastructure",
        "worktreeIdentity" => "worktree-infrastructure",
        "prNumber" => "1854",
        "baseRef" => "develop",
        "baseSha" => "base-infrastructure",
        "headSha" => "head-infrastructure",
        "candidateFingerprint" => "fingerprint-infrastructure",
        "gateConfigHash" => "config-infrastructure",
        "mutablePrStateHash" => "mutable-infrastructure",
        "candidateHash" => "candidate-infrastructure",
        "exactHash" => "exact-infrastructure"
      },
      "summary" => "gate runner unavailable",
      "checks" => []
    }

    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "mutation Move($issueId: String!, $stateId: String!) { issueUpdate(id: $issueId, input: {stateId: $stateId}) { success } }",
          "variables" => %{"issueId" => issue.id, "stateId" => "state-review"}
        },
        handoff_gate_context: %{
          issue: issue,
          workspace: workspace,
          worker_host: nil,
          before_handoff_command: "printf '%s' '#{Jason.encode!(report)}'; exit 1",
          handoff_gate_start_callback: fn request ->
            send(test_pid, {:starting_handoff, request})
            :ok
          end,
          handoff_gate_clear_callback: fn _request ->
            send(test_pid, :starting_handoff_cleared)
            :ok
          end,
          handoff_infrastructure_failure_callback: fn prompt, gate ->
            send(test_pid, {:handoff_infrastructure_failure, prompt, gate})
          end
        },
        linear_client: fn
          query, %{"issueId" => "issue-infrastructure-gate"}, [] ->
            assert query =~ "SymphonyResolveIssueTransition"

            {:ok,
             %{
               "data" => %{
                 "issue" => %{
                   "state" => %{"name" => "In Progress"},
                   "team" => %{
                     "states" => %{"nodes" => [%{"id" => "state-review", "name" => "In Review"}]}
                   }
                 }
               }
             }}

          _query, _variables, [] ->
            flunk("infrastructure-blocked handoff mutation must not be applied")
        end
      )

    assert response["success"] == false

    assert_receive {:starting_handoff, %{target_state: "In Review"}}
    assert_receive {:handoff_infrastructure_failure, prompt, %{job_id: "job-infrastructure", status: :infrastructure_error}}

    assert prompt =~ "gate runner unavailable"
    assert_receive :starting_handoff_cleared
  end

  test "linear_graphql runs handoff gates when issueUpdate uses the issue identifier" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-identifier-handoff-tool-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(workspace),
      hook_before_handoff: """
      printf '%s' '{"checks":[{"name":"review-required","status":"failed","detail":"review gate should run"}]}'
      exit 2
      """
    )

    on_exit(fn -> File.rm_rf(workspace) end)

    issue = %Issue{
      id: "ecd8bdb3-fa08-4a5f-b4b9-3026ab8be294",
      identifier: "UDPE-6085",
      title: "Identifier handoff",
      state: "In Progress"
    }

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "mutation UpdateIssueState($id: String!, $stateId: String!) { issueUpdate(id: $id, input: { stateId: $stateId }) { success } }",
          "variables" => %{"id" => "UDPE-6085", "stateId" => "state-review"}
        },
        handoff_gate_context: %{issue: issue, workspace: workspace, worker_host: nil},
        linear_client: fn
          query, %{"issueId" => "UDPE-6085"}, [] ->
            assert query =~ "SymphonyResolveIssueTransition"

            {:ok,
             %{
               "data" => %{
                 "issue" => %{
                   "state" => %{"name" => "In Progress"},
                   "team" => %{
                     "states" => %{"nodes" => [%{"id" => "state-review", "name" => "In Review"}]}
                   }
                 }
               }
             }}

          _query, _variables, [] ->
            flunk("blocked identifier handoff mutation should not be sent to Linear")
        end
      )

    assert response["success"] == false

    output = Jason.decode!(response["output"])
    assert get_in(output, ["error", "message"]) =~ "before_handoff hook blocked"
    assert get_in(output, ["error", "remediation"]) =~ "review-required: review gate should run"
  end

  test "remote handoff revalidates base drift on its worker instead of bypassing the check" do
    workspace = "/srv/remote worktree"
    issue = %Issue{id: "issue-remote-base", identifier: "UDPE-7163", title: "Remote base", state: "In Progress"}
    test_pid = self()

    ssh_runner = fn host, command, opts ->
      send(test_pid, {:remote_handoff_git, host, command, opts})

      output =
        cond do
          String.contains?(command, "'rev-parse' 'HEAD'") -> "head-remote\n"
          String.contains?(command, "'rev-parse' 'refs/remotes/origin/main'") -> "base-remote\n"
          String.contains?(command, "'merge-base'") -> "base-remote\n"
          true -> ""
        end

      {:ok, {output, 0}}
    end

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "mutation Move($issueId: String!, $stateId: String!) { issueUpdate(id: $issueId, input: {stateId: $stateId}) { success } }",
          "variables" => %{"issueId" => issue.id, "stateId" => "state-review"}
        },
        handoff_gate_context: %{
          issue: issue,
          workspace: workspace,
          worker_host: "builder-a",
          review_opts: [base_drift_ref: "main", base_drift_ssh_runner: ssh_runner]
        },
        linear_client: fn
          query, %{"issueId" => "issue-remote-base"} = variables, []
          when map_size(variables) == 1 ->
            assert query =~ "SymphonyResolveIssueTransition"

            {:ok,
             %{
               "data" => %{
                 "issue" => %{
                   "state" => %{"name" => "In Progress"},
                   "team" => %{
                     "states" => %{"nodes" => [%{"id" => "state-review", "name" => "In Review"}]}
                   }
                 }
               }
             }}

          _mutation, %{"issueId" => "issue-remote-base", "stateId" => "state-review"}, [] ->
            send(test_pid, :remote_handoff_mutation_sent)
            {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
        end
      )

    assert response["success"] == true
    assert_received :remote_handoff_mutation_sent
    assert_received {:remote_handoff_git, "builder-a", command, [stderr_to_stdout: true]}
    assert command =~ "cd '/srv/remote worktree' && git"
  end

  test "linear_graphql runs handoff gates when IssueUpdateInput carries stateId" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-input-state-handoff-tool-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(workspace),
      hook_before_handoff: """
      printf '%s' '{"checks":[{"name":"nested-input-state","status":"failed","detail":"nested stateId should run gates"}]}'
      exit 2
      """
    )

    on_exit(fn -> File.rm_rf(workspace) end)

    issue = %Issue{
      id: "30d1224d-9343-4f8f-a60c-e7ff285d13dd",
      identifier: "UDPE-6112",
      title: "Nested input handoff",
      state: "Todo"
    }

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => """
          mutation MoveIssueToInReview($id: String!, $input: IssueUpdateInput!) {
            issueUpdate(id: $id, input: $input) {
              success
            }
          }
          """,
          "variables" => %{
            "id" => "UDPE-6112",
            "input" => %{"stateId" => "state-review"}
          }
        },
        handoff_gate_context: %{issue: issue, workspace: workspace, worker_host: nil},
        linear_client: fn
          query, %{"issueId" => "UDPE-6112"}, [] ->
            assert query =~ "SymphonyResolveIssueTransition"

            {:ok,
             %{
               "data" => %{
                 "issue" => %{
                   "state" => %{"name" => "In Progress"},
                   "team" => %{
                     "states" => %{"nodes" => [%{"id" => "state-review", "name" => "In Review"}]}
                   }
                 }
               }
             }}

          _query, _variables, [] ->
            flunk("blocked nested-input handoff mutation should not be sent to Linear")
        end
      )

    assert response["success"] == false

    output = Jason.decode!(response["output"])
    assert get_in(output, ["error", "message"]) =~ "before_handoff hook blocked"
    assert get_in(output, ["error", "remediation"]) =~ "nested-input-state: nested stateId should run gates"
  end

  test "linear_graphql runs review before before_handoff and skips the expensive gate on request_changes" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-gate-tool-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    gate_marker = Path.join(workspace, "before-handoff-started")

    review_workflow = %{
      config: %{"review" => %{"max_iterations" => 3}},
      prompt: "Review {{ issue.identifier }}",
      prompt_template: "Review {{ issue.identifier }}"
    }

    # Stand-in reviewer session: writes a request_changes verdict to the
    # gate-provided path instead of launching Codex.
    test_pid = self()

    session_runner = fn ctx ->
      send(test_pid, {:review_issue_state, ctx.issue.state})
      refute File.exists?(gate_marker)

      write_review_verdict(
        ctx,
        %{
          "verdict" => "request_changes",
          "summary" => "missing test",
          "comments" => [
            %{
              "severity" => "major",
              "file" => "app/x.ts",
              "body" => "add a test",
              "missing_regression_test" => "No test covers the changed failure branch."
            }
          ]
        }
      )

      {:ok, %{}}
    end

    issue = %Issue{id: "issue-review", identifier: "UDPE-2", title: "Review me", state: "Todo"}

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "mutation Move($issueId: String!, $stateId: String!) { issueUpdate(id: $issueId, input: {stateId: $stateId}) { success } }",
          "variables" => %{"issueId" => "issue-review", "stateId" => "state-review"}
        },
        handoff_gate_context: %{
          issue: issue,
          workspace: workspace,
          worker_host: nil,
          before_handoff_command: "touch #{gate_marker}",
          review_workflow: review_workflow,
          review_opts: [session_runner: session_runner, pr_runner: stub_pr_runner()]
        },
        linear_client: fn
          _query, %{"issueId" => "issue-review"}, [] ->
            {:ok,
             %{
               "data" => %{
                 "issue" => %{
                   "state" => %{"name" => "In Progress"},
                   "team" => %{
                     "states" => %{"nodes" => [%{"id" => "state-review", "name" => "In Review"}]}
                   }
                 }
               }
             }}

          _query, _variables, [] ->
            flunk("the issue transition mutation must not reach Linear when the reviewer blocks")
        end
      )

    assert response["success"] == false
    assert_received {:review_issue_state, "In Progress"}
    refute File.exists?(gate_marker)

    output = Jason.decode!(response["output"])
    assert get_in(output, ["error", "message"]) =~ "Automated review did not approve"
    assert get_in(output, ["error", "remediation"]) =~ "requested changes (review pass 1 of 3)"
    assert get_in(output, ["error", "remediation"]) =~ "app/x.ts"
    assert [%{"severity" => "major"}] = get_in(output, ["error", "findings"])
    assert get_in(output, ["error", "review", "outcome"]) == "request_changes"
    assert get_in(output, ["error", "review", "reviewed_sha"]) == "head-7"
    assert get_in(output, ["error", "review", "severity_counts"]) == %{"major" => 1}
  end

  test "linear_graphql lets the transition through when the reviewer approves" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-gate-approve-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.dirname(workspace))
    on_exit(fn -> File.rm_rf(workspace) end)

    review_workflow = %{
      config: %{"review" => %{}},
      prompt: "Review {{ issue.identifier }}",
      prompt_template: "Review {{ issue.identifier }}"
    }

    test_pid = self()
    gate_marker = Path.join(workspace, "before-handoff-started")

    session_runner = fn ctx ->
      send(test_pid, {:inline_review_attestations, ctx.packet.validation_attestations})
      refute File.exists?(gate_marker)
      write_review_verdict(ctx, %{"verdict" => "approve", "comments" => []})
      {:ok, %{}}
    end

    issue = %Issue{id: "issue-ok", identifier: "UDPE-3", title: "Ship it", state: "In Progress"}

    gate_report = %{
      "protocolVersion" => 1,
      "jobId" => "job-inline-passed",
      "status" => "passed",
      "identity" => %{
        "repositoryIdentity" => "repo-inline",
        "worktreeIdentity" => "worktree-inline",
        "prNumber" => "7",
        "baseRef" => "main",
        "baseSha" => "base-7",
        "headSha" => "head-7",
        "candidateFingerprint" => "fingerprint-inline",
        "gateConfigHash" => "config-inline",
        "mutablePrStateHash" => "mutable-inline",
        "candidateHash" => "candidate-inline",
        "exactHash" => "exact-inline"
      },
      "resultArtifact" => ".artifacts/before-handoff/result.json",
      "checks" => [%{"id" => "check-evidence-fresh", "status" => "passed"}]
    }

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "mutation Move($issueId: String!, $stateId: String!) { issueUpdate(id: $issueId, input: {stateId: $stateId}) { success } }",
          "variables" => %{"issueId" => "issue-ok", "stateId" => "state-review"}
        },
        handoff_gate_context: %{
          issue: issue,
          workspace: workspace,
          worker_host: nil,
          before_handoff_command: "touch #{gate_marker} && printf '%s' '#{Jason.encode!(gate_report)}'",
          review_workflow: review_workflow,
          review_opts: [session_runner: session_runner, pr_runner: stub_pr_runner()]
        },
        linear_client: fn
          query, %{"issueId" => "issue-ok"}, [] ->
            if query =~ "SymphonyResolveIssueTransition" do
              {:ok,
               %{
                 "data" => %{
                   "issue" => %{
                     "state" => %{"name" => "In Progress"},
                     "team" => %{
                       "states" => %{"nodes" => [%{"id" => "state-review", "name" => "In Review"}]}
                     }
                   }
                 }
               }}
            else
              send(test_pid, :mutation_sent)
              {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
            end
        end
      )

    assert response["success"] == true
    assert_received {:inline_review_attestations, []}
    assert File.exists?(gate_marker)

    assert_received :mutation_sent
  end

  test "budget exhaustion remains blocked across repeated handoff mutations without new reviewers" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-budget-tool-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    issue = %Issue{
      id: "issue-budget",
      identifier: "UDPE-BUDGET",
      title: "Do not fail open",
      state: "In Progress"
    }

    test_pid = self()

    session_runner = fn ctx ->
      send(test_pid, :budget_reviewer_started)

      write_review_verdict(
        ctx,
        %{
          "verdict" => "request_changes",
          "summary" => "blocking finding remains",
          "comments" => [
            %{
              "severity" => "blocker",
              "body" => "fix tenant isolation",
              "failing_state" => "A user can read another tenant's record."
            }
          ]
        }
      )

      {:ok, %{}}
    end

    linear_client = fn
      query, %{"issueId" => "issue-budget"}, [] ->
        if query =~ "SymphonyResolveIssueTransition" do
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "state" => %{"name" => "In Progress"},
                 "team" => %{
                   "states" => %{
                     "nodes" => [%{"id" => "state-review", "name" => "In Review"}]
                   }
                 }
               }
             }
           }}
        else
          send(test_pid, :unexpected_budget_handoff_mutation)
          {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
        end
    end

    arguments = %{
      "query" => "mutation Move($issueId: String!, $stateId: String!) { issueUpdate(id: $issueId, input: {stateId: $stateId}) { success } }",
      "variables" => %{"issueId" => "issue-budget", "stateId" => "state-review"}
    }

    opts = [
      handoff_gate_context: %{
        issue: issue,
        workspace: workspace,
        worker_host: nil,
        review_workflow: review_workflow(%{"max_iterations" => 1}),
        review_opts: [
          session_runner: session_runner,
          pr_runner: stub_pr_runner(),
          comment_fn: fn _issue_id, _body -> :ok end
        ]
      },
      linear_client: linear_client
    ]

    [first, second, third] =
      Enum.map(1..3, fn _attempt ->
        DynamicTool.execute("linear_graphql", arguments, opts)
      end)

    assert first["success"] == false

    assert get_in(Jason.decode!(first["output"]), ["error", "review", "outcome"]) ==
             "budget_exhausted_with_findings"

    assert get_in(Jason.decode!(second["output"]), ["error", "review", "outcome"]) ==
             "budget_exhausted_with_findings"

    assert get_in(Jason.decode!(third["output"]), ["error", "review", "outcome"]) ==
             "budget_exhausted_with_findings"

    assert_received :budget_reviewer_started
    refute_received :budget_reviewer_started
    refute_received :unexpected_budget_handoff_mutation
  end

  test "linear_graphql defers the reviewer gate when a deferred callback is provided" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-gate-deferred-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    review_workflow = %{
      config: %{"review" => %{}},
      prompt: "Review {{ issue.identifier }}",
      prompt_template: "Review {{ issue.identifier }}"
    }

    issue = %Issue{id: "issue-defer", identifier: "UDPE-4", title: "Defer review", state: "In Progress"}
    test_pid = self()

    query =
      "mutation Move($issueId: String!, $stateId: String!) { issueUpdate(id: $issueId, input: {stateId: $stateId}) { success } }"

    variables = %{"issueId" => "issue-defer", "stateId" => "state-review"}

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query, "variables" => variables},
        handoff_gate_context: %{
          issue: issue,
          workspace: workspace,
          worker_host: nil,
          review_workflow: review_workflow,
          deferred_review_callback: fn request -> send(test_pid, {:deferred_review, request}) end
        },
        linear_client: fn
          state_query, %{"issueId" => "issue-defer"}, [] ->
            assert state_query =~ "SymphonyResolveIssueTransition"

            {:ok,
             %{
               "data" => %{
                 "issue" => %{
                   "state" => %{"name" => "In Progress"},
                   "team" => %{
                     "states" => %{"nodes" => [%{"id" => "state-review", "name" => "In Review"}]}
                   }
                 }
               }
             }}

          _mutation, _mutation_variables, [] ->
            flunk("deferred handoff mutation should not be sent before the reviewer runs")
        end
      )

    assert response["success"] == true
    output = Jason.decode!(response["output"])

    assert %{
             "success" => true,
             "status" => "deferred_review_started",
             "issueIdentifier" => "UDPE-4",
             "review" => %{"deferred" => true},
             "instructions" => instructions
           } = output

    assert instructions =~ "Do not retry the Linear handoff mutation"
    assert instructions =~ "End the turn now"
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]

    assert_received {:deferred_review, request}
    assert request.query == query
    assert request.variables == variables
    assert request.issue.identifier == "UDPE-4"
    assert request.review_workflow == review_workflow
    assert request.handoff_after_review.target_state == "In Review"
    refute Map.has_key?(request.handoff_after_review, :gate)
  end

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:linear_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ")

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert Jason.decode!(missing_token["output"]) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `tracker.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
      )

    assert Jason.decode!(status_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    detailed_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Bad { issueByKey(key: \"UDPE-1\") { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:error, {:linear_api_status, 400, [%{"message" => "Unknown field issueByKey", "code" => "GRAPHQL_VALIDATION_FAILED"}]}}
        end
      )

    decoded_detail = Jason.decode!(detailed_error["output"])
    assert decoded_detail["error"]["graphqlErrors"] == [%{"message" => "Unknown field issueByKey", "code" => "GRAPHQL_VALIDATION_FAILED"}]
    assert decoded_detail["error"]["hint"] =~ "Prefer `linear_issue`"

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_request, :timeout}} end
      )

    assert Jason.decode!(request_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "linear_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true
    assert response["output"] == ":ok"
  end
end
