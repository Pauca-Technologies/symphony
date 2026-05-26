defmodule SymphonyElixir.RepoConfig do
  @moduledoc """
  Loads `~/.symphony/repos.yaml` — the multi-repo Symphony driver config.

  This is the cross-repo configuration that lives on the Symphony host, not in
  any consumer repo. The audit (§9.4) requires:

    * single GraphQL poll per tick across the configured Linear team
    * label-based routing (`repo:<name>` label is the only routing key)
    * cardinality enforcement from a configurable cutover date

  Schema (per implementation plan T24):

      defaults:
        max_concurrent_global: 6
        workspace_root: /tmp/symphony_workspaces
        poll_interval_seconds: 30
        cardinality_enforced_from: "2026-06-01"
      linear:
        team_id: <udp-team-id-uuid-or-key>   # accepts a Linear team UUID
                                             # or a team key like "UDPE";
                                             # Linear.Client auto-detects
        filter_label: udpagent               # optional opt-in label; when
                                             # set, the team-scoped poll
                                             # only returns issues that
                                             # carry this label
      repos:
        - id: udp-dashboard-v2
          label: repo:dashboard-v2
          repo_url: git@github.com:Pauca-Technologies/udp-dashboard-v2.git
          workflow_path: WORKFLOW.md
          max_concurrent: 3

  This module never raises on a missing file: when `~/.symphony/repos.yaml`
  does not exist, the config is treated as empty (no repos configured) and
  routing falls back to the legacy single-repo path so an unconfigured host
  keeps booting.
  """

  require Logger

  # Canonical filename for the unified Symphony config. The file holds
  # everything that isn't per-repo: tracker, polling, workspace.root,
  # agent, codex, observability, plus the linear/team + repos[] blocks
  # that used to live in repos.yaml.
  @canonical_filename "config.yml"
  # Legacy filename — older deployments shipped with a separate
  # `repos.yaml` for repo registration and a host-level WORKFLOW.md at
  # cwd. `RepoConfig.path/0` prefers config.yml when present, falls
  # back to repos.yaml so existing setups keep loading.
  @legacy_filename "repos.yaml"
  @default_poll_interval_seconds 30
  @default_max_concurrent_global 6
  @default_workspace_root_relative "symphony_workspaces"

  @type repo_entry :: %{
          id: String.t(),
          label: String.t(),
          repo_url: String.t() | nil,
          workflow_path: String.t(),
          base_branch: String.t(),
          max_concurrent: pos_integer()
        }

  @type t :: %{
          defaults: %{
            max_concurrent_global: pos_integer(),
            workspace_root: String.t(),
            poll_interval_seconds: pos_integer(),
            cardinality_enforced_from: Date.t() | nil
          },
          linear: %{team_id: String.t() | nil, filter_label: String.t() | nil},
          repos: [repo_entry()],
          source: :file | :default,
          path: String.t() | nil
        }

  @spec path() :: String.t()
  def path do
    Application.get_env(:symphony_elixir, :repo_config_path) || pick_canonical_path()
  end

  defp pick_canonical_path do
    home = System.user_home!() || ""
    config = Path.join([home, ".symphony", @canonical_filename])
    legacy = Path.join([home, ".symphony", @legacy_filename])

    cond do
      File.regular?(config) -> config
      File.regular?(legacy) -> legacy
      true -> config
    end
  end

  @doc """
  Return the raw decoded YAML from the config file (or `nil` when the
  file is absent). Used by `SymphonyElixir.Config` to source host-level
  settings (tracker, polling, workspace, agent, codex, observability)
  from the same file that holds the multi-repo routing config.
  """
  @spec load_yaml() :: {:ok, map() | nil} | {:error, term()}
  def load_yaml do
    path = path()

    case File.read(path) do
      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          {:ok, _other} -> {:error, {:repo_config_invalid, path, :not_a_map}}
          {:error, reason} -> {:error, {:repo_config_invalid, path, reason}}
        end

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, {:repo_config_unreadable, path, reason}}
    end
  end

  @doc """
  True when the loaded YAML contains host-level configuration blocks
  (tracker / codex / polling / workspace / agent / observability /
  server). Used by `SymphonyElixir.Config` to decide whether to source
  settings from `~/.symphony/config.yml` or fall back to a WORKFLOW.md
  (legacy single-repo mode).
  """
  @spec host_config?(map() | nil) :: boolean()
  def host_config?(yaml) when is_map(yaml) do
    Enum.any?(
      ~w(tracker polling workspace agent codex observability server worker),
      &Map.has_key?(yaml, &1)
    )
  end

  def host_config?(_), do: false

  @doc """
  Load the repo config. Returns an `{:ok, config}` tuple. If the file is
  absent, returns an empty config (the orchestrator can still run in legacy
  single-repo mode using WORKFLOW.md). If the file exists but cannot be
  parsed, returns `{:error, reason}`.
  """
  @spec load() :: {:ok, t()} | {:error, term()}
  def load do
    path = path()

    case File.read(path) do
      {:ok, content} ->
        parse(content, path)

      {:error, :enoent} ->
        {:ok, empty()}

      {:error, reason} ->
        {:error, {:repo_config_unreadable, path, reason}}
    end
  end

  @spec load!() :: t()
  def load! do
    case load() do
      {:ok, config} ->
        config

      {:error, reason} ->
        raise ArgumentError, "Failed to load repos.yaml: #{inspect(reason)}"
    end
  end

  @doc """
  Find the repo entry whose `label` matches one of the issue's labels.
  Returns `nil` if no repo matches. Label comparison is case-insensitive on
  the label name; the issue labels are already lower-cased in
  `Linear.Issue`.
  """
  @spec match_repo(t(), [String.t()]) :: repo_entry() | nil
  def match_repo(%{repos: repos}, labels) when is_list(repos) and is_list(labels) do
    normalized_labels = MapSet.new(Enum.map(labels, &normalize_label/1))

    Enum.find(repos, fn %{label: label} ->
      MapSet.member?(normalized_labels, normalize_label(label))
    end)
  end

  def match_repo(_config, _labels), do: nil

  @doc """
  Suggest the closest configured repo label for fuzzy-match advisory
  comments. Returns a list of label strings sorted by similarity.
  """
  @spec fuzzy_suggestions(t(), [String.t()]) :: [String.t()]
  def fuzzy_suggestions(%{repos: repos}, observed_labels) when is_list(observed_labels) do
    configured = Enum.map(repos, fn %{label: label} -> label end)
    candidate_labels = Enum.filter(observed_labels, &String.starts_with?(&1, "repo:"))

    case candidate_labels do
      [] ->
        configured

      [observed | _] ->
        configured
        |> Enum.map(fn label -> {label, jaro_distance(label, observed)} end)
        |> Enum.sort_by(fn {_label, score} -> -score end)
        |> Enum.map(&elem(&1, 0))
    end
  end

  def fuzzy_suggestions(_config, _labels), do: []

  @spec empty() :: t()
  def empty do
    %{
      defaults: %{
        max_concurrent_global: @default_max_concurrent_global,
        workspace_root: default_workspace_root(),
        poll_interval_seconds: @default_poll_interval_seconds,
        cardinality_enforced_from: nil
      },
      linear: %{team_id: nil, filter_label: nil},
      repos: [],
      source: :default,
      path: nil
    }
  end

  defp parse(content, path) do
    case YamlElixir.read_from_string(content) do
      {:ok, decoded} when is_map(decoded) ->
        case build(decoded) do
          {:ok, config} -> {:ok, %{config | source: :file, path: path}}
          {:error, reason} -> {:error, {:repo_config_invalid, path, reason}}
        end

      {:ok, _other} ->
        {:error, {:repo_config_invalid, path, :not_a_map}}

      {:error, reason} ->
        {:error, {:repo_config_invalid, path, reason}}
    end
  end

  defp build(decoded) do
    defaults_raw = Map.get(decoded, "defaults", %{}) || %{}
    linear_raw = Map.get(decoded, "linear", %{}) || %{}
    repos_raw = Map.get(decoded, "repos", []) || []

    with {:ok, defaults} <- build_defaults(defaults_raw),
         {:ok, linear} <- build_linear(linear_raw),
         {:ok, repos} <- build_repos(repos_raw) do
      {:ok,
       %{
         defaults: defaults,
         linear: linear,
         repos: repos,
         source: :file,
         path: nil
       }}
    end
  end

  defp build_defaults(raw) when is_map(raw) do
    cutover_raw = Map.get(raw, "cardinality_enforced_from")

    case parse_cutover_date(cutover_raw) do
      {:ok, cutover} ->
        {:ok,
         %{
           max_concurrent_global:
             pos_integer(raw, "max_concurrent_global", @default_max_concurrent_global),
           workspace_root: string_or_default(raw, "workspace_root", default_workspace_root()),
           poll_interval_seconds:
             pos_integer(raw, "poll_interval_seconds", @default_poll_interval_seconds),
           cardinality_enforced_from: cutover
         }}

      {:error, reason} ->
        {:error, {:invalid_defaults_cardinality_enforced_from, cutover_raw, reason}}
    end
  end

  defp build_linear(raw) when is_map(raw) do
    team_id =
      case Map.get(raw, "team_id") do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end

    filter_label =
      case Map.get(raw, "filter_label") do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end

    {:ok, %{team_id: team_id, filter_label: filter_label}}
  end

  defp build_repos(raw) when is_list(raw) do
    raw
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
      case build_repo_entry(entry, index) do
        {:ok, repo} -> {:cont, {:ok, [repo | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, repos} -> {:ok, Enum.reverse(repos)}
      other -> other
    end
  end

  defp build_repos(_raw), do: {:error, :repos_not_a_list}

  defp build_repo_entry(entry, index) when is_map(entry) do
    with id when is_binary(id) and id != "" <- Map.get(entry, "id") || {:missing, :id},
         label when is_binary(label) and label != "" <-
           Map.get(entry, "label") || {:missing, :label} do
      repo_url =
        case Map.get(entry, "repo_url") do
          value when is_binary(value) and value != "" -> value
          _ -> nil
        end

      workflow_path = string_or_default(entry, "workflow_path", "WORKFLOW.md")
      base_branch = string_or_default(entry, "base_branch", "main")
      max_concurrent = pos_integer(entry, "max_concurrent", 1)

      {:ok,
       %{
         id: id,
         label: label,
         repo_url: repo_url,
         workflow_path: workflow_path,
         base_branch: base_branch,
         max_concurrent: max_concurrent
       }}
    else
      {:missing, field} -> {:error, {:repo_entry_missing_field, index, field}}
      _ -> {:error, {:invalid_repo_entry, index}}
    end
  end

  defp build_repo_entry(_entry, index), do: {:error, {:invalid_repo_entry, index}}

  defp parse_cutover_date(nil), do: {:ok, nil}
  defp parse_cutover_date(""), do: {:ok, nil}

  defp parse_cutover_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_cutover_date(%Date{} = date), do: {:ok, date}
  defp parse_cutover_date(other), do: {:error, {:unsupported_date_value, other}}

  defp pos_integer(map, key, default) do
    case Map.get(map, key) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp string_or_default(map, key, default) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _ -> default
    end
  end

  defp default_workspace_root do
    Path.join(System.tmp_dir!(), @default_workspace_root_relative)
  end

  defp normalize_label(value) when is_binary(value) do
    value |> String.trim() |> String.downcase()
  end

  defp normalize_label(_), do: ""

  # Simple Jaro distance for fuzzy suggestions. Avoids pulling a dep.
  defp jaro_distance(a, b) when is_binary(a) and is_binary(b) do
    String.jaro_distance(a, b)
  end

  defp jaro_distance(_, _), do: 0.0
end
