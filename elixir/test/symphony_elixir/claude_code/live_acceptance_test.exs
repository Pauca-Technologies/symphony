# Live, network-dependent acceptance for the native Claude Code backend against
# the REAL `claude` binary — the §14.4 go/no-go checklist item from
# docs/acp-support-plan.md. Excluded from the normal suite: the module is only
# defined when LIVE_CLAUDE_CODE=1, so a plain `mix test` never compiles or runs
# it.
#
#   LIVE_CLAUDE_CODE=1 mix test test/symphony_elixir/claude_code/live_acceptance_test.exs
#
# Requires `claude` (>= 2.1) reachable on the login-shell PATH (override with
# CLAUDE_BIN) and a working Claude Code auth (ANTHROPIC_API_KEY or a logged-in
# session). Unlike claude_code/client_test.exs (which drives a fake shell agent),
# this proves the real agent completes a `claude -p` stream-json turn through
# SymphonyElixir.ClaudeCode.Client, that its streamed output normalizes into the
# existing transcript shape and renders, and that the in-VM LinearGate MCP
# channel (advertised via --mcp-config) is actually reachable by the real agent.
if System.get_env("LIVE_CLAUDE_CODE") == "1" do
  defmodule SymphonyElixir.ClaudeCode.LiveAcceptanceTest do
    @moduledoc false
    use SymphonyElixir.TestSupport

    alias SymphonyElixir.ClaudeCode.Client, as: ClaudeCode
    alias SymphonyElixir.CodexSessionLogRenderer

    @moduletag :live
    @moduletag timeout: 300_000

    @claude System.get_env("CLAUDE_BIN") || "claude"
    # Default to a cheap model; override with CLAUDE_CODE_LIVE_MODEL.
    @model System.get_env("CLAUDE_CODE_LIVE_MODEL") || "haiku"

    @issue %SymphonyElixir.Linear.Issue{
      id: "issue-cc-live",
      identifier: "CC-LIVE",
      title: "Claude Code live acceptance",
      description: "Drive a real claude -p turn end-to-end.",
      state: "In Progress",
      url: "https://example.org/issues/CC-LIVE",
      labels: ["backend"]
    }

    test "completes a real turn end-to-end and the streamed output renders as a transcript" do
      with_live_cc_env(fn workspace ->
        {result, events} =
          capture(fn collector ->
            ClaudeCode.run(
              workspace.binary,
              "Reply with exactly the single word: ACK. Do not use any tools.",
              @issue,
              on_message: collector
            )
          end)

        assert {:ok, %{session_id: session_id, stop_reason: stop_reason}} = result
        assert is_binary(session_id) and session_id != ""
        assert stop_reason in ["end_turn", "max_tokens"],
               "unexpected stop_reason=#{inspect(stop_reason)}; events=#{inspect(event_names(events))}"

        assert Enum.any?(events, &(&1.event == :session_started))
        assert Enum.any?(events, &(&1.event == :turn_completed))

        agent_payloads =
          for %{event: :notification, payload: %{"method" => "item/agentMessage/delta"} = payload} <- events,
              do: payload

        assert agent_payloads != [],
               "expected at least one normalized agent message; events=#{inspect(event_names(events))}"

        rendered = render_transcript(events)
        IO.puts("\n──── rendered Claude Code transcript ────\n" <> rendered <> "\n─────────────────────────────────────────")
        assert rendered =~ "AGENT"
      end)
    end

    test "real agent invokes the gated linear_graphql tool via the in-VM LinearGate" do
      test_pid = self()

      tool_executor = fn tool_name, arguments ->
        send(test_pid, {:tool_called, tool_name, arguments})
        %{"success" => true, "output" => Jason.encode!(%{"data" => %{"viewer" => %{"id" => "u_live"}}})}
      end

      prompt =
        "You have an MCP tool named mcp__symphony-linear__linear_graphql. " <>
          ~s|Call it RIGHT NOW with arguments {"query":"query { viewer { id } }"}. | <>
          "Do not write code, do not explain — just invoke that one tool."

      with_live_cc_env(fn workspace ->
        {result, _events} =
          capture(fn collector ->
            ClaudeCode.run(workspace.binary, prompt, @issue,
              on_message: collector,
              tool_executor: tool_executor
            )
          end)

        assert {:ok, _} = result

        assert_received {:tool_called, "linear_graphql", %{"query" => query}},
                        "expected the real agent to call linear_graphql through the in-VM gate"

        assert query =~ "viewer"
      end)
    end

    # ── harness ──────────────────────────────────────────────────────────────

    defp with_live_cc_env(fun) do
      root = Path.join(System.tmp_dir!(), "symphony-cc-live-#{System.unique_integer([:positive])}")
      workspace_dir = Path.join(root, "CC-LIVE")
      File.mkdir_p!(workspace_dir)
      File.write!(Path.join(workspace_dir, "README.md"), "# Claude Code live acceptance workspace\n")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: root,
        agent_backend: "claude_code",
        claude_code_command: @claude,
        claude_code_model: @model,
        claude_code_stall_timeout_ms: 120_000,
        claude_code_prompt_timeout_ms: 180_000
      )

      on_exit(fn -> File.rm_rf(root) end)

      fun.(%{binary: workspace_dir, root: root})
    end

    defp capture(fun) do
      test_pid = self()
      collector = fn message -> send(test_pid, {:cc_event, message}) end
      result = fun.(collector)
      {result, drain_events([])}
    end

    defp drain_events(acc) do
      receive do
        {:cc_event, message} -> drain_events([message | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp event_names(events), do: Enum.map(events, & &1.event)

    defp render_transcript(events) do
      events
      |> Enum.map_join("\n", fn event ->
        %{
          "at" => DateTime.to_iso8601(event.timestamp),
          "event" => to_string(event.event),
          "payload" => Map.get(event, :payload),
          "raw" => Map.get(event, :raw)
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
        |> Jason.encode!()
      end)
      |> CodexSessionLogRenderer.render_string(use_color: false)
    end
  end
end
