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
          overlap_policy: advisory
          overlap_threshold: 0.75
          scheduling_override_label: symphony:force-overlap
          path_hints:
            area:auth:
              - lib/auth/**
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
                 overlap_policy: "advisory",
                 overlap_threshold: 0.75,
                 scheduling_override_label: "symphony:force-overlap",
                 path_hints: %{"area:auth" => ["lib/auth/**"]},
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

  describe "load/0 and load!/0 error and edge paths" do
    test "errors when the YAML root is not a map", %{path: path} do
      File.write!(path, "- just\n- a\n- list\n")
      assert {:error, {:repo_config_invalid, ^path, :not_a_map}} = RepoConfig.load()
    end

    test "errors with :unreadable when the config path is unreadable (a directory)", %{path: path} do
      File.rm_rf(path)
      File.mkdir_p!(path)

      assert {:error, {:repo_config_unreadable, ^path, _reason}} = RepoConfig.load()
    end

    test "errors on an invalid cardinality_enforced_from date string", %{path: path} do
      File.write!(path, """
      defaults:
        cardinality_enforced_from: "not-a-date"
      """)

      assert {:error, {:repo_config_invalid, ^path, {:invalid_defaults_cardinality_enforced_from, _, _}}} =
               RepoConfig.load()
    end

    test "errors on a non-string cardinality_enforced_from value", %{path: path} do
      File.write!(path, """
      defaults:
        cardinality_enforced_from: 123
      """)

      assert {:error, {:repo_config_invalid, ^path, {:invalid_defaults_cardinality_enforced_from, _, _}}} =
               RepoConfig.load()
    end

    test "accepts an empty cardinality_enforced_from as no cutover", %{path: path} do
      File.write!(path, """
      defaults:
        cardinality_enforced_from: ""
      """)

      assert {:ok, config} = RepoConfig.load()
      assert config.defaults.cardinality_enforced_from == nil
    end

    test "errors when repos is not a list", %{path: path} do
      File.write!(path, """
      repos:
        not: a-list
      """)

      assert {:error, {:repo_config_invalid, ^path, :repos_not_a_list}} = RepoConfig.load()
    end

    test "errors when a repo entry is not a map", %{path: path} do
      File.write!(path, """
      repos:
        - just-a-string
      """)

      assert {:error, {:repo_config_invalid, ^path, {:invalid_repo_entry, 0}}} = RepoConfig.load()
    end

    test "errors when a repo id is not a string", %{path: path} do
      File.write!(path, """
      repos:
        - id: 123
          label: repo:foo
      """)

      assert {:error, {:repo_config_invalid, ^path, {:invalid_repo_entry, 0}}} = RepoConfig.load()
    end

    test "defaults repo_url to nil when absent", %{path: path} do
      File.write!(path, """
      repos:
        - id: udp
          label: repo:foo
      """)

      assert {:ok, config} = RepoConfig.load()
      assert [%{id: "udp", repo_url: nil}] = config.repos
    end

    test "load!/0 returns the config on success", %{path: path} do
      File.write!(path, """
      linear:
        team_id: UDPE
      """)

      assert %{linear: %{team_id: "UDPE"}} = RepoConfig.load!()
    end

    test "load!/0 raises on an unreadable config", %{path: path} do
      File.rm_rf(path)
      File.mkdir_p!(path)

      assert_raise ArgumentError, fn -> RepoConfig.load!() end
    end
  end

  describe "load_yaml/0" do
    test "returns {:error, :not_a_map} when the YAML root is not a map", %{path: path} do
      File.write!(path, "- a\n- b\n")
      assert {:error, {:repo_config_invalid, ^path, :not_a_map}} = RepoConfig.load_yaml()
    end

    test "returns an invalid error on malformed YAML", %{path: path} do
      File.write!(path, "::not-yaml::\n  ---\nbroken")
      assert {:error, {:repo_config_invalid, ^path, _reason}} = RepoConfig.load_yaml()
    end

    test "returns :unreadable when the path is a directory", %{path: path} do
      File.rm_rf(path)
      File.mkdir_p!(path)
      assert {:error, {:repo_config_unreadable, ^path, _reason}} = RepoConfig.load_yaml()
    end
  end

  describe "resolve_config_path/2" do
    test "prefers config.yml, then repos.yaml, then defaults to config.yml" do
      dir = Path.join(System.tmp_dir!(), "symphony-home-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      config_path = Path.join(dir, "config.yml")
      legacy_path = Path.join(dir, "repos.yaml")

      # Neither present -> defaults to config.yml.
      assert RepoConfig.resolve_config_path(config_path, legacy_path) == config_path

      # Only legacy present -> repos.yaml.
      File.write!(legacy_path, "linear:\n  team_id: UDPE\n")
      assert RepoConfig.resolve_config_path(config_path, legacy_path) == legacy_path

      # config.yml present -> preferred over legacy.
      File.write!(config_path, "linear:\n  team_id: UDPE\n")
      assert RepoConfig.resolve_config_path(config_path, legacy_path) == config_path
    end
  end

  describe "host_config?/1" do
    test "true when a host-level config block is present" do
      assert RepoConfig.host_config?(%{"tracker" => %{}}) == true
    end

    test "false for a non-map or a repos-only map" do
      assert RepoConfig.host_config?(nil) == false
      assert RepoConfig.host_config?(%{"repos" => []}) == false
    end
  end

  describe "match_repo/2 and fuzzy_suggestions/2 fallbacks" do
    test "match_repo returns nil for a config without a repos list" do
      assert RepoConfig.match_repo(%{}, ["repo:foo"]) == nil
    end

    test "match_repo tolerates non-binary labels on the issue" do
      config = %{RepoConfig.empty() | repos: [%{label: "repo:foo"}]}
      assert RepoConfig.match_repo(config, [123, "repo:foo"]) == %{label: "repo:foo"}
    end

    test "fuzzy_suggestions returns [] when observed_labels is not a list" do
      assert RepoConfig.fuzzy_suggestions(%{repos: []}, :not_a_list) == []
    end

    test "fuzzy_suggestions tolerates a non-binary configured label" do
      config = %{RepoConfig.empty() | repos: [%{label: 123}]}
      assert RepoConfig.fuzzy_suggestions(config, ["repo:x"]) == [123]
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
