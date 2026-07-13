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

## Message Design

- Use explicit `key=value` pairs in message text for high-signal fields.
- Prefer deterministic wording for recurring lifecycle events.
- Include the action outcome (`completed`, `failed`, `retrying`) and the reason/error when available.
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
when the prompt is built; correlate these events by issue, workspace, attempt, and turn number.
`prompt_chars` and `prompt_bytes` measure only the newly submitted turn text. Retained thread history
and effective model-input cost remain represented by the backend's context/input-token telemetry.

## Checklist For New Logs

- Is this event tied to a Linear issue? Include `issue_id` and `issue_identifier`.
- Is this event tied to a Codex session? Include `session_id`.
- Is the failure reason present and concise?
- Is the message format consistent with existing lifecycle logs?
