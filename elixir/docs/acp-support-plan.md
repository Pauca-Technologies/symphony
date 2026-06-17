# Implementation Plan — Add ACP (Agent Client Protocol) backend alongside Codex app-server

**Branch:** `acp-support` (cut from `udp`)
**Status:** plan / not yet implemented
**Guiding constraint:** *additive only*. The Codex app-server path must keep working byte-for-byte. ACP is a second, config-selected backend. No Codex behavior is removed or changed; the Codex tests stay green untouched.

**Ship blocker:** ACP must enforce a Linear handoff gate equivalent to the Codex path (`before_handoff` + reviewer `ReviewGate`). Shipping ACP without it is a correctness regression — an ACP agent that can move a Linear issue In Progress → In Review by any path Symphony doesn't mediate bypasses the gate. The gate is in the **MVP scope (Phase 2)**, not deferred. See §5.5 and §9 (go/no-go spike).

---

## 1. Why / what

Symphony today drives exactly one kind of coding agent: **OpenAI Codex in `app-server` mode**, speaking the Codex JSON-RPC-over-stdio protocol (`initialize` → `thread/start` → `turn/start` + streaming `item/*`/`turn/*` notifications, with the client answering `requestApproval` / `item/tool/call`). See `lib/symphony_elixir/codex/app_server.ex`.

We want to also support agents that speak the **Agent Client Protocol (ACP)** — the editor-agent standard used by OpenCode (`opencode acp`), Gemini CLI, Qwen Code, and (via bridges) Claude Code. ACP is *also* JSON-RPC-over-stdio and structurally similar, but it is a **different wire protocol** (`initialize` → `session/new` → `session/prompt`; streaming `session/update`; client implements `session/request_permission`, `fs/*`, `terminal/*`). It is **not** the Codex app-server protocol — method names, message shapes, and the direction of tool/permission flow all differ.

Reference target for testing: **OpenCode** (`opencode acp`), because it ships ACP today and runs the same models (incl. Kimi K2 via Moonshot). Note: *Kimi Code CLI itself has no ACP/headless mode*, so the ACP backend reaches Kimi only by running it as the model under an ACP-capable agent like OpenCode — see `find-clients` analysis. The plan is protocol-level, so any ACP agent works.

---

## 2. The integration contract Symphony actually depends on

Everything downstream of the agent depends on a small Elixir-side surface, **not** on Codex specifics. A new backend that honors this surface drops in cleanly.

### 2.1 The call surface (what `AgentRunner` invokes)
`lib/symphony_elixir/agent_runner.ex` (`run_codex_turns/5` → `do_run_codex_turns/8`) only ever calls three functions:

```elixir
{:ok, session}      = AppServer.start_session(workspace, worker_host: worker_host)
{:ok, turn_session} = AppServer.run_turn(session, prompt, issue, on_message: fn, tool_executor: fn)
:ok                 = AppServer.stop_session(session)
```

- `start_session/2` returns an opaque session map (must carry `:worker_host`; the rest is backend-private).
- `run_turn/4` runs one turn, streaming events via the `on_message` callback, and returns `{:ok, %{session_id: ..., ...}}` or `{:error, reason}`. The loop calls it repeatedly on the same session for multi-turn continuation.
- `tool_executor.(tool, arguments)` executes a Symphony dynamic tool (today: `linear_graphql`) and returns a result map.

### 2.2 The event vocabulary (what `on_message` emits)
`on_message` receives `%{event: atom, timestamp: DateTime, payload: map, raw: string, ...metadata}`. The orchestrator forwards anything matching `%{event: _, timestamp: _}` (`orchestrator.ex:252`). The atoms the Codex backend emits — and which the dashboard/transcript pipeline understands — are:

`:session_started`, `:turn_completed`, `:turn_failed`, `:turn_cancelled`, `:turn_completed_abnormally`, `:turn_ended_with_error`, `:startup_failed`, `:notification`, `:other_message`, `:malformed`, `:subagent_turn_event`, `:tool_call_completed`, `:tool_call_failed`, `:unsupported_tool_call`, `:approval_auto_approved`, `:approval_required`, `:turn_input_required`, `:tool_input_auto_answered`, `:turn_interruption_signal`.

**The ACP backend must reuse these same atoms** so the existing orchestrator/presenter/renderer keep working with zero downstream branching on backend type.

### 2.3 The observability pipeline (event-driven, not file-based)
The transcript is built from the **live `on_message` stream**, not from a Codex-written log file:
- `orchestrator.ex:1750` appends each update to *Symphony's own* NDJSON at `codex_session_logs_dir()` (`codex_session_log_record/2`).
- `orchestrator.ex:1538 transcript_block_for_update/2` branches on **`payload["method"]`** (Codex method names) and extracts text via path lists (`agent_text_paths/0`, `output_text_paths/0`, `reasoning_text_paths/0`, etc.).
- `Presenter` (`presenter.ex:278`) and `CodexSessionLogRenderer` render those records.

This is the one place the ACP payload shape diverges from Codex's. Two options (see §6).

### 2.4 Transport/runtime concerns already solved for Codex (reusable)
`app_server.ex` already implements, backend-agnostically: workspace cwd validation + symlink-escape guard (`validate_workspace_cwd/2`), sourced-`.env` sanitization (`prepare_sourced_env_files/2`), local `Port.open` with `SYMPHONY_RUN`/`SYMPHONY_AGENT` env, remote launch over `SSH.start_port/3`, line-framed stdio (`@port_line_bytes`), and `stop_port/1`. **These must be extracted and shared, not reimplemented.**

---

## 3. Codex ↔ ACP mapping (the heart of the new backend)

| Concern | Codex app-server | ACP | Notes for backend |
|---|---|---|---|
| Framing | NDJSON, **no** `"jsonrpc"` field | NDJSON, **includes** `"jsonrpc":"2.0"` | ACP encoder must add the field; decoder tolerant either way |
| Handshake | `initialize` (capabilities.experimentalApi) + `initialized` | `initialize` (protocolVersion int, clientCapabilities `{fs,terminal}`) | negotiate `protocolVersion`; advertise capabilities (§5.3) |
| Open conversation | `thread/start` (approvalPolicy, sandbox, cwd, dynamicTools) | `session/new` (cwd, **mcpServers[]**, additionalDirectories) → `sessionId` | dynamicTools has **no ACP equivalent** → bridge via MCP (§5.4) |
| Run a turn | `turn/start` (threadId, input[], title, sandboxPolicy) → turnId | `session/prompt` (sessionId, prompt content blocks) | one `run_turn` = one `session/prompt` |
| Turn finished | `turn/completed` notification | `session/prompt` **response** with `stopReason` | `end_turn`→`:turn_completed`; `cancelled`/`refusal`→abnormal; `max_tokens`/`max_turn_requests`→completed-with-note |
| Agent text | `item/agentMessage/delta` notif | `session/update` `agent_message_chunk` | normalize (§6) |
| Reasoning | `item/reasoning/textDelta` notif | `session/update` `agent_thought_chunk` | normalize |
| Command output | `item/commandExecution/outputDelta` | `session/update` `tool_call_update` (content: terminal) | normalize |
| Tool call (visibility) | `item/tool/call` request→client | `session/update` `tool_call` / `tool_call_update` notif | ACP tool calls are notifications, not client requests |
| Plan/TODO | (none) | `session/update` `plan` | optional new transcript block |
| Command approval | server **requests** `item/commandExecution/requestApproval` | agent **requests** `session/request_permission` (options: allow_once/allow_always/reject_once/reject_always) | mirror auto-approve logic; pick `allow_always` option when auto-approving |
| File-write approval | `item/fileChange/requestApproval` | covered by `session/request_permission` for the write tool | same handler |
| File IO | agent does its own | agent **may** call `fs/read_text_file` / `fs/write_text_file` on client | advertise `fs:false` initially → agent uses own tools (§5.3) |
| Terminal | n/a | agent **may** call `terminal/*` | advertise `terminal:false` initially |
| Operator question | `item/tool/requestUserInput` | (no first-class equiv; surfaces via permission/prompt) | non-interactive: reject/deny by default |
| Custom tool (`linear_graphql`) | `dynamicTools` in `thread/start` | **MCP server** in `session/new.mcpServers` | requires a stdio MCP shim (§5.4) |
| Subagent multiplexing | multiple threads on one connection (`foreign_turn_terminal_event?`) | single sessionId, no multiplexing | Codex-only logic; ACP backend skips it |
| Post-completion audit | re-reads Codex thread JSONL for `turn_aborted` | none | ACP trusts `stopReason`; no audit |
| Cancel | close port | `session/cancel` notification then close | add graceful cancel |

---

## 4. Architecture

