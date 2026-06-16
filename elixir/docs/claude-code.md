# Native Claude Code backend (`claude -p` stream-json)

Symphony can drive **Claude Code directly** as a third coding-agent backend,
alongside the default Codex app-server and the ACP backend. This talks to Claude
Code's own non-interactive interface — headless `claude --print` with JSON
streaming over stdio — rather than going through the `claude-code-acp` bridge.
It is the most native surface that maps onto Symphony's shell-out-to-stdio
architecture, and it reuses the shared transport (`SymphonyElixir.AgentTransport`)
and the in-VM handoff gate (`SymphonyElixir.Acp.LinearGate`) built for ACP.

The backends are mutually exclusive per deployment and selected by config. The
Codex path is unchanged and remains the default; choosing `claude_code` swaps
the wire protocol and the agent binary but keeps the same Symphony lifecycle,
handoff gate, and observability transcript.

## Enabling Claude Code

In your host config (`~/.symphony/config.yml`) or single-repo `WORKFLOW.md`
front matter:

```yaml
agent:
  backend: claude_code     # "codex" (default) | "acp" | "claude_code"
claude_code:
  command: claude          # base launch command (the binary)
  model: opus              # optional; passed as --model
```

`agent.backend` defaults to `codex`. When set to `claude_code`,
`claude_code.command` must be non-empty (it defaults to `claude`).

### `claude_code` options

| Field | Default | Meaning |
|---|---|---|
| `command` | `claude` | Base launch command (the binary). Symphony appends the stream-json / mcp-config flags. |
| `model` | _(unset)_ | Passed as `--model` (e.g. `opus`, `claude-fable-5`). Unset ⇒ Claude Code's own resolution. |
| `permission_mode` | `bypassPermissions` | Passed as `--permission-mode`. One of `default`, `acceptEdits`, `bypassPermissions`, `auto`, `dontAsk`, `plan`. Mirrors Codex `approval_policy: never` for non-interactive runs. |
| `extra_args` | `[]` | Extra raw CLI args appended verbatim (e.g. `["--append-system-prompt", "..."]`). |
| `prompt_timeout_ms` | `3_600_000` | Max wall-clock for one turn. |
| `stall_timeout_ms` | `300_000` | Idle timeout between streamed events during a turn. |
| `withhold_linear_credentials` | `true` | **Load-bearing.** Scrub `LINEAR_API_KEY` (and friends) from the agent's process env. |

## How it works

Symphony launches:

```
claude -p \
  --output-format stream-json --input-format stream-json --verbose \
  --permission-mode <permission_mode> --add-dir <workspace> \
  --mcp-config '{"mcpServers":{"symphony-linear":{"type":"http","url":"http://127.0.0.1:<port>/mcp/<token>"}}}' \
  --strict-mcp-config [--model <model>] [extra_args…]
```

1. **Session.** `start_session` spawns the `claude -p` process (it waits on
   stdin) and starts the per-session in-VM gate listener. There is no
   `initialize`/`session/new` handshake on the wire — the session id arrives in
   Claude's first `system/init` event, after the first user message.
2. **Turn.** Each Symphony turn writes one stream-json user-message line to
   stdin. Streamed `assistant` content blocks (`text`, `thinking`, `tool_use`),
   `tool_result`s, and `system`/`result` events are normalized into Symphony's
   existing transcript shape, so the dashboard and CLI renderer render Claude
   Code turns with no Claude-specific rendering code (same synthetic
   `item/agentMessage/delta` / `item/reasoning/textDelta` / `item/tool/call` /
   `item/commandExecution/outputDelta` methods the ACP backend emits).
3. **Completion.** The terminal `result` message carries `stop_reason` /
   `is_error` / `subtype`: a successful result ⇒ completed (`max_tokens` /
   `max_turn_requests` complete with a note); any error result ⇒ abnormal.

The same persistent process serves multiple Symphony turns: each subsequent
user-message line starts a new turn that ends in its own `result`.

## The handoff gate (how it holds)

Identical guarantee to the ACP path — and structurally lower-risk:

- The gated `linear_graphql` tool is served by the **same in-VM MCP HTTP
  endpoint** (`SymphonyElixir.Acp.LinearGate`) advertised to Claude Code via
  `--mcp-config` (HTTP MCP servers are documented and first-class). When the
  agent calls the tool, the call is dispatched **back into the run's own
  process**, where `DynamicTool.execute/3` runs the `before_handoff` hook +
  reviewer gate with the run's context and counters intact — byte-for-byte the
  same gate as Codex.
- **`--strict-mcp-config`** makes the agent use *only* the servers Symphony
  passed, ignoring every other MCP source — an explicit lock, stronger than the
  ACP path's implicit "we just didn't pass a Linear MCP".
- **Credential withholding is the hard guarantee.** The agent is given no Linear
  token in its env (`claude_code.withhold_linear_credentials`) and no other
  Linear MCP — only Symphony's gated channel, whose token stays server-side. A
  bypass attempt has no credential and fails, so the gate holds even if the
  agent ignores guidance.

Claude Code authentication (`ANTHROPIC_API_KEY` / a logged-in session /
Bedrock/Vertex) passes through unchanged — Symphony scrubs only Linear
credentials.

## Limitations

- **Local only.** The in-VM gate listens on Symphony's loopback, which a remote
  worker host cannot reach. `claude_code` on a `worker.ssh_hosts` host is **not
  supported** — Symphony logs a warning. Use the Codex backend for remote
  workers.
- **No per-write approval interception.** With `bypassPermissions` (the
  default), Claude Code uses its own file/exec tools inside the workspace;
  Symphony does not intercept individual writes. The handoff gate still holds
  via credential withholding.

## Reference version

Verified against `claude` **2.1.178**: `claude -p` stream-json completes a turn
and emits a terminal `result`, connects to a client-passed `--mcp-config` HTTP
MCP server (`initialize` → `tools/list` → `tools/call`) and the model invokes
the gated tool, all with no Linear credentials in env. Symphony's decoder is
tolerant of unknown event types (they surface as generic notifications). See
`docs/acp-support-plan.md` §14 for the go/no-go details and
`test/symphony_elixir/claude_code/live_acceptance_test.exs`
(`LIVE_CLAUDE_CODE=1`) for the live acceptance run.
```
LIVE_CLAUDE_CODE=1 mix test test/symphony_elixir/claude_code/live_acceptance_test.exs
# optional: pin the model (default "haiku")
LIVE_CLAUDE_CODE=1 CLAUDE_CODE_LIVE_MODEL=opus mix test test/...
```
