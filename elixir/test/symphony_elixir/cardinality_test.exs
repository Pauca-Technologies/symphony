defmodule SymphonyElixir.CardinalityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Cardinality, RepoConfig}
  alias SymphonyElixir.Linear.Issue

  defp repo(id, label) do
    %{
      id: id,
      label: label,
      repo_url: nil,
      workflow_path: "WORKFLOW.md",
      max_concurrent: 1
    }
  end

  defp config_with_repos(repos) do
    %{RepoConfig.empty() | source: :file, repos: repos}
  end

  defp config_with_cutover_and_repos(date, repos) do
    defaults = Map.put(RepoConfig.empty().defaults, :cardinality_enforced_from, date)
    %{RepoConfig.empty() | defaults: defaults, repos: repos, source: :file}
  end

  describe "check/2" do
    test "ok for a routable single-repo issue with no PRs" do
      config = config_with_repos([repo("udp", "repo:dashboard-v2")])

      issue = %Issue{
        id: "1",
        identifier: "UDPE-1",
        labels: ["dashboard-v2"]
      }

      assert Cardinality.check(issue, config) == :ok
    end

    test "multiple_repo_labels when two configured-repo labels match" do
      config = config_with_repos([repo("a", "repo:a"), repo("b", "repo:b")])

      issue = %Issue{
        id: "1",
        identifier: "UDPE-1",
        labels: ["a", "b"]
      }

      assert {:violations, [:multiple_repo_labels]} = Cardinality.check(issue, config)
    end

    test "parent_with_repo_label when a parent carries a configured-repo label" do
      config = config_with_repos([repo("a", "repo:a")])

      issue = %Issue{
        id: "1",
        identifier: "UDPE-1",
        labels: ["a"],
        children: [%{id: "2", identifier: "UDPE-2", state: "Todo", labels: []}]
      }

      assert {:violations, list} = Cardinality.check(issue, config)
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
      config = config_with_repos([repo("a", "repo:a")])

      issue = %Issue{
        id: "1",
        identifier: "UDPE-1",
        labels: ["a"],
        attachment_urls: [
          "https://github.com/x/y/pull/1",
          "https://github.com/x/y/pull/2"
        ]
      }

      assert {:violations, list} = Cardinality.check(issue, config)
      assert :multiple_prs in list
    end

    test "ignores labels that don't match any configured repo" do
      config = config_with_repos([repo("udp", "repo:dashboard-v2")])

      issue = %Issue{
        id: "1",
        identifier: "UDPE-1",
        labels: ["frontend", "backend", "chore"],
        children: [%{id: "2", identifier: "UDPE-2", state: "Todo", labels: []}]
      }

      # No configured-repo label is set on this parent, so no violation
      # — even though it has unrelated labels.
      assert Cardinality.check(issue, config) == :ok
    end
  end

  describe "cutover" do
    test "issues created before cutover are not enforced" do
      config =
        config_with_cutover_and_repos(~D[2026-06-01], [repo("a", "repo:a"), repo("b", "repo:b")])

      issue = %Issue{
        id: "1",
        identifier: "UDPE-1",
        labels: ["a", "b"],
        created_at: ~U[2026-05-15 12:00:00Z]
      }

      assert Cardinality.check(issue, config) == {:not_enforced, :pre_cutover}
    end

    test "issues created on/after cutover are enforced" do
      config =
        config_with_cutover_and_repos(~D[2026-06-01], [repo("a", "repo:a"), repo("b", "repo:b")])

      issue = %Issue{
        id: "1",
        identifier: "UDPE-1",
        labels: ["a", "b"],
        created_at: ~U[2026-06-15 12:00:00Z]
      }

      assert {:violations, list} = Cardinality.check(issue, config)
      assert :multiple_repo_labels in list
    end
  end

  describe "check/2 with config maps that omit cardinality defaults" do
    test "checks a config without a cardinality_enforced_from default" do
      issue = %Issue{id: "1", identifier: "UDPE-1", labels: []}
      assert Cardinality.check(issue, %{repos: []}) == :ok
    end

    test "treats a config without a repos list as having no configured labels" do
      issue = %Issue{id: "1", identifier: "UDPE-1", labels: ["a"]}
      assert Cardinality.check(issue, %{}) == :ok
    end

    test "tolerates an issue whose labels field is not a list" do
      config = config_with_repos([repo("a", "repo:a")])
      issue = %Issue{id: "1", identifier: "UDPE-1", labels: nil, attachment_urls: []}
      assert Cardinality.check(issue, config) == :ok
    end

    test "does not enforce when a cutover is set but the issue has no created_at" do
      config = config_with_cutover_and_repos(~D[2026-06-01], [repo("a", "repo:a"), repo("b", "repo:b")])
      issue = %Issue{id: "1", identifier: "UDPE-1", labels: ["a", "b"], created_at: nil}

      assert {:violations, list} = Cardinality.check(issue, config)
      assert :multiple_repo_labels in list
    end
  end

  describe "pr_urls/1" do
    test "returns [] when attachment_urls is not a list" do
      assert Cardinality.pr_urls(%Issue{attachment_urls: nil}) == []
    end

    test "keeps only GitHub PR URLs and ignores non-binary entries" do
      issue = %Issue{
        attachment_urls: [123, "https://example.com/not-a-pr", "https://github.com/x/y/pull/7"]
      }

      assert Cardinality.pr_urls(issue) == ["https://github.com/x/y/pull/7"]
    end
  end

  describe "violation_comment/2" do
    test "includes the routing-warned marker for idempotency and explains each violation" do
      issue = %Issue{
        id: "1",
        identifier: "UDPE-1",
        labels: ["a", "b"]
      }

      body = Cardinality.violation_comment(issue, [:multiple_repo_labels])
      assert body =~ "symphony:routing-warned"
      assert body =~ "Multiple configured repo labels"
    end

    test "explains parent, multi-PR, and unknown violations" do
      issue = %Issue{
        id: "1",
        identifier: "UDPE-1",
        labels: ["a"],
        attachment_urls: ["https://github.com/x/y/pull/1", "https://github.com/x/y/pull/2"]
      }

      body =
        Cardinality.violation_comment(issue, [
          :parent_with_repo_label,
          :parent_with_pr,
          :multiple_prs,
          :some_future_violation
        ])

      assert body =~ "Parents must not be routed"
      assert body =~ "Parents must not have PRs"
      assert body =~ "Multiple PRs attached"
      assert body =~ "Unknown violation: :some_future_violation"
    end
  end
end
