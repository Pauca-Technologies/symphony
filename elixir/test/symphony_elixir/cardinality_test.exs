defmodule SymphonyElixir.CardinalityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Cardinality, RepoConfig}
  alias SymphonyElixir.Linear.Issue

  defp config_with_cutover(date) do
    defaults = Map.put(RepoConfig.empty().defaults, :cardinality_enforced_from, date)
    %{RepoConfig.empty() | defaults: defaults}
  end

  describe "check/2" do
    test "ok for a routable single-repo issue with no PRs" do
      issue = %Issue{
        id: "1",
        identifier: "UDPE-1",
        labels: ["repo:dashboard-v2"]
      }

      assert Cardinality.check(issue, RepoConfig.empty()) == :ok
    end

    test "multiple_repo_labels when two repo: labels are present" do
      issue = %Issue{
        id: "1",
        identifier: "UDPE-1",
        labels: ["repo:a", "repo:b"]
      }

      assert {:violations, [:multiple_repo_labels]} =
               Cardinality.check(issue, RepoConfig.empty())
    end

    test "parent_with_repo_label when a parent (has children) carries a repo: label" do
      issue = %Issue{
        id: "1",
        identifier: "UDPE-1",
        labels: ["repo:a"],
        children: [%{id: "2", identifier: "UDPE-2", state: "Todo", labels: []}]
      }

      assert {:violations, list} = Cardinality.check(issue, RepoConfig.empty())
      assert :parent_with_repo_label in list
    end

    test "parent_with_pr when a parent has attached GitHub PR URLs" do
      issue = %Issue{
        id: "1",
        identifier: "UDPE-1",
        labels: [],
        attachment_urls: ["https://github.com/Pauca-Technologies/udp/pull/12"],
        children: [%{id: "2", identifier: "UDPE-2", state: "Todo", labels: []}]
      }

      assert {:violations, list} = Cardinality.check(issue, RepoConfig.empty())
      assert :parent_with_pr in list
    end

    test "multiple_prs when more than one PR URL is attached" do
      issue = %Issue{
        id: "1",
        identifier: "UDPE-1",
        labels: ["repo:a"],
        attachment_urls: [
          "https://github.com/x/y/pull/1",
          "https://github.com/x/y/pull/2"
        ]
      }

      assert {:violations, list} = Cardinality.check(issue, RepoConfig.empty())
      assert :multiple_prs in list
    end
  end

  describe "cutover" do
    test "issues created before cutover are not enforced" do
      config = config_with_cutover(~D[2026-06-01])

      issue = %Issue{
        id: "1",
        identifier: "UDPE-1",
        labels: ["repo:a", "repo:b"],
        created_at: ~U[2026-05-15 12:00:00Z]
      }

      assert Cardinality.check(issue, config) == {:not_enforced, :pre_cutover}
    end

    test "issues created on/after cutover are enforced" do
      config = config_with_cutover(~D[2026-06-01])

      issue = %Issue{
        id: "1",
        identifier: "UDPE-1",
        labels: ["repo:a", "repo:b"],
        created_at: ~U[2026-06-15 12:00:00Z]
      }

      assert {:violations, list} = Cardinality.check(issue, config)
      assert :multiple_repo_labels in list
    end
  end

  describe "violation_comment/2" do
    test "includes the routing-warned marker for idempotency and explains each violation" do
      issue = %Issue{
        id: "1",
        identifier: "UDPE-1",
        labels: ["repo:a", "repo:b"]
      }

      body = Cardinality.violation_comment(issue, [:multiple_repo_labels])
      assert body =~ "symphony:routing-warned"
      assert body =~ "Multiple `repo:<name>` labels"
    end
  end
end
