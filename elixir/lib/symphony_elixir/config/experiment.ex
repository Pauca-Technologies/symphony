defmodule SymphonyElixir.Config.Experiment do
  @moduledoc "Strict parser for one repository-owned reasoning-effort experiment."

  @schema_version 1
  @max_revision 1_000_000
  @max_repositories 8
  @max_variants 3
  @max_weight 1_000
  @task_families ~w(simple_direct ui security_tenant data_schema concurrency_liveness broad_architecture)
  @reasoning_efforts ~w(none low medium high xhigh max)
  @manifest_keys ~w(schema_version id revision opt_in_label backend repositories task_families variable control variants)
  @arm_keys ~w(id weight value)

  @type arm :: %{
          id: String.t(),
          role: :control | :variant,
          weight: pos_integer(),
          value: String.t(),
          config_digest: String.t()
        }

  @type t :: %{
          schema_version: 1,
          id: String.t(),
          revision: pos_integer(),
          opt_in_label: String.t(),
          backend: :codex,
          repositories: [String.t()],
          task_families: [String.t()],
          variable: :reasoning_effort,
          control: arm(),
          variants: [arm()],
          manifest_digest: String.t()
        }

  @doc "Parse the optional strict `agent.experiment` manifest."
  @spec parse(map()) :: {:ok, t() | nil} | {:error, {:invalid_agent_experiment, String.t()}}
  def parse(config) when is_map(config) do
    with {:ok, agent} <- optional_map(value(config, "agent"), "agent") do
      case value(agent, "experiment") do
        nil -> {:ok, nil}
        raw when is_map(raw) -> parse_manifest(raw)
        _invalid -> error("agent.experiment must be a map")
      end
    end
  end

  defp parse_manifest(raw) do
    with {:ok, manifest} <- stringify_map(raw, @manifest_keys, "agent.experiment"),
         :ok <- exact_keys(manifest, @manifest_keys, "agent.experiment"),
         :ok <- equals(manifest["schema_version"], @schema_version, "schema_version must be 1"),
         {:ok, id} <- safe_id(manifest["id"], 64, "id"),
         {:ok, revision} <- bounded_integer(manifest["revision"], 1, @max_revision, "revision"),
         {:ok, label} <- safe_label(manifest["opt_in_label"]),
         :ok <- equals(manifest["backend"], "codex", "backend must be codex"),
         :ok <- equals(manifest["variable"], "reasoning_effort", "variable must be reasoning_effort"),
         {:ok, repositories} <- member_list(manifest["repositories"], :repository),
         {:ok, task_families} <- member_list(manifest["task_families"], :task_family),
         {:ok, control} <- parse_arm(manifest["control"], :control),
         {:ok, variants} <- parse_variants(manifest["variants"]),
         :ok <- validate_arms(control, variants) do
      core = %{
        schema_version: @schema_version,
        id: id,
        revision: revision,
        opt_in_label: label,
        backend: :codex,
        repositories: repositories,
        task_families: task_families,
        variable: :reasoning_effort,
        control: control,
        variants: variants
      }

      {:ok, Map.put(core, :manifest_digest, manifest_digest(core))}
    end
  end

  defp parse_variants(variants) when is_list(variants) and length(variants) in 1..@max_variants do
    variants
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, parsed} ->
      case parse_arm(raw, :variant) do
        {:ok, arm} -> {:cont, {:ok, [arm | parsed]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.sort_by(parsed, & &1.id)}
      error -> error
    end
  end

  defp parse_variants(_variants), do: error("variants must contain one to three arms")

  defp parse_arm(raw, role) when is_map(raw) do
    prefix = if role == :control, do: "control", else: "variant"

    with {:ok, arm} <- stringify_map(raw, @arm_keys, prefix),
         :ok <- exact_keys(arm, @arm_keys, prefix),
         {:ok, id} <- safe_id(arm["id"], 32, "#{prefix}.id"),
         {:ok, weight} <- bounded_integer(arm["weight"], 1, @max_weight, "#{prefix}.weight"),
         {:ok, effort} <- member(arm["value"], @reasoning_efforts, "#{prefix}.value") do
      parsed = %{id: id, role: role, weight: weight, value: effort}
      {:ok, Map.put(parsed, :config_digest, digest([id, Atom.to_string(role), weight, effort]))}
    end
  end

  defp parse_arm(_raw, role), do: error("#{role} must be a map")

  defp validate_arms(control, variants) do
    arms = [control | variants]
    ids = Enum.map(arms, & &1.id)
    values = Enum.map(arms, & &1.value)
    total_weight = Enum.sum(Enum.map(arms, & &1.weight))

    cond do
      control.id != "control" -> error_value("control.id must be control")
      length(Enum.uniq(ids)) != length(ids) -> error_value("arm ids must be unique")
      length(Enum.uniq(values)) != length(values) -> error_value("arm values must be unique")
      total_weight > @max_weight -> error_value("total arm weight must not exceed #{@max_weight}")
      true -> :ok
    end
  end

  defp member_list(values, :repository) when is_list(values) and length(values) in 1..@max_repositories do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case safe_id(value, 64, "repositories") do
        {:ok, id} -> {:cont, {:ok, [id | acc]}}
        error -> {:halt, error}
      end
    end)
    |> unique_sorted("repositories")
  end

  defp member_list(values, :task_family)
       when is_list(values) and values != [] and length(values) <= 6 do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case member(value, @task_families, "task_families") do
        {:ok, task_family} -> {:cont, {:ok, [task_family | acc]}}
        error -> {:halt, error}
      end
    end)
    |> unique_sorted("task_families")
  end

  defp member_list(_values, field), do: error("#{field} list is missing or exceeds its cap")

  defp unique_sorted({:ok, values}, field) do
    if length(Enum.uniq(values)) == length(values),
      do: {:ok, Enum.sort(values)},
      else: error("#{field} values must be unique")
  end

  defp unique_sorted(error, _field), do: error

  defp safe_id(value, max_bytes, field) when is_binary(value) and byte_size(value) <= max_bytes do
    if Regex.match?(~r/\A[a-z0-9][a-z0-9._-]*\z/, value), do: {:ok, value}, else: error("#{field} is invalid")
  end

  defp safe_id(_value, _max_bytes, field), do: error("#{field} is invalid")

  defp safe_label(value) when is_binary(value) and byte_size(value) <= 128 do
    if Regex.match?(~r/\A[a-z0-9][a-z0-9:._-]*\z/, value), do: {:ok, value}, else: error("opt_in_label is invalid")
  end

  defp safe_label(_value), do: error("opt_in_label is invalid")

  defp bounded_integer(value, minimum, maximum, _field)
       when is_integer(value) and value >= minimum and value <= maximum,
       do: {:ok, value}

  defp bounded_integer(_value, _minimum, _maximum, field), do: error("#{field} is out of bounds")

  defp member(value, values, field) do
    if value in values, do: {:ok, value}, else: error("#{field} is invalid")
  end

  defp optional_map(nil, _field), do: {:ok, %{}}
  defp optional_map(value, _field) when is_map(value), do: {:ok, value}
  defp optional_map(_value, field), do: error("#{field} must be a map")

  defp exact_keys(map, expected, field) do
    if Map.keys(map) |> Enum.sort() == Enum.sort(expected), do: :ok, else: error_value("#{field} has invalid fields")
  end

  defp equals(value, value, _message), do: :ok
  defp equals(_actual, _expected, message), do: error_value(message)

  defp stringify_map(map, allowed, field) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key

      cond do
        not is_binary(key) or key not in allowed -> {:halt, error("#{field} has invalid fields")}
        Map.has_key?(acc, key) -> {:halt, error("#{field} has duplicate fields")}
        true -> {:cont, {:ok, Map.put(acc, key, value)}}
      end
    end)
  end

  defp manifest_digest(core) do
    arms = Enum.map([core.control | core.variants], &[&1.id, &1.role, &1.weight, &1.value])

    digest([
      core.schema_version,
      core.id,
      core.revision,
      core.opt_in_label,
      core.backend,
      core.repositories,
      core.task_families,
      core.variable,
      arms
    ])
  end

  defp digest(value), do: :crypto.hash(:sha256, Jason.encode!(value)) |> Base.encode16(case: :lower)
  defp value(map, "agent") when is_map(map), do: Map.get(map, "agent", Map.get(map, :agent))

  defp value(map, "experiment") when is_map(map),
    do: Map.get(map, "experiment", Map.get(map, :experiment))

  defp error(message), do: {:error, {:invalid_agent_experiment, message}}
  defp error_value(message), do: error(message)
end