Introduce a thin **backend behaviour** and select the implementation by config. Model it on the existing `SymphonyElixir.Tracker` behaviour + `Linear.Adapter`/`Tracker.Memory` precedent (`tracker.ex:8`).

```
SymphonyElixir.AgentBackend            (new behaviour)
├── SymphonyElixir.Codex.AppServer     (existing — add `@behaviour`, no logic change)
└── SymphonyElixir.Acp.Client          (new ACP implementation)

SymphonyElixir.AgentTransport          (new — extracted Port/SSH/env/cwd/sourced-env)
SymphonyElixir.Acp.Mcp.LinearServer    (new — stdio MCP shim exposing linear_graphql)
```

```elixir
defmodule SymphonyElixir.AgentBackend do
  @callback start_session(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback run_turn(map(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback stop_session(map()) :: :ok
end
```

`AgentRunner` resolves the module once and dispatches dynamically:

```elixir
backend = SymphonyElixir.AgentBackend.resolve()   # reads config; default Codex.AppServer
{:ok, session} = backend.start_session(workspace, worker_host: worker_host)
```

---

## 5. Work breakdown

### 5.1 Config (`lib/symphony_elixir/config/schema.ex`, `config.ex`)
- Add a backend selector. Keep `codex` block as-is. Two reasonable shapes — **recommend** adding `field(:backend, :string, default: "codex")` to the existing `agent` schema (selector lives with other agent settings) plus a new sibling `Acp` embedded schema:
  ```elixir
  defmodule Acp do
    embedded_schema do
      field(:command, :string, default: "opencode acp")
      field(:auto_approve, :boolean, default: true)   # mirrors codex approval_policy == "never"
      field(:protocol_version, :integer, default: 1)
      field(:linear_gate_transport, :string, default: "http")  # "http" | "sse" | "stdio" — see §5.5
      field(:withhold_linear_credentials, :boolean, default: true)  # never put LINEAR_API_KEY in agent env
      field(:advertise_fs, :boolean, default: false)
      field(:advertise_terminal, :boolean, default: false)
      field(:prompt_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
    end
  end
  ```
  - `withhold_linear_credentials` defaults true and is the load-bearing safety property (§5.5); making it false should be impossible to do silently — validate that disabling it is paired with an explicit ack, or drop the field and hard-code it.
- `embeds_one(:acp, Acp, ...)`; cast in `Settings.changeset`; add `Config.acp_runtime_settings/1,2` mirroring `codex_runtime_settings`.
- Validate: when `backend == "acp"`, require `acp.command`.

### 5.2 Behaviour + Codex conformance
- New `lib/symphony_elixir/agent_backend.ex` with the callbacks above plus `resolve/0` (reads `Config`, maps `"codex"`→`Codex.AppServer`, `"acp"`→`Acp.Client`).
- Add `@behaviour SymphonyElixir.AgentBackend` to `Codex.AppServer`. Its existing `start_session/2`, `run_turn/4`, `stop_session/1` already match — **no logic change**, compile-time conformance only.

### 5.3 Shared transport (`lib/symphony_elixir/agent_transport.ex`)
Extract from `app_server.ex` (move, then have `AppServer` delegate so its behavior is identical):
`validate_workspace_cwd/2`, `prepare_sourced_env_files/2` + sanitizers, `start_port/2` (local + SSH), `agent_env/0`, `remote_launch_command/1` (parameterized by command), `port_metadata/2`, `stop_port/1`, line-framed `send_message`/receive helpers. Both backends call these with their own configured command. *Lowest-risk sequencing:* keep the functions in `AppServer` initially and have `Acp.Client` call them, then extract in a follow-up once green — avoids churning the Codex module first.

### 5.4 ACP client (`lib/symphony_elixir/acp/client.ex`) — the bulk of the work
Implement `AgentBackend`:

**`start_session/2`**: validate cwd → sanitize sourced env → spawn `acp.command` via shared transport → `initialize` (send `protocolVersion`, `clientInfo`, `clientCapabilities` from config `advertise_fs`/`advertise_terminal`) → await result, store negotiated `protocolVersion` + `agentCapabilities` → `session/new` (cwd, `mcpServers` from §5.5) → store `sessionId`. Return session map `%{port:, session_id:, worker_host:, auto_approve:, agent_capabilities:, metadata:}`.

**`run_turn/4`**: send `session/prompt` (id N) with `prompt: [%{"type"=>"text","text"=>prompt}]`. Emit `:session_started`. Enter a receive loop that:
- Handles **agent→client requests** (have `"id"` + `"method"`), responding on the port:
  - `session/request_permission` → mirror `auto_approve`: if true, respond `outcome: %{outcome: "selected", optionId: <allow_always option>}` and emit `:approval_auto_approved`; else emit `:approval_required` and end turn `{:error, {:approval_required, payload}}` (parity with Codex `approve_or_require/8`).
  - `fs/read_text_file` / `fs/write_text_file` → only reachable if we advertised `fs:true`; phase 1 advertises false, so respond method-not-found defensively.
  - `terminal/*` → same (advertise false in phase 1).
- Handles **notifications** (`session/update`): translate each `update.type` into an `on_message` event (§6) and continue.
- Detects turn end: the **`session/prompt` response** (matched by id N) carries `stopReason`. Map → `:turn_completed` (end_turn) / `:turn_completed_abnormally` (refusal/cancelled, also emit `:turn_interruption_signal` for cancelled) / `:turn_completed` with note (max_tokens/max_turn_requests). Return `{:ok, %{session_id:, stop_reason:}}` or `{:error, ...}`.
- Timeouts: reuse `read_timeout_ms` (handshake), `prompt_timeout_ms` (turn), `stall_timeout_ms` (idle between updates).

**`stop_session/1`**: best-effort `session/cancel` then `stop_port`.

No subagent multiplexing, no post-completion file audit (ACP has neither).

### 5.5 Linear handoff gate for ACP — **ship blocker (Phase 2 MVP)**

The handoff gate is the reason `linear_graphql` exists. When the agent attempts an `issueUpdate` crossing a handoff transition (In Progress → In Review/Human Review, per `HandoffGate.handoff_transition?`), `DynamicTool.execute` **intercepts the write**, runs `before_handoff` + the reviewer `ReviewGate`, and only then applies the mutation — otherwise it blocks with remediation (`dynamic_tool.ex:113-157`). ACP must enforce an *equivalent* gate. Two non-obvious facts drive the design (both verified in code):

1. **The gate must run inside Symphony's VM, in the per-issue orchestrating process.** `DynamicTool.execute` runs *in AgentRunner's process* today: it closes over `handoff_gate_context` (issue, workspace, loaded `review_workflow`, per-repo `before_handoff` command) and uses the **process dictionary** for deferred review (`agent_runner.ex:403`) and reviewer dedup/iteration counters (`review_gate.ex:642-667`). A standalone stdio-MCP subprocess would run the gate in a *different OS process* with none of this context — silently no-op'ing the gate. So the ACP tool channel must route each call **back into the session's Symphony process**, never execute the gate standalone.

2. **The hard guarantee is credential withholding, not the agent's good behavior.** Even on Codex the agent has no Linear token of its own — `linear_graphql` uses Symphony's server-side auth (`Client.graphql/3`). The native-Linear deny heuristic (`app_server.ex:1312 deny_linear_save_issue_request?`) is only a secondary guard against a consumer-configured Linear MCP. We carry the same model to ACP and make withholding the *load-bearing* guarantee.

**Design (all Phase 2):**

- **Gated tool channel, in-VM.** Expose `linear_graphql` as the *only* sanctioned Linear path, served by a Symphony-owned **in-VM MCP endpoint** — not an external subprocess. OpenCode supports remote/HTTP MCP servers and ACP `session/new.mcpServers` accepts `type: "http"`/`"sse"`, so `Acp.Client.start_session/2` passes `%{type: "http", url: "http://127.0.0.1:<port>/acp/mcp/<session_token>"}`. The endpoint resolves `<session_token>` → the per-issue session process and executes the tool **via `GenServer.call` into that process**, so `handoff_gate_context`, deferred review, and dedup counters work exactly as on Codex. The handler reuses `DynamicTool.execute/3` **unchanged** — only the *transport* and the *process it runs in* differ. (Fallback, if the chosen agent supports stdio MCP only: a thin stdio shim that RPCs back to the node over a local authenticated socket — same in-VM execution, more plumbing. Selected by `acp.linear_gate_transport`.)

