# Logging Best Practices

This guide defines logging conventions for Symphony so Codex can diagnose failures quickly.

## Goals

- Make logs searchable by issue and session.
- Capture enough execution context to identify root cause without reruns.
- Keep messages stable so dashboards/alerts are reliable.

## Required Context Fields

When logging issue-related work, include both identifiers:

- `issue_id`: Linear internal UUID (stable foreign key).
- `issue_identifier`: human ticket key (for example `MT-620`).

When logging Codex execution lifecycle events, include:

- `session_id`: combined Codex thread/turn identifier.

Compact lifecycle telemetry also includes `run_id`, which is unique to one worker attempt. Retried
runs retain `parent_run_id`, the triggering `retry_id`, and a numeric retry attempt; do not replace
the existing issue, session, thread, or turn identifiers with run lineage.

Task-delivery telemetry is separate from worker lifecycle. Version 1 `task_outcome` events carry
`outcome_version`, `stage`, `status`, and `authoritative`. Current authoritative emit points are the
before/after repository delta (`material_progress:recorded`) and a passed versioned exact-head
handoff gate (`exact_head_handoff:accepted`). Worktree evidence contains only bounded SHA-256
fingerprints, never file contents. CI, human-review, merge, reopen, and revert stay unknown unless a
future authoritative integration emits them explicitly; do not infer them from `run_end` or Linear
state. Correlate downstream delivery by exact/candidate/reviewed/head SHA before falling back to
`run_id` or conservative legacy issue/date identity.

## Message Design

- Use explicit `key=value` pairs in message text for high-signal fields.
- Prefer deterministic wording for recurring lifecycle events.
- Include the action outcome (`completed`, `failed`, `retrying`, `waiting`, or `resumed`) and the reason/error when available.
- Avoid logging large payloads unless required for debugging.

## Scope Guidance

- `AgentRunner`: log start/completion/failure with issue context, plus `session_id` when known.
- `Orchestrator`: log dispatch, retry, terminal/non-active transitions, and worker exits with issue context. Include `session_id` whenever running-entry data has it.
- `Codex.AppServer`: log session start/completion/error with issue context and `session_id`.

## Agent Prompt Observability

`AgentRunner` emits `[:symphony_elixir, :agent, :prompt_built]` and a matching
`agent.prompt_built` log before every backend turn. The event records `prompt_chars`,
`prompt_bytes`, `prompt_kind`, `included_sections`, `turn_number`, and `max_turns`, together with
the issue, workspace, worker, and retry-attempt context. The local JSONL telemetry sink persists the
same fields as a `prompt_built` event so prompt-size regressions can be measured across runs.

Never include raw prompt content in prompt observability. Per-turn `session_id` is not yet available
when the prompt is built; correlate these events by `run_id`, issue, workspace, attempt, and turn
number.
`prompt_chars` and `prompt_bytes` measure only the newly submitted turn text. Retained thread history
and effective model-input cost remain represented by the backend's context/input-token telemetry.

## Status/Resume Packet Observability

Every fresh and continuation backend turn includes one
`continuation.status_resume_packet` v1 section as its literal final dynamic section. Ordinary
`prompt_built` provenance reports that section's source/version/hash/bytes. Runtime-info and compact
telemetry MUST carry only the validated packet id, SHA-256, trusted relative sidecar reference,
boundary, and bounded evidence references—never the packet or prompt body, diff/workpad content,
command-output body, environment values, credentials, or tokens. Sanitized bounded single-line
validation/check/attestation labels may be retained as structured evidence; raw command output may
not.

The worker reuses its existing startup repository manifest for turn 1 and performs at most one
post-turn repository refresh after each handled turn. Production therefore performs N+1 repository
snapshots for N handled turns: the startup snapshot plus N post-turn refreshes. That refreshed
packet becomes the next continuation input without an additional packet-specific pre-turn probe.
Bounded diff telemetry is scoped to the selected paths and tracked `git diff --numstat`; paths
considered/omitted, binary files, partial untracked coverage, and probe failures must remain
explicit. Verification evidence is current only when its SHA matches a known current HEAD.

Lifecycle-only packet marks are `outer_worker_exit`, `retry_scheduled`, `wait_parked`,
`quota_parked`, and `restart_adopted`. They update only the trusted sidecar boundary and preserve
the original observation timestamps/sources. Mark/load/write failures emit
`resume_packet_error` with issue/run/retry context plus a bounded `error_code` and boundary; never
log raw I/O/command output, and never let the error block the underlying exit, retry, park, resume,
or adoption. Legacy records without a reference remain valid.

