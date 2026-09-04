defmodule SymphonyElixir.Config.AgentEfficiency do
  @moduledoc false

  @modes ~w(off shadow enforce)
  @enforceable_actions ~w(
    bound_future_tool_output
    fresh_thin_context_delegation_only
    prohibit_full_history_delegation
  )
  @reasoning_efforts ~w(none low medium high xhigh max)
  @task_types ~w(simple_direct ui security_tenant data_schema concurrency_liveness broad_architecture)

  # These starting points intentionally approximate recent fleet p50/p90 bands.
  # Repositories can tune them from their own rolling telemetry report.
  @default_profiles %{
    "simple" => %{
      total_tokens: 250_000,
      delegated_tokens: 75_000,
      per_thread_tokens: 150_000,
      per_turn_growth_tokens: 100_000,
      uncached_input_tokens: 125_000,
      cached_input_tokens: 500_000,
      tool_output_bytes: 250_000,
      elapsed_phase_ms: 900_000,
      review_packet_bytes: 32_000,
      reviewer_lenses: 2,
      review_iterations: 2,
      allow_overage: false,
      reviewer_model: nil,
      reviewer_reasoning_effort: "medium",
      review_lenses: ["correctness", "test_evidence"]
    },
    "standard" => %{
      total_tokens: 750_000,
      delegated_tokens: 300_000,
      per_thread_tokens: 300_000,
      per_turn_growth_tokens: 225_000,
      uncached_input_tokens: 350_000,
      cached_input_tokens: 1_500_000,
      tool_output_bytes: 750_000,
      elapsed_phase_ms: 1_800_000,
      review_packet_bytes: 48_000,
      reviewer_lenses: 4,
      review_iterations: 3,
      allow_overage: false,
      reviewer_model: nil,
      reviewer_reasoning_effort: nil,
      review_lenses: ["correctness", "regression", "test_evidence", "structure"]
    },
    "high_risk" => %{
      total_tokens: 1_500_000,
      delegated_tokens: 750_000,
      per_thread_tokens: 500_000,
      per_turn_growth_tokens: 350_000,
      uncached_input_tokens: 750_000,
      cached_input_tokens: 3_000_000,
      tool_output_bytes: 1_000_000,
      elapsed_phase_ms: 3_600_000,
      review_packet_bytes: 64_000,
      reviewer_lenses: 5,
      review_iterations: 5,
      allow_overage: true,
      reviewer_model: nil,
      reviewer_reasoning_effort: "high",
      review_lenses: ["correctness", "regression", "test_evidence", "security_tenant_auth", "structure"]
    }
  }

  @default_task_profiles %{
    "simple_direct" => "simple",
    "ui" => "standard",
    "security_tenant" => "high_risk",
    "data_schema" => "high_risk",
    "concurrency_liveness" => "high_risk",
    "broad_architecture" => "high_risk"
  }

  @type profile :: %{
          total_tokens: pos_integer(),
          delegated_tokens: pos_integer(),
          per_thread_tokens: pos_integer(),
          per_turn_growth_tokens: pos_integer(),
          uncached_input_tokens: pos_integer(),
          cached_input_tokens: pos_integer(),
          tool_output_bytes: pos_integer(),
          elapsed_phase_ms: pos_integer(),
          review_packet_bytes: pos_integer(),
          reviewer_lenses: pos_integer(),
          review_iterations: pos_integer(),
          allow_overage: boolean(),
          reviewer_model: String.t() | nil,
          reviewer_reasoning_effort: String.t() | nil,
          review_lenses: [String.t()]
        }

  @type t :: %{
          mode: String.t(),
          enforced_actions: [String.t()],
          capsule_max_bytes: pos_integer(),
          extreme_multiplier: float(),
          profiles: %{required(String.t()) => profile()},
          task_profiles: %{required(String.t()) => String.t()}
        }

  @spec parse(map()) :: {:ok, t()} | {:error, {:invalid_agent_efficiency, String.t()}}
  def parse(config) when is_map(config) do
    raw = config |> value("agent") |> value("efficiency")

    case raw do
      nil -> {:ok, defaults()}
      efficiency when is_map(efficiency) -> parse_efficiency(efficiency)
      _other -> error("agent.efficiency must be a map")
    end
  end

  @spec task_types() :: [String.t()]
  def task_types, do: @task_types

  defp defaults do
    %{
      mode: "shadow",
      enforced_actions: [],
      capsule_max_bytes: 4_000,
      extreme_multiplier: 2.0,
      profiles: @default_profiles,
      task_profiles: @default_task_profiles
    }
  end

  defp parse_efficiency(raw) do
    defaults = defaults()
    mode = value(raw, "mode") || defaults.mode

    with :ok <- validate_mode(mode),
         {:ok, enforced_actions} <- enforced_actions(raw, defaults.enforced_actions),
         {:ok, profiles} <- parse_profiles(value(raw, "profiles"), defaults.profiles),
         {:ok, task_profiles} <- parse_task_profiles(value(raw, "task_profiles"), defaults.task_profiles, profiles),
         {:ok, capsule_max_bytes} <- capsule_max_bytes(raw, defaults.capsule_max_bytes),
         {:ok, extreme_multiplier} <- multiplier(raw, defaults.extreme_multiplier) do
      {:ok,
       %{
         mode: mode,
         enforced_actions: enforced_actions,
         capsule_max_bytes: capsule_max_bytes,
         extreme_multiplier: extreme_multiplier,
         profiles: profiles,
         task_profiles: task_profiles
       }}
    end
  end

  defp validate_mode(mode) when mode in @modes, do: :ok
  defp validate_mode(_mode), do: error("agent.efficiency.mode must be one of: #{Enum.join(@modes, ", ")}")

  defp enforced_actions(map, default) do
    case value(map, "enforced_actions") do
      nil ->
        {:ok, default}

      actions when is_list(actions) ->
        normalized = Enum.map(actions, &normalize_action/1)

        if Enum.all?(normalized, &(&1 in @enforceable_actions)) do
          {:ok, Enum.uniq(normalized)}
        else
          error("agent.efficiency.enforced_actions must contain only: #{Enum.join(@enforceable_actions, ", ")}")
        end

      _other ->
        error("agent.efficiency.enforced_actions must be a list")
    end
  end

  defp normalize_action(action) when is_binary(action), do: String.trim(action)
  defp normalize_action(_action), do: nil

  defp parse_profiles(nil, defaults), do: {:ok, defaults}

  defp parse_profiles(profiles, defaults) when is_map(profiles) do
    Enum.reduce_while(profiles, {:ok, defaults}, fn {name, attrs}, {:ok, acc} ->
      profile_name = to_string(name)
      baseline = Map.get(defaults, profile_name, Map.fetch!(defaults, "standard"))

      case parse_profile(profile_name, attrs, baseline) do
        {:ok, profile} -> {:cont, {:ok, Map.put(acc, profile_name, profile)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_profiles(_profiles, _defaults), do: error("agent.efficiency.profiles must be a map")

  defp parse_profile(name, attrs, baseline) when is_map(attrs) and name != "" do
    integer_keys = [
      :total_tokens,
      :delegated_tokens,
      :per_thread_tokens,
      :per_turn_growth_tokens,
      :uncached_input_tokens,
      :cached_input_tokens,
      :tool_output_bytes,
      :elapsed_phase_ms,
      :review_packet_bytes,
      :reviewer_lenses,
      :review_iterations
    ]

    with {:ok, profile} <- parse_integer_fields(attrs, baseline, integer_keys),
         {:ok, allow_overage} <- optional_boolean(attrs, "allow_overage", baseline.allow_overage),
         {:ok, reviewer_model} <- optional_string(attrs, "reviewer_model", baseline.reviewer_model),
         {:ok, reviewer_effort} <- optional_effort(attrs, baseline.reviewer_reasoning_effort),
         {:ok, lenses} <- string_list(attrs, "review_lenses", baseline.review_lenses) do
      {:ok,
       profile
       |> Map.put(:allow_overage, allow_overage)
       |> Map.put(:reviewer_model, reviewer_model)
       |> Map.put(:reviewer_reasoning_effort, reviewer_effort)
       |> Map.put(:review_lenses, lenses)}
    end
  end

  defp parse_profile(name, _attrs, _baseline),
    do: error("agent.efficiency.profiles.#{name} must be a non-empty map")

  defp parse_integer_fields(attrs, baseline, keys) do
    Enum.reduce_while(keys, {:ok, baseline}, fn key, {:ok, profile} ->
      string_key = Atom.to_string(key)

      case positive_integer(attrs, string_key, Map.fetch!(baseline, key)) do
        {:ok, value} -> {:cont, {:ok, Map.put(profile, key, value)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_task_profiles(nil, defaults, _profiles), do: {:ok, defaults}

  defp parse_task_profiles(task_profiles, defaults, profiles) when is_map(task_profiles) do
    merged = Map.merge(defaults, Map.new(task_profiles, fn {key, value} -> {to_string(key), value} end))

    cond do
      Enum.any?(Map.keys(merged), &(&1 not in @task_types)) ->
        error("agent.efficiency.task_profiles contains an unsupported task type")

      Enum.any?(Map.values(merged), &(not is_binary(&1) or not Map.has_key?(profiles, &1))) ->
        error("agent.efficiency.task_profiles must reference configured budget profiles")

      true ->
        {:ok, merged}
    end
  end

  defp parse_task_profiles(_task_profiles, _defaults, _profiles),
    do: error("agent.efficiency.task_profiles must be a map")

  defp positive_integer(map, key, default) do
    case value(map, key) do
      nil -> {:ok, default}
      number when is_integer(number) and number > 0 -> {:ok, number}
      _other -> error("agent.efficiency.#{key} must be a positive integer")
    end
  end

  defp multiplier(map, default) do
    case value(map, "extreme_multiplier") do
      nil -> {:ok, default}
      number when is_number(number) and number >= 1.0 -> {:ok, number / 1}
      _other -> error("agent.efficiency.extreme_multiplier must be at least 1.0")
    end
  end

  defp capsule_max_bytes(map, default) do
    case value(map, "capsule_max_bytes") do
      nil -> {:ok, default}
      bytes when is_integer(bytes) and bytes >= 512 and bytes <= 65_536 -> {:ok, bytes}
      _other -> error("agent.efficiency.capsule_max_bytes must be between 512 and 65536")
    end
  end

  defp optional_boolean(map, key, default) do
    case value(map, key) do
      nil -> {:ok, default}
      value when is_boolean(value) -> {:ok, value}
      _other -> error("agent.efficiency.#{key} must be a boolean")
    end
  end

  defp optional_string(map, key, default) do
    case value(map, key) do
      nil -> {:ok, default}
      value when is_binary(value) -> {:ok, if(String.trim(value) == "", do: nil, else: String.trim(value))}
      _other -> error("agent.efficiency.#{key} must be a string or null")
    end
  end

  defp optional_effort(map, default) do
    with {:ok, effort} <- optional_string(map, "reviewer_reasoning_effort", default),
         true <- is_nil(effort) or effort in @reasoning_efforts do
      {:ok, effort}
    else
      false -> error("agent.efficiency.reviewer_reasoning_effort must be one of: #{Enum.join(@reasoning_efforts, ", ")}")
      {:error, _reason} = error -> error
    end
  end

  defp string_list(map, key, default) do
    case value(map, key) do
      nil ->
        {:ok, default}

      values when is_list(values) and values != [] ->
        if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
          {:ok, Enum.map(values, &String.trim/1) |> Enum.uniq()}
        else
          error("agent.efficiency.#{key} must contain non-blank strings")
        end

      _other ->
        error("agent.efficiency.#{key} must be a non-empty list")
    end
  end

  defp value(map, key) when is_map(map) and is_binary(key), do: Map.get(map, key)
  defp value(_other, _key), do: nil

  defp error(message), do: {:error, {:invalid_agent_efficiency, message}}
end
