defmodule SymphonyElixir.RepoConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RepoConfig

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "symphony-repo-config-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    path = Path.join(tmp_dir, "repos.yaml")
    Application.put_env(:symphony_elixir, :repo_config_path, path)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :repo_config_path)
      File.rm_rf(tmp_dir)
    end)

    %{path: path}
  end

  describe "load/0" do
    test "returns empty default config when file is absent", %{path: path} do
      File.rm(path)

      assert {:ok, config} = RepoConfig.load()
      assert config.source == :default
      assert config.repos == []
      assert config.linear.team_id == nil
      assert config.linear.filter_label == nil
      assert config.defaults.cardinality_enforced_from == nil
    end

    test "parses a fully-populated repos.yaml", %{path: path} do
      File.write!(path, """
      defaults:
        max_concurrent_global: 6
        workspace_root: /tmp/symphony_workspaces
        poll_interval_seconds: 30
        cardinality_enforced_from: "2026-06-01"
      linear:
        team_id: udp-team-uuid
        filter_label: udpagent
      repos:
        - id: udp-dashboard-v2
          label: repo:dashboard-v2
          repo_url: git@github.com:Pauca-Technologies/udp-dashboard-v2.git
          workflow_path: WORKFLOW.md
          max_concurrent: 3
      """)

      assert {:ok, config} = RepoConfig.load()
      assert config.source == :file
      assert config.linear.team_id == "udp-team-uuid"
      assert config.linear.filter_label == "udpagent"
      assert config.defaults.cardinality_enforced_from == ~D[2026-06-01]
      assert config.defaults.max_concurrent_global == 6
      assert config.defaults.poll_interval_seconds == 30

      assert [
               %{
                 id: "udp-dashboard-v2",
                 label: "repo:dashboard-v2",
                 max_concurrent: 3,
                 workflow_path: "WORKFLOW.md"
               }
             ] = config.repos
    end

    test "filter_label is optional and defaults to nil", %{path: path} do
      File.write!(path, """
      linear:
        team_id: UDPE
      """)

      assert {:ok, config} = RepoConfig.load()
      assert config.linear.team_id == "UDPE"
      assert config.linear.filter_label == nil
    end

    test "errors on malformed YAML", %{path: path} do
      File.write!(path, "::not-yaml::\n  ---\nbroken")
      assert {:error, {:repo_config_invalid, ^path, _}} = RepoConfig.load()
    end

    test "errors when a repo entry is missing id", %{path: path} do
      File.write!(path, """
      repos:
        - label: repo:foo
      """)

      assert {:error, {:repo_config_invalid, ^path, {:repo_entry_missing_field, 0, :id}}} =
               RepoConfig.load()
    end
  end

  describe "match_repo/2" do
    test "finds an exact repo-label match" do
      config = %{
        RepoConfig.empty()
        | source: :file,
          repos: [
            %{
              id: "udp-dashboard-v2",
              label: "repo:dashboard-v2",
              repo_url: nil,
              workflow_path: "WORKFLOW.md",
              max_concurrent: 3
            }
          ]
      }

      assert %{id: "udp-dashboard-v2"} =
               RepoConfig.match_repo(config, ["bug", "repo:dashboard-v2"])

      assert RepoConfig.match_repo(config, ["bug"]) == nil
    end

    test "match is case-insensitive on the label" do
      config = %{
        RepoConfig.empty()
        | source: :file,
          repos: [
            %{
              id: "x",
              label: "Repo:Foo",
              repo_url: nil,
              workflow_path: "WORKFLOW.md",
              max_concurrent: 1
            }
          ]
      }

      assert %{id: "x"} = RepoConfig.match_repo(config, ["repo:foo"])
    end
  end

  describe "fuzzy_suggestions/2" do
    test "ranks configured labels by jaro distance to the first observed repo: label" do
      config = %{
        RepoConfig.empty()
        | source: :file,
          repos: [
            %{
              id: "udp",
              label: "repo:dashboard-v2",
              repo_url: nil,
              workflow_path: "WORKFLOW.md",
              max_concurrent: 1
            },
            %{
              id: "api",
              label: "repo:api",
              repo_url: nil,
              workflow_path: "WORKFLOW.md",
              max_concurrent: 1
            }
          ]
      }

      ordered = RepoConfig.fuzzy_suggestions(config, ["repo:dashbord-v2"])
      assert hd(ordered) == "repo:dashboard-v2"
    end
  end
end
