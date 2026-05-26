defmodule SymphonyElixir.RouterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{RepoConfig, Router}
  alias SymphonyElixir.Linear.Issue

  defp config_with_repos(repos) do
    %{RepoConfig.empty() | source: :file, repos: repos}
  end

  defp repo(id, label) do
    %{
      id: id,
      label: label,
      repo_url: nil,
      workflow_path: "WORKFLOW.md",
      max_concurrent: 1
    }
  end

  describe "route/2" do
    test "falls back to legacy_mode when no repos are configured" do
      issue = %Issue{id: "1", identifier: "UDPE-1", labels: ["dashboard-v2"]}
      assert Router.route(issue, RepoConfig.empty()) == {:skip, :legacy_mode}
    end

    test "ok when a single configured label matches a leaf label on the issue" do
      config = config_with_repos([repo("udp", "repo:dashboard-v2")])
      # Linear stores grouped labels by leaf name only — the `repo:` prefix
      # in repos.yaml is normalized away to match.
      issue = %Issue{id: "1", identifier: "UDPE-1", labels: ["bug", "dashboard-v2"]}
      assert {:ok, %{id: "udp"}} = Router.route(issue, config)
    end

    test "ok when the configured label includes no prefix and matches verbatim" do
      config = config_with_repos([repo("udp", "udp-dashboard-v2")])
      issue = %Issue{id: "1", labels: ["udp-dashboard-v2"]}
      assert {:ok, %{id: "udp"}} = Router.route(issue, config)
    end

    test "skip no_match when no label matches a configured repo" do
      config = config_with_repos([repo("udp", "repo:dashboard-v2")])
      issue = %Issue{id: "1", identifier: "UDPE-1", labels: ["bug"]}
      assert Router.route(issue, config) == {:skip, :no_match, ["bug"]}
    end

    test "no_match carries the observed labels" do
      config = config_with_repos([repo("udp", "repo:dashboard-v2")])
      issue = %Issue{id: "1", identifier: "UDPE-1", labels: ["typo", "bug"]}
      assert Router.route(issue, config) == {:skip, :no_match, ["typo", "bug"]}
    end

    test "skip ambiguous when an issue carries labels matching multiple configured repos" do
      config = config_with_repos([repo("a", "repo:a"), repo("b", "repo:b")])
      # Linear's leaf names — both match because Router normalizes
      # `repo:a` -> `a` and `repo:b` -> `b`.
      issue = %Issue{id: "1", identifier: "UDPE-1", labels: ["a", "b"]}

      assert {:skip, :ambiguous, matches} = Router.route(issue, config)
      assert length(matches) == 2
    end
  end

  describe "eligible_for_warning?/2" do
    setup do
      %{active_states: MapSet.new(["todo", "in progress"])}
    end

    test "true when issue is active, assigned to symphony, and not already warned",
         %{active_states: active} do
      issue = %Issue{state: "Todo", assigned_to_worker: true, labels: []}
      assert Router.eligible_for_warning?(issue, active) == true
    end

    test "true when symphony:pick-up label is set even without assignment",
         %{active_states: active} do
      issue = %Issue{state: "Todo", assigned_to_worker: false, labels: ["symphony:pick-up"]}
      assert Router.eligible_for_warning?(issue, active) == true
    end

    test "false when issue carries the routing-warned idempotency label",
         %{active_states: active} do
      issue = %Issue{
        state: "Todo",
        assigned_to_worker: true,
        labels: ["symphony:routing-warned"]
      }

      assert Router.eligible_for_warning?(issue, active) == false
    end

    test "false when issue is in a non-active state", %{active_states: active} do
      issue = %Issue{state: "Done", assigned_to_worker: true, labels: []}
      assert Router.eligible_for_warning?(issue, active) == false
    end
  end

  describe "warning_comment/3" do
    test "includes the routing-warned marker for idempotency" do
      config = config_with_repos([repo("udp", "repo:dashboard-v2")])
      issue = %Issue{id: "1", labels: ["typo"]}
      decision = {:skip, :no_match, ["typo"]}

      body = Router.warning_comment(issue, decision, config)
      assert body =~ "symphony:routing-warned"
      assert body =~ "typo"
    end
  end
end
