defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard}
  @transcript_line_limit 500
  @transcript_block_limit 80
  @transcript_byte_limit 262_144

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying)
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry),
        host: workspace_host(running, retry)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        codex_session_logs: codex_session_logs_payload(running, retry)
      },
      transcript: transcript_payload(running || retry),
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      recent_events: recent_events_payload(entry),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      recent_events: recent_events_payload(running),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp codex_session_logs_payload(running, retry) do
    logs =
      (running && Map.get(running, :codex_session_logs)) ||
        (retry && Map.get(retry, :codex_session_logs)) ||
        []

    Enum.map(logs, &codex_session_log_payload/1)
  end

  defp recent_events_payload(running) do
    running
    |> Map.get(:recent_codex_events, [])
    |> Enum.map(&recent_event_payload/1)
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp recent_event_payload(%{timestamp: timestamp, event: event} = message) do
    %{
      at: iso8601(timestamp),
      event: to_string(event),
      message: summarize_message(message)
    }
  end

  defp recent_event_payload(_message), do: %{at: nil, event: nil, message: nil}

  defp codex_session_log_payload(log_entry) when is_map(log_entry) do
    %{
      session_id: Map.get(log_entry, :session_id),
      path: Map.get(log_entry, :path),
      started_at: iso8601(Map.get(log_entry, :started_at)),
      last_event_at: iso8601(Map.get(log_entry, :last_event_at)),
      worker_host: Map.get(log_entry, :worker_host),
      workspace_path: Map.get(log_entry, :workspace_path)
    }
  end

  defp transcript_payload(entry) when is_map(entry) do
    case latest_session_log_entry(entry) do
      %{path: path} = log_entry when is_binary(path) ->
        %{
          session_id: Map.get(log_entry, :session_id),
          path: path,
          started_at: iso8601(Map.get(log_entry, :started_at)),
          last_event_at: iso8601(Map.get(log_entry, :last_event_at)),
          blocks: transcript_blocks_for_entry(entry, path)
        }

      _ ->
        %{session_id: nil, path: nil, started_at: nil, last_event_at: nil, blocks: []}
    end
  end

  defp transcript_payload(_entry),
    do: %{session_id: nil, path: nil, started_at: nil, last_event_at: nil, blocks: []}

  defp latest_session_log_entry(entry) do
    entry
    |> Map.get(:codex_session_logs, [])
    |> Enum.max_by(
      fn log_entry ->
        Map.get(log_entry, :last_event_at) || Map.get(log_entry, :started_at) || ~U[1970-01-01 00:00:00Z]
      end,
      fn -> nil end
    )
  end

  defp transcript_blocks_for_entry(entry, _path) when is_map(entry) do
    case Map.get(entry, :recent_codex_transcript_blocks) do
      blocks when is_list(blocks) and blocks != [] ->
        blocks

      [] ->
        if running_entry?(entry), do: [], else: load_transcript_blocks(Map.get(latest_session_log_entry(entry) || %{}, :path))

      _ ->
        load_transcript_blocks(Map.get(latest_session_log_entry(entry) || %{}, :path))
    end
  end

  defp running_entry?(entry) when is_map(entry) do
    Map.has_key?(entry, :turn_count)
  end

  defp load_transcript_blocks(path) when is_binary(path) do
    case read_transcript_tail(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.take(-@transcript_line_limit)
        |> Enum.map(&transcript_record/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&transcript_fragment/1)
        |> Enum.reject(&is_nil/1)
        |> merge_transcript_fragments()
        |> Enum.take(-@transcript_block_limit)

      {:error, _reason} ->
        []
    end
  end

  defp read_transcript_tail(path) when is_binary(path) do
    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         bytes_to_read <- min(size, @transcript_byte_limit),
         offset <- max(size - bytes_to_read, 0),
         {:ok, chunk} <- read_transcript_chunk(path, offset, bytes_to_read) do
      {:ok, drop_partial_transcript_line(chunk, offset)}
    end
  end

  defp read_transcript_chunk(path, offset, bytes_to_read)
       when is_binary(path) and is_integer(offset) and is_integer(bytes_to_read) do
    case File.open(path, [:binary, :read], &pread_transcript_chunk(&1, offset, bytes_to_read)) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp pread_transcript_chunk(file, offset, bytes_to_read) do
    case :file.pread(file, offset, bytes_to_read) do
      {:ok, chunk} -> {:ok, chunk}
      :eof -> {:ok, ""}
      {:error, reason} -> {:error, reason}
    end
  end

  defp drop_partial_transcript_line(chunk, 0) when is_binary(chunk), do: chunk

  defp drop_partial_transcript_line(chunk, _offset) when is_binary(chunk) do
    case String.split(chunk, "\n", parts: 2) do
      [_partial, remainder] -> remainder
      [_partial_only] -> ""
    end
  end

  defp transcript_record(line) when is_binary(line) do
    line
    |> String.trim()
    |> case do
      "" ->
        nil

      content ->
        case Jason.decode(content) do
          {:ok, payload} when is_map(payload) -> payload
          _ -> nil
        end
    end
  end

  defp transcript_fragment(%{"payload" => %{} = payload} = record) do
    method = map_value(payload, ["method"])
    at = Map.get(record, "at")

    cond do
      method in ["codex/event/agent_message_content_delta", "codex/event/agent_message_delta", "item/agentMessage/delta"] ->
        build_text_fragment("agent", at, extract_text(payload, agent_text_paths()))

      method in ["codex/event/exec_command_output_delta", "item/commandExecution/outputDelta"] ->
        build_text_fragment("output", at, extract_text(payload, output_text_paths()))

      method == "codex/event/exec_command_begin" ->
        build_text_fragment("command", at, extract_command(payload))

      true ->
        nil
    end
  end

  defp transcript_fragment(_record), do: nil

  defp build_text_fragment(kind, at, text) when is_binary(kind) and is_binary(text) do
    case normalize_transcript_text(text) do
      "" -> nil
      normalized -> %{kind: kind, at: at, text: normalized}
    end
  end

  defp build_text_fragment(_kind, _at, _text), do: nil

  defp merge_transcript_fragments(fragments) when is_list(fragments) do
    fragments
    |> Enum.reduce([], fn fragment, acc ->
      case acc do
        [%{kind: kind, text: existing_text} = previous | rest]
        when kind == fragment.kind and kind in ["agent", "output"] ->
          [%{previous | text: existing_text <> fragment.text} | rest]

        _ ->
          [fragment | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp agent_text_paths do
    [
      ["params", "msg", "content"],
      ["params", "msg", "delta"],
      ["params", "delta"],
      ["params", "text"],
      ["params", "content"]
    ]
  end

  defp output_text_paths do
    [
      ["params", "msg", "content"],
      ["params", "msg", "delta"],
      ["params", "delta"],
      ["params", "output"],
      ["params", "content"]
    ]
  end

  defp extract_text(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      case map_value(payload, path) do
        text when is_binary(text) -> text
        _ -> nil
      end
    end)
  end

  defp extract_command(payload) when is_map(payload) do
    [
      ["params", "msg", "command"],
      ["params", "command"],
      ["params", "cmd"]
    ]
    |> Enum.find_value(fn path ->
      case map_value(payload, path) do
        command when is_binary(command) -> "$ #{String.trim(command)}"
        _ -> nil
      end
    end)
  end

  defp normalize_transcript_text(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.replace(~r/\x1B\[[0-9;]*[A-Za-z]/, "")
    |> String.replace(~r/\x1B./, "")
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
  end

  defp map_value(value, []), do: value

  defp map_value(map, [key | rest]) when is_map(map) and is_atom(key) do
    case Map.get(map, key) do
      nil -> map_value(map, [Atom.to_string(key) | rest])
      nested -> map_value(nested, rest)
    end
  end

  defp map_value(map, [key | rest]) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      nil -> map_value(map, [String.to_atom(key) | rest])
      nested -> map_value(nested, rest)
    end
  rescue
    ArgumentError -> nil
  end

  defp map_value(_map, _path), do: nil

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
