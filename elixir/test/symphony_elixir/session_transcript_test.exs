defmodule SymphonyElixir.SessionTranscriptTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.CodexSessionLogRenderer
  alias SymphonyElixir.SessionTranscript

  setup do
    root = Path.join(System.tmp_dir!(), "session-transcript-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "compacted and raw fixtures have equivalent terminal meaning", %{root: root} do
    path = Path.join(root, "session.ndjson")
    entry = %{session_id: "thread-turn", path: path}

    delta = record("notification", "item/agentMessage/delta", %{"delta" => "hel"})

    completed =
      record("notification", "item/completed", %{
        "item" => %{"id" => "message-1", "type" => "agentMessage", "text" => "hello"}
      })

    assert {:ok, entry} = SessionTranscript.persist(entry, delta)
    assert File.exists?(SessionTranscript.active_marker_path(path))
    assert {:ok, entry} = SessionTranscript.persist(entry, completed)
    assert :ok = SessionTranscript.finalize([entry], :failure)
    refute File.exists?(SessionTranscript.active_marker_path(path))

    compact = SessionTranscript.read_records(path)
    raw = SessionTranscript.read_records(String.replace_suffix(path, ".ndjson", ".raw.ndjson.gz"))

    assert length(compact) == 1
    assert length(raw) == 2
    assert SessionTranscript.semantic_projection(compact) == SessionTranscript.semantic_projection(raw)
  end

  test "successful default sessions remove pending raw traces", %{root: root} do
    path = Path.join(root, "success.ndjson")
    entry = %{session_id: "success-thread", path: path}
    assert {:ok, entry} = SessionTranscript.persist(entry, record("turn_completed", "turn/completed", %{}))
    assert :ok = SessionTranscript.finalize([entry], :success)

    raw_path = String.replace_suffix(path, ".ndjson", ".raw.ndjson.gz")
    refute File.exists?(raw_path <> ".pending")
  end

  test "raw retention pruning never removes another active session sidecar", %{root: root} do
    policy = SymphonyElixir.Telemetry.observability()
    active_path = Path.join(root, "active-session.ndjson")
    active_entry = %{session_id: "active-thread", path: active_path}

    assert {:ok, active_entry} =
             SessionTranscript.persist(
               active_entry,
               record("notification", "error", %{"message" => "active"}),
               policy
             )

    active_pending = active_entry.raw_trace_pending_path
    File.touch!(active_pending, System.system_time(:second) - 8 * 86_400)

    completed_path = Path.join(root, "completed-session.ndjson")
    completed_entry = %{session_id: "completed-thread", path: completed_path}

    assert {:ok, completed_entry} =
             SessionTranscript.persist(
               completed_entry,
               record("notification", "error", %{"message" => "completed"}),
               policy
             )

    assert :ok = SessionTranscript.finalize([completed_entry], :failure)
    assert File.exists?(active_pending)
    assert File.exists?(SessionTranscript.active_marker_path(active_path))

    assert :ok = SessionTranscript.finalize([active_entry], :success)
  end

  test "streaming and token chatter is coalesced from compact NDJSON", %{root: root} do
    path = Path.join(root, "compact.ndjson")
    entry = %{session_id: "compact-thread", path: path}

    records = [
      record("notification", "item/agentMessage/delta", %{"delta" => "a"}),
      record("notification", "thread/tokenUsage/updated", %{"tokenUsage" => %{}}),
      record("notification", "item/completed", %{"item" => %{"id" => "1", "type" => "agentMessage", "text" => "a"}})
    ]

    entry =
      Enum.reduce(records, entry, fn record, acc ->
        {:ok, next} = SessionTranscript.persist(acc, record)
        next
      end)

    assert :ok = SessionTranscript.finalize([entry], :failure)
    assert [%{"payload" => %{"method" => "item/completed"}}] = SessionTranscript.read_records(path)
  end

  test "raw protocol payloads redact secret fields", %{root: root} do
    path = Path.join(root, "redacted.ndjson")
    entry = %{session_id: "redacted-thread", path: path}

    secret_record =
      record("notification", "item/completed", %{
        "authorization" => "Bearer do-not-store",
        "item" => %{"id" => "1", "type" => "agentMessage", "text" => "safe"}
      })

    assert {:ok, entry} = SessionTranscript.persist(entry, secret_record)
    assert is_binary(entry.raw_trace_pending_path)
    assert :ok = SessionTranscript.finalize([entry], :failure)

    [raw] = SessionTranscript.read_records(entry.raw_trace_path)
    [compact] = SessionTranscript.read_records(path)
    assert get_in(raw, ["payload", "params", "authorization"]) == "[REDACTED]"
    refute inspect(raw) =~ "do-not-store"
    assert get_in(compact, ["payload", "params", "authorization"]) == "[REDACTED]"
    refute File.read!(path) =~ "do-not-store"
  end

  test "compaction-disabled legacy NDJSON preserves shape without persisting secrets", %{root: root} do
    path = Path.join(root, "legacy-redacted.ndjson")
    entry = %{session_id: "legacy-redacted-thread", path: path}

    record =
      record("notification", "item/agentMessage/delta", %{
        "authorization" => "Bearer legacy-secret",
        "delta" => "safe"
      })

    policy = Map.put(SymphonyElixir.Telemetry.observability(), :session_compaction_enabled, false)
    assert {:ok, _entry} = SessionTranscript.persist(entry, record, policy)

    [durable] = SessionTranscript.read_records(path)
    assert durable["event"] == "notification"
    assert durable["session_id"] == "thread-turn"
    assert get_in(durable, ["payload", "params", "authorization"]) == "[REDACTED]"
    assert Jason.decode!(durable["raw"])["params"]["authorization"] == "[REDACTED]"
    refute File.read!(path) =~ "legacy-secret"
  end

  test "raw traces preserve complete redacted protocol originals without fleet bounds", %{root: root} do
    path = Path.join(root, "raw-fidelity.ndjson")
    entry = %{session_id: "raw-thread", path: path}
    output = String.duplicate("x", 12_000)

    protocol = %{
      "method" => "provider/event",
      "params" => %{"output" => output, "providerEnvelope" => %{"requestId" => "req-1", "private_key" => "do-not-store"}}
    }

    record =
      record("notification", "item/commandExecution/outputDelta", %{"output" => output})
      |> Map.put(:raw, Jason.encode!(protocol))

    assert {:ok, entry} = SessionTranscript.persist(entry, record)
    assert :ok = SessionTranscript.finalize([entry], :failure)

    [raw] = SessionTranscript.read_records(entry.raw_trace_path)
    assert get_in(raw, ["protocol_raw", "params", "output"]) == output
    assert get_in(raw, ["protocol_raw", "params", "providerEnvelope", "requestId"]) == "req-1"
    assert get_in(raw, ["protocol_raw", "params", "providerEnvelope", "private_key"]) == "[REDACTED]"
    refute File.read!(entry.raw_trace_path) =~ "do-not-store"
    refute inspect(raw) =~ "truncated sha256"
  end

  test "invalid protocol originals retain safe diagnostics only", %{root: root} do
    path = Path.join(root, "invalid-raw.ndjson")
    entry = %{session_id: "invalid-thread", path: path}
    record = record("notification", "error", %{}) |> Map.put(:raw, "not-json secret material")

    assert {:ok, entry} = SessionTranscript.persist(entry, record)
    assert :ok = SessionTranscript.finalize([entry], :failure)

    [raw] = SessionTranscript.read_records(entry.raw_trace_path)
    assert raw["protocol_raw_invalid"]
    assert raw["protocol_raw_bytes"] == byte_size("not-json secret material")
    assert byte_size(raw["protocol_raw_sha256"]) == 64
    refute Map.has_key?(raw, "protocol_raw")
    refute inspect(raw) =~ "secret material"
  end

  test "a truncated final gzip append leaves earlier evidence readable", %{root: root} do
    path = Path.join(root, "truncated.ndjson")
    entry = %{session_id: "truncated-thread", path: path}
    assert {:ok, entry} = SessionTranscript.persist(entry, record("notification", "error", %{"message" => "first"}))
    assert {:ok, entry} = SessionTranscript.persist(entry, record("notification", "error", %{"message" => "second"}))
    assert :ok = SessionTranscript.finalize([entry], :failure)

    compressed = File.read!(entry.raw_trace_path)
    File.write!(entry.raw_trace_path, binary_part(compressed, 0, byte_size(compressed) - 5))

    assert [%{"payload" => %{"params" => %{"message" => "first"}}}] = SessionTranscript.read_records(entry.raw_trace_path)
  end

  test "ACP chunks and cumulative tool updates retain one semantic stream", %{root: root} do
    path = Path.join(root, "acp.ndjson")
    entry = %{session_id: "acp-thread", path: path}

    records = [
      acp_record(%{"sessionUpdate" => "agent_message_chunk", "content" => %{"type" => "text", "text" => "hello "}}),
      acp_record(%{"sessionUpdate" => "agent_message_chunk", "content" => %{"type" => "text", "text" => "world"}}),
      acp_record(%{"sessionUpdate" => "tool_call", "toolCallId" => "tc-1", "kind" => "read", "title" => "read", "rawInput" => %{}}),
      acp_record(%{"sessionUpdate" => "tool_call_update", "toolCallId" => "tc-1", "rawInput" => %{"filePath" => "lib/a.ex"}}),
      acp_record(%{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "tc-1",
        "status" => "completed",
        "rawInput" => %{"filePath" => "lib/a.ex"},
        "content" => %{"type" => "text", "text" => "alpha\nbeta\n"}
      }),
      record("turn_completed", "turn/completed", %{})
    ]

    entry = persist_all(entry, records)
    assert :ok = SessionTranscript.finalize([entry], :failure)
    rendered = render_records(SessionTranscript.read_records(path))

    assert rendered =~ "hello world"
    assert rendered =~ "TOOL read: read"
    assert rendered =~ "lib/a.ex"
    assert rendered =~ "alpha\n  beta"
    assert length(String.split(rendered, "] TOOL ")) == 2
    assert length(String.split(rendered, "] OUT")) == 2
  end

  test "Claude tool correlation and terminal output survive compaction", %{root: root} do
    path = Path.join(root, "claude.ndjson")
    entry = %{session_id: "claude-thread", path: path}

    records = [
      record("notification", "item/agentMessage/delta", %{"itemId" => "msg-1", "delta" => "answer"}),
      record("notification", "item/tool/call", %{"callId" => "toolu-1", "itemId" => "toolu-1", "name" => "Read", "arguments" => %{"file_path" => "README.md"}}),
      record("notification", "item/commandExecution/outputDelta", %{"callId" => "toolu-1", "itemId" => "toolu-1", "output" => "contents", "terminal" => true, "status" => "completed"}),
      record("turn_completed", "turn/completed", %{})
    ]

    entry = persist_all(entry, records)
    assert :ok = SessionTranscript.finalize([entry], :failure)
    rendered = render_records(SessionTranscript.read_records(path))

    assert rendered =~ "answer"
    assert rendered =~ "Read"
    assert rendered =~ "README.md"
    assert rendered =~ "contents"
  end

  test "Codex terminal items replace their streaming records", %{root: root} do
    path = Path.join(root, "codex.ndjson")
    entry = %{session_id: "codex-thread", path: path}

    records = [
      record("notification", "item/agentMessage/delta", %{"itemId" => "msg-1", "delta" => "hello"}),
      record("notification", "item/completed", %{"item" => %{"id" => "msg-1", "type" => "agentMessage", "text" => "hello"}}),
      record("notification", "item/started", %{"item" => %{"id" => "cmd-1", "type" => "commandExecution", "command" => "mix test"}}),
      record("notification", "item/commandExecution/outputDelta", %{"itemId" => "cmd-1", "output" => "ok"}),
      record("notification", "item/completed", %{"item" => %{"id" => "cmd-1", "type" => "commandExecution", "command" => "mix test", "aggregatedOutput" => "ok", "status" => "completed"}})
    ]

    entry = persist_all(entry, records)
    assert :ok = SessionTranscript.finalize([entry], :failure)
    compact = SessionTranscript.read_records(path)

    assert Enum.count(compact, &(get_in(&1, ["payload", "method"]) == "item/completed")) == 2
    refute Enum.any?(compact, &(get_in(&1, ["payload", "method"]) =~ "delta"))
    assert render_records(compact) |> String.split("hello") |> length() == 2
  end

  test "compact bounds remain valid UTF-8 when a codepoint crosses the byte limit", %{root: root} do
    path = Path.join(root, "utf8-bound.ndjson")
    entry = %{session_id: "utf8-thread", path: path}
    text = String.duplicate("a", 65_535) <> "€tail"

    completed =
      record("notification", "item/completed", %{
        "item" => %{"id" => "message-utf8", "type" => "agentMessage", "text" => text}
      })

    assert {:ok, _entry} = SessionTranscript.persist(entry, completed)
    [compact] = SessionTranscript.read_records(path)
    bounded = get_in(compact, ["payload", "params", "item", "text"])

    assert String.valid?(bounded)
    assert String.starts_with?(bounded, String.duplicate("a", 65_535))
    assert bounded =~ "coalesced stream truncated sha256="
    assert {:ok, _json} = Jason.encode(compact)
  end

  test "empty custom redaction cannot expose nested camelCase credentials", %{root: root} do
    path = Path.join(root, "camel-secrets.ndjson")
    entry = %{session_id: "camel-thread", path: path}

    params = %{
      "item" => %{"id" => "secret-item", "type" => "agentMessage", "text" => "safe"},
      "apiKey" => "api-secret",
      "nested" => %{"accessToken" => "access-secret", "clientSecret" => "client-secret", "privateKey" => "private-secret"}
    }

    policy = Map.put(SymphonyElixir.Telemetry.observability(), :redact_fields, [])
    assert {:ok, entry} = SessionTranscript.persist(entry, record("notification", "item/completed", params), policy)
    assert :ok = SessionTranscript.finalize([entry], :failure)

    [compact] = SessionTranscript.read_records(path)
    [raw] = SessionTranscript.read_records(entry.raw_trace_path)

    for durable <- [compact, raw] do
      assert get_in(durable, ["payload", "params", "apiKey"]) == "[REDACTED]"
      assert get_in(durable, ["payload", "params", "nested", "accessToken"]) == "[REDACTED]"
      assert get_in(durable, ["payload", "params", "nested", "clientSecret"]) == "[REDACTED]"
      assert get_in(durable, ["payload", "params", "nested", "privateKey"]) == "[REDACTED]"
      refute inspect(durable) =~ "-secret"
    end
  end

  defp persist_all(entry, records) do
    Enum.reduce(records, entry, fn item, acc ->
      {:ok, next} = SessionTranscript.persist(acc, item)
      next
    end)
  end

  defp acp_record(update) do
    record("notification", "session/update", %{"sessionId" => "acp-thread", "update" => update})
  end

  defp render_records(records) do
    records
    |> Enum.map_join("\n", &Jason.encode!/1)
    |> CodexSessionLogRenderer.render_string(use_color: false)
  end

  defp record(event, method, params) do
    %{
      at: "2026-08-01T12:00:00Z",
      event: event,
      issue_id: "issue-1",
      issue_identifier: "UDPE-7165",
      session_id: "thread-turn",
      thread_id: "thread",
      turn_id: "turn",
      raw: Jason.encode!(%{"method" => method, "params" => params}),
      payload: %{"method" => method, "params" => params}
    }
  end
end
