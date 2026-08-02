defmodule SymphonyElixir.RepositoryScheduler do
  @moduledoc """
  Deterministic repository-aware dispatch policy.

  Reservations are derived from the orchestrator's live `running` entries.
  They therefore disappear with terminal/stalled workers and cannot survive a
  process restart as stale scheduling leases.
  """

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RepoConfig

  @override_label "symphony:overlap-override"
  @path_regex ~r{(?:^|[\s`'"(])((?:[A-Za-z0-9_.-]+/)+[A-Za-z0-9_.*/-]+)}
  @suggested_order_limit 20

  @type decision ::
          {:allow, map()}
          | {:queue, map()}

  @doc "Evaluate one candidate against live reservations in its repository."
  @spec decide(Issue.t(), map(), map()) :: decision()
  def decide(%Issue{} = issue, repo_config, running) when is_map(repo_config) and is_map(running) do
    case RepoConfig.match_repo(repo_config, issue.labels) do
      nil ->
        {:allow, base_decision(issue, nil, predicted_paths(issue, nil), "legacy_mode")}

      repo ->
        decide_for_repo(issue, repo, running)
    end
  end

  defp decide_for_repo(issue, repo, running) do
    paths = predicted_paths(issue, repo)
    reservations = reservations_for_repo(running, repo.id)
    override? = override?(issue, repo)

    cond do
      length(reservations) >= Map.get(repo, :max_concurrent, 1) ->
        {:queue, queue_decision(issue, repo, paths, reservations, "repository_ceiling", [], 1.0, override?)}

      override? ->
        {:allow, base_decision(issue, repo, paths, "operator_override")}

      Map.get(repo, :overlap_policy, "serialize") != "serialize" ->
        {:allow, base_decision(issue, repo, paths, "advisory_policy")}

      true ->
        decide_overlap(issue, repo, paths, reservations)
    end
  end

  defp decide_overlap(issue, repo, paths, reservations) do
    threshold = Map.get(repo, :overlap_threshold, 0.5)

    case highest_overlap(paths, reservations) do
      {score, overlap_paths, reservation}
      when score >= threshold and overlap_paths != [] ->
        {:queue, queue_decision(issue, repo, paths, [reservation], "path_overlap", overlap_paths, score, false)}

      _disjoint_or_unknown ->
        {:allow, base_decision(issue, repo, paths, "disjoint_or_unknown")}
    end
  end

  @doc "Return progressively stronger predicted paths from issue metadata."
  @spec predicted_paths(Issue.t(), map() | nil) :: [String.t()]
  def predicted_paths(%Issue{labels: labels}, repo) when is_list(labels) do
    direct =
      Enum.flat_map(labels, fn
        "path:" <> path -> [path]
        _label -> []
      end)

    hinted =
      Enum.flat_map(labels, fn label ->
        repo
        |> then(&if(is_map(&1), do: Map.get(&1, :path_hints, %{}), else: %{}))
        |> Map.get(String.downcase(label), [])
      end)

    normalize_paths(direct ++ hinted)
  end

  def predicted_paths(_issue, _repo), do: []

  @doc "Extract conservative path predictions from a backend plan update."
  @spec plan_paths(map()) :: [String.t()]
  def plan_paths(update) when is_map(update) do
    if plan_update?(update) do
      update
      |> plan_content()
      |> collect_strings()
      |> Enum.flat_map(fn text ->
        Regex.scan(@path_regex, text, capture: :all_but_first)
        |> List.flatten()
      end)
      |> normalize_paths()
    else
      []
    end
  end

  def plan_paths(_update), do: []

  @doc "Apply a plan prediction without replacing a stronger actual manifest."
  @spec observe_plan(map(), map()) :: map()
  def observe_plan(running_entry, update) when is_map(running_entry) and is_map(update) do
    paths = plan_paths(update)

    if paths != [] and Map.get(running_entry, :scheduling_path_source) != "actual" do
      running_entry
      |> Map.put(:scheduling_paths, paths)
      |> Map.put(:scheduling_path_source, "plan")
    else
      running_entry
    end
  end

  @doc "Compute symmetric overlap details for two path manifests."
  @spec overlap([String.t()], [String.t()]) ::
          %{score: float(), paths: [String.t()], omitted: non_neg_integer()}
  def overlap(left, right) when is_list(left) and is_list(right) do
    left = normalize_paths(left)
    right = normalize_paths(right)

    matches =
      for left_path <- left,
          right_path <- right,
          paths_overlap?(left_path, right_path),
          do: overlap_path(left_path, right_path)

    all_paths = matches |> Enum.uniq() |> Enum.sort()
    denominator = min(length(left), length(right))
    score = if denominator > 0, do: min(length(all_paths) / denominator, 1.0), else: 0.0
    %{score: score, paths: Enum.take(all_paths, 20), omitted: max(length(all_paths) - 20, 0)}
  end

  @doc "Normalize and bound paths used in scheduling snapshots and telemetry."
  @spec normalize_paths([term()]) :: [String.t()]
  def normalize_paths(paths) when is_list(paths) do
    paths
    |> Enum.flat_map(fn
      path when is_binary(path) -> [normalize_path(path)]
      _other -> []
    end)
    |> Enum.reject(&invalid_path?/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(200)
  end

  def normalize_paths(_paths), do: []

  defp reservations_for_repo(running, repository_id) do
    running
    |> Enum.flat_map(fn
      {_issue_id, %{repository_id: ^repository_id} = entry} -> [entry]
      _other -> []
    end)
    |> Enum.sort_by(fn entry ->
      issue = Map.get(entry, :issue, %{})
      {Map.get(issue, :priority) || 5, created_at_key(Map.get(issue, :created_at)), Map.get(entry, :identifier, "")}
    end)
  end

  defp highest_overlap(paths, reservations) do
    reservations
    |> Enum.map(fn reservation ->
      result = overlap(paths, Map.get(reservation, :scheduling_paths, []))
      {result.score, result.paths, reservation}
    end)
    |> Enum.max_by(
      fn {score, overlap_paths, reservation} ->
        {score, length(overlap_paths), invert_string(Map.get(reservation, :identifier, ""))}
      end,
      fn -> {0.0, [], nil} end
    )
  end

  defp queue_decision(issue, repo, paths, reservations, reason, overlap_paths, score, override?) do
    suggested_order =
      Enum.map(reservations, &(Map.get(&1, :identifier) || Map.get(&1, :issue_id))) ++
        [issue.identifier]

    base_decision(issue, repo, paths, reason)
    |> Map.merge(%{
      overlap_paths: overlap_paths,
      overlap_score: Float.round(score, 3),
      override: override?,
      base_age_seconds:
        reservations
        |> Enum.map(&Map.get(&1, :base_age_seconds))
        |> Enum.filter(&is_integer/1)
        |> Enum.max(fn -> nil end),
      suggested_order: Enum.take(suggested_order, @suggested_order_limit),
      suggested_order_omitted: max(length(suggested_order) - @suggested_order_limit, 0)
    })
  end

  defp base_decision(issue, repo, paths, reason) do
    %{
      issue_id: issue.id,
      identifier: issue.identifier,
      repository_id: repo && repo.id,
      reason: reason,
      predicted_paths: paths,
      overlap_paths: [],
      overlap_score: 0.0,
      suggested_order: [issue.identifier],
      suggested_order_omitted: 0,
      override: false,
      base_age_seconds: nil,
      policy: repo && Map.get(repo, :overlap_policy, "serialize"),
      max_concurrent: repo && Map.get(repo, :max_concurrent, 1)
    }
  end

  defp override?(%Issue{labels: labels}, repo) do
    override_label = Map.get(repo, :scheduling_override_label, @override_label)
    Enum.any?(labels, &(String.downcase(&1) == String.downcase(override_label)))
  end

  defp plan_update?(update) do
    event = string_value(update, :event)
    payload = flexible_value(update, :payload) || %{}
    method = string_value(payload, :method)
    session_update = payload |> flexible_value(:params) |> flexible_value(:update) |> flexible_value(:sessionUpdate)
    event in ["plan_updated", "turn_plan_updated"] or method == "turn/plan/updated" or session_update == "plan"
  end

  defp plan_content(update) do
    payload = flexible_value(update, :payload) || %{}
    params = flexible_value(payload, :params) || %{}
    details = flexible_value(update, :details) || %{}

    [
      flexible_value(params, :plan),
      params |> flexible_value(:update) |> flexible_value(:entries),
      flexible_value(details, :plan),
      flexible_value(update, :plan)
    ]
  end

  defp collect_strings(value) when is_binary(value), do: [value]
  defp collect_strings(value) when is_list(value), do: Enum.flat_map(value, &collect_strings/1)
  defp collect_strings(value) when is_map(value), do: value |> Map.values() |> Enum.flat_map(&collect_strings/1)
  defp collect_strings(_value), do: []

  defp normalize_path(path) do
    path
    |> String.trim(" \t\r\n`'\"(),:;")
    |> String.replace("\\", "/")
    |> String.trim_leading("./")
    |> String.trim_trailing("/")
  end

  defp invalid_path?(path) do
    path == "" or String.starts_with?(path, "/") or String.contains?(path, "..") or
      String.length(path) > 240
  end

  defp paths_overlap?(left, right) do
    wildcard_match?(left, right) or wildcard_match?(right, left) or
      left == right or String.starts_with?(left, right <> "/") or String.starts_with?(right, left <> "/")
  end

  defp wildcard_match?(pattern, path) do
    if String.contains?(pattern, "*") do
      regex = pattern |> Regex.escape() |> String.replace("\\*\\*", ".*") |> String.replace("\\*", "[^/]*")
      Regex.match?(Regex.compile!("^" <> regex <> "$"), path)
    else
      false
    end
  end

  defp overlap_path(left, right), do: if(String.length(left) <= String.length(right), do: left, else: right)
  defp created_at_key(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)
  defp created_at_key(_value), do: 9_223_372_036_854_775_807
  defp invert_string(value), do: value |> to_string() |> String.to_charlist() |> Enum.map(&(1_114_111 - &1))

  defp flexible_value(nil, _key), do: nil
  defp flexible_value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp flexible_value(_value, _key), do: nil

  defp string_value(map, key) do
    case flexible_value(map, key) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end
end
