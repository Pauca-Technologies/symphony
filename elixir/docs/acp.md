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
| `model` | _(unset)_ | Model id, e.g. `opencode/north-mini-code-free`. **OpenCode-only** (see below). |
| `auto_approve` | `true` | Auto-approve `session/request_permission` instead of blocking the turn (mirrors Codex `approval_policy: never`). |
| `protocol_version` | `1` | ACP protocol version sent in `initialize`. |
| `withhold_linear_credentials` | `true` | **Load-bearing.** Scrub `LINEAR_API_KEY` (and friends) from the agent's process env. |
| `advertise_fs` | `false` | Advertise client `fs/*` capability. False ⇒ the agent uses its own file tools. |
| `advertise_terminal` | `false` | Advertise client `terminal/*` capability. False ⇒ the agent uses its own exec tools. |
| `prompt_timeout_ms` | `0` | Optional wall-clock ceiling for one `session/prompt` turn; `0` disables it. |
| `read_timeout_ms` | `5_000` | Handshake (`initialize` / `session/new`) response timeout. |
| `stall_timeout_ms` | `300_000` | Idle timeout between streamed `session/update`s during a turn. |
| `heartbeat_ms` | `30_000` | While a turn is idle, emit a `:notification` "still waiting" heartbeat (and log line) every this-many ms, so a silent/stalled turn shows a visible countdown to `stall_timeout_ms` instead of dead air. `0` disables. See the stall note below. |

### Selecting the model

ACP has no protocol field for the model, and Symphony's `session/new` does not
set one — each agent picks its model from its own configuration. For **OpenCode**
specifically, `opencode acp` rejects a `--model` flag and ignores `OPENCODE_MODEL`,
but honors inline config via `OPENCODE_CONFIG_CONTENT`. So setting `acp.model`
injects `OPENCODE_CONFIG_CONTENT={"model":"<acp.model>"}` into the agent's env:

```yaml
acp:
  command: opencode acp
  model: opencode/north-mini-code-free   # provider/model-id
```

This field is OpenCode-specific. Other ACP agents (e.g. a Claude Code ACP bridge)
ignore `OPENCODE_CONFIG_CONTENT` and select their model through their own
config/auth; leave `acp.model` unset for them. Without `acp.model`, OpenCode
falls back to its own resolution order (workspace `opencode.jsonc`, then global
config). Note OpenCode Zen free models are rate-limited per-model and report
throttling only in `~/.local/share/opencode/log/opencode.log`, not over ACP — a
throttled model surfaces as a turn stall (`stall_timeout_ms`). While the turn is
idle, Symphony emits a "still waiting" heartbeat every `heartbeat_ms` (default
30s) so the silence is visible rather than dead air; lower `stall_timeout_ms` if
you want a throttled turn to fail faster (at the cost of false positives on
legitimately long-but-quiet operations).

## How it works

1. **Handshake.** `initialize` (protocol version + client capabilities) →
   `session/new` (cwd + `mcpServers`) → a `sessionId`.
2. **Turn.** Each Symphony turn is one `session/prompt`. Streaming
   `session/update` notifications are forwarded verbatim and rendered
   **natively** by the observability pipeline, which dispatches on the
   `update.sessionUpdate` discriminator: `agent_message_chunk` → agent text,
   `agent_thought_chunk` → reasoning, `tool_call` → a tool block that surfaces
   the ACP tool **kind** (read/edit/execute/…), `tool_call_update` → command
   output, and `plan` → a checklist block. ACP-only data (tool kinds, plans) is
   preserved instead of being flattened into a Codex shape. The Codex and Claude
   Code paths are untouched — they keep their own rendering branches.
3. **Completion.** The `session/prompt` response carries a `stopReason`:
   `end_turn` ⇒ completed; `refusal`/`cancelled` ⇒ abnormal; `max_tokens` /
   `max_turn_requests` ⇒ completed with a note.

## The handoff gate (how it holds)

The Codex path enforces the `In Progress → In Review` handoff gate by
intercepting Linear writes through Symphony's `linear_graphql` dynamic tool.
ACP has no `dynamicTools`, so Symphony exposes the **same server-authenticated
Linear tool** through an in-VM MCP HTTP endpoint listed in
`session/new.mcpServers`:

- The endpoint runs on Symphony's loopback (a per-session listener). When the
  agent calls `linear_graphql`, the call is dispatched **back into the run's
  own process**. The tool runs the
  `before_handoff` hook + reviewer gate for review-state mutations with the
  run's context and counters intact — byte-for-byte the same gate as Codex.
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
