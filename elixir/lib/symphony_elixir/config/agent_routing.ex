defmodule SymphonyElixir.Config.AgentRouting do
  @moduledoc false

  @reasoning_efforts ~w(none low medium high xhigh max)
  @supported_backend "codex"
  @default_classifier_timeout_ms 120_000

  @type classifier :: %{
          backend: String.t(),
          model: String.t(),
          reasoning_effort: String.t(),
          timeout_ms: pos_integer()
        }

  @type profile :: %{
          backend: String.t(),
          model: String.t(),
          reasoning_effort: String.t(),
          description: String.t()
        }

  @type t :: %{
          classifier: classifier(),
          default_profile: String.t(),
          fallback_profile: String.t(),
          profiles: %{required(String.t()) => profile()}
        }

  @spec parse(map()) :: {:ok, t() | nil} | {:error, {:invalid_agent_routing, String.t()}}
  def parse(config) when is_map(config) do
    case config |> value("agent") |> value("routing") do
      nil ->
        {:ok, nil}

      routing when is_map(routing) ->
        parse_routing(routing)

      _other ->
        error("agent.routing must be a map")
    end
  end

  defp parse_routing(routing) do
    with {:ok, classifier} <- parse_classifier(value(routing, "classifier")),
         {:ok, profiles} <- parse_profiles(value(routing, "profiles")),
         {:ok, default_profile} <- profile_reference(routing, "default_profile", profiles),
         {:ok, fallback_profile} <- fallback_profile(routing, default_profile, profiles) do
      {:ok,
       %{
         classifier: classifier,
         default_profile: default_profile,
         fallback_profile: fallback_profile,
         profiles: profiles
       }}
    end
  end

  defp parse_classifier(classifier) when is_map(classifier) do
    backend = value(classifier, "backend") || @supported_backend

    with :ok <- validate_backend(backend, "agent.routing.classifier"),
         {:ok, model} <- non_blank_string(classifier, "model", "agent.routing.classifier.model"),
         {:ok, effort} <- reasoning_effort(classifier, "agent.routing.classifier.reasoning_effort"),
         {:ok, timeout_ms} <- classifier_timeout(classifier) do
      {:ok,
       %{
         backend: backend,
         model: model,
         reasoning_effort: effort,
         timeout_ms: timeout_ms
       }}
    end
  end

  defp parse_classifier(_classifier),
    do: error("agent.routing.classifier must be a map")

  defp classifier_timeout(classifier) do
    case value(classifier, "timeout_ms") do
      nil -> {:ok, @default_classifier_timeout_ms}
      timeout when is_integer(timeout) and timeout > 0 -> {:ok, timeout}
      _other -> error("agent.routing.classifier.timeout_ms must be a positive integer")
    end
  end

  defp parse_profiles(profiles) when is_map(profiles) and map_size(profiles) > 0 do
    Enum.reduce_while(profiles, {:ok, %{}}, fn {name, attrs}, {:ok, parsed} ->
      profile_name = to_string(name)

      case parse_profile(profile_name, attrs) do
        {:ok, profile} -> {:cont, {:ok, Map.put(parsed, profile_name, profile)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_profiles(_profiles),
    do: error("agent.routing.profiles must be a non-empty map")

  defp parse_profile(name, attrs) when is_map(attrs) do
    prefix = "agent.routing.profiles.#{name}"
    backend = value(attrs, "backend") || @supported_backend

    with :ok <- validate_profile_name(name),
         :ok <- validate_backend(backend, prefix),
         {:ok, model} <- non_blank_string(attrs, "model", "#{prefix}.model"),
         {:ok, effort} <- reasoning_effort(attrs, "#{prefix}.reasoning_effort"),
         {:ok, description} <- non_blank_string(attrs, "description", "#{prefix}.description") do
      {:ok,
       %{
         backend: backend,
         model: model,
         reasoning_effort: effort,
         description: description
       }}
    end
  end

  defp parse_profile(name, _attrs),
    do: error("agent.routing.profiles.#{name} must be a map")

  defp validate_profile_name(name) do
    if String.trim(name) == "" do
      error("agent.routing profile names must not be blank")
    else
      :ok
    end
  end

  defp validate_backend(@supported_backend, _prefix), do: :ok

  defp validate_backend(backend, prefix),
    do: error("#{prefix}.backend must be codex, got: #{inspect(backend)}")

  defp profile_reference(routing, key, profiles) do
    with {:ok, profile_name} <- non_blank_string(routing, key, "agent.routing.#{key}"),
         true <- Map.has_key?(profiles, profile_name) do
      {:ok, profile_name}
    else
      false -> error("agent.routing.#{key} must name a configured profile")
      {:error, _reason} = error -> error
    end
  end

  defp fallback_profile(routing, default_profile, profiles) do
    case value(routing, "fallback_profile") do
      nil -> {:ok, default_profile}
      _configured -> profile_reference(routing, "fallback_profile", profiles)
    end
  end

  defp reasoning_effort(attrs, field_name) do
    case value(attrs, "reasoning_effort") do
      effort when effort in @reasoning_efforts -> {:ok, effort}
      _other -> error("#{field_name} must be one of: #{Enum.join(@reasoning_efforts, ", ")}")
    end
  end

  defp non_blank_string(attrs, key, field_name) do
    case value(attrs, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> error("#{field_name} must not be blank")
          trimmed -> {:ok, trimmed}
        end

      _other ->
        error("#{field_name} must be a string")
    end
  end

  defp value(map, key) when is_map(map) and is_binary(key), do: Map.get(map, key)

  defp value(_other, _key), do: nil

  defp error(message), do: {:error, {:invalid_agent_routing, message}}
end
