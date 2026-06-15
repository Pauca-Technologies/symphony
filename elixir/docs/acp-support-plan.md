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

**Files:** `lib/symphony_elixir/acp/linear_gate_endpoint.ex` (in-VM MCP HTTP handler, mounted on the existing Phoenix endpoint or a tiny dedicated listener) + a session-token registry; wiring in `Acp.Client.start_session/2` to emit the `mcpServers` entry and to scrub Linear creds from the agent env. `DynamicTool`, `HandoffGate`, `ReviewGate` reused unchanged.

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

- **Option B (follow-up) — teach the renderer ACP natively.** Add ACP method/shape branches to `transcript_block_for_update/2`, the `*_text_paths/0` lists, and `CodexSessionLogRenderer`, plus tests. Cleaner long-term and surfaces ACP-only data (plans, tool kinds), but edits shared observability code → must prove Codex rendering is unchanged. Defer until ACP is real.

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
2. **ACP MVP — includes the Linear gate (first shippable ACP):** `Acp.Client` (handshake/session/prompt, Option-A normalization, permission auto-approve) **+ the §5.5 gate**: in-VM HTTP MCP `linear_graphql` channel executing in the session process, Linear creds withheld from the agent env, bypass denial, prompt guidance. `fs/terminal` advertised false. Acceptance gate: the §5.5 *gate parity* tests pass (before_handoff failure and reviewer-request-changes both block the handoff) in addition to a happy turn. Verify against the fake agent **and** real `opencode acp`. ACP is not enabled in any real deployment until this phase's acceptance gate is green.
3. **Hardening:** stdio-MCP gate fallback (`linear_gate_transport: "stdio"`) for agents without HTTP MCP; lift deferred-review/counters out of the process dictionary (optional); `fs`/`terminal` handlers with PathSafety; `session/load` resume; `session/set_mode`.
4. **Observability polish (Option B):** native ACP rendering (plans, tool kinds, thoughts) in renderer/presenter, with Codex-unchanged proof.

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
- `lib/symphony_elixir/acp/linear_gate_endpoint.ex` (+ session-token registry) — in-VM HTTP MCP gate, **Phase 2 MVP**; executes `DynamicTool.execute/3` in the session process (§5.5). Stdio fallback shim added in Phase 3 only if needed.
- `lib/symphony_elixir/agent_transport.ex` — extracted shared transport (Phase 1.5/2)
- `docs/acp.md`
- `test/support/` fake ACP agent fixtures (incl. a handoff-attempt fixture for gate-parity tests); `test/symphony_elixir/acp/client_test.exs`; `test/symphony_elixir/acp/linear_gate_test.exs`; `test/symphony_elixir/agent_backend_test.exs`

**Edited (additive)**
- `lib/symphony_elixir/config/schema.ex` — `agent.backend` selector + `Acp` embedded schema + casts/validation
- `lib/symphony_elixir/config.ex` — `acp_runtime_settings/1,2`
- `lib/symphony_elixir/agent_runner.ex` — dispatch via `AgentBackend.resolve/0`
- `lib/symphony_elixir/codex/app_server.ex` — add `@behaviour` (+ later delegate to `AgentTransport`)
- `README.md` — mention ACP backend
- (Phase 4 only) `lib/symphony_elixir/orchestrator.ex`, `presenter.ex`, `codex_session_log_renderer.ex` — native ACP rendering

**Untouched contract:** the `on_message` event atoms (§2.2) and the `start_session`/`run_turn`/`stop_session` shapes — both backends conform.

---

## 11. Validation checklist (done = all true)
- [ ] **Phase 0 spike resolved:** `opencode acp` calls a client-passed HTTP MCP tool, with no Linear creds in the agent env. (No → ACP not shipped for that agent.)
- [ ] `agent.backend` defaults to `"codex"`; existing deployments unchanged.
- [ ] Full pre-existing test suite green with no edits to Codex tests.
- [ ] `Acp.Client` passes fake-agent tests for handshake/turn/permission/stopReason/timeouts.
- [ ] **Gate parity:** ACP run with a failing `before_handoff` hook blocks the handoff; ACP run with reviewer-requests-changes blocks the handoff — same remediation as Codex. (Hard requirement; ACP cannot be enabled until green.)
- [ ] **Credential withholding:** asserted that no `LINEAR_API_KEY`/Linear token reaches the agent process env, and that the agent is passed no native Linear MCP — only Symphony's gated tool.
- [ ] Gate executes in the session's Symphony process: deferred-review and reviewer dedup/iteration counters behave identically to Codex.
- [ ] Real `opencode acp` completes a turn end-to-end in a scratch workspace; transcript renders in the dashboard.
- [ ] Codex path verified unchanged (run one Codex issue; transcript identical to pre-change).
- [ ] Docs updated; no "gate deferred" caveat anywhere.

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
