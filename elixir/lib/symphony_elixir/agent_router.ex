defmodule SymphonyElixir.AgentRouter do
  @moduledoc """
  Resolves the backend execution profile for an issue.

  Existing host-level label presets remain the highest-precedence override.
  Repository profile labels come next, followed by the repository's classifier.
  Classifier failures and high-risk classifications use the configured quality
  fallback profile.
  """

  require Logger

  alias SymphonyElixir.{AgentBackend, AgentClassifier, Config}
  alias SymphonyElixir.Linear.Issue

  @type selection :: %{
          backend: module(),
          overrides: map(),
          profile: String.t() | nil,
          source: atom()
        }

  @spec resolve(Path.t(), Issue.t(), map() | nil, String.t() | nil, keyword()) ::
          {:ok, selection()} | {:error, term()}
  def resolve(workspace, %Issue{} = issue, repo_workflow, worker_host, opts \\ []) do
    with {:ok, routing} <- Config.agent_routing_settings(repo_workflow) do
      resolve_with_settings(workspace, issue, routing, worker_host, opts)
    end
  end

  defp resolve_with_settings(_workspace, issue, nil, _worker_host, _opts) do
    {:ok, legacy_selection(issue)}
  end

  defp resolve_with_settings(workspace, issue, %{} = routing, worker_host, opts) do
    preset_resolver = Keyword.get(opts, :preset_resolver, &AgentBackend.resolve_preset_for_issue/1)

    case preset_resolver.(issue) do
      {backend, overrides} ->
        {:ok, %{backend: backend, overrides: overrides, profile: nil, source: :label_preset}}

      nil ->
        resolve_repo_profile(workspace, issue, routing, worker_host, opts)
    end
  end

  defp resolve_repo_profile(workspace, issue, routing, worker_host, opts) do
    case explicitly_labeled_profiles(issue, routing) do
      [profile_name] ->
        {:ok, selection(routing, profile_name, :profile_label)}

      [] ->
        classify(workspace, issue, routing, worker_host, opts)

      profile_names ->
        Logger.warning("Ambiguous agent profile labels; using quality fallback for #{issue_context(issue)} profiles=#{Enum.join(profile_names, ",")}")

        {:ok, selection(routing, routing.fallback_profile, :ambiguous_profile_labels)}
    end
  end

  defp classify(workspace, issue, routing, worker_host, opts) do
    classifier = Keyword.get(opts, :classifier, &AgentClassifier.classify/5)
    classifier_opts = Keyword.take(opts, [:issue_context_file, :app_server])

    case classifier.(workspace, issue, routing, worker_host, classifier_opts) do
      {:ok, result} ->
        profile_name = quality_profile(result, routing)

        Logger.info(
          "Selected agent profile for #{issue_context(issue)} profile=#{profile_name} classifier_profile=#{result.profile} risk=#{result.risk} complexity=#{result.complexity} ambiguity=#{result.ambiguity}"
        )

        {:ok, selection(routing, profile_name, :classifier)}

      {:error, reason} ->
        Logger.warning("Agent profile classifier failed; using quality fallback for #{issue_context(issue)} profile=#{routing.fallback_profile} reason=#{inspect(reason)}")

        {:ok, selection(routing, routing.fallback_profile, :classifier_fallback)}
    end
  end

  defp quality_profile(result, routing) do
    if "high" in [result.risk, result.complexity, result.ambiguity] do
      routing.fallback_profile
    else
      result.profile
    end
  end

  defp explicitly_labeled_profiles(%Issue{labels: labels}, routing) when is_list(labels) do
    routing.profiles
    |> Map.keys()
    |> Enum.filter(&("agent:#{&1}" in labels))
    |> Enum.sort()
  end

  defp selection(routing, profile_name, source) do
    profile = Map.fetch!(routing.profiles, profile_name)

    %{
      backend: AgentBackend.resolve(profile.backend),
      overrides: %{
        model: profile.model,
        reasoning_effort: profile.reasoning_effort
      },
      profile: profile_name,
      source: source
    }
  end

  defp legacy_selection(issue) do
    {backend, overrides} = AgentBackend.resolve_for_issue(issue)
    %{backend: backend, overrides: overrides, profile: nil, source: :legacy}
  end

  defp issue_context(%Issue{} = issue) do
    "issue_id=#{issue.id} issue_identifier=#{issue.identifier}"
  end
end
