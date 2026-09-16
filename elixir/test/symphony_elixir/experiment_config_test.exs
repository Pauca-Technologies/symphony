defmodule SymphonyElixir.ExperimentConfigTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.{Experiment, Schema}

  setup do
    previous = Application.get_env(:symphony_elixir, :repo_config_path)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :repo_config_path, previous),
        else: Application.delete_env(:symphony_elixir, :repo_config_path)
    end)

    :ok
  end

  test "parses one strict bounded manifest deterministically" do
    assert {:ok, manifest} = Experiment.parse(config())
    assert manifest.schema_version == 1
    assert manifest.id == "effort-ablation"
    assert manifest.revision == 3
    assert manifest.backend == :codex
    assert manifest.variable == :reasoning_effort
    assert manifest.repositories == ["symphony", "udp"]
    assert manifest.task_families == ["concurrency_liveness", "simple_direct"]
    assert manifest.control == arm("control", :control, 2, "xhigh")
    assert Enum.map(manifest.variants, & &1.id) == ["low", "medium"]
    assert String.match?(manifest.manifest_digest, ~r/\A[0-9a-f]{64}\z/)

    reordered =
      config()
      |> put_in(["agent", "experiment", "repositories"], ["udp", "symphony"])
      |> put_in(["agent", "experiment", "task_families"], ["simple_direct", "concurrency_liveness"])
      |> update_in(["agent", "experiment", "variants"], &Enum.reverse/1)

    assert {:ok, %{manifest_digest: digest}} = Experiment.parse(reordered)
    assert digest == manifest.manifest_digest
    assert {:ok, ^manifest} = Config.experiment_settings(%{config: config()})
  end

  test "absence is disabled while malformed workflow containers fail clearly" do
    assert {:ok, nil} = Experiment.parse(%{})
    assert {:ok, nil} = Experiment.parse(%{agent: %{}})
    assert {:ok, nil} = Config.experiment_settings(nil)

    assert {:error, {:invalid_agent_experiment, _}} = Experiment.parse(%{"agent" => "bad"})

    assert {:error, {:invalid_agent_experiment, _}} =
             Config.experiment_settings(%{config: "bad"})

    assert {:error, {:invalid_agent_experiment, _}} =
             Experiment.parse(%{"agent" => %{"experiment" => "bad"}})
  end

  test "rejects unknown, missing, duplicate, unsafe, and unbounded manifest values" do
    invalid = [
      update_manifest(&Map.put(&1, "unknown", true)),
      update_manifest(&Map.delete(&1, "id")),
      update_manifest(&Map.put(&1, :id, &1["id"])),
      update_manifest(&Map.put(&1, "schema_version", 2)),
      update_manifest(&Map.put(&1, "id", "Prompt\nInjection")),
      update_manifest(&Map.put(&1, "id", nil)),
      update_manifest(&Map.put(&1, "revision", 0)),
      update_manifest(&Map.put(&1, "opt_in_label", "experiment bad")),
      update_manifest(&Map.put(&1, "opt_in_label", 42)),
      update_manifest(&Map.put(&1, "backend", "acp")),
      update_manifest(&Map.put(&1, "variable", "model")),
      update_manifest(&Map.put(&1, "repositories", [])),
      update_manifest(&Map.put(&1, "repositories", List.duplicate("repo", 9))),
      update_manifest(&Map.put(&1, "repositories", ["repo", "repo"])),
      update_manifest(&Map.put(&1, "repositories", ["repo/unsafe"])),
      update_manifest(&Map.put(&1, "task_families", [])),
      update_manifest(&Map.put(&1, "task_families", ["unknown"])),
      update_manifest(&Map.put(&1, "task_families", ["ui", "ui"])),
      update_manifest(&Map.put(&1, "variants", [])),
      update_manifest(&Map.put(&1, "variants", List.duplicate(variant("v", 1, "low"), 4)))
    ]

    Enum.each(invalid, fn raw ->
      assert {:error, {:invalid_agent_experiment, message}} = Experiment.parse(raw)
      assert is_binary(message) and byte_size(message) < 200
    end)
  end

  test "requires one unique control and one to three unique bounded variants" do
    invalid = [
      update_control(&Map.put(&1, "id", "baseline")),
      update_control(&Map.put(&1, "weight", 0)),
      update_control(&Map.put(&1, "value", "ultra")),
      update_control(&Map.put(&1, "extra", "raw")),
      update_manifest(&Map.put(&1, "control", "bad")),
      update_variants(fn variants -> [Map.put(hd(variants), "id", "control") | tl(variants)] end),
      update_variants(fn variants -> [Map.put(hd(variants), "value", "xhigh") | tl(variants)] end),
      update_variants(fn variants -> [Map.put(hd(variants), "weight", 999) | tl(variants)] end),
      update_variants(fn variants -> [Map.put(hd(variants), "id", "bad id") | tl(variants)] end),
      update_variants(fn variants -> [Map.delete(hd(variants), "value") | tl(variants)] end),
      update_variants(fn variants -> ["bad" | tl(variants)] end)
    ]

    Enum.each(invalid, fn raw ->
      assert {:error, {:invalid_agent_experiment, _}} = Experiment.parse(raw)
    end)
  end

  test "host experiment mode defaults and fails closed through Config and Schema" do
    assert {:ok, defaults} = Schema.parse(%{})
    assert defaults.agent.experiment_mode == "off"
    assert {:ok, apply} = Schema.parse(%{"agent" => %{"experiment_mode" => "apply"}})
    assert apply.agent.experiment_mode == "apply"
    assert {:error, {:invalid_workflow_config, _}} = Schema.parse(%{"agent" => %{"experiment_mode" => "on"}})

    path = temp_config("agent:\n  experiment_mode: apply\n")
    Application.put_env(:symphony_elixir, :repo_config_path, path)
    assert Config.experiment_mode() == :apply

    File.write!(path, "agent:\n  experiment_mode: invalid\n")
    assert Config.experiment_mode() == :off

    File.write!(path, "agent: [malformed")
    assert Config.experiment_mode() == :off
  end

  defp config do
    %{
      "agent" => %{
        "experiment" => %{
          "schema_version" => 1,
          "id" => "effort-ablation",
          "revision" => 3,
          "opt_in_label" => "experiment:effort-ablation",
          "backend" => "codex",
          "repositories" => ["symphony", "udp"],
          "task_families" => ["simple_direct", "concurrency_liveness"],
          "variable" => "reasoning_effort",
          "control" => %{"id" => "control", "weight" => 2, "value" => "xhigh"},
          "variants" => [variant("medium", 3, "medium"), variant("low", 1, "low")]
        }
      }
    }
  end

  defp variant(id, weight, value), do: %{"id" => id, "weight" => weight, "value" => value}

  defp arm(id, role, weight, value) do
    %{id: id, role: role, weight: weight, value: value, config_digest: digest([id, to_string(role), weight, value])}
  end

  defp digest(value), do: :crypto.hash(:sha256, Jason.encode!(value)) |> Base.encode16(case: :lower)
  defp update_manifest(fun), do: update_in(config(), ["agent", "experiment"], fun)
  defp update_control(fun), do: update_in(config(), ["agent", "experiment", "control"], fun)
  defp update_variants(fun), do: update_in(config(), ["agent", "experiment", "variants"], fun)

  defp temp_config(contents) do
    path = Path.join(System.tmp_dir!(), "experiment-host-#{System.unique_integer([:positive])}.yml")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
