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
