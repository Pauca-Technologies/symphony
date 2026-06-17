# Live, network-dependent acceptance for the ACP backend against the REAL
# `opencode acp` binary — the §11 manual checklist item from
# docs/acp-support-plan.md. Excluded from the normal suite: the module is only
# defined when LIVE_ACP=1, so a plain `mix test` never compiles or runs it.
#
#   LIVE_ACP=1 mix test test/symphony_elixir/acp/live_acceptance_test.exs
#
# Requires `opencode` (>= 1.17) reachable on the login-shell PATH (override with
# OPENCODE_BIN) and network access to OpenCode Zen free models. Unlike
# acp/client_test.exs (which drives a fake shell agent), this proves the real
# agent completes a turn through SymphonyElixir.Acp.Client, that its streamed
# native `session/update` output renders through the transcript pipeline, and
# that the in-VM LinearGate MCP channel is actually reachable by the real agent.
if System.get_env("LIVE_ACP") == "1" do
  defmodule SymphonyElixir.Acp.LiveAcceptanceTest do
    @moduledoc false
    use SymphonyElixir.TestSupport

    alias SymphonyElixir.Acp.Client, as: AcpClient
    alias SymphonyElixir.CodexSessionLogRenderer

    @moduletag :live
    # The free models can take tens of seconds for first token; give the whole
    # case room beyond the ACP turn timeouts configured below.
    @moduletag timeout: 300_000

    @opencode System.get_env("OPENCODE_BIN") || "opencode"

    @issue %SymphonyElixir.Linear.Issue{
      id: "issue-acp-live",
      identifier: "ACP-LIVE",
      title: "ACP live acceptance",
      description: "Drive a real opencode acp turn end-to-end.",
      state: "In Progress",
      url: "https://example.org/issues/ACP-LIVE",
      labels: ["backend"]
    }

    test "completes a real turn end-to-end and the streamed output renders as a transcript" do
      with_live_acp_env(fn workspace ->
        {result, events} =
          capture(fn collector ->
            AcpClient.run(
              workspace.binary,
              "Reply with exactly the single word: ACK. Do not use any tools.",
              @issue,
              on_message: collector
            )
          end)

        assert {:ok, %{session_id: session_id, stop_reason: stop_reason}} = result
        assert is_binary(session_id) and session_id != ""
        # A trivial reply ends the turn normally; max_tokens is tolerated in case
        # a free model rambles, since it still maps to a completed turn.
        assert stop_reason in ["end_turn", "max_tokens"],
               "unexpected stop_reason=#{inspect(stop_reason)}; events=#{inspect(event_names(events))}"

        assert Enum.any?(events, &(&1.event == :session_started))
        assert Enum.any?(events, &(&1.event == :turn_completed))

        # The real agent's text must arrive as a native ACP `session/update`
        # `agent_message_chunk` (Option B); the observability pipeline renders it
        # directly via the `update.sessionUpdate` discriminator.
        agent_payloads =
          for %{
                event: :notification,
                payload: %{"method" => "session/update", "params" => %{"update" => %{"sessionUpdate" => "agent_message_chunk"}}} = payload
              } <- events,
              do: payload

        assert agent_payloads != [],
               "expected at least one native agent_message_chunk; events=#{inspect(event_names(events))}"

        # And that native stream renders through the real session-log renderer.
        rendered = render_transcript(events)
        IO.puts("\n──── rendered ACP transcript ────\n" <> rendered <> "\n────────────────────────────────")
        assert rendered =~ "AGENT"
      end)
    end

    test "real agent invokes the gated linear_graphql tool via the in-VM LinearGate" do
      test_pid = self()

      # Record the dispatch instead of running the real handoff gate: this proves
      # the full channel — real opencode → client-passed HTTP MCP → McpPlug →
      # dispatch_tool_call → the run process → tool_executor — without needing a
      # live Linear/handoff context. The gate-blocking behaviour itself is proven
      # against Symphony's own logic in acp/linear_gate_test.exs.
      tool_executor = fn tool_name, arguments ->
        send(test_pid, {:tool_called, tool_name, arguments})
        %{"success" => true, "output" => Jason.encode!(%{"data" => %{"viewer" => %{"id" => "u_live"}}})}
      end

      prompt =
        "You have an MCP tool named symphony-linear_linear_graphql. " <>
          ~s|Call it RIGHT NOW with arguments {"query":"query { viewer { id } }"}. | <>
          "Do not write code, do not explain — just invoke that one tool."

      with_live_acp_env(fn workspace ->
        {result, _events} =
          capture(fn collector ->
            AcpClient.run(workspace.binary, prompt, @issue,
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

    # Pin opencode's model via a workspace-local config so the acceptance does
    # not depend on (or mutate) the host's global opencode config or default
    # model. Override with ACP_LIVE_MODEL when the chosen free model is
    # rate-limited (the OpenCode Zen free tier throttles per-model).
    @model System.get_env("ACP_LIVE_MODEL") || "opencode/north-mini-code-free"

    defp with_live_acp_env(fun) do
      root = Path.join(System.tmp_dir!(), "symphony-acp-live-#{System.unique_integer([:positive])}")
      workspace_dir = Path.join(root, "ACP-LIVE")
      File.mkdir_p!(workspace_dir)
      # A minimal real file so the agent sees a non-empty workspace.
      File.write!(Path.join(workspace_dir, "README.md"), "# ACP live acceptance workspace\n")

      File.write!(
        Path.join(workspace_dir, "opencode.jsonc"),
        ~s({"$schema": "https://opencode.ai/config.json", "model": "#{@model}"}\n)
      )

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: root,
        agent_backend: "acp",
        acp_command: "#{@opencode} acp",
        acp_read_timeout_ms: 30_000,
        acp_stall_timeout_ms: 120_000,
        acp_prompt_timeout_ms: 180_000
      )

      on_exit(fn -> File.rm_rf(root) end)

      fun.(%{binary: workspace_dir, root: root})
    end

    defp capture(fun) do
      test_pid = self()
      collector = fn message -> send(test_pid, {:acp_event, message}) end
      result = fun.(collector)
      {result, drain_events([])}
    end

    defp drain_events(acc) do
      receive do
        {:acp_event, message} -> drain_events([message | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp event_names(events), do: Enum.map(events, & &1.event)

    # Reproduce the orchestrator's session-log NDJSON (codex_session_log_record/2)
    # for the captured stream, then render it the way `symphony transcript` does.
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
