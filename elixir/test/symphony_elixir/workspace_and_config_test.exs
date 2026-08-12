defmodule SymphonyElixir.WorkspaceAndConfigTest do
  use SymphonyElixir.TestSupport
  alias Ecto.Changeset
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.{Codex, StringOrMap}
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Linear.Comment

  defmodule UnsetTokenGitHubAuthProvider do
    @behaviour SymphonyElixir.GitHubAuth

    @impl true
    def prepare(workspace, _opts) do
      {:ok,
       %{
         env: [
           {"GH_TOKEN", false},
           {"GITHUB_ENTERPRISE_TOKEN", false},
           {"GITHUB_TOKEN", false},
           {"GH_ENTERPRISE_TOKEN", false}
         ],
         repo: "test/example",
         host: "github.com",
         auth_root: Path.join(workspace, ".artifacts/github-app-auth"),
         expires_at: ~U[2099-01-01 00:00:00Z]
       }}
    end

    @impl true
    def token(_workspace, _opts), do: {:error, :not_implemented}
  end

  test "workspace bootstrap can be implemented in after_create hook" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(Path.join(template_repo, "keep"))
      File.write!(Path.join([template_repo, "keep", "file.txt"]), "keep me")
      File.write!(Path.join(template_repo, "README.md"), "hook clone\n")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md", "keep/file.txt"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone --depth 1 #{template_repo} ."
      )

      assert {:ok, workspace} = Workspace.create_for_issue("S-1")
      assert File.exists?(Path.join(workspace, ".git"))
      assert File.read!(Path.join(workspace, "README.md")) == "hook clone\n"
      assert File.read!(Path.join([workspace, "keep", "file.txt"])) == "keep me"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace path is deterministic per issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-deterministic-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, first_workspace} = Workspace.create_for_issue("MT/Det")
    assert {:ok, second_workspace} = Workspace.create_for_issue("MT/Det")

    assert first_workspace == second_workspace
    assert Path.basename(first_workspace) == "MT_Det"
  end

  test "workspace hooks remove inherited token variables for GitHub App auth" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-auth-#{System.unique_integer([:positive])}"
      )

    token_variables = [
      "GH_TOKEN",
      "GITHUB_ENTERPRISE_TOKEN",
      "GITHUB_TOKEN",
      "GH_ENTERPRISE_TOKEN"
    ]

    previous_values = Map.new(token_variables, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous_values, fn {name, value} -> restore_env(name, value) end)
      File.rm_rf(workspace_root)
    end)

    Enum.each(token_variables, &System.put_env(&1, "inherited-personal-token"))

    Application.put_env(
      :symphony_elixir,
      :github_auth_provider,
      UnsetTokenGitHubAuthProvider
    )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOK-AUTH")

    assert {:ok, "unset:unset:unset:unset"} =
             Workspace.run_session_start_hook(workspace, "MT-HOOK-AUTH", nil,
               hook_command: "printf '%s:%s:%s:%s' \"${GH_TOKEN-unset}\" \"${GITHUB_ENTERPRISE_TOKEN-unset}\" \"${GITHUB_TOKEN-unset}\" \"${GH_ENTERPRISE_TOKEN-unset}\""
             )
  end

  test "workspace publishes and refreshes trusted issue context for hooks and agents" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-context-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        test_worker_limit: 3,
        heavy_validation_limit: 4
      )

      issue = %Issue{
        id: "issue-context-1",
        identifier: "UDPE-7011",
        title: "Keep repository gates informed",
        description: "Original scope",
        url: "https://linear.app/example/issue/UDPE-7011",
        state: "In Progress",
        labels: ["repo:udp-dashboard-v2"],
        comments: [
          %Comment{
            id: "comment-workpad",
            body: "## Codex Workpad\n\nWaiting for a decision.",
            author_id: "agent-1",
            author_name: "UDPAgent",
            created_at: ~U[2026-07-28 09:31:00Z],
            updated_at: ~U[2026-07-28 09:32:00Z]
          }
        ],
        comments_truncated: true,
        updated_at: ~U[2026-07-28 09:30:00Z]
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      context_file = Workspace.issue_context_path(workspace)
      refute String.starts_with?(context_file, workspace <> "/")
      assert File.regular?(context_file)

      assert %{
               "version" => 2,
               "capturedAt" => captured_at,
               "issue" => %{
                 "id" => "issue-context-1",
                 "identifier" => "UDPE-7011",
                 "title" => "Keep repository gates informed",
                 "description" => "Original scope",
                 "url" => "https://linear.app/example/issue/UDPE-7011",
                 "state" => "In Progress",
                 "labels" => ["repo:udp-dashboard-v2"],
                 "comments" => [
                   %{
                     "id" => "comment-workpad",
                     "body" => "## Codex Workpad\n\nWaiting for a decision.",
                     "author" => %{"id" => "agent-1", "name" => "UDPAgent"},
                     "createdAt" => "2026-07-28T09:31:00Z",
                     "updatedAt" => "2026-07-28T09:32:00Z"
                   }
                 ],
                 "commentsTruncated" => true,
                 "updatedAt" => "2026-07-28T09:30:00Z"
               }
             } = context_file |> File.read!() |> Jason.decode!()

      assert {:ok, _captured_at, 0} = DateTime.from_iso8601(captured_at)

      assert {:ok, ^context_file} =
               Workspace.run_session_start_hook(workspace, issue, nil, hook_command: "printf '%s' \"$SYMPHONY_ISSUE_CONTEXT_FILE\"")

      updated_issue = %{issue | description: "Updated scope"}

      assert {:ok, "3:4"} =
               Workspace.run_before_handoff_hook(workspace, updated_issue, nil, hook_command: "printf '%s:%s' \"$SYMPHONY_TEST_WORKER_LIMIT\" \"$SYMPHONY_HEAVY_VALIDATION_LIMIT\"")

      assert get_in(context_file |> File.read!() |> Jason.decode!(), ["issue", "description"]) ==
               "Updated scope"

      assert :ok =
               Workspace.persist_handoff_gate_state(workspace, %{
                 "query" => "mutation DeferredHandoff { issueUpdate { success } }",
                 "gate" => %{"jobId" => "job-context-1"}
               })

      assert {:ok, %{"gate" => %{"jobId" => "job-context-1"}}} =
               Workspace.load_handoff_gate_state(workspace)

      handoff_state_file = Workspace.handoff_gate_state_path(workspace)
      assert File.exists?(handoff_state_file)

      assert {:ok, _removed} = Workspace.remove(workspace)
      refute File.exists?(context_file)
      refute File.exists?(handoff_state_file)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace reuses existing issue directory without deleting local changes" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-reuse-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo first > README.md"
      )

      assert {:ok, first_workspace} = Workspace.create_for_issue("MT-REUSE")

      File.write!(Path.join(first_workspace, "README.md"), "changed\n")
      File.write!(Path.join(first_workspace, "local-progress.txt"), "in progress\n")
      File.mkdir_p!(Path.join(first_workspace, "deps"))
      File.mkdir_p!(Path.join(first_workspace, "_build"))
      File.mkdir_p!(Path.join(first_workspace, "tmp"))
      File.write!(Path.join([first_workspace, "deps", "cache.txt"]), "cached deps\n")
      File.write!(Path.join([first_workspace, "_build", "artifact.txt"]), "compiled artifact\n")
      File.write!(Path.join([first_workspace, "tmp", "scratch.txt"]), "remove me\n")

      assert {:ok, second_workspace} = Workspace.create_for_issue("MT-REUSE")
      assert second_workspace == first_workspace
      assert File.read!(Path.join(second_workspace, "README.md")) == "changed\n"
      assert File.read!(Path.join(second_workspace, "local-progress.txt")) == "in progress\n"
      assert File.read!(Path.join([second_workspace, "deps", "cache.txt"])) == "cached deps\n"
      assert File.read!(Path.join([second_workspace, "_build", "artifact.txt"])) == "compiled artifact\n"
      assert File.read!(Path.join([second_workspace, "tmp", "scratch.txt"])) == "remove me\n"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace replaces stale non-directory paths" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-stale-path-#{System.unique_integer([:positive])}"
      )

    try do
      stale_workspace = Path.join(workspace_root, "MT-STALE")
      File.mkdir_p!(workspace_root)
      File.write!(stale_workspace, "old state\n")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(stale_workspace)
      assert {:ok, workspace} = Workspace.create_for_issue("MT-STALE")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace rejects symlink escapes under the configured root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_root = Path.join(test_root, "outside")
      symlink_path = Path.join(workspace_root, "MT-SYM")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_root)
      File.ln_s!(outside_root, symlink_path)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_outside_root} = SymphonyElixir.PathSafety.canonicalize(outside_root)
      assert {:ok, canonical_workspace_root} = SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_outside_root, ^canonical_outside_root, ^canonical_workspace_root}} =
               Workspace.create_for_issue("MT-SYM")
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace canonicalizes symlinked workspace roots before creating issue directories" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      actual_root = Path.join(test_root, "actual-workspaces")
      linked_root = Path.join(test_root, "linked-workspaces")

      File.mkdir_p!(actual_root)
      File.ln_s!(actual_root, linked_root)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: linked_root)

      assert {:ok, canonical_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(actual_root, "MT-LINK"))

      assert {:ok, workspace} = Workspace.create_for_issue("MT-LINK")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove rejects the workspace root itself with a distinct error" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-remove-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_equals_root, ^canonical_workspace_root, ^canonical_workspace_root}, ""} =
               Workspace.remove(workspace_root)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook failures" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-failure-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo nope && exit 17"
      )

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               Workspace.create_for_issue("MT-FAIL")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook timeouts" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_timeout_ms: 10,
        hook_after_create: "sleep 1"
      )

      assert {:error, {:workspace_hook_timeout, "after_create", 10}} =
               Workspace.create_for_issue("MT-TIMEOUT")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace creates an empty directory when no bootstrap hook is configured" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-empty-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      workspace = Path.join(workspace_root, "MT-608")
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      assert {:ok, ^canonical_workspace} = Workspace.create_for_issue("MT-608")
      assert File.dir?(workspace)
      assert {:ok, []} = File.ls(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace removes all workspaces for a closed issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-workspace-cleanup-#{System.unique_integer([:positive])}"
      )

    try do
      target_workspace = Path.join(workspace_root, "S_1")
      untouched_workspace = Path.join(workspace_root, "OTHER-#{System.unique_integer([:positive])}")

      File.mkdir_p!(target_workspace)
      File.mkdir_p!(untouched_workspace)
      File.write!(Path.join(target_workspace, "marker.txt"), "stale")
      File.write!(Path.join(untouched_workspace, "marker.txt"), "keep")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert :ok = Workspace.remove_issue_workspaces("S_1")
      refute File.exists?(target_workspace)
      assert File.exists?(untouched_workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace cleanup handles missing workspace root" do
    missing_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-workspaces-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: missing_root)

    assert :ok = Workspace.remove_issue_workspaces("S-2")
  end

  test "workspace cleanup ignores non-binary identifier" do
    assert :ok = Workspace.remove_issue_workspaces(nil)
  end

  test "linear issue helpers" do
    issue = %Issue{
      id: "abc",
      labels: ["frontend", "infra"],
      assigned_to_worker: false
    }

    assert Issue.label_names(issue) == ["frontend", "infra"]
    assert issue.labels == ["frontend", "infra"]
    refute issue.assigned_to_worker

    assert Enum.map([1, 2, 3, 4, 0, nil, 99], &Issue.dispatch_priority_rank/1) ==
             [1, 2, 3, 4, 5, 5, 5]
  end

  test "linear client normalizes blockers from inverse relations" do
    raw_issue = %{
      "id" => "issue-1",
      "identifier" => "MT-1",
      "title" => "Blocked todo",
      "description" => "Needs dependency",
      "priority" => 2,
      "state" => %{"name" => "Todo"},
      "branchName" => "mt-1",
      "url" => "https://example.org/issues/MT-1",
      "assignee" => %{
        "id" => "user-1",
        "displayName" => "raul",
        "email" => "raul@pauca.co"
      },
      "creator" => %{
        "id" => "user-9",
        "displayName" => "someone-else",
        "email" => "creator@example.org"
      },
      "labels" => %{"nodes" => [%{"name" => "Backend"}]},
      "inverseRelations" => %{
        "nodes" => [
          %{
            "type" => "blocks",
            "issue" => %{
              "id" => "issue-2",
              "identifier" => "MT-2",
              "state" => %{"name" => "In Progress"}
            }
          },
          %{
            "type" => "relatesTo",
            "issue" => %{
              "id" => "issue-3",
              "identifier" => "MT-3",
              "state" => %{"name" => "Done"}
            }
          }
        ]
      },
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-02T00:00:00Z"
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    assert issue.blocked_by == [%{id: "issue-2", identifier: "MT-2", state: "In Progress"}]
    assert issue.labels == ["backend"]
    assert issue.priority == 2
    assert issue.state == "Todo"
    assert issue.assignee_id == "user-1"
    assert issue.assignee_display_name == "raul"
    assert issue.assignee_email == "raul@pauca.co"
    assert issue.creator_id == "user-9"
    assert issue.creator_display_name == "someone-else"
    assert issue.creator_email == "creator@example.org"
    assert issue.assigned_to_worker
  end

  test "linear client flattens grouped labels to <group>:<leaf>" do
    raw_issue = %{
      "id" => "issue-grouped",
      "identifier" => "UDPE-6563",
      "title" => "Grouped labels",
      "state" => %{"name" => "In Progress"},
      "labels" => %{
        "nodes" => [
          # ungrouped flat label → bare name
          %{"name" => "improve-skill", "parent" => nil},
          # grouped under "repo" → "repo:udp-dashboard-v2"
          %{"name" => "udp-dashboard-v2", "parent" => %{"name" => "repo"}},
          # ungrouped → bare name
          %{"name" => "udpagent"},
          # grouped under "agent" (leaf already contains a colon) →
          # "agent:opencode:kimi2.7" — the case that drives backend selection
          %{"name" => "opencode:kimi2.7", "parent" => %{"name" => "agent"}}
        ]
      }
    }

    issue = Client.normalize_issue_for_test(raw_issue, nil)

    assert issue.labels == [
             "improve-skill",
             "repo:udp-dashboard-v2",
             "udpagent",
             "agent:opencode:kimi2.7"
           ]
  end

  test "linear client dedupes a grouped label and its legacy flat twin" do
    raw_issue = %{
      "id" => "issue-dupe",
      "identifier" => "UDPE-1",
      "title" => "Dupe labels",
      "state" => %{"name" => "Todo"},
      "labels" => %{
        "nodes" => [
          %{"name" => "repo:udp-dashboard-v2", "parent" => nil},
          %{"name" => "udp-dashboard-v2", "parent" => %{"name" => "repo"}}
        ]
      }
    }

    issue = Client.normalize_issue_for_test(raw_issue, nil)

    assert issue.labels == ["repo:udp-dashboard-v2"]
  end

  test "linear client marks explicitly unassigned issues as not routed to worker" do
    raw_issue = %{
      "id" => "issue-99",
      "identifier" => "MT-99",
      "title" => "Someone else's task",
      "state" => %{"name" => "Todo"},
      "assignee" => %{
        "id" => "user-2"
      }
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    refute issue.assigned_to_worker
  end

  test "linear client pagination merge helper preserves issue ordering" do
    issue_page_1 = [
      %Issue{id: "issue-1", identifier: "MT-1"},
      %Issue{id: "issue-2", identifier: "MT-2"}
    ]

    issue_page_2 = [
      %Issue{id: "issue-3", identifier: "MT-3"}
    ]

    merged = Client.merge_issue_pages_for_test([issue_page_1, issue_page_2])

    assert Enum.map(merged, & &1.identifier) == ["MT-1", "MT-2", "MT-3"]
  end

  test "linear client paginates issue state fetches by id beyond one page" do
    issue_ids = Enum.map(1..55, &"issue-#{&1}")
    first_batch_ids = Enum.take(issue_ids, 50)
    second_batch_ids = Enum.drop(issue_ids, 50)

    raw_issue = fn issue_id ->
      suffix = String.replace_prefix(issue_id, "issue-", "")

      %{
        "id" => issue_id,
        "identifier" => "MT-#{suffix}",
        "title" => "Issue #{suffix}",
        "description" => "Description #{suffix}",
        "state" => %{"name" => "In Progress"},
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      }
    end

    graphql_fun = fn query, variables ->
      send(self(), {:fetch_issue_states_page, query, variables})

      body = %{
        "data" => %{
          "issues" => %{
            "nodes" => Enum.map(variables.ids, raw_issue)
          }
        }
      }

      {:ok, body}
    end

    assert {:ok, issues} = Client.fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)

    assert Enum.map(issues, & &1.id) == issue_ids

    assert_receive {:fetch_issue_states_page, query, %{ids: ^first_batch_ids, first: 50, relationFirst: 50}}
    assert query =~ "SymphonyLinearIssuesById"

    assert_receive {:fetch_issue_states_page, ^query, %{ids: ^second_batch_ids, first: 5, relationFirst: 50}}
  end

  test "linear client fetches a bounded, chronological issue comment snapshot" do
    graphql_fun = fn query, variables ->
      send(self(), {:fetch_issue_comments, query, variables})

      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "comments" => %{
               "nodes" => [
                 %{
                   "id" => "comment-2",
                   "body" => "Decision: use option B.",
                   "createdAt" => "2026-07-29T10:00:00Z",
                   "updatedAt" => "2026-07-29T10:00:00Z",
                   "user" => %{"id" => "user-1", "name" => "Product owner"}
                 },
                 %{
                   "id" => "comment-1",
                   "body" => "## Codex Workpad\n\nBlocked on the product decision.",
                   "createdAt" => "2026-07-29T09:00:00Z",
                   "updatedAt" => "2026-07-29T09:30:00Z",
                   "user" => %{"id" => "agent-1", "name" => "UDPAgent"}
                 }
               ],
               "pageInfo" => %{"hasNextPage" => true}
             }
           }
         }
       }}
    end

    assert {:ok, %{comments: [workpad, decision], truncated: true}} =
             Client.fetch_issue_comments_for_test("issue-1", graphql_fun)

    assert workpad.id == "comment-1"
    assert workpad.author_name == "UDPAgent"
    assert decision.id == "comment-2"
    assert decision.body == "Decision: use option B."

    assert_receive {:fetch_issue_comments, query, %{issueId: "issue-1", first: 50}}
    assert query =~ "SymphonyLinearIssueComments"
    assert query =~ "orderBy: updatedAt"
  end

  test "linear client rejects malformed comments instead of dropping required activity" do
    graphql_fun = fn _query, _variables ->
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "comments" => %{
               "nodes" => [%{"id" => "comment-without-body"}],
               "pageInfo" => %{"hasNextPage" => false}
             }
           }
         }
       }}
    end

    assert {:error, :linear_invalid_comment} =
             Client.fetch_issue_comments_for_test("issue-1", graphql_fun)
  end

  test "linear client logs response bodies for non-200 graphql responses" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:linear_api_status, 400}} =
                 Client.graphql(
                   "query Viewer { viewer { id } }",
                   %{},
                   request_fun: fn _payload, _headers ->
                     {:ok,
                      %{
                        status: 400,
                        body: %{
                          "errors" => [
                            %{
                              "message" => "Variable \"$ids\" got invalid value",
                              "extensions" => %{"code" => "BAD_USER_INPUT"}
                            }
                          ]
                        }
                      }}
                   end
                 )
      end)

    assert log =~ "Linear GraphQL request failed status=400"
    assert log =~ ~s(body=%{"errors" => [%{"extensions" => %{"code" => "BAD_USER_INPUT"})
    assert log =~ "Variable \\\"$ids\\\" got invalid value"
  end

  test "orchestrator sorts every Linear priority then oldest created_at and identifier" do
    issue_same_priority_older = %Issue{
      id: "issue-old-urgent",
      identifier: "MT-200",
      title: "Old urgent priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-01 00:00:00Z]
    }

    issue_same_priority_newer = %Issue{
      id: "issue-new-urgent",
      identifier: "MT-201",
      title: "New urgent priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-02 00:00:00Z]
    }

    issue_lower_priority_older = %Issue{
      id: "issue-old-low",
      identifier: "MT-199",
      title: "Old high priority",
      state: "Todo",
      priority: 2,
      created_at: ~U[2025-12-01 00:00:00Z]
    }

    medium = %Issue{
      id: "issue-medium",
      identifier: "MT-300",
      title: "Medium",
      state: "Todo",
      priority: 3,
      created_at: ~U[2025-01-01 00:00:00Z]
    }

    low = %{medium | id: "issue-low", identifier: "MT-400", title: "Low", priority: 4}

    no_priority = %{
      medium
      | id: "issue-none",
        identifier: "MT-500",
        title: "No priority",
        priority: nil
    }

    zero_priority = %{
      medium
      | id: "issue-zero",
        identifier: "MT-501",
        title: "Zero priority",
        priority: 0
    }

    sorted =
      Orchestrator.sort_issues_for_dispatch_for_test([
        zero_priority,
        issue_lower_priority_older,
        low,
        issue_same_priority_newer,
        no_priority,
        medium,
        issue_same_priority_older
      ])

    assert Enum.map(sorted, & &1.identifier) == [
             "MT-200",
             "MT-201",
             "MT-199",
             "MT-300",
             "MT-400",
             "MT-500",
             "MT-501"
           ]
  end

  test "todo issue with non-terminal blocker is not dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "blocked-1",
      identifier: "MT-1001",
      title: "Blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-1", identifier: "MT-1002", state: "In Progress"}]
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "non-todo active issue still respects a non-terminal dependency" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "blocked-active",
      identifier: "MT-1001A",
      title: "Active but dependency-blocked work",
      state: "In Progress",
      blocked_by: [%{id: "blocker-active", identifier: "MT-1002A", state: "In Progress"}]
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue assigned to another worker is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "dev@example.com")

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "assigned-away-1",
      identifier: "MT-1007",
      title: "Owned elsewhere",
      state: "Todo",
      assigned_to_worker: false
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "todo issue with terminal blockers remains dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "ready-1",
      identifier: "MT-1003",
      title: "Ready work",
      state: "Todo",
      blocked_by: [%{id: "blocker-2", identifier: "MT-1004", state: "Closed"}]
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch revalidation skips stale todo issue once a non-terminal blocker appears" do
    stale_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: []
    }

    refreshed_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
    }

    fetcher = fn ["blocked-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, %Issue{} = skipped_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)

    assert skipped_issue.identifier == "MT-1005"
    assert skipped_issue.blocked_by == [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
  end

  # UDPE-6950: `Ready to Merge` (and the other @review_states_set states) is a
  # human-actor handoff where the repo prompt forbids the agent from touching
  # the PR. Dispatching an implementor there wastes ~40 no-op turns and ends in
  # a false Blocked via mark_blocked_on_giveup(:max_turns_exhausted). The code
  # guard in candidate_issue?/3 must refuse the pickup even when a host's config
  # (mis)lists the state as active — so this test deliberately configures it as
  # active and proves it is still not dispatched.
  test "Ready to Merge issue with agent labels is not dispatched even when misconfigured as active" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "Ready to Merge"]
    )

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    ready_to_merge_issue = %Issue{
      id: "rtm-1",
      identifier: "MT-6950",
      title: "Approved, waiting on human merge",
      state: "Ready to Merge",
      labels: ["agent:claude:opus4.8", "symphony"],
      assigned_to_worker: true
    }

    refute Orchestrator.should_dispatch_issue_for_test(ready_to_merge_issue, state)

    # Control: the same setup still dispatches a genuinely active issue, so the
    # guard is specific to review/merge states rather than a blanket refusal.
    in_progress_issue = %{ready_to_merge_issue | id: "ip-1", identifier: "MT-6951", state: "In Progress"}
    assert Orchestrator.should_dispatch_issue_for_test(in_progress_issue, state)
  end

  # UDPE-6950: the continuation/retry path revalidates against the tracker via
  # retry_candidate_issue? (-> candidate_issue?/3) before re-dispatching. A
  # Ready to Merge issue must be skipped there too, so the do_run_codex_turns
  # loop can never keep re-running it up to agent.max_turns and demote it to
  # Blocked. Active_states lists the state so the skip is attributable to the
  # review-state guard, not to the state simply being non-active.
  test "dispatch revalidation skips a Ready to Merge issue so the max_turns->Blocked path is unreachable" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "Ready to Merge"]
    )

    ready_to_merge_issue = %Issue{
      id: "rtm-2",
      identifier: "MT-6952",
      title: "Approved, waiting on human merge",
      state: "Ready to Merge",
      labels: ["agent:claude:opus4.8"],
      assigned_to_worker: true
    }

    fetcher = fn ["rtm-2"] -> {:ok, [ready_to_merge_issue]} end

    assert {:skip, %Issue{} = skipped_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(ready_to_merge_issue, fetcher)

    assert skipped_issue.identifier == "MT-6952"
  end

  test "review_state?/1 identifies the human-actor review/merge states (UDPE-6950)" do
    for state <- ["Human Review", "In Review", "Merging", "Ready to Merge"] do
      assert Orchestrator.review_state?(state), "#{state} should be a review state"
    end

    # Case- and whitespace-insensitive (states arrive normalized elsewhere).
    assert Orchestrator.review_state?("  ready to merge  ")
    assert Orchestrator.review_state?("READY TO MERGE")

    # Genuine work states and non-strings are not review states.
    refute Orchestrator.review_state?("Todo")
    refute Orchestrator.review_state?("In Progress")
    refute Orchestrator.review_state?("Rework")
    refute Orchestrator.review_state?(nil)
  end

  test "workspace remove returns error information for missing directory" do
    random_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-#{System.unique_integer([:positive])}"
      )

    assert {:ok, []} = Workspace.remove(random_path)
  end

  test "workspace hooks support multiline YAML scripts and run at lifecycle boundaries" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      before_remove_marker = Path.join(test_root, "before_remove.log")
      after_create_counter = Path.join(test_root, "after_create.count")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo after_create > after_create.log\necho call >> \"#{after_create_counter}\"",
        hook_before_remove: "echo before_remove > \"#{before_remove_marker}\""
      )

      config = Config.settings!()
      assert config.hooks.after_create =~ "echo after_create > after_create.log"
      assert config.hooks.before_remove =~ "echo before_remove >"

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert File.read!(Path.join(workspace, "after_create.log")) == "after_create\n"

      assert {:ok, _workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert length(String.split(String.trim(File.read!(after_create_counter)), "\n")) == 1

      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS")
      assert File.read!(before_remove_marker) == "before_remove\n"
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "echo failure && exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails with large output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-large-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "i=0; while [ $i -lt 3000 ]; do printf a; i=$((i+1)); done; exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-LARGE-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-LARGE-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook times out" do
    previous_timeout = Application.get_env(:symphony_elixir, :workspace_hook_timeout_ms)

    on_exit(fn ->
      if is_nil(previous_timeout) do
        Application.delete_env(:symphony_elixir, :workspace_hook_timeout_ms)
      else
        Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, previous_timeout)
      end
    end)

    Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, 10)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "sleep 1"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-TIMEOUT")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-TIMEOUT")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "config reads defaults for optional settings" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.delete_env("LINEAR_API_KEY")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: nil,
      max_concurrent_agents: nil,
      codex_approval_policy: nil,
      codex_thread_sandbox: nil,
      codex_turn_sandbox_policy: nil,
      codex_turn_timeout_ms: nil,
      codex_read_timeout_ms: nil,
      codex_stall_timeout_ms: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    config = Config.settings!()
    assert config.tracker.endpoint == "https://api.linear.app/graphql"
    assert config.tracker.api_key == nil
    assert config.tracker.project_slug == nil
    assert config.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
    assert config.worker.max_concurrent_agents_per_host == nil
    assert config.agent.max_concurrent_agents == 10
    assert config.codex.command == "codex app-server"

    assert config.codex.approval_policy == %{
             "reject" => %{
               "sandbox_approval" => true,
               "rules" => true,
               "mcp_elicitations" => true
             }
           }

    assert config.codex.thread_sandbox == "workspace-write"

    assert {:ok, canonical_default_workspace_root} =
             SymphonyElixir.PathSafety.canonicalize(Path.join(System.tmp_dir!(), "symphony_workspaces"))

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "workspaceWrite",
             "writableRoots" => [canonical_default_workspace_root],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert config.codex.turn_timeout_ms == 0
    assert config.acp.prompt_timeout_ms == 0
    assert config.claude_code.prompt_timeout_ms == 0
    assert config.codex.read_timeout_ms == 5_000
    assert config.codex.stall_timeout_ms == 300_000
    assert config.hooks.before_handoff_timeout_ms == nil
    assert config.hooks.before_handoff_stale_ms == 120_000

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command: "codex --config 'model=\"gpt-5.5\"' app-server"
    )

    assert Config.settings!().codex.command ==
             "codex --config 'model=\"gpt-5.5\"' app-server"

    explicit_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-explicit-sandbox-root-#{System.unique_integer([:positive])}"
      )

    explicit_workspace = Path.join(explicit_root, "MT-EXPLICIT")
    explicit_cache = Path.join(explicit_workspace, "cache")
    File.mkdir_p!(explicit_cache)

    on_exit(fn -> File.rm_rf(explicit_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: explicit_root,
      codex_approval_policy: "on-request",
      codex_thread_sandbox: "workspace-write",
      codex_turn_sandbox_policy: %{
        type: "workspaceWrite",
        writableRoots: [explicit_workspace, explicit_cache]
      }
    )

    config = Config.settings!()
    assert config.codex.approval_policy == "on-request"
    assert config.codex.thread_sandbox == "workspace-write"

    assert Config.codex_turn_sandbox_policy(explicit_workspace) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [explicit_workspace, explicit_cache]
           }

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: ",")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_concurrent_agents"

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "worker.max_concurrent_agents_per_host"

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.turn_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_read_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.read_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_stall_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.stall_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: %{todo: true},
      tracker_terminal_states: %{done: true},
      poll_interval_ms: %{bad: true},
      workspace_root: 123,
      max_retry_backoff_ms: 0,
      max_concurrent_agents_by_state: %{"Todo" => "1", "Review" => 0, "Done" => "bad"},
      hook_timeout_ms: 0,
      observability_enabled: "maybe",
      observability_refresh_ms: %{bad: true},
      observability_render_interval_ms: %{bad: true},
      server_port: -1,
      server_host: 123
    )

    assert {:error, {:invalid_workflow_config, _message}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.approval_policy == ""

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.thread_sandbox == ""

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_sandbox_policy: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.turn_sandbox_policy"

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: "future-policy",
      codex_thread_sandbox: "future-sandbox",
      codex_turn_sandbox_policy: %{
        type: "futureSandbox",
        nested: %{flag: true}
      }
    )

    config = Config.settings!()
    assert config.codex.approval_policy == "future-policy"
    assert config.codex.thread_sandbox == "future-sandbox"

    assert :ok = Config.validate!()

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "futureSandbox",
             "nested" => %{"flag" => true}
           }

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "codex app-server")
    assert Config.settings!().codex.command == "codex app-server"
  end

  test "parses a gc lookback_days override and rejects a non-positive value" do
    assert {:ok, settings} = Schema.parse(%{"gc" => %{"lookback_days" => 14}})
    assert settings.gc.lookback_days == 14

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"gc" => %{"lookback_days" => 0}})

    assert message =~ "lookback_days"
  end

  test "gc lookback_days defaults to 7 when unset" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.gc.lookback_days == 7
  end

  test "acp block defaults to safe values when unset" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.acp.command == "opencode acp"
    assert settings.acp.auto_approve == true
    assert settings.acp.protocol_version == 1
    assert settings.acp.withhold_linear_credentials == true
    assert settings.acp.advertise_fs == false
    assert settings.acp.advertise_terminal == false
  end

  test "parses an acp block and runtime settings" do
    assert {:ok, settings} =
             Schema.parse(%{
               "agent" => %{"backend" => "acp"},
               "acp" => %{
                 "command" => "opencode acp",
                 "auto_approve" => false,
                 "withhold_linear_credentials" => false,
                 "read_timeout_ms" => 1234
               }
             })

    assert settings.agent.backend == "acp"
    assert settings.acp.auto_approve == false
    assert settings.acp.withhold_linear_credentials == false
    assert settings.acp.read_timeout_ms == 1234
  end

  test "acp_runtime_settings exposes the acp block as a map" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "acp",
      acp_command: "opencode acp",
      acp_auto_approve: false
    )

    assert {:ok, acp} = Config.acp_runtime_settings()
    assert acp.command == "opencode acp"
    assert acp.auto_approve == false
    assert acp.withhold_linear_credentials == true
    assert acp.heartbeat_ms == 30_000
  end

  test "acp.heartbeat_ms defaults to 30s and rejects negative values" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.acp.heartbeat_ms == 30_000

    assert {:ok, custom} = Schema.parse(%{"acp" => %{"heartbeat_ms" => 0}})
    assert custom.acp.heartbeat_ms == 0

    assert {:error, {:invalid_workflow_config, _message}} =
             Schema.parse(%{"acp" => %{"heartbeat_ms" => -1}})
  end

  test "validate! rejects an empty acp command when the acp backend is selected" do
    assert {:error, {:invalid_workflow_config, _message}} =
             Schema.parse(%{"agent" => %{"backend" => "acp"}, "acp" => %{"command" => ""}})
  end

  test "claude_code block defaults to safe values when unset" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.claude_code.command == "claude"
    assert settings.claude_code.permission_mode == "bypassPermissions"
    assert settings.claude_code.extra_args == []
    assert settings.claude_code.withhold_linear_credentials == true
  end

  test "parses a claude_code block and runtime settings" do
    assert {:ok, settings} =
             Schema.parse(%{
               "agent" => %{"backend" => "claude_code"},
               "claude_code" => %{
                 "command" => "claude",
                 "model" => "opus",
                 "permission_mode" => "acceptEdits",
                 "extra_args" => ["--append-system-prompt", "hi"]
               }
             })

    assert settings.agent.backend == "claude_code"
    assert settings.claude_code.model == "opus"
    assert settings.claude_code.permission_mode == "acceptEdits"
    assert settings.claude_code.extra_args == ["--append-system-prompt", "hi"]
  end

  test "claude_code_runtime_settings exposes the claude_code block as a map" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "claude_code",
      claude_code_command: "claude",
      claude_code_model: "opus"
    )

    assert {:ok, cc} = Config.claude_code_runtime_settings()
    assert cc.command == "claude"
    assert cc.model == "opus"
    assert cc.permission_mode == "bypassPermissions"
    assert cc.withhold_linear_credentials == true
  end

  test "backend_stall_timeout_ms/1 resolves per-backend, falling back to codex (UDPE-6952)" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_stall_timeout_ms: 111_000,
      acp_stall_timeout_ms: 333_000,
      claude_code_stall_timeout_ms: 555_000
    )

    assert Config.backend_stall_timeout_ms("codex") == 111_000
    assert Config.backend_stall_timeout_ms("acp") == 333_000
    assert Config.backend_stall_timeout_ms("claude_code") == 555_000
    # nil (backend not yet reported) and unknown names fall back to codex.
    assert Config.backend_stall_timeout_ms(nil) == 111_000
    assert Config.backend_stall_timeout_ms("gemini") == 111_000
  end

  test "backend_turn_timeout_ms/1 resolves per-backend, falling back to codex (UDPE-6952)" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_timeout_ms: 222_000,
      acp_prompt_timeout_ms: 444_000,
      claude_code_prompt_timeout_ms: 666_000
    )

    assert Config.backend_turn_timeout_ms("codex") == 222_000
    # ACP/Claude Code expose the turn-timeout equivalent as prompt_timeout_ms.
    assert Config.backend_turn_timeout_ms("acp") == 444_000
    assert Config.backend_turn_timeout_ms("claude_code") == 666_000
    assert Config.backend_turn_timeout_ms(nil) == 222_000
    assert Config.backend_turn_timeout_ms("gemini") == 222_000
  end

  test "backend_review_timeout_ms/1 prefers the stall timeout when positive (UDPE-6952)" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_stall_timeout_ms: 111_000,
      codex_turn_timeout_ms: 222_000,
      acp_stall_timeout_ms: 333_000,
      acp_prompt_timeout_ms: 444_000,
      claude_code_stall_timeout_ms: 555_000,
      claude_code_prompt_timeout_ms: 666_000
    )

    assert Config.backend_review_timeout_ms("codex") == 111_000
    assert Config.backend_review_timeout_ms("acp") == 333_000
    assert Config.backend_review_timeout_ms("claude_code") == 555_000
    assert Config.backend_review_timeout_ms(nil) == 111_000
    assert Config.backend_review_timeout_ms("gemini") == 111_000
  end

  test "backend_review_timeout_ms/1 falls back to the turn timeout when stall is 0 (UDPE-6952)" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_stall_timeout_ms: 0,
      codex_turn_timeout_ms: 222_000,
      acp_stall_timeout_ms: 0,
      acp_prompt_timeout_ms: 444_000
    )

    assert Config.backend_review_timeout_ms("codex") == 222_000
    assert Config.backend_review_timeout_ms("acp") == 444_000
    # nil/unknown still resolve through codex (stall 0 -> turn timeout).
    assert Config.backend_review_timeout_ms(nil) == 222_000
  end

  test "review_settings/1 bounds repository-owned packet and fresh-thread budgets" do
    workflow = %{
      config: %{
        "review" => %{
          "max_iterations" => 99,
          "packet_path" => ".review/packet.json",
          "packet_max_bytes" => 1,
          "context_budget_tokens" => 999_999,
          "turn_budget" => 12,
          "turn_timeout_ms" => 10,
          "tool_output_max_bytes" => 99,
          "model" => "gpt-review",
          "reasoning_effort" => "high",
          "require_pr" => false
        }
      },
      prompt: "review",
      prompt_template: "review"
    }

    settings = Config.review_settings(workflow)

    assert settings.max_iterations == 20
    assert settings.packet_path == ".review/packet.json"
    assert settings.packet_max_bytes == 8_192
    assert settings.context_budget_tokens == 65_536
    assert settings.turn_budget == 1
    assert settings.turn_timeout_ms == 30_000
    assert settings.tool_output_max_bytes == 512
    assert settings.model == "gpt-review"
    assert settings.reasoning_effort == "high"
    refute settings.require_pr

    minimum =
      Config.review_settings(%{
        config: %{"review" => %{"context_budget_tokens" => 1}},
        prompt: "review",
        prompt_template: "review"
      })

    assert minimum.context_budget_tokens == 6_144
  end

  test "rejects an unknown claude_code permission_mode" do
    assert {:error, {:invalid_workflow_config, _message}} =
             Schema.parse(%{"claude_code" => %{"permission_mode" => "yolo"}})
  end

  test "validate! rejects an empty claude_code command when the claude_code backend is selected" do
    assert {:error, {:invalid_workflow_config, _message}} =
             Schema.parse(%{"agent" => %{"backend" => "claude_code"}, "claude_code" => %{"command" => ""}})
  end

  test "agent.label_presets defaults to an empty list" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.agent.label_presets == []
  end

  test "agent.pre_command defaults to nil and parses when set" do
    assert {:ok, defaults} = Schema.parse(%{})
    assert defaults.agent.pre_command == nil

    assert {:ok, settings} =
             Schema.parse(%{"agent" => %{"pre_command" => ". .artifacts/github-app-auth/session.env"}})

    assert settings.agent.pre_command == ". .artifacts/github-app-auth/session.env"
  end

  test "parses agent.label_presets with backend+model overrides" do
    assert {:ok, settings} =
             Schema.parse(%{
               "agent" => %{
                 "backend" => "codex",
                 "label_presets" => [
                   %{"label" => "agent:fast", "backend" => "acp", "model" => "opencode/north-mini-code-free"},
                   %{"label" => "agent:deep", "backend" => "claude_code", "model" => "opus"},
                   %{"label" => "agent:codex", "backend" => "codex"}
                 ]
               }
             })

    assert [fast, deep, codex] = settings.agent.label_presets
    assert fast.label == "agent:fast"
    assert fast.backend == "acp"
    assert fast.model == "opencode/north-mini-code-free"
    assert deep.backend == "claude_code"
    assert deep.model == "opus"
    assert codex.backend == "codex"
    assert codex.model == nil
  end

  test "rejects a label_preset with an unknown backend" do
    assert {:error, {:invalid_workflow_config, _message}} =
             Schema.parse(%{"agent" => %{"label_presets" => [%{"label" => "x", "backend" => "gemini"}]}})
  end

  test "rejects a label_preset with a blank label" do
    assert {:error, {:invalid_workflow_config, _message}} =
             Schema.parse(%{"agent" => %{"label_presets" => [%{"label" => "  ", "backend" => "acp"}]}})
  end

  test "rejects a label_preset missing its backend" do
    assert {:error, {:invalid_workflow_config, _message}} =
             Schema.parse(%{"agent" => %{"label_presets" => [%{"label" => "agent:fast"}]}})
  end

  test "config resolves $VAR references for env-backed secret and path values" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    project_slug_env_var = "SYMP_LINEAR_PROJECT_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"
    project_slug = "resolved-project"
    codex_bin = Path.join(["~", "bin", "codex"])

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)
    previous_project_slug = System.get_env(project_slug_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)
    System.put_env(project_slug_env_var, project_slug)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
      restore_env(project_slug_env_var, previous_project_slug)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$#{api_key_env_var}",
      tracker_project_slug: "$#{project_slug_env_var}",
      workspace_root: "$#{workspace_env_var}",
      codex_command: "#{codex_bin} app-server"
    )

    config = Config.settings!()
    assert config.tracker.api_key == api_key
    assert config.tracker.project_slug == project_slug
    assert config.workspace.root == Path.expand(workspace_root)
    assert config.codex.command == "#{codex_bin} app-server"
  end

  test "config no longer resolves legacy env: references" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "env:#{api_key_env_var}",
      workspace_root: "env:#{workspace_env_var}"
    )

    config = Config.settings!()
    assert config.tracker.api_key == "env:#{api_key_env_var}"
    assert config.workspace.root == "env:#{workspace_env_var}"
  end

  test "config supports per-state max concurrent agent overrides" do
    workflow = """
    ---
    agent:
      max_concurrent_agents: 10
      max_concurrent_agents_by_state:
        todo: 1
        "In Progress": 4
        "In Review": 2
    ---
    """

    File.write!(Workflow.workflow_file_path(), workflow)

    assert Config.settings!().agent.max_concurrent_agents == 10
    assert Config.max_concurrent_agents_for_state("Todo") == 1
    assert Config.max_concurrent_agents_for_state("In Progress") == 4
    assert Config.max_concurrent_agents_for_state("In Review") == 2
    assert Config.max_concurrent_agents_for_state("Closed") == 10
    assert Config.max_concurrent_agents_for_state(:not_a_string) == 10

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 2)
    assert :ok = Config.validate!()
    assert Config.settings!().worker.max_concurrent_agents_per_host == 2
  end

  test "schema helpers cover custom type and state limit validation" do
    assert StringOrMap.type() == :map
    assert StringOrMap.embed_as(:json) == :self
    assert StringOrMap.equal?(%{"a" => 1}, %{"a" => 1})
    refute StringOrMap.equal?(%{"a" => 1}, %{"a" => 2})

    assert {:ok, "value"} = StringOrMap.cast("value")
    assert {:ok, %{"a" => 1}} = StringOrMap.cast(%{"a" => 1})
    assert :error = StringOrMap.cast(123)

    assert {:ok, "value"} = StringOrMap.load("value")
    assert :error = StringOrMap.load(123)

    assert {:ok, %{"a" => 1}} = StringOrMap.dump(%{"a" => 1})
    assert :error = StringOrMap.dump(123)

    assert Schema.normalize_state_limits(nil) == %{}

    assert Schema.normalize_state_limits(%{"In Progress" => 2, todo: 1}) == %{
             "todo" => 1,
             "in progress" => 2
           }

    changeset =
      {%{}, %{limits: :map}}
      |> Changeset.cast(%{limits: %{"" => 1, "todo" => 0}}, [:limits])
      |> Schema.validate_state_limits(:limits)

    assert changeset.errors == [
             limits: {"state names must not be blank", []},
             limits: {"limits must be positive integers", []}
           ]
  end

  test "schema parse normalizes policy keys and env-backed fallbacks" do
    missing_workspace_env = "SYMP_MISSING_WORKSPACE_#{System.unique_integer([:positive])}"
    empty_secret_env = "SYMP_EMPTY_SECRET_#{System.unique_integer([:positive])}"
    missing_secret_env = "SYMP_MISSING_SECRET_#{System.unique_integer([:positive])}"
    empty_project_env = "SYMP_EMPTY_PROJECT_#{System.unique_integer([:positive])}"
    missing_project_env = "SYMP_MISSING_PROJECT_#{System.unique_integer([:positive])}"

    previous_missing_workspace_env = System.get_env(missing_workspace_env)
    previous_empty_secret_env = System.get_env(empty_secret_env)
    previous_missing_secret_env = System.get_env(missing_secret_env)
    previous_empty_project_env = System.get_env(empty_project_env)
    previous_missing_project_env = System.get_env(missing_project_env)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    previous_linear_project_slug = System.get_env("LINEAR_PROJECT_SLUG")

    System.delete_env(missing_workspace_env)
    System.put_env(empty_secret_env, "")
    System.delete_env(missing_secret_env)
    System.put_env(empty_project_env, "")
    System.delete_env(missing_project_env)
    System.put_env("LINEAR_API_KEY", "fallback-linear-token")
    System.put_env("LINEAR_PROJECT_SLUG", "fallback-linear-project")

    on_exit(fn ->
      restore_env(missing_workspace_env, previous_missing_workspace_env)
      restore_env(empty_secret_env, previous_empty_secret_env)
      restore_env(missing_secret_env, previous_missing_secret_env)
      restore_env(empty_project_env, previous_empty_project_env)
      restore_env(missing_project_env, previous_missing_project_env)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
      restore_env("LINEAR_PROJECT_SLUG", previous_linear_project_slug)
    end)

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{empty_secret_env}", project_slug: "$#{empty_project_env}"},
               workspace: %{root: "$#{missing_workspace_env}"},
               codex: %{approval_policy: %{reject: %{sandbox_approval: true}}}
             })

    assert settings.tracker.api_key == nil
    assert settings.tracker.project_slug == nil
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")

    assert settings.codex.approval_policy == %{
             "reject" => %{"sandbox_approval" => true}
           }

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{missing_secret_env}", project_slug: "$#{missing_project_env}"},
               workspace: %{root: ""}
             })

    assert settings.tracker.api_key == "fallback-linear-token"
    assert settings.tracker.project_slug == "fallback-linear-project"
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
  end

  test "schema resolves sandbox policies from explicit and default workspaces" do
    explicit_policy = %{"type" => "workspaceWrite", "writableRoots" => ["/tmp/explicit"]}

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             codex: %Codex{turn_sandbox_policy: explicit_policy},
             workspace: %Schema.Workspace{root: "/tmp/ignored"}
           }) == explicit_policy

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             codex: %Codex{turn_sandbox_policy: nil},
             workspace: %Schema.Workspace{root: ""}
           }) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert Schema.resolve_turn_sandbox_policy(
             %Schema{
               codex: %Codex{turn_sandbox_policy: nil},
               workspace: %Schema.Workspace{root: "/tmp/ignored"}
             },
             "/tmp/workspace"
           ) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("/tmp/workspace")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "schema keeps workspace roots raw while sandbox helpers expand only for local use" do
    assert {:ok, settings} =
             Schema.parse(%{
               workspace: %{root: "~/.symphony-workspaces"},
               codex: %{}
             })

    assert settings.workspace.root == "~/.symphony-workspaces"

    assert Schema.resolve_turn_sandbox_policy(settings) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("~/.symphony-workspaces")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert {:ok, remote_policy} =
             Schema.resolve_runtime_turn_sandbox_policy(settings, nil, remote: true)

    assert remote_policy == %{
             "type" => "workspaceWrite",
             "writableRoots" => ["~/.symphony-workspaces"],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "runtime sandbox policy resolution passes explicit policies through unchanged" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-100")
      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: ["relative/path"],
          networkAccess: true
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => ["relative/path"],
               "networkAccess" => true
             }

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "futureSandbox",
          nested: %{flag: true}
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "futureSandbox",
               "nested" => %{"flag" => true}
             }
    after
      File.rm_rf(test_root)
    end
  end

  test "path safety returns errors for invalid path segments" do
    invalid_segment = String.duplicate("a", 300)
    path = Path.join(System.tmp_dir!(), invalid_segment)
    expanded_path = Path.expand(path)

    assert {:error, {:path_canonicalize_failed, ^expanded_path, :enametoolong}} =
             SymphonyElixir.PathSafety.canonicalize(path)
  end

  test "runtime sandbox policy resolution defaults when omitted and ignores workspace for explicit policies" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-branches-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-101")

      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      settings = Config.settings!()

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:ok, default_policy} = Schema.resolve_runtime_turn_sandbox_policy(settings)
      assert default_policy["type"] == "workspaceWrite"
      assert default_policy["writableRoots"] == [canonical_workspace_root]

      assert {:ok, blank_workspace_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, "")

      assert blank_workspace_policy == default_policy

      read_only_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "readOnly", "networkAccess" => true}}
      }

      assert {:ok, %{"type" => "readOnly", "networkAccess" => true}} =
               Schema.resolve_runtime_turn_sandbox_policy(read_only_settings, 123)

      future_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "futureSandbox", "nested" => %{"flag" => true}}}
      }

      assert {:ok, %{"type" => "futureSandbox", "nested" => %{"flag" => true}}} =
               Schema.resolve_runtime_turn_sandbox_policy(future_settings, 123)

      assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, 123}}} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, 123)
    after
      File.rm_rf(test_root)
    end
  end

  test "workflow prompt is used when building base prompt" do
    workflow_prompt = "Workflow prompt body used as codex instruction."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)
    assert Config.workflow_prompt() == workflow_prompt
  end

  test "remote workspace lifecycle uses ssh host aliases from worker config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-workspace-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      workspace_root = "~/.symphony-remote-workspaces"
      workspace_path = "/remote/home/.symphony-remote-workspaces/MT-SSH-WS"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '#{workspace_path}'
          ;;
      esac

      exit 0
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01:2200"],
        hook_before_run: "echo before-run",
        hook_after_run: "echo after-run",
        hook_before_remove: "echo before-remove"
      )

      assert Config.settings!().worker.ssh_hosts == ["worker-01:2200"]
      assert Config.settings!().workspace.root == workspace_root
      assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.run_before_run_hook(workspace_path, "MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.run_after_run_hook(workspace_path, "MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.remove_issue_workspaces("MT-SSH-WS", "worker-01:2200")

      trace = File.read!(trace_file)
      assert trace =~ "-p 2200 worker-01 bash -lc"
      assert trace =~ "__SYMPHONY_WORKSPACE__"
      assert trace =~ "~/.symphony-remote-workspaces/MT-SSH-WS"
      assert trace =~ "${workspace#~/}"
      assert trace =~ "echo before-run"
      assert trace =~ "echo after-run"
      assert trace =~ "echo before-remove"
      assert trace =~ "rm -rf"
      assert trace =~ workspace_path
    after
      File.rm_rf(test_root)
    end
  end
end
