# UDP changes to Symphony

This branch (`udp`) is UDP's fork of `github.com/openai/symphony`. The
`Pauca-Technologies/symphony` remote (`udp`) hosts these changes; the upstream
remote is `origin`.

## Commits ahead of `origin/main`

In chronological order (oldest first), as of 2026-05-25:

1. **d3e90f00cb2b71c22fd8e77d461f1ebb828b5bd2** — `feat(config): support env-backed Linear project slug` (2026-03-31)
   Allow the Linear project slug in WORKFLOW.md to interpolate from environment
   variables so the same workflow file is reusable per consumer.

2. **cc8a771db1746a250840525afee413ea5412273c** — `feat(elixir): add issue transcript observability` (2026-04-23)
   Emit per-issue Codex session log paths so operators can locate the
   transcript that drove a given run.

3. **5d6f37107fc6baa00c3028439580c1d325afa7f6** — `fix problems with some issues` (2026-05-04)
   Misleadingly-titled commit. Actually:
   - Adds `codex_session_log_renderer.ex` (711 lines) + tests
   - Adds the `mix codex.session.render` task and `bin/codex-session-log` entry
   - Extends `codex/app_server.ex` to configure the Codex app-server's model
     from Symphony config (this is the change the implementation plan
     describes as `fix(elixir): configure Codex app-server model via config`)

4. **91f28ca93cdda7c67fe1e2a2b161bdd218f1f5ea** — `feat(hooks): add before_handoff gate` (2026-05-11)
   New Symphony hook lifecycle event: `before_handoff` runs the consumer
   repo's PR-handoff gates before an agent declares work complete.

5. **995cfcc8f522d0384a19a243dd188d69952b1a02** — `feat(elixir): add session_start hook` (2026-05-16)
   Mirror of Claude Code's `SessionStart`: Symphony emits a `session_start`
   hook event before the first turn so per-repo session-prep work runs
   consistently across Claude / Codex / Symphony runtimes.

6. **928419ebe34cdbfe85195ee380fb9f53ccaacb69** — `test(elixir): restore udp validation gate` (2026-05-16)
   Restore the UDP validation test that upstream had removed.

7. **a390490** — `feat(elixir): mark issues Blocked on terminal agent give-up` (2026-05-25)
   T04: AgentRunner posts a marker-tagged comment, applies
   needs-human-input + symphony:routing-warned labels, and transitions
   to Blocked when an agent run terminally gives up. Idempotent via the
   routing-warned label.

8. **0b3b033** — `feat(orchestrator): write a periodic heartbeat for dead-man's switch` (2026-05-25)
   T18: every minute, the orchestrator writes
   ~/.symphony/heartbeat. A cron-driven check-heartbeat script
   surfaces a local alert if the timestamp goes stale.

9. **(this commit)** — `feat(elixir): multi-repo Symphony driver (T24)`
   T24 + T26 from the audit:
   - New `~/.symphony/repos.yaml` loader (`SymphonyElixir.RepoConfig`).
   - Label-based routing (`SymphonyElixir.Router`) — `repo:<name>` is
     the only routing key; fuzzy-match advisory + idempotent
     `symphony:routing-warned` label.
   - Cardinality gate (`SymphonyElixir.Cardinality`) using bulk-poll
     fields: one repo per issue, parents have no repo/no PR, one PR
     per issue. Cutover via `cardinality_enforced_from`.
   - Extended `Linear.Client` query to fetch `team`, `parent`,
     `children`, `attachments`. Added optional team-scoped poll path
     for multi-repo mode.
   - `mix symphony.cardinality --all --dry-run` for the T23 audit.
   - JSONL telemetry (`SymphonyElixir.Telemetry`) +
     `mix telemetry.report` for the T26 fleet CLI.
   - `orchestrator_version_required` WORKFLOW.md gate.
   - Label-drift mid-flight: AgentRunner finishes the current turn
     cleanly and halts (no reroute) when the `repo:<name>` label
     changes during a run.

## Upstream sync cadence

Attempt `git fetch origin && git merge origin/main` into `udp` on the **first
Monday of each month**. The named owner (raul@pauca.co) triages conflicts and
publishes the merge result to the `udp` remote.

If a sync surfaces a conflict in any file these UDP commits touch, prefer the
UDP behaviour — those files exist because upstream Symphony does not yet
cover UDP's harness needs.

## Why this file exists

So an upstream sync conflict, or an attempt to upstream one of these changes,
can quickly identify which commit is UDP-local and why.
