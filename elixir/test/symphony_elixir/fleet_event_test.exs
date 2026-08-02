defmodule SymphonyElixir.FleetEventTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{FleetEvent, Telemetry}

  setup do
    root = Path.join(System.tmp_dir!(), "fleet-event-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:symphony_elixir, :telemetry_dir)
    Application.put_env(:symphony_elixir, :telemetry_dir, root)

    on_exit(fn ->
      File.rm_rf!(root)

      if previous,
        do: Application.put_env(:symphony_elixir, :telemetry_dir, previous),
        else: Application.delete_env(:symphony_elixir, :telemetry_dir)
    end)

    :ok
  end

  test "emits terminal tool lifecycle once for Codex ACP and Claude shapes" do
    entry = %{
      issue: %{id: "issue-1", identifier: "UDPE-7165", parent_id: nil, labels: ["repo:symphony"]},
      identifier: "UDPE-7165",
      backend: "codex",
      session_id: "thread-1",
      observability_policy: %{redact_fields: ["authorization"]}
    }

    updates = [
      update("item/started", %{"item" => %{"id" => "cmd-1", "type" => "commandExecution", "command" => "mix test"}}, 0),
      update("item/completed", %{"item" => %{"id" => "cmd-1", "type" => "commandExecution", "command" => "mix test", "aggregatedOutput" => "ok", "status" => "completed"}}, 10),
      update("session/update", %{"update" => %{"sessionUpdate" => "tool_call", "toolCallId" => "acp-1", "kind" => "edit", "title" => "edit", "rawInput" => %{"path" => "README.md"}}}, 20),
      update(
        "session/update",
        %{"update" => %{"sessionUpdate" => "tool_call_update", "toolCallId" => "acp-1", "kind" => "edit", "status" => "completed", "content" => %{"type" => "text", "text" => "patched"}}},
        30
      ),
      update("item/tool/call", %{"callId" => "claude-1", "itemId" => "claude-1", "name" => "Read", "arguments" => %{"file_path" => "README.md"}}, 40),
      update("item/commandExecution/outputDelta", %{"callId" => "claude-1", "itemId" => "claude-1", "output" => "contents", "terminal" => true, "status" => "completed"}, 50),
      update("item/tool/call", %{"callId" => "claude-rebase", "itemId" => "claude-rebase", "name" => "Bash", "arguments" => %{"command" => "git rebase origin/main"}}, 51),
      update("item/commandExecution/outputDelta", %{"callId" => "claude-rebase", "itemId" => "claude-rebase", "output" => "Successfully rebased", "terminal" => true, "status" => "completed"}, 52),
      update(
        "item/tool/call",
        %{"callId" => "dynamic-1", "tool" => "linear_graphql", "arguments" => %{"query" => "query Viewer { viewer { id } }"}},
        55,
        event: :tool_call_completed,
        details: %{result: %{"success" => true, "output" => %{"data" => "ok"}}}
      ),
      update("item/started", %{"item" => %{"id" => "msg-1", "type" => "agentMessage"}}, 60),
      update("item/completed", %{"item" => %{"id" => "msg-1", "type" => "agentMessage", "text" => "not a tool"}}, 70),
      update("item/completed", %{"item" => %{"id" => "reason-1", "type" => "reasoning", "text" => "not a tool"}}, 80)
    ]

    Enum.reduce(updates, entry, &FleetEvent.observe(&2, &1, nil))

    tools =
      Telemetry.read_events(Date.utc_today(), Date.utc_today())
      |> Enum.filter(&(&1["event"] == "tool"))

    assert Enum.frequencies_by(tools, & &1["action"]) == %{"end" => 5, "start" => 4}
    assert tools |> Enum.filter(&(&1["action"] == "end")) |> Enum.all?(&(&1["output_bytes"] > 0))
    assert Enum.map(tools, & &1["tool_id"]) |> Enum.uniq() |> Enum.sort() == ["acp-1", "claude-1", "claude-rebase", "cmd-1", "dynamic-1"]
    refute Enum.any?(tools, &(&1["tool_id"] in ["msg-1", "reason-1"]))

    assert %{"vcs_operation" => "rebase", "outcome" => "completed"} =
             Enum.find(tools, &(&1["tool_id"] == "claude-rebase" and &1["action"] == "end"))
  end

  defp update(method, params, offset_ms, extra \\ []) do
    Map.merge(
      %{
        event: :notification,
        timestamp: DateTime.add(DateTime.utc_now(), offset_ms, :millisecond),
        payload: %{"method" => method, "params" => params},
        turn_id: "turn-1"
      },
      Map.new(extra)
    )
  end
end
