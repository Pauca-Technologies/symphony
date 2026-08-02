defmodule SymphonyElixir.SessionStartHook do
  @moduledoc """
  Runs the non-blocking session_start lifecycle hook and returns structured results.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue, SSH, Telemetry, Workspace}

  @telemetry_event [:symphony_elixir, :gate, :session_start]

  @type artifact :: %{path: String.t(), description: String.t() | nil}
  @type result :: %{
          outcome: :skipped | :passed | :failed,
          output: String.t(),
          workpad_files: [String.t()],
          artifacts: [artifact()],
          script_timings: [map()]
        }

  @spec run(Path.t(), Issue.t(), String.t() | nil, keyword()) :: result()
  def run(workspace, %Issue{} = issue, worker_host \\ nil, opts \\ [])
      when is_binary(workspace) do
    # When a per-repo workflow override is in play (T27 multi-repo
    # dispatch), prefer its session_start command over the host-level
    # Config. Falls back to the global setting when not provided.
    override = Keyword.get(opts, :hook_command)
    command = override || Config.settings!().hooks.session_start

    case command do
      nil ->
        result(:skipped, "", [])

      _command ->
        started_at = System.monotonic_time()

        {outcome, output} =
          case Workspace.run_session_start_hook(workspace, issue, worker_host, opts) do
            {:ok, hook_output} ->
              {:passed, hook_output}

            {:error, reason} ->
              Logger.warning(
                "session_start hook failed issue_id=#{issue.id || "n/a"} issue_identifier=#{issue.identifier || "n/a"} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)} reason=#{inspect(reason)}"
              )

              {:failed, hook_failure_output(reason)}
          end

        report = decode_hook_report(output)
        discovered_files = discover_workpad_files(workspace, issue, worker_host)
        artifacts = resolve_artifacts(report, discovered_files)
        workpad_files = Enum.map(artifacts, & &1.path)
        script_timings = timings_from_report(report)
        duration_ms = elapsed_ms(started_at)

        emit_telemetry(issue, workspace, worker_host, outcome, duration_ms, script_timings, workpad_files)

        result(outcome, output, artifacts, script_timings)
    end
  end

  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  defp hook_failure_output({:workspace_hook_failed, _hook_name, _status, output}) do
    IO.iodata_to_binary(output)
  end

  defp hook_failure_output(reason), do: inspect(reason)

  defp result(outcome, output, artifacts, script_timings \\ [])

  defp result(:skipped, _output, artifacts, script_timings) do
    %{outcome: :skipped, output: "", workpad_files: [], artifacts: artifacts, script_timings: script_timings}
  end

  defp result(outcome, output, artifacts, script_timings) do
    %{
      outcome: outcome,
      output: output,
      workpad_files: Enum.map(artifacts, & &1.path),
      artifacts: artifacts,
      script_timings: script_timings
    }
  end

  defp emit_telemetry(%Issue{} = issue, workspace, worker_host, outcome, duration_ms, script_timings, workpad_files) do
    metadata = %{
      subtype: "session_start",
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      parent_issue_id: issue.parent_id,
      workspace: workspace,
      worker_host: worker_host,
      outcome: outcome,
      duration_ms: duration_ms,
      checks: script_timings,
      artifact_refs: workpad_files,
      script_timings: script_timings,
      workpad_files: workpad_files
    }

    :telemetry.execute(
      @telemetry_event,
      %{count: 1, duration_ms: duration_ms},
      Map.put(metadata, :event, "gate.session_start")
    )

    Telemetry.emit(:gate, metadata)

    Logger.info(
      "gate.session_start issue_id=#{issue.id || "n/a"} issue_identifier=#{issue.identifier || "n/a"} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)} outcome=#{outcome} duration_ms=#{duration_ms}"
    )
  end

  defp elapsed_ms(started_at) do
    started_at
    |> then(&(System.monotonic_time() - &1))
    |> System.convert_time_unit(:native, :millisecond)
  end

  defp discover_workpad_files(workspace, %Issue{} = issue, nil) do
    branch = local_branch_name(workspace)

    workspace
    |> candidate_workpad_dirs(branch, issue)
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.md")))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&Path.relative_to(&1, workspace))
  end

  defp discover_workpad_files(workspace, %Issue{} = issue, worker_host) when is_binary(worker_host) do
    branch = remote_branch_name(workspace, worker_host)
    relative_dirs = candidate_relative_workpad_dirs(branch, issue)

    find_script =
      [
        "cd #{shell_escape(workspace)}",
        relative_dirs
        |> Enum.map_join("\n", fn dir ->
          "if [ -d #{shell_escape(dir)} ]; then find #{shell_escape(dir)} -type f -name '*.md'; fi"
        end)
      ]
      |> Enum.join("\n")

    case run_remote_discovery(worker_host, find_script) do
      {:ok, {output, 0}} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.uniq()
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp local_branch_name(workspace) do
    case System.cmd("git", ["branch", "--show-current"], cd: workspace, stderr_to_stdout: true) do
      {branch, 0} -> normalize_branch(branch)
      _ -> nil
    end
  end

  defp remote_branch_name(workspace, worker_host) do
    command = "cd #{shell_escape(workspace)} && git branch --show-current 2>/dev/null"

    case run_remote_discovery(worker_host, command) do
      {:ok, {branch, 0}} -> normalize_branch(branch)
      _ -> nil
    end
  end

  defp run_remote_discovery(worker_host, command) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    task =
      Task.async(fn ->
        SSH.run(worker_host, command, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:session_start_discovery_timeout, timeout_ms}}
    end
  end

  defp normalize_branch(branch) when is_binary(branch) do
    case String.trim(branch) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp candidate_workpad_dirs(workspace, branch, %Issue{} = issue) do
    candidate_relative_workpad_dirs(branch, issue)
    |> Enum.map(&Path.join(workspace, &1))
  end

  defp candidate_relative_workpad_dirs(branch, %Issue{} = issue) do
    base = Path.join(["docs", "agent-workpad"])

    [issue.branch_name, sanitize_branch(issue.branch_name), branch, sanitize_branch(branch), issue.identifier]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.map(&Path.join(base, &1))
  end

  defp sanitize_branch(nil), do: nil

  defp sanitize_branch(branch) when is_binary(branch) do
    String.replace(branch, ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp decode_hook_report(output) do
    trimmed = String.trim(output)

    case Jason.decode(trimmed) do
      {:ok, decoded} when is_map(decoded) ->
        decoded

      _ ->
        case decoded_line_reports(trimmed) do
          [] -> decode_embedded_report(trimmed)
          reports -> Enum.reduce(reports, %{}, &Map.merge/2)
        end
    end
  end

  defp decoded_line_reports(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(String.trim(line)) do
        {:ok, decoded} when is_map(decoded) -> [decoded]
        _ -> []
      end
    end)
  end

  defp decode_embedded_report(output) do
    with {:ok, candidate} <- json_object_candidate(output),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(candidate) do
      decoded
    else
      _ -> %{}
    end
  end

  defp resolve_artifacts(report, discovered_files) do
    case reported_artifacts(report) do
      {:present, artifacts} -> artifacts
      :missing -> Enum.map(discovered_files, &%{path: &1, description: nil})
    end
  end

  defp reported_artifacts(report) do
    if map_has_key?(report, "artifacts") do
      artifacts =
        case map_get(report, "artifacts") do
          entries when is_list(entries) ->
            entries
            |> Enum.map(&artifact_entry/1)
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq_by(& &1.path)

          _ ->
            []
        end

      {:present, artifacts}
    else
      :missing
    end
  end

  defp artifact_entry(entry) when is_map(entry) do
    with path when is_binary(path) <- map_string(entry, ["path"], nil),
         true <- valid_artifact_path?(path) do
      %{path: path, description: artifact_description(entry)}
    else
      _ -> nil
    end
  end

  defp artifact_entry(_entry), do: nil

  defp valid_artifact_path?(path) do
    case Path.split(path) do
      ["docs", "agent-workpad" | rest] -> rest != [] and Enum.all?(rest, &(&1 not in [".", "..", ""]))
      _ -> false
    end
  end

  defp artifact_description(entry) do
    case map_string(entry, ["description"], nil) do
      nil ->
        nil

      description ->
        case description |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 240) do
          "" -> nil
          normalized -> normalized
        end
    end
  end

  defp json_object_candidate(output) do
    start_index = :binary.match(output, "{")
    end_index = last_binary_match(output, "}")

    case {start_index, end_index} do
      {{start, _}, {last, _}} when last >= start ->
        {:ok, binary_part(output, start, last - start + 1)}

      _ ->
        {:error, :no_json_object}
    end
  end

  defp last_binary_match(output, pattern) do
    output
    |> :binary.matches(pattern)
    |> List.last()
  end

  defp timings_from_report(report) when is_map(report) do
    cond do
      is_map(map_get(report, "timings")) ->
        map_get(report, "timings")
        |> Enum.map(fn {name, duration_ms} -> timing_entry(%{"name" => to_string(name), "duration_ms" => duration_ms}) end)
        |> Enum.reject(&is_nil/1)

      is_list(map_get(report, "scripts")) ->
        timings_from_list(map_get(report, "scripts"))

      is_list(map_get(report, "checks")) ->
        timings_from_list(map_get(report, "checks"))

      is_list(map_get(report, "gates")) ->
        timings_from_list(map_get(report, "gates"))

      true ->
        []
    end
  end

  defp timings_from_list(entries) do
    entries
    |> Enum.map(&timing_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp timing_entry(entry) when is_map(entry) do
    with name when is_binary(name) <- map_string(entry, ["name", "script", "check", "gate"], nil),
         duration_ms when is_integer(duration_ms) <- map_integer(entry, ["duration_ms", "durationMs", "elapsed_ms", "elapsedMs", "time_ms"]) do
      %{
        name: name,
        duration_ms: duration_ms,
        status: map_string(entry, ["status", "result"], nil)
      }
    else
      _ -> nil
    end
  end

  defp timing_entry(_entry), do: nil

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || map_get_existing_atom(map, key)
  end

  defp map_has_key?(map, key) when is_map(map) do
    Map.has_key?(map, key) or map_has_existing_atom?(map, key)
  end

  defp map_has_existing_atom?(map, key) do
    Map.has_key?(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> false
  end

  defp map_get_existing_atom(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp map_string(map, keys, default) when is_map(map) do
    Enum.find_value(keys, default, fn key ->
      case map_get(map, key) do
        value when is_binary(value) -> value
        value when is_integer(value) or is_boolean(value) -> to_string(value)
        _ -> nil
      end
    end)
  end

  defp map_integer(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case map_get(map, key) do
        value when is_integer(value) -> value
        value when is_float(value) -> round(value)
        value when is_binary(value) -> parse_integer(value)
        _ -> nil
      end
    end)
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, _rest} -> integer
      :error -> nil
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host
end