- **Withhold all other Linear access.** Symphony gives the agent (a) **no** native Linear MCP server and (b) **no** `LINEAR_API_KEY` in its env (`acp.withhold_linear_credentials`). The gated MCP tool holds the token server-side. A bypass attempt (model `curl`-ing `api.linear.app`, or its own Linear integration) then has no credential and fails — the gate cannot be routed around *even if the agent ignores instructions and ignores permission requests*. This is what makes the gate hold without depending on unverified agent behavior.

- **Bypass denial (defense-in-depth, parity with Codex).** Mirror `deny_linear_save_issue_request?`: intercept `session/request_permission` and deny any tool call targeting a Linear write (native Linear MCP `save_issue`, or a shell command hitting `api.linear.app`). Best-effort and dependent on the agent honoring permission requests (see §9 spike), so strictly *on top of* credential withholding — never the sole guarantee.

- **Prompt guidance.** Reuse `agent_runner.ex:503 handoff_tool_guidance/1` so the agent is told the only handoff path is Symphony's `linear_graphql` tool.

- **Process coordination.** The ACP turn loop runs in (or is owned by) AgentRunner's process; MCP tool calls are dispatched to that process so the existing `Process`-dictionary deferred-review/counter semantics hold with no change. Optional follow-up: lift deferred-review/counter state into explicit session state (a contained refactor shared by both backends) to drop the process-dictionary coupling — but routing-to-the-owning-process preserves today's behavior with zero Codex change, so it is not required to ship.

**Files (as built):** `lib/symphony_elixir/acp/linear_gate.ex` — note the implementation chose a **per-session dedicated Bandit listener** (the "tiny dedicated listener" option) over "mounted on the Phoenix endpoint + a global session-token registry". Each ACP session starts its own loopback listener on an OS-assigned port whose path carries a per-session token, so there is **no separate token registry**: the session pid and token are the listener's own plug state, and the listener is started/stopped by `Acp.Client` over the session lifecycle. The nested `LinearGate.McpPlug` implements the MCP Streamable-HTTP server; `LinearGate.dispatch_tool_call/4` is the send/receive hop into the session process. `Acp.Client.start_session/2` emits the `mcpServers` entry (`LinearGate.mcp_server_entry/1`) and scrubs Linear creds from the agent env. `DynamicTool`, `HandoffGate`, `ReviewGate` reused unchanged.

**Gate parity acceptance:** an ACP run whose `before_handoff` hook fails, and one whose reviewer requests changes, must each **block** the In Progress → In Review transition and surface the same remediation the Codex path does — proven by test before ACP is enabled anywhere.

### 5.6 Observability normalization (§6) — see next section.

### 5.7 AgentRunner wiring (`agent_runner.ex`)
- Replace the hardcoded `alias ...AppServer` dispatch in `run_codex_turns/5`/`do_run_codex_turns/8` with `backend = AgentBackend.resolve()` and `backend.start_session/run_turn/stop_session`. Names like `run_codex_turns` can stay (cosmetic) or be renamed `run_agent_turns` in a follow-up — **no behavior change** either way.
- `tool_executor` already abstracts the tool layer; for ACP it's only invoked if the MCP shim routes back through it (otherwise unused on the ACP path).

### 5.8 Docs
- New `docs/acp.md`: how to enable (`agent.backend = "acp"`, `acp.command = "opencode acp"`), capabilities/limitations, the handoff-gate caveat.
- README: add ACP as an alternative backend next to the Codex app-server line.

---

## 6. Observability strategy (decision)

The transcript pipeline keys on Codex `payload["method"]` strings (`orchestrator.ex:1543`). ACP payloads don't have those. Two options:

- **Option A (recommended for Phase 1) — normalize in the backend.** `Acp.Client` translates each `session/update` into the *existing* `on_message` shape, synthesizing a `payload["method"]` the orchestrator already understands and placing text at the existing extraction paths. Mapping:
  - `agent_message_chunk` → method `"item/agentMessage/delta"`, text at agent path
  - `agent_thought_chunk` → a reasoning method, text at reasoning path
  - `tool_call_update` (terminal content) → `"item/commandExecution/outputDelta"`
  - `tool_call` → `"item/tool/call"` (tool block)
  - `plan` → either drop or map to a new compaction-like block
  **Blast radius: entirely inside the new module.** Zero changes to orchestrator/presenter/renderer → guarantees the Codex path is untouched. Keep `raw` = the real ACP JSON for fidelity.

- **Option B (follow-up) — teach the renderer ACP natively — ✅ DONE (Phase 4, 2026-06-17).** Added a `method == "session/update"` branch to `transcript_block_for_update/2`, `Presenter.transcript_fragment/1`, and `CodexSessionLogRenderer.dispatch_payload/5`, dispatching on `update.sessionUpdate`. Surfaces ACP-only data (tool **kinds**, **plan** checklists) that Option-A flattening dropped. The edit is purely additive — the existing Codex/Claude-Code method branches are untouched — so Codex (and Claude Code, which keeps Option-A normalization) render byte-for-byte as before; the full Codex/Claude suites pass unchanged. The ACP backend switched from Option-A synthesis to native `session/update` pass-through.

Either way, generalize log-dir/field names only cosmetically; `codex_session_logs` can stay as the internal key to avoid a wide rename in Phase 1.

---

## 7. Testing

Mirror the existing harness in `test/symphony_elixir/app_server_test.exs` (63 KB): tests write a **fake agent shell script** that emits canned JSON-RPC lines and read stdin, then point the configured command at it. For ACP:
- `test/support/` fake ACP agent script(s): emit `initialize` result, `session/new` result, stream `session/update` notifications, optionally issue a `session/request_permission` request, then return a `session/prompt` response with a chosen `stopReason`.
- `test/symphony_elixir/acp/client_test.exs`:
  - handshake + session/new (capabilities, mcpServers wiring)
  - happy-turn → `:turn_completed`, returned `session_id`
  - permission auto-approve vs `:approval_required` when `auto_approve=false`
  - each `stopReason` → correct event/result mapping
  - timeout paths (read/prompt/stall)
  - cwd guard + sourced-env sanitization reuse (parity with Codex tests)
  - normalization (Option A): assert emitted `on_message` events match the existing atoms and payload paths
- `agent_backend_test.exs`: `resolve/0` returns Codex by default, ACP when configured.
- Config tests: extend `workspace_and_config_test.exs` for the new `acp` block + selector defaults/validation.
- **Regression guard:** run the full existing suite — `app_server_test.exs`, `codex_session_log_renderer_test.exs`, `orchestrator_status_test.exs`, `agent_runner_test.exs` must pass unchanged.

---

## 8. Phasing

