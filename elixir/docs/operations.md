# Symphony rollout and session-log maintenance

This runbook deploys the observability hot-path, compact trace, and test-worker changes without
interrupting active work. Commands that stop/restart a service or remove retained logs are examples
for an explicitly authorized maintenance window; do not run them during an active agent session.

## 1. Build and stage

Build away from the live executable and keep the currently installed binary available for rollback:

```bash
cd /path/to/symphony/elixir
mise exec -- make all
mise exec -- mix build
sha256sum bin/symphony
```

Record the source commit, binary checksum, current service command (including `--logs-root` and
`--port`), and the existing binary path. Do not overwrite the executable used by the live process.

## 2. Drain without lowering agent concurrency

Enable Symphony's persisted drain mode; do not change `agent.max_concurrent_agents`. Existing agents
continue, while new candidates, retries, and quota probes remain paused:

```bash
curl -fsS -X POST http://127.0.0.1:PORT/api/v1/drain
curl -fsS http://127.0.0.1:PORT/api/v1/state
```

The state response reports `mode.draining: true`. You may wait for all work to finish, or restart
while sessions are still active: detached workers keep owning their backend processes and the next
orchestrator reconnects to them. Do not remove `~/.symphony/workers` or stop worker PIDs.

The first rollout that introduces persistent workers cannot adopt agents launched by an older
Symphony version; drain those legacy runs fully once. Subsequent rollouts can reconnect.

## Parked external waits

Agents use the typed `wait_for` tool instead of consuming turns while polling unchanged GitHub,
git, Linear, or time conditions. These waits survive restarts in `~/.symphony/waits.json`, appear in
the dashboard as **Waiting work**, and do not occupy agent slots. **Resume now** wakes the issue
without waiting for the next probe. **Cancel wait** removes the external condition and returns the
issue to normal scheduling; it does not cancel or close the Linear issue.

## 3. Install and restart

Atomically install the staged binary using the deployment's normal release mechanism, retain the
previous binary, and start the service with the exact recorded workflow/log-root/port arguments.
Verify the new PID, start time, source commit/checksum, and configured `agent.test_worker_limit`.
Confirm the same `persistent_worker_id` values appear in `/api/v1/state`, then resume dispatch:

```bash
curl -fsS -X POST http://127.0.0.1:PORT/api/v1/resume
```

If verification fails, leave drain mode enabled while investigating or rolling back. Cancelling
drain mode is reversible and schedules an immediate tracker poll.

## 4. Verify before cleanup

Check all of the following before touching retained files:

- A disposable issue starts and its agent environment contains
  `SYMPHONY_TEST_WORKER_LIMIT=<configured limit>`; Vitest uses `--maxWorkers` and Playwright uses
  `--workers` with that value.
- `agent.max_concurrent_agents` is unchanged.
- A connected dashboard receives coalesced refreshes and its live transcript reports a bounded
  window for a large session; the issue JSON endpoint still exposes explicit full history.
- Ordinary notification deltas do not create one debug log line or compact NDJSON record each.
- `observability.raw_trace_policy`, sample rate, redaction, and retention match `WORKFLOW.md`.
  A successful unsampled test session removes its pending raw sidecar; a failed test session keeps
  a readable redacted gzip trace.
- While a test session runs, `<session>.ndjson.active` exists; normal finalization removes it.
- CPU/run-queue sampling over a representative dashboard stream is materially below the old
  baseline and has no sustained I/O wait.

Rollback to the preserved binary if these checks fail. Keep the retained logs for diagnosis.

## 5. Plan and apply retention

The maintenance task only considers `.ndjson`, `.raw.ndjson.gz`, and
`.raw.ndjson.gz.pending` files older than the configured
`observability.session_retention_days`. It ignores symlinks and protects every compact/raw path
associated with an `.active` marker. For a legacy process that predates markers, drain fully or pass
each known live compact path with repeated `--active-path` options.

First run the default dry run against the same log root used by the service:

```bash
mise exec -- mix session_logs.prune --root /path/to/log/codex_sessions --verbose
```

You may override the policy explicitly for the maintenance window:

```bash
mise exec -- mix session_logs.prune \
  --root /path/to/log/codex_sessions \
  --older-than-days 30
```

Record the candidate file count and bytes, confirm the service has no active work, take any required
backup, and obtain deletion authorization. Only then apply the exact reviewed policy:

```bash
mise exec -- mix session_logs.prune \
  --root /path/to/log/codex_sessions \
  --older-than-days 30 \
  --apply
```

Record removed files/reclaimed bytes/failures, rerun the dry run, check disk usage, and verify the
dashboard/API again. The task rechecks age and active markers immediately before each removal; it
does not remove marker files or files outside the selected session-log directory.
