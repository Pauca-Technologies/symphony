# ACP backend (Agent Client Protocol)

Symphony can drive a coding agent through the **Agent Client Protocol (ACP)** as
an alternative to the default Codex app-server backend. ACP is the editor-agent
standard spoken by [OpenCode](https://opencode.ai) (`opencode acp`), Gemini CLI,
Qwen Code, and (via bridges) Claude Code.

The two backends are mutually exclusive per deployment and selected by config.
The Codex path is unchanged and remains the default; choosing ACP swaps the wire
protocol and the agent binary but keeps the same Symphony lifecycle, handoff
gate, and observability transcript.

## Enabling ACP

In your host config (`~/.symphony/config.yml`) or single-repo `WORKFLOW.md`
front matter:

```yaml
agent:
  backend: acp          # "codex" (default) | "acp"
acp:
  command: opencode acp # stdio ACP agent launch command
```

`agent.backend` defaults to `codex`. When set to `acp`, `acp.command` must be
non-empty (it defaults to `opencode acp`).

### `acp` options

| Field | Default | Meaning |
|---|---|---|
| `command` | `opencode acp` | Shell command that launches the ACP agent over stdio. |
| `auto_approve` | `true` | Auto-approve `session/request_permission` instead of blocking the turn (mirrors Codex `approval_policy: never`). |
| `protocol_version` | `1` | ACP protocol version sent in `initialize`. |
| `withhold_linear_credentials` | `true` | **Load-bearing.** Scrub `LINEAR_API_KEY` (and friends) from the agent's process env. |
| `advertise_fs` | `false` | Advertise client `fs/*` capability. False ⇒ the agent uses its own file tools. |
| `advertise_terminal` | `false` | Advertise client `terminal/*` capability. False ⇒ the agent uses its own exec tools. |
| `prompt_timeout_ms` | `3_600_000` | Max wall-clock for one `session/prompt` turn. |
| `read_timeout_ms` | `5_000` | Handshake (`initialize` / `session/new`) response timeout. |
| `stall_timeout_ms` | `300_000` | Idle timeout between streamed `session/update`s during a turn. |

## How it works

1. **Handshake.** `initialize` (protocol version + client capabilities) →
   `session/new` (cwd + `mcpServers`) → a `sessionId`.
2. **Turn.** Each Symphony turn is one `session/prompt`. Streaming
   `session/update` notifications are normalized into Symphony's existing
   transcript shape, so the dashboard renders ACP turns with no ACP-specific
   rendering code (agent text, reasoning, tool calls, command output).
3. **Completion.** The `session/prompt` response carries a `stopReason`:
   `end_turn` ⇒ completed; `refusal`/`cancelled` ⇒ abnormal; `max_tokens` /
   `max_turn_requests` ⇒ completed with a note.

## The handoff gate (how it holds)

The Codex path enforces the `In Progress → In Review` handoff gate by
intercepting Linear writes through Symphony's `linear_graphql` dynamic tool.
ACP has no `dynamicTools`, so Symphony exposes the **same gated tool** through an
in-VM MCP HTTP endpoint listed in `session/new.mcpServers`:

- The endpoint runs on Symphony's loopback (a per-session listener). When the
  agent calls `linear_graphql`, the call is dispatched **back into the run's
  own process**, where `DynamicTool.execute/3` runs the `before_handoff` hook +
  reviewer gate with the run's context and counters intact — byte-for-byte the
  same gate as Codex.
- **Credential withholding is the hard guarantee.** The agent is given no Linear
  token in its env and no native Linear MCP server — only Symphony's gated
  channel, whose token stays server-side. A bypass attempt (the model `curl`-ing
  `api.linear.app`, or its own Linear integration) has no credential and fails.
  The gate therefore holds *even if the agent ignores guidance and ignores
  permission requests*.
- A best-effort permission-deny layer (mirroring the Codex native-Linear deny
  heuristic) is defense-in-depth only.

## Limitations (Phase 2)

- **Local only.** The in-VM gate listens on Symphony's loopback, which a remote
  worker host cannot reach. ACP on a `worker.ssh_hosts` host is **not
  supported** in this phase — Symphony logs a warning. Use the Codex backend for
  remote workers.
- **`fs` / `terminal` advertised false.** The agent uses its own file/exec tools
  inside the workspace; Symphony does not intercept per-write approvals on the
  ACP path. (Revisit in a later phase if interception is needed.)
- **No subagent multiplexing and no post-completion JSONL audit** — ACP has
  neither; the backend trusts `stopReason`.

## Reference agent / version pinning

ACP and OpenCode are young; pin a known-good `opencode` version in your
deployment. Symphony's decoder is tolerant of unknown `session/update` types
(they surface as generic notifications). Verified against `opencode` **1.17.4**:
it advertises `mcpCapabilities {http:true, sse:true}`, connects to a
client-passed HTTP MCP server at session creation, and invokes the gated tool
from a prompt — all with no credentials in env. See
`docs/acp-support-plan.md` §12 for the spike details.