0. **Go/no-go spike — ✅ RESOLVED (verified 2026-06-15, opencode 1.17.4). Result: GO.** Empirically confirmed against the real `opencode acp` binary that it accepts a client-passed `session/new.mcpServers` HTTP entry and **connects to it** (full MCP handshake → `tools/list`), advertises `mcpCapabilities {http:true, sse:true}`, and creates a session **with no credentials in env**. Details + reproduction in §12. The gated-Linear-path approach is viable for OpenCode; proceed to build.
1. **Scaffolding (no behavior change) — ✅ DONE (2026-06-15).** `AgentBackend` behaviour + `resolve/0`; `@behaviour` on `Codex.AppServer`; inert `Acp.Client` stub; `AgentRunner` dispatches via `resolve/0` (threads `backend` through the turn loop); `agent.backend` config selector (`"codex"` default, validated `["codex","acp"]`). The full `acp` config block (§5.1) is deferred to Phase 2 with the real client — only the selector was needed to dispatch. Verified: `mix compile --warnings-as-errors` clean; full suite **427 passed / 0 failed / 2 pre-existing skips**; new `agent_backend_test.exs` (5 tests). Default `backend = "codex"` → byte-for-byte unchanged Codex path.
2. **ACP MVP — includes the Linear gate (first shippable ACP) — ✅ DONE (2026-06-15, including live acceptance).** Implemented:
   - `SymphonyElixir.AgentTransport` — shared cwd validation / sourced-env sanitization / `start_port` (local + SSH) / line-framed stdio / `stop_port`, parameterized by command + env (ACP-only consumer; Codex untouched, AppServer-delegation is a follow-up).
   - `SymphonyElixir.Acp.Client` — full `AgentBackend`: `initialize` → `session/new` (mcpServers wiring) → `session/prompt`; Option-A `session/update` normalization keyed on `update.sessionUpdate`; permission auto-approve (option picked by `kind`, `allow_always`-first) + bypass-deny; stopReason mapping (`end_turn`/`max_tokens`/`refusal`/`cancelled`); handshake/turn/stall timeouts; in-loop `acp_tool_call` dispatch so the tool runs in the run process.
   - `SymphonyElixir.Acp.LinearGate` (+ `McpPlug`) — per-session in-VM MCP HTTP listener (Bandit on loopback, OS-assigned port, path token), `initialize`/`tools/list`/`tools/call`/`ping`; `tools/call` dispatched back into the session process; reuses `DynamicTool.execute/3` unchanged.
   - **Credential withholding** — agent env scrubs `LINEAR_API_KEY`/variants via Port `{name, false}`; no native Linear MCP advertised (`acp.withhold_linear_credentials`, default true).
   - Config: `Acp` embedded schema + `Config.acp_runtime_settings/0` + `backend == "acp"` requires `acp.command`.
   - Tests: `acp/client_test.exs` (10 — handshake/turn/normalization/permission/stopReason/timeout/cwd-guard/**cred-withholding**), `acp/linear_gate_test.exs` (7 — MCP handshake, routing, **gate parity: before_handoff failure + reviewer request_changes both block**, runs-in-session-process, bad-token). Full suite **450 passed / 0 failed / 2 pre-existing skips** (449 + 1 new renderer test, below); Codex tests untouched and green; `mix compile --warnings-as-errors` + `mix credo` clean. Docs: `docs/acp.md` + README.
   - **CLI transcript fix (observability, Codex-neutral):** `CodexSessionLogRenderer.buffer_agent_message/3` dropped ACP-normalized agent chunks because they carry no item id and are never followed by `item/completed` — so `symphony transcript` showed reasoning/tools but not the agent's text for ACP runs. Added a `{nil, delta}` branch mirroring `buffer_reasoning/3` (Codex agent messages always have item ids → branch is ACP-only). The dashboard path (`Orchestrator.transcript_block_for_update/2`, `Presenter.transcript_fragment/1`) already rendered these via `agent_text_paths()`; only the CLI renderer had the gap. Covered by a new renderer test.
   - **Live acceptance — ✅ DONE (2026-06-15, opencode 1.17.4/1.17.7).** Drove the real `opencode acp` binary through `Acp.Client` end-to-end in a scratch workspace (env-gated test `test/symphony_elixir/acp/live_acceptance_test.exs`, run with `LIVE_ACP=1`; invisible to the normal suite). Proven against the live agent: (a) a real turn completes `stopReason=end_turn`, the streamed `agent_message_chunk` normalizes to `item/agentMessage/delta` and **renders** through `CodexSessionLogRenderer` (`AGENT / ACK`); (b) the real agent **invokes the gated `linear_graphql`** through Symphony's in-VM `LinearGate` HTTP MCP listener, dispatched back into the run process — confirming the load-bearing gate channel with a real agent, not just the fake-agent tests. Reproduction + the rate-limit caveat are in §13.
3. **Hardening:** stdio-MCP gate fallback (`linear_gate_transport: "stdio"`) for agents without HTTP MCP; lift deferred-review/counters out of the process dictionary (optional); `fs`/`terminal` handlers with PathSafety; `session/load` resume; `session/set_mode`.
4. **Observability polish (Option B) — ✅ DONE (2026-06-17).** Native ACP rendering across all three observability surfaces, with the Codex *and* Claude Code paths untouched (both keep their existing method branches; only ACP switched from Option-A synthesis to native pass-through). Implemented:
   - `Acp.Client` — `handle_session_update/3` now forwards the native `session/update` message verbatim (the `synthetic_payload`/`content_text` Option-A helpers are removed); `raw` still carries the real ACP JSON. Claude Code stays on Option A (its stream-json is Claude-specific, not ACP).
   - **Renderers learn ACP natively (additive).** `Orchestrator.transcript_block_for_update/2`, `Presenter.transcript_fragment/1`, and `CodexSessionLogRenderer.dispatch_payload/5` each gained a `method == "session/update"` branch that dispatches on `update.sessionUpdate`: `agent_message_chunk`→agent, `agent_thought_chunk`→reasoning, `tool_call`→a **tool** block surfacing the ACP tool `kind` (e.g. `"edit: Update README"`), `tool_call_update`→output, `plan`→a new **plan** checklist block (`- [x]`/`- [~]`/`- [ ]` by entry status). Existing Codex/Claude-Code method branches are unchanged, so those paths render byte-for-byte as before. `transcript_block_for_update/2` was kept under credo's complexity cap by extracting `text_block_spec/1`.
   - **Dashboard.** `dashboard_live.ex` renders the new `"plan"` kind as a markdown checklist (label "Plan", own chip/block slug); `dashboard.css` adds `.transcript-block-plan`/`.transcript-chip-plan`.
   - Tests: `acp/client_test.exs` (native `session/update` pass-through; native tool-call + plan render through the CLI renderer), `codex_session_log_renderer_test.exs` (native ACP chunks/tool kinds/plan; the prior Option-A test relabelled to the Claude-Code path it now describes), `orchestrator_status_test.exs` (native ACP `session/update` → agent/tool/plan transcript blocks), `extensions_test.exs` (dashboard renders the ACP tool kind + plan block), `acp/live_acceptance_test.exs` updated to assert the native shape. Full suite **499 passed / 0 failed / 2 pre-existing skips**; `mix compile --warnings-as-errors` + `mix credo` clean (only the pre-existing `do_run_codex_turns` arity-9).
5. **Native Claude Code backend (§14) — ✅ DONE (2026-06-16, incl. live acceptance).** A third `AgentBackend` (`SymphonyElixir.ClaudeCode.Client`) driving `claude -p` headless stream-json, reusing `AgentTransport` + `LinearGate` wholesale. Implemented:
   - `SymphonyElixir.ClaudeCode.Client` — full `AgentBackend`: `start_session` spawns `claude -p --output-format stream-json --input-format stream-json --verbose --permission-mode <mode> --add-dir <ws> --mcp-config <inline-json> --strict-mcp-config [--model …] [extra_args…]` via `AgentTransport` (no on-the-wire handshake; session id arrives in the first `system/init`); `run_turn` writes one stream-json user message and reads to the terminal `result`; Option-A normalization of `assistant` content blocks (`text`/`thinking`/`tool_use`), `tool_result`, and `system`/`result` into the **same** synthetic methods the ACP backend emits, so the renderer is untouched; in-loop `acp_tool_call` dispatch (same gate channel as ACP) so the tool runs in the run process; `result` mapping (`end_turn`/`max_tokens` → completed, `is_error`/non-`success` subtype → abnormal); prompt + stall timeouts.
   - **Credential withholding** — agent env scrubs `LINEAR_API_KEY`/variants via Port `{name, false}`; `--strict-mcp-config` + the single client-passed gated MCP server is the only Linear path (`claude_code.withhold_linear_credentials`, default true). Claude auth (`ANTHROPIC_API_KEY`/session) passes through.
   - Config: `ClaudeCode` embedded schema (`command` default `"claude"`, `model`, `permission_mode` default `"bypassPermissions"` validated against claude's modes, `extra_args`, `prompt_timeout_ms`, `stall_timeout_ms`, `withhold_linear_credentials`) + `Config.claude_code_runtime_settings/0` + `backend == "claude_code"` requires `claude_code.command`; `"claude_code"` registered in `AgentBackend.@backends` and `agent.backend` inclusion.
   - Tests: `claude_code/client_test.exs` (9 — happy turn/session-id, command+mcp-config+`--strict-mcp-config` wiring, normalization of text/thinking/tool_use/tool_result, error→abnormal, max_tokens note, timeout, **cred-withholding**, `--model` flag, cwd guard) against a fake `claude` shell fixture; `agent_backend_test.exs` + `workspace_and_config_test.exs` extended. Full suite **466 passed / 0 failed / 2 pre-existing skips**; Codex + ACP tests untouched and green; `mix compile --warnings-as-errors` + `mix credo` clean (the new module is clean; pre-existing `do_run_codex_turns` arity-9 is unchanged). Docs: `docs/claude-code.md` + README.
   - **Go/no-go spike + live acceptance — ✅ GO (2026-06-16, claude 2.1.178).** Confirmed against the real `claude` binary: (a) `claude -p` stream-json completes a turn and emits a terminal `result` (`stop_reason=end_turn`); (b) it connects to a client-passed `--mcp-config` HTTP MCP server (`initialize` → `tools/list` → `tools/call`, POST-only Streamable HTTP — no SSE GET) and the model **invokes** the gated `linear_graphql` with exact args (tool name to our endpoint is the bare `linear_graphql`; Claude exposes it to the model as `mcp__symphony-linear__linear_graphql`); (c) `session/new` needs no Linear creds. Captured as the env-gated `test/symphony_elixir/claude_code/live_acceptance_test.exs` (`LIVE_CLAUDE_CODE=1`, invisible to the normal suite): a real turn completes + normalizes + **renders** through `CodexSessionLogRenderer` (`AGENT`/`REASONING`), and the real agent invokes the gated tool through the in-VM `LinearGate` HTTP listener dispatched back into the run process. Verified pass.
6. **Per-task backend+model selection via Linear labels (§15) — ✅ DONE (2026-06-16).** `agent.label_presets` map label → `{backend, model}`; `AgentBackend.resolve_for_issue/1` picks the first preset (positional, list-order) whose label is on the issue, else the global `agent.backend` with empty overrides. Implemented:
   - `AgentBackend.resolve_for_issue/1` (+ pure `resolve_for_labels/2` for unit testing) returns `{module(), overrides :: map()}`. Overrides carry only `%{model: …}` for `acp`/`claude_code`; always `%{}` for `codex` (no per-task model). No match / no presets → `{resolve(agent.backend), %{}}`, i.e. identical to today.
   - `Config.Schema.Agent.LabelPreset` embedded schema + `embeds_many(:label_presets, …)` on the `agent` block; validates `backend ∈ {codex,acp,claude_code}`, requires non-blank `label` + `backend`. Positional first-match-wins documented (no cross-preset uniqueness enforced).
   - `AgentRunner` call site switched to `{backend, overrides} = AgentBackend.resolve_for_issue(issue)` and threads `overrides:` into `start_session`. `Acp.Client`/`ClaudeCode.Client.start_session` merge `opts[:overrides]` (`%{model}`) over their config-derived settings (empty overrides → byte-for-byte unchanged); `Codex.AppServer` ignores `overrides` (tolerates the extra opt). Fixed a latent `Schema.format_errors` bug that crashed on `embeds_many` nested errors (first triggered by `label_presets` validation).
   - Tests: `agent_backend_test.exs` — preset match picks backend+overrides, positional precedence, codex+model ignored, model-less preset → `%{}`, no-match/empty-presets → default; `resolve_for_issue/1` reads labels off an `Issue` and tolerates `nil`. `client_test.exs` (both backends) — a per-task model override reaches the agent (OPENCODE_CONFIG_CONTENT / `--model`) even with no configured model. `workspace_and_config_test.exs` — `label_presets` parse + default `[]` + rejects unknown backend / blank label / missing backend. Full suite green; `mix compile --warnings-as-errors` + `mix credo` clean. Docs: README `agent.label_presets` block.

---

## 9. Risks & open questions

- ~~**[GATING] OpenCode honors client-passed HTTP MCP servers?**~~ **RESOLVED ✅ (§12):** `opencode acp` 1.17.4 advertises `mcpCapabilities {http:true,sse:true}` and connects to a client-passed HTTP MCP server at session creation (observed `initialize`→`tools/list` against our stub). The gated Linear path is viable. Remaining sub-point for Phase 2: confirm the model actually *invokes* `linear_graphql` from a prompt (needs a model; OpenCode Zen free models are available for this test — see §12).
- **Handoff gate enforcement is no longer deferred.** It is Phase 2 MVP scope (§5.5). The hard guarantee is credential withholding (agent has no Linear token), so the gate holds even if the agent ignores guidance and ignores permission requests. The native-Linear permission-deny heuristic is defense-in-depth only.
- **Does the agent honor `session/request_permission` for its builtin/MCP tools?** Affects only the *defense-in-depth* deny layer, not the core guarantee. Unverified for OpenCode; confirm opportunistically, don't block on it.
- **`fs`/`terminal` capabilities:** advertising false means the agent uses its own file/exec tools (it runs in the workspace) — simplest, but Symphony loses per-write approval interception. Revisit in Phase 3 if interception is needed.
- **Approval semantics:** ACP option *kinds* (`allow_always` etc.) vary per agent; pick the option by `kind`, fall back to first allow-ish option. Mirror Codex's `auto_approve_requests == (approval_policy == "never")` default.
- **OpenCode ACP surface drift:** ACP/OpenCode are young; pin to a known `opencode` version in docs and keep the decoder tolerant (ignore unknown `session/update` types → `:notification`).
- **Remote (SSH) ACP:** `opencode acp` over `SSH.start_port/3` should reuse the Codex remote path unchanged; verify env-forwarding and that the agent is installed on the worker host.

---

## 10. File-by-file change list

**New**
- `lib/symphony_elixir/agent_backend.ex` — behaviour + `resolve/0`
- `lib/symphony_elixir/acp/client.ex` — ACP backend
- `lib/symphony_elixir/acp/linear_gate.ex` (per-session in-VM HTTP MCP listener + nested `McpPlug`; **no separate token registry** — token is per-listener plug state, see §5.5) — **Phase 2 MVP, DONE**; executes `DynamicTool.execute/3` in the session process (§5.5). Stdio fallback shim added in Phase 3 only if needed.
- `lib/symphony_elixir/agent_transport.ex` — shared transport, **DONE** (ACP-only consumer; Codex `AppServer` still holds its own private copies and should be made to delegate here in a follow-up — see §5.3)
- `docs/acp.md`
- `test/support/` fake ACP agent fixtures (incl. a handoff-attempt fixture for gate-parity tests); `test/symphony_elixir/acp/client_test.exs`; `test/symphony_elixir/acp/linear_gate_test.exs`; `test/symphony_elixir/agent_backend_test.exs`
- `lib/symphony_elixir/claude_code/client.ex` — native Claude Code `claude -p` stream-json backend (reuses `AgentTransport` + `LinearGate`); `test/symphony_elixir/claude_code/client_test.exs` + fake `claude` fixture; `test/symphony_elixir/claude_code/live_acceptance_test.exs` (`LIVE_CLAUDE_CODE=1`); `docs/claude-code.md` — **Phase 5, DONE (§14)**

**Edited (additive)**
- `lib/symphony_elixir/config/schema.ex` — `agent.backend` selector + `Acp` embedded schema + casts/validation; `acp.model` (DONE §13); `ClaudeCode` block (DONE §14); `agent.label_presets` embedded list + `Agent.LabelPreset` (DONE §15); fixed `format_errors` for `embeds_many` nested errors (DONE §15)
- `lib/symphony_elixir/config.ex` — `acp_runtime_settings/1,2` (incl. `model`, DONE); `claude_code_runtime_settings/0` (DONE §14)
- `lib/symphony_elixir/agent_backend.ex` — register `"claude_code"` (DONE §14); `resolve_for_issue/1` + `resolve_for_labels/2` + per-task overrides (DONE §15)
- `lib/symphony_elixir/agent_runner.ex` — dispatch via `AgentBackend.resolve/0`; call site switched to `resolve_for_issue(issue)` threading `overrides` into `start_session` (DONE §15)
- `lib/symphony_elixir/codex/app_server.ex` — add `@behaviour` (+ later delegate to `AgentTransport`); ignores `opts[:overrides]` — no per-task model (DONE §15)
- `lib/symphony_elixir/acp/client.ex` — merge `opts[:overrides]` (`%{model}`) over `acp_runtime_settings` (DONE §15); `lib/symphony_elixir/claude_code/client.ex` — merge `opts[:overrides]` (`%{model}`) over `claude_code_runtime_settings` (DONE §15)
- `README.md` — mention ACP backend + Claude Code backend (DONE §14)
- `lib/symphony_elixir/orchestrator.ex`, `symphony_elixir_web/presenter.ex`, `codex_session_log_renderer.ex` — native ACP `session/update` rendering branch (DONE §8 Phase 4); `symphony_elixir_web/live/dashboard_live.ex` + `priv/static/dashboard.css` — `"plan"` block kind (DONE Phase 4)

**Untouched contract:** the `on_message` event atoms (§2.2) and the `start_session`/`run_turn`/`stop_session` shapes — both backends conform.

---

## 11. Validation checklist (done = all true)
- [x] **Phase 0 spike resolved:** `opencode acp` calls a client-passed HTTP MCP tool, with no Linear creds in the agent env. (No → ACP not shipped for that agent.) — §12.
- [x] `agent.backend` defaults to `"codex"`; existing deployments unchanged.
- [x] Full pre-existing test suite green with no edits to Codex tests. (450 passed / 0 failed / 2 pre-existing skips — 449 + 1 new CLI-renderer ACP test.)
- [x] `Acp.Client` passes fake-agent tests for handshake/turn/permission/stopReason/timeouts.
- [x] **Gate parity:** ACP run with a failing `before_handoff` hook blocks the handoff; ACP run with reviewer-requests-changes blocks the handoff — same remediation as Codex. (`acp/linear_gate_test.exs`.)
- [x] **Credential withholding:** asserted that no `LINEAR_API_KEY`/Linear token reaches the agent process env, and that the agent is passed no native Linear MCP — only Symphony's gated tool.
- [x] Gate executes in the session's Symphony process: tool dispatch routes to the session pid (asserted in `linear_gate_test.exs` "runs in the session process"), so deferred-review and reviewer dedup/iteration counters use the run's process dictionary exactly as Codex.
- [x] Real `opencode acp` completes a turn end-to-end in a scratch workspace; streamed output normalizes + renders (dashboard path already covered; CLI renderer fixed and proven). **Done 2026-06-15 via `LIVE_ACP=1 mix test test/symphony_elixir/acp/live_acceptance_test.exs` — see §13.** (Free-tier model rate limits are transient; pin a working model with `ACP_LIVE_MODEL` to re-run.)
- [x] Codex path verified unchanged: Option-A keeps all changes inside `Acp.Client` (no edits to orchestrator/presenter/renderer); the full Codex test suite passes untouched.
- [x] Docs updated; no "gate deferred" caveat anywhere.

---

## 12. Phase-0 spike results — OpenCode ACP (verified 2026-06-15)

**Setup:** `opencode` 1.17.4 (binary cached at `~/.bun/install/global/node_modules/opencode-linux-x64/bin/opencode`). Drove `opencode acp` over stdio with a minimal ndjson JSON-RPC ACP client; pointed `session/new.mcpServers` at a local stub Streamable-HTTP MCP server that logs inbound requests. Scripts: `/tmp/acp-spike/{mcp_stub.mjs,acp_drive.mjs}`. No model/Linear creds in env.

**Result: GO.** Everything the gate design depends on is confirmed.

1. **HTTP MCP supported.** `initialize` response advertises:
   ```json
   "agentCapabilities":{"loadSession":true,
     "mcpCapabilities":{"http":true,"sse":true},
     "promptCapabilities":{"embeddedContext":true,"image":true},
     "sessionCapabilities":{"close":{},"fork":{},"list":{},"resume":{}}}
   "protocolVersion":1, "agentInfo":{"name":"OpenCode","version":"1.17.4"}
   ```
2. **Client-passed HTTP MCP server is actually connected to.** After `session/new`, opencode performed the full MCP handshake against our stub **at session-create time, before any prompt**: `POST initialize` → `POST notifications/initialized` → `GET /mcp` (SSE stream) → **`POST tools/list`**. This is the exact channel Symphony's in-VM gated `linear_graphql` endpoint will use (§5.5). Server push isn't required (we returned `405` to the GET and `tools/list` still proceeded over POST).
3. **`session/new` succeeds with no credentials.** Returned a `sessionId` and `configOptions` offering free **OpenCode Zen** models (`opencode/big-pickle`, `deepseek-v4-flash-free`, …) as the default — so a session is creatable without auth, and credential-withholding (§5.5) is fully compatible. *Bonus:* these free models make a real end-to-end ACP integration test feasible in CI without a paid key.

**Concrete schema facts for implementation (observed, not from docs):**
- ACP `protocolVersion` is the integer `1`. Framing is ndjson with `"jsonrpc":"2.0"`.
- `session/new.mcpServers[]` is a discriminated union on `type`, validated strictly (Zod; bad shapes → `-32602 Invalid params` with per-variant errors):
  - **http:** `{ "type":"http", "name":string, "url":string, "headers":[{ "name","value" }] }` — `headers` is **required** (empty array OK). *(This tripped the first attempt — missing `headers` → invalid params.)*
  - **sse:** `{ "type":"sse", ... , "headers":[...] }`
  - **stdio:** `{ "type":"stdio", "name":string, "command":string, "args":[...], "env":[{ "name","value" }] }`
- `session/new` result carries `sessionId`, `configOptions[]` (incl. a `model` select), and `modes`.
- **Streaming discriminator is `update.sessionUpdate`** (not `update.type` as some third-party docs claim) — e.g. `{"sessionId":...,"update":{"sessionUpdate":"available_commands_update", ...}}`. The observability normalization (§6) must key on `update.sessionUpdate`. Adjust the §3 mapping rows accordingly when implementing.

**End-to-end tool invocation — also confirmed ✅ (same session, free model, no creds).** A real `session/prompt` on the default free model `opencode/big-pickle` made the model **call the gated tool**: the stub logged `tools/call name=linear_graphql args={"query":"query { viewer { id } }"}` and the turn ended `stopReason=end_turn`. The full gated path is proven: client-passed HTTP MCP → model invokes → request lands at our endpoint with exact args.

Implementation notes from this run:
- opencode exposes an MCP tool to the model **namespaced as `<mcpServerName>_<toolName>`** — here `symphony-linear_linear_graphql`. Pick the MCP server `name` so the resulting tool name is sane, and have the ACP `handoff_tool_guidance` reference that namespaced name. (The MCP `tools/call` *to our endpoint* still uses the bare `linear_graphql`.)
- opencode-in-ACP **did not** send `session/request_permission` for the MCP tool call — it auto-allowed (pending → in_progress → completed). So the bypass-deny permission layer (§5.5) cannot be assumed to fire for MCP/tool calls; **credential withholding is the load-bearing guarantee, exactly as designed.**
- `session/update` discriminator stream observed: `available_commands_update`, `agent_thought_chunk`, `tool_call`, `tool_call_update` (with `status` pending/in_progress/completed), `agent_message_chunk`, `usage_update` — all keyed on `update.sessionUpdate`. This is the concrete set §6 normalization must map.

**Still deferred to Phase 2 acceptance (Symphony-side, not a protocol question):** the gate actually *blocking* a handoff when `before_handoff`/reviewer fails. That's tested against Symphony's own gate logic, not opencode.

---

## 13. Live acceptance results — Symphony `Acp.Client` ↔ real `opencode acp` (verified 2026-06-15)

Unlike §12 (an ad-hoc Node driver), this exercised **Symphony's own `Acp.Client` + `LinearGate`** against the real binary. Captured as `test/symphony_elixir/acp/live_acceptance_test.exs`, which only compiles when `LIVE_ACP=1` (the module is wrapped in `if System.get_env("LIVE_ACP") == "1"`), so a normal `mix test` never runs it.

**Run it:**
```
LIVE_ACP=1 mix test test/symphony_elixir/acp/live_acceptance_test.exs
# optional, when the default free model is throttled:
LIVE_ACP=1 ACP_LIVE_MODEL=opencode/north-mini-code-free mix test test/...
```
Requires `opencode` (>=1.17) on the login-shell PATH (override `OPENCODE_BIN`) and network to OpenCode Zen free models. The test drops a **workspace-local `opencode.jsonc`** pinning the model, so it neither reads nor mutates the host's global opencode config.

**Result: PASS (2 tests).**
1. *Turn end-to-end + transcript render.* `Acp.Client.run/4` completed a real turn `stopReason=end_turn`; `:session_started` + `:turn_completed` emitted; the streamed `agent_message_chunk` normalized to `item/agentMessage/delta` (Option A) and rendered through `CodexSessionLogRenderer` as an `AGENT` block.
2. *Gated tool via in-VM listener.* With a prompt instructing the agent to call `symphony-linear_linear_graphql`, the **real agent** issued a `tools/call` that landed on Symphony's per-session `LinearGate` HTTP listener and was dispatched (`{:acp_tool_call, …}`) back into the run process — the exact in-VM hop that makes the gate hold (§5.5). (The test stubs `tool_executor` to record the dispatch; gate *blocking* is proven separately in `acp/linear_gate_test.exs`.)

**Caveat — OpenCode Zen free-tier rate limits are per-model and transient.** On this run the default `opencode/big-pickle` (and `deepseek-v4-flash-free`, `nemotron-3-ultra-free`) returned `AI_APICallError: Rate limit exceeded` — opencode surfaces this only in its **own log** (`~/.local/share/opencode/log/opencode.log`), *not* as an ACP `session/prompt` error, so from the client's view the turn simply produces no `session/update` and `Acp.Client` correctly falls back to `stall_timeout_ms` → `{:error, :turn_stalled}`. This is the safety net behaving as designed, not a bug. `opencode/north-mini-code-free` was un-throttled and used for the passing run; set `ACP_LIVE_MODEL` to whatever is healthy when re-running. (Phase 3 nicety — ✅ DONE 2026-06-16: opencode does not report model-stream failures over ACP, so a long stall is the only signal. Added `acp.heartbeat_ms` (default 30s, 0 disables): while a turn is idle, `Acp.Client` slices its `after` window and emits a `:notification` "still waiting" heartbeat + log line, tracking `last_activity` so heartbeats don't reset the stall clock. Renders to no transcript block (unknown method) → advisory only. Lowering `stall_timeout_ms` still makes a throttled turn fail faster; the heartbeat just makes the dead air visible without the false-positive risk of an aggressive timeout. Tests: `acp/client_test.exs` (heartbeat fires before stall), `workspace_and_config_test.exs` (default + reject negative). Claude Code is largely unaffected — its stream-json reports a terminal `result` with `is_error`, so it doesn't go silent on failure.)

**Note on `acp.model` (DONE 2026-06-16).** Model selection for the ACP/OpenCode path is now a first-class Symphony config field. ACP has no protocol field for the model and Symphony's `session/new` doesn't set one, so each agent picks its model from its own config. For OpenCode specifically, `opencode acp` **rejects** a `--model` flag and **ignores** `OPENCODE_MODEL`, but **honors** inline config via `OPENCODE_CONFIG_CONTENT` (all three verified against opencode 1.17.7). So `acp.model` is surfaced to the agent as `OPENCODE_CONFIG_CONTENT={"model":"<model>"}` injected into the agent env by `Acp.Client.agent_env/1`. It is OpenCode-specific (other ACP agents ignore the var); unset → opencode's own resolution (workspace/global `opencode.jsonc`). Schema `acp.model`, `Config.acp_runtime_settings`, `docs/acp.md`, and tests updated.

---

## 14. Native Claude Code backend — `claude -p` headless stream-json (Phase 5 — ✅ DONE 2026-06-16)

`claude-code-acp` (Zed's bridge) lets Claude Code ride the ACP backend, but it is a **third-party translator over the Claude Agent SDK**, not native. Claude Code's own non-interactive interface is headless `--print` mode with JSON streaming over stdio — structurally the same shape Symphony already drives for Codex and ACP. A dedicated backend talking to it directly is more robust than the bridge and a clean fit for the existing `AgentBackend` behaviour. **Verified against the installed `claude` 2.1.178.**

### 14.1 The native interface
```
claude -p --input-format stream-json --output-format stream-json --verbose \
  --model <alias|full-name> --add-dir <workspace> \
  --mcp-config <json> --strict-mcp-config \
  --permission-mode bypassPermissions
```
- **stdio JSON stream.** `--input-format stream-json` (write user-message lines to stdin) + `--output-format stream-json` (read `system`/`assistant`/`tool_use`/`tool_result`/partial/`result` lines from stdout). The terminal `result` message carries the stop reason and `is_error`. Line-framed JSON over stdio — the same transport family as Codex/ACP.
- This **is** Claude Code, no bridge process. (`claude-code-acp` ⊃ Claude Agent SDK ⊃ this CLI. The CLI is the most native surface that maps onto Symphony's shell-out-to-stdio architecture; embedding the TS/Python SDK would mean running a Node/Python sidecar from Elixir — worse.)

### 14.2 Mapping onto `AgentBackend` (`SymphonyElixir.ClaudeCode.Client`)
- **`start_session/2`** — spawn the `claude -p` command via the existing `AgentTransport` (cwd validation, env scrubbing, line-framed stdio reused). No new transport.
- **`run_turn/4`** — write one user-message stream-json line to stdin; read the streamed events; map the terminal `result` stop reason → `:turn_completed` / abnormal. **Option-A normalization again:** translate Claude's `assistant`/`tool_use`/`result`/partial message types into Symphony's existing `on_message` atoms (§2.2) — new mapping table, same pattern, **zero downstream changes**.
- **`stop_session/1`** — close the port (best-effort).
- **Approvals** — `--permission-mode bypassPermissions` (or `acceptEdits`) mirrors Codex `approval_policy: never` / ACP `auto_approve`. Confirmed `--permission-mode` choices: `default | acceptEdits | bypassPermissions | auto | dontAsk | plan`.

### 14.3 The handoff gate — reuses §5.5 infrastructure, *lower risk* than ACP
- `--mcp-config <json>` loads MCP servers (HTTP/SSE/stdio first-class). Point it at the **same in-VM `LinearGate` HTTP listener** built in Phase 2 — no new gate code; `tools/call` dispatches back into the run process exactly as today.
- `--strict-mcp-config` makes the agent use **only** those servers, ignoring all other MCP configuration — an *explicit* lock, stronger than the ACP path's implicit "we just didn't pass a Linear MCP." `--disallowedTools`/`--allowedTools`/`--tools` further restrict the toolset.
- **Credential withholding** (scrub `LINEAR_API_KEY` from env) works identically and remains the load-bearing guarantee.
- **Risk reduction vs ACP:** the §12 spike had to *empirically verify* that opencode forwards a **client-passed** HTTP MCP server. With native Claude Code there is no bridge in the path — `--mcp-config` HTTP servers are documented and first-class, so the "does the agent actually connect to our endpoint?" gating risk largely disappears. (Still confirm with a small spike before enabling.)

### 14.4 Notes / trade-offs
- **It is a third backend, not free from the ACP work.** ACP was chosen to cover a *family* of agents (OpenCode, Gemini, Qwen…) via one protocol; Claude Code stream-json is Claude-specific. So this is another `AgentBackend` impl + its own normalization — but it reuses `AgentTransport` + `LinearGate` wholesale, so it is meaningfully smaller than Phase 2 was.
- **Model selection is a real native flag** here (`--model opus` / `--model claude-fable-5`), unlike opencode — so the per-task model from §15 maps directly to `--model` with no env shim.
- **Auth** flows through Claude Code's own mechanism (`ANTHROPIC_API_KEY` / logged-in session / Bedrock/Vertex). Symphony scrubs only Linear creds, so Claude auth passes through. Consider `--bare`/`--safe-mode`/`--setting-sources` to control which host settings/hooks leak into the run.
- **Useful natives:** `--session-id`/`--resume` (continuity), `--include-partial-messages`, `--replay-user-messages`, `--append-system-prompt`, `--max-budget-usd`, `--json-schema` (structured output).
- **Config:** add `"claude_code" => SymphonyElixir.ClaudeCode.Client` to `AgentBackend.@backends`; a `ClaudeCode` embedded schema (`command` default `"claude"`, `model`, `permission_mode`, `extra_args`, timeouts) mirroring the `Acp` block; `Config.claude_code_runtime_settings/0`.
- **Spike first (go/no-go, mirrors §12):** confirm `claude -p` stream-json (a) completes a turn and emits a terminal `result`, (b) connects to a `--mcp-config` HTTP server and the model invokes the gated tool, (c) creates no Linear creds in env. Capture the real stream-json event shapes (the normalization table depends on them).

---

## 15. Per-task backend + model selection via Linear labels (Phase 6)

Today the backend is global: `AgentBackend.resolve/0` reads `Config.settings!().agent.backend` once (`agent_backend.ex:32`). We want the backend **and model** chosen **per task**, driven by the issue's Linear labels, so e.g. a `agent:fast` ticket runs OpenCode on a cheap model while a `agent:deep` ticket runs Claude Code on Opus — with a configured default for unlabelled issues.

### 15.1 Why labels are a clean signal (verified in code)
- `SymphonyElixir.Linear.Issue.labels :: [String.t()]` is a list of **label-name strings**, with a `label_names/1` helper (`linear/issue.ex:64`). Labels are already fetched on every polled issue and carried on the `Issue` struct (used in telemetry, `agent_runner.ex:78`).
- `AgentRunner.run_codex_turns/5` calls `AgentBackend.resolve()` at `agent_runner.ex:287` with the `issue` already in scope — so threading the issue into resolution is a one-line change, no new plumbing.

### 15.2 Config shape (recommended)
A new ordered `agent.label_presets` list; first preset whose `label` is present on the issue wins; fall through to the existing `agent.backend` (+ that backend's block) as the default.
```yaml
agent:
  backend: codex            # default backend for unmatched issues
  label_presets:
    - label: "agent:fast"
      backend: acp
      model: opencode/north-mini-code-free
    - label: "agent:deep"
      backend: claude_code
      model: opus
    - label: "agent:codex"
      backend: codex          # model omitted → backend default
```
- **`label`** matches a Linear label name exactly (case-sensitive, as Linear stores it).
- **`backend`** ∈ the `@backends` keys (`"codex" | "acp" | "claude_code"`).
- **`model`** is interpreted by the chosen backend: ACP/OpenCode → `OPENCODE_CONFIG_CONTENT` (§13 `acp.model`); Claude Code → `--model` (§14); Codex → no per-task model today (Codex picks its model from its own config) → `model` ignored with a one-time `log()` if set, or validated out for `backend: codex`.
- **Precedence is positional and deterministic** — list order, first match wins — so multiple matching labels on one issue resolve unambiguously. Document this; do not rely on label sort order from Linear.

### 15.3 Resolution API
Replace the global `resolve/0` call site with an issue-aware resolver that returns both the module and the per-task overrides:
```elixir
@spec resolve_for_issue(Issue.t()) :: {module(), overrides :: map()}
# overrides carries e.g. %{model: "opus"} (and could carry command/extra_args later)
```
- `AgentRunner` calls `{backend, overrides} = AgentBackend.resolve_for_issue(issue)` and passes `overrides` into `backend.start_session(workspace, worker_host: …, overrides: overrides)`.
- **Backends must accept the override instead of re-reading global config.** Today `Acp.Client.start_session` reads `Config.acp_runtime_settings()` internally and `Codex.AppServer` reads `Config.settings!().codex.command`; for per-task model to take effect, `start_session` must merge `opts[:overrides]` over the config-derived settings (e.g. `Map.merge(acp_runtime_settings, Map.take(overrides, [:model]))`). This is the one real code change beyond resolution — keep it minimal and additive (empty overrides → identical to today, so the Codex default path is byte-for-byte unchanged).
- Keep `resolve/0` (no-issue) as the default/back-compat entry; `resolve_for_issue/1` delegates to it when no preset matches.

### 15.4 Validation & edge cases
- Validate each preset's `backend` against `@backends` and (when `backend: codex`) reject/ignore `model` per §15.2; require `label` non-empty and unique across presets (or document first-wins on duplicates).
- An unmatched issue → default backend + that backend's configured model — i.e. exactly today's behavior when `label_presets` is empty/absent. **Default-path regression guard:** with no `label_presets`, the resolved `{backend, overrides}` must equal `{resolve/0, %{}}`.
- Labels change mid-flight? Resolution happens once at run start (parity with how the backend is fixed for a run today); a relabel takes effect on the next run/turn-loop start, not mid-session.
- Tests: `agent_backend_test.exs` — preset match picks backend+overrides; positional precedence; no-match → default; unknown backend rejected; `codex`+model handled. Config tests for the `label_presets` block.

**Files:** `agent_backend.ex` (`resolve_for_issue/1` + overrides), `config/schema.ex` (`agent.label_presets` embedded list), `config.ex` (accessor), `agent_runner.ex` (call site `resolve_for_issue(issue)` + thread `overrides` into `start_session`), each backend's `start_session` (merge `overrides`). Additive; default path unchanged.

---

## 16. Shared pre-launch hook — `agent.pre_command` (✅ DONE 2026-06-16)

Cross-cutting addition (not ACP-specific). The Codex command historically embedded its own env-sourcing wrapper — `sh -lc '. .artifacts/github-app-auth/session.env && exec codex … app-server'` — to expose a per-worktree GitHub-App session env to the agent. That trick works for Codex (self-contained command) and ACP (`acp.command` used verbatim), but **not** for Claude Code: `ClaudeCode.Client.build_command` appends its own flags (`-p --output-format … --mcp-config '<json>' --strict-mcp-config`) *after* the configured command, so wrapping the base in `sh -lc '… exec claude'` would hand those flags to the outer `sh`, not to `claude`.

**Design (chosen: arbitrary shell snippet over a declarative `env_file`).** A new optional `agent.pre_command` shell snippet runs in the launch shell, in the workspace cwd, before every backend's agent process. Backend-agnostic, joined with `&&`. Picked over a path-only `env_file` so it can source multiple files or run env-setting commands.

- **Central application in `AgentTransport`:** `pre_command/0` (config read, blank→nil) + `with_pre_command/2` (prepend `pre && ` to a launch-shell fragment, no-op when nil). Applied at both launch points — local (`bash -lc "<pre> && <command>"`) and remote (`cd … && <exports> && <pre> && exec <command>"`) — so it runs before exec on either path. **Quote-safe for Claude Code:** the prefix is concatenated as raw shell text in the *same* shell the flags were escaped for, so it avoids the nested-`sh -lc '…'` quoting hazard.
- **Codex parity:** `Codex.AppServer` (still on its private transport copies, §5.3) calls the same `AgentTransport.with_pre_command/1` at its local + remote launch points. **Unset ⇒ no-op ⇒ Codex byte-for-byte unchanged** (and Codex tests, which never set it, are untouched).
- **Sanitization:** `prepare_sourced_env_files` (both the shared one and Codex's private copy) now scans the `pre_command` *in addition to* the command for `. file.env` / `source file.env`, so a generated env file sourced via `pre_command` is still stripped of non-assignment noise before launch.
- **Migration:** with `pre_command` set, `codex.command` simplifies to the bare `codex … app-server`; ACP/Claude commands stay bare and all three get the env uniformly.
- **Config:** `agent.pre_command` (string, optional, nil default). **Files:** `config/schema.ex` (field+cast), `agent_transport.ex` (`pre_command/0`, `with_pre_command/1,2`, two launch points, sanitizer), `codex/app_server.ex` (two launch points + sanitizer, via `AgentTransport`), `README.md`. **Tests:** `agent_transport_test.exs` (pure `with_pre_command/2` + config-backed `pre_command/0`); `claude_code/client_test.exs` (a `pre_command` `export` reaches the agent env — the motivating Claude case); `app_server_test.exs` (Codex applies `pre_command`, sources the session env, and sanitizes it, with a bare codex command); `workspace_and_config_test.exs` (parse + nil default). Full suite **488 passed / 0 failed / 2 pre-existing skips**; `--warnings-as-errors` + credo clean.

---

## 17. Surface the actual backend + model in the dashboard (✅ DONE 2026-06-16)

Operators need to see **which backend and model each run is actually using** — in the running-issues list and on the issue detail page. The values are the *actual* ones (what is really running), **not** re-derived from the issue's labels: the backend is the resolved `AgentBackend` module the session runs on, and the model is the value handed to (or reported by) the live agent.

**Design — capture at run start, refine from the live stream, surface through the existing snapshot/presenter.** No new persistence; rides the channels already in place.

- **Backend (authoritative).** `AgentRunner.run_codex_turns` already resolves `{backend, overrides}` via `AgentBackend.resolve_for_issue/1` and calls `backend.start_session`. Right after a session starts it now sends the orchestrator `{:worker_runtime_info, issue_id, %{backend: name, model: …}}` (reusing the existing runtime-info channel + handler). `AgentBackend.backend_name/1` reverse-maps the module to its config key (`"codex"`/`"acp"`/`"claude_code"`).
- **Model (best actual signal per backend).** The initial model is the config/override value actually passed to the agent process — `session.claude_code.model` (→ `--model`) or `session.acp.model` (→ `OPENCODE_CONFIG_CONTENT`); `nil` when the agent picks its own (Codex always; ACP/Claude when unset). It is then **refined from the wire**: Claude Code reports the model it actually resolved in its `system/init`, which `ClaudeCode.Client` now carries on the `:session_started` event; the orchestrator's `model_for_update/2` prefers that over the configured value. ACP/Codex emit no model on `:session_started`, so the configured value (or `nil`) stands.
- **Orchestrator.** Running entry seeds `backend: nil, model: nil`; the `:worker_runtime_info` handler `maybe_put`s `:backend`/`:model` (nil never clobbers); `integrate_codex_update` refines `:model` from any event that carries one; `snapshot` exposes both on each running entry. Scoped to running entries — a retrying issue has no agent running, so it shows no agent until the next run.
- **Presenter / dashboard.** `Presenter.agent_payload/1` projects `%{backend, model}` (blank→nil) onto the list rows (`running_entry_payload`), the detail running payload (`running_issue_payload`), and a top-level `agent` on the issue body. `dashboard_live.ex` adds an **"Agent" column** to the running table and an **"Agent" metric card** to the detail page, humanizing the backend (`agent_backend_label/1`: Codex / ACP · OpenCode / Claude Code) with the model beneath.

**Files:** `agent_backend.ex` (`backend_name/1`), `agent_runner.ex` (`send_agent_backend_info/4` + `agent_session_model/1`), `claude_code/client.ex` (`:session_started` carries `model` from `system/init`), `orchestrator.ex` (running-entry seed, `:worker_runtime_info` backend/model, `model_for_update/2`, snapshot), `symphony_elixir_web/presenter.ex` (`agent_payload/1` on list + detail), `symphony_elixir_web/live/dashboard_live.ex` (Agent column + card + `agent_backend_label/1`), `priv/static/dashboard.css` (`.agent-stack`), `README.md`. **Tests:** `agent_backend_test.exs` (`backend_name/1`); `orchestrator_status_test.exs` (snapshot captures backend + refined model; configured model retained when the agent reports none); `claude_code/client_test.exs` (`:session_started` carries the `system/init` model); `extensions_test.exs` (API payloads expose `agent`). Additive — Codex default path unchanged. Full suite **494 passed / 0 failed / 2 pre-existing skips**; `--warnings-as-errors` clean; credo clean (only the pre-existing `do_run_codex_turns` arity-9).