## Shadow No-Progress Observability

The existing budget collector keeps a fixed 128-slot ring of safe terminal tool-attempt signals and
assesses it once at the post-turn packet boundary. Starts, output streams, unmatched terminals, and
long-running single calls do not count as completed attempts. Tool fingerprints use a coarse
allowlisted operation class plus canonical redacted argument and result-class hashes. Raw arguments,
outputs, call/thread IDs, URLs with credentials, secret values, external tool names, and canonical
fingerprint input MUST NOT enter ETS snapshots, logs, runtime info, packets, or telemetry.

Version 1 `no_progress_loop` telemetry is always `shadow=true` and is emitted sparsely for
`alert`, `suppressed_progress`, `progress_unavailable`, and an actual latched `reset`. Fields are
limited to fixed decision/kind/tool/result/progress enums, bounded counts and omission codes,
digest/warning identifiers, and changed/unchanged/unavailable progress-channel enums. Runtime info
contains only the separately validated compact cumulative summary. The orchestrator rejects a
malformed whole summary and retains the last valid value; it never persists the summary through
retry, wait, or quota records because the trusted resume packet owns durable warning delivery.

Warnings are generated only after a qualified repeated terminal pattern and safe post-turn progress
comparison. Any comparable changed repository/workpad/exact-head channel suppresses and resets the
episode; no comparable channels means progress unavailable and no warning. A pending packet warning
is delivered on the next turn and cleared after a handled consuming turn. A crash before refresh can
redeliver it, so restart delivery is at-least-once rather than exactly-once. No event or warning may
interrupt, retry, block, park, or change stall policy.

## Offline Regression Candidate Privacy

`mix telemetry.regression_candidates` reads retained compact JSONL through a separate bounded
streaming reader. Candidate projection allowlists versioned manifests, classified failures,
extreme-budget transitions, valid shadow loop alerts, and explicit task/review outcomes. It must
not fall back to protocol/session transcripts, prompt or workpad bodies, original event rows, tool
arguments/output, arbitrary failure or review text, or user content.

The pending corpus contains only fixed enums/counts, non-secret manifest digests/provenance,
generated evidence references, and deterministic candidate/corpus IDs. Human CLI output is
narrower: candidate IDs, fixed selection reason enums, retained reproduction field names, safe
evidence references, and fixed omission/cap diagnostics. The task emits no corpus body as runtime
telemetry or application log context. Export is an explicit `0600` write to an existing
operator-owned `0700` staging directory; Symphony provides no approval, promotion, pruning, or
cleanup command. Externally supplied approval metadata is review-process evidence, not
cryptographic authentication.

## Agent Profile Routing

Repository profile classification logs the final `profile`, the classifier's proposed profile, and
its `risk`, `complexity`, and `ambiguity` levels. Failures and ambiguous profile-label overrides log
the quality fallback. Every routing message includes both `issue_id` and `issue_identifier`; issue
content and classifier reasons are deliberately excluded from logs.

## Dynamic Tool Outcomes

Codex `tool_call_completed` and `tool_call_failed` session events include the normalized tool result
under `details.result`. The record keeps the result's `success` flag and decoded structured `output`
without duplicating `contentItems`. For deferred handoff reviews, inspect
`details.result.output.status == "deferred_review_started"`; reviewer blocks and actual tool or
GraphQL failures remain failed events with their distinct structured error output.

Automated-review terminal state is emitted as `gate.review` with `outcome`, `iteration`,
`max_iterations`, `reviewed_sha`, `authoritative`, `severity_counts`, and `failure_reason`. The same
state appears under `running[].review_state` in the orchestrator snapshot and under
`running[].review` in the HTTP/dashboard projection. Treat only `outcome=approved` with
`authoritative=true` as review approval; `automation_inconclusive`, `infrastructure_unavailable`,
and `budget_exhausted_with_findings` are operational/human-escalation states, not successful
handoffs.

## Checklist For New Logs

- Is this event tied to a Linear issue? Include `issue_id` and `issue_identifier`.
- Is this event tied to a worker attempt? Include `run_id` and available retry lineage.
- Is this event tied to a Codex session? Include `session_id`.
- Is the failure reason present and concise?
- Is the message format consistent with existing lifecycle logs?
