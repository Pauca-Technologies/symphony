defmodule SymphonyElixir.SessionStartHook do
  @moduledoc """
  Runs the non-blocking session_start lifecycle hook and formats first-turn guidance.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue, SSH, Workspace}

  @telemetry_event [:symphony_elixir, :gate, :session_start]

  @type result :: %{
          prompt: String.t(),
          outcome: :skipped | :passed | :failed,
          output: String.t(),
          workpad_files: [String.t()],
          script_timings: [map()]
        }

  @spec run(Path.t(), Issue.t(), String.t() | nil) :: result()
  def run(workspace, %Issue{} = issue, worker_host \\ nil) when is_binary(workspace) do
    case Config.settings!().hooks.session_start do
      nil ->
        result(:skipped, "", [])

      _command ->
        started_at = System.monotonic_time()

        {outcome, output} =
          case Workspace.run_session_start_hook(workspace, issue, worker_host) do
            {:ok, hook_output} ->
              {:passed, hook_output}

            {:error, reason} ->
              Logger.warning(
                "session_start hook failed issue_id=#{issue.id || "n/a"} issue_identifier=#{issue.identifier || "n/a"} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)} reason=#{inspect(reason)}"
              )

              {:failed, hook_failure_output(reason)}
          end

        workpad_files = discover_workpad_files(workspace, issue, worker_host)
        script_timings = extract_script_timings(output)
        duration_ms = elapsed_ms(started_at)

        emit_telemetry(issue, workspace, worker_host, outcome, duration_ms, script_timings, workpad_files)

        result(outcome, output, workpad_files, script_timings)
    end
  end

  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  defp hook_failure_output({:workspace_hook_failed, _hook_name, _status, output}) do
    IO.iodata_to_binary(output)
  end

  defp hook_failure_output(reason), do: inspect(reason)

  defp result(outcome, output, workpad_files, script_timings \\ [])

  defp result(:skipped, _output, workpad_files, script_timings) do
    %{prompt: "", outcome: :skipped, output: "", workpad_files: workpad_files, script_timings: script_timings}
  end

  defp result(outcome, output, workpad_files, script_timings) do
    %{
      prompt: advisory_prompt(outcome, workpad_files),
      outcome: outcome,
      output: output,
      workpad_files: workpad_files,
      script_timings: script_timings
    }
  end

  defp advisory_prompt(:passed, []), do: ""

  defp advisory_prompt(:passed, workpad_files) do
    """
    System message:

    The session_start lifecycle hook ran before this turn. Review these generated workpad files before reading source:
    #{format_file_links(workpad_files)}
    """
    |> String.trim()
  end

  defp advisory_prompt(:failed, workpad_files) do
    """
    System message:

    The session_start lifecycle hook failed, but it is informational and must not block this session. Continue with the task and account for any available workpad files:
    #{format_file_links(workpad_files)}
    """
    |> String.trim()
  end

  defp format_file_links([]), do: "- No session_start workpad files were found."

  defp format_file_links(files) do
    Enum.map_join(files, "\n", &"- #{&1}")
  end

  defp emit_telemetry(%Issue{} = issue, workspace, worker_host, outcome, duration_ms, script_timings, workpad_files) do
    :telemetry.execute(
      @telemetry_event,
      %{count: 1, duration_ms: duration_ms},
      %{
        event: "gate.session_start",
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        workspace: workspace,
        worker_host: worker_host,
        outcome: outcome,
        script_timings: script_timings,
        workpad_files: workpad_files
      }
    )

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

  defp extract_script_timings(output) when is_binary(output) do
    output
    |> decode_hook_report()
    |> timings_from_report()
  end

  defp decode_hook_report(output) do
    trimmed = String.trim(output)

    with {:error, _reason} <- Jason.decode(trimmed),
         {:ok, candidate} <- json_object_candidate(trimmed),
         {:error, _reason} <- Jason.decode(candidate) do
      %{}
    else
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
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
