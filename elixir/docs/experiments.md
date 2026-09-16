# Controlled Reasoning-Effort Experiments

Symphony supports one deliberately narrow experiment protocol: an explicitly opted-in Codex task
may be deterministically assigned a control or variant `reasoning_effort`. It does not change the
backend, model, prompt, workflow text, retry policy, or task routing. The feature is default-off and
has no automatic promotion, approval, cleanup, polling, or background process.

## Configuration and authority

The host/operator owns the fail-closed master switch in its loaded workflow:

```yaml
agent:
  experiment_mode: off # off | apply
```

A target repository owns the versioned manifest in that repository's `WORKFLOW.md`:

```yaml
agent:
  experiment:
    schema_version: 1
    id: codex-effort-v1
    revision: 1
    opt_in_label: experiment:codex-effort-v1
    backend: codex
    repositories: [symphony]
    task_families: [simple_direct]
    variable: reasoning_effort
    control: {id: control, weight: 1, value: xhigh}
    variants:
      - {id: high, weight: 1, value: high}
```

The manifest is strict: one `control` arm, one to three variants, unique effort values and safe IDs,
positive weights whose total is at most 1,000, and exact repository/task-family eligibility. The
task must also have the exact opt-in label. Unknown fields or invalid values make the manifest
unavailable; they do not widen eligibility.

Assignment is allowed only when the task lineage is genuinely fresh, before its first backend turn.
A task that starts while the host switch is off or is ineligible cannot join later. Deterministic
unit, assignment, arm, manifest, and arm-configuration IDs make the assignment reproducible. The
existing trusted resume-packet sidecar preserves it across continuation, retry, wait, quota, and
restart boundaries. Manifest, route, or repository/issue identity drift permanently suspends the
assignment instead of reassigning it.

The host mode is checked again immediately before every turn. Switching to `off` does not interrupt
the current turn; it permanently suspends that task before its next turn and uses the baseline
effort from then on. Re-enabling does not resume it. This is an emergency rollback boundary, not a
pause switch.

## Prompt and privacy boundary

The assignment is host control state, never model input. Symphony reserves a fixed hidden budget
before compacting visible resume evidence, then removes the assignment before rendering and hashing
the literal-tail status packet. Otherwise-identical control, variant, active, and suspended tasks
therefore produce identical prompt-visible packet bytes even near the 16 KiB sidecar cap.

The packet, runtime metadata, and telemetry never carry labels, issue prose, prompt/transcript
bodies, tool arguments/output, workpad bodies, or arbitrary user content. Compact events contain
only fixed enums, bounded IDs/digests/counts, and normal run/retry lineage. Workspace collection and
turn cwd rules remain unchanged; experiments add no Git, Linear, validation, or source-repository
cwd operation.

## Exposure and suspension semantics

`experiment_exposure` is emitted only when a run actually begins an experiment-controlled turn. A
stable `exposure_id` gives one logical exposure per `run_id`; a retry has a new run and exposure, but
is not an independent trial. A process crash can replay the same physical JSONL event, so consumers
deduplicate the ID. `experiment_suspended` uses the same initial/replay convention and a stable
`suspension_id`. Suspension is contamination evidence, not a worker failure or interruption.

The persisted packet is written before a turn. If that write fails, execution remains nonblocking;
stable IDs preserve logical idempotence. There is intentionally no second store or two-phase event
delivery protocol.

## Offline descriptive report

Use retained compact telemetry only:

```bash
mix telemetry.experiment_report --days 7
mix telemetry.experiment_report --days 30 --through 2026-09-03 --json
mix telemetry.experiment_report --experiment codex-effort-v1 --revision 1 \
  --repository symphony --task-family simple_direct
```

Windows are exactly 7 or 30 UTC dates, inclusive of `--through`; the default is today's UTC date.
The reader retains its existing 50,000-event/60-file caps. Projection is capped at 20 experiment
version/stratum groups, four arms per group, and 80 arm rows. Invalid filters fail closed.

The report joins only strict v1 exposures, suspensions, run manifests, worker ends, token high
waters, explicit numeric costs, and authoritative task outcomes. It separates every experiment
version by repository and task family. A unit is excluded from comparable denominators when it has
a suspension, missing/mismatched/conflicting manifest, conflicting exposure/suspension ID,
cross-arm/config identity, multiple exposure IDs in one run, or repository/task stratum conflict.
Unavailable evidence stays unavailable.

Results are descriptive only: raw per-arm denominators, p50/p90 duration and high-water tokens,
explicit cost when present, authoritative exact-head/task outcomes, post-handoff evidence, and
treatment-minus-control deltas. Symphony does not report causal confidence or significance.
Pairing and Pass@k/Pass^k are explicitly unavailable because v1 has no repeated-trial protocol;
retries never become trials.

## Human decision boundary

The CLI cannot approve, promote, enable, disable, or mutate an experiment. Before using a report to
make any operator decision, manually verify:

- the exact reviewed host mode and repository manifest revision;
- the 7/30-day retention and `--through` window boundaries;
- workspace ownership, trusted sidecar permissions, and source-repository cwd isolation;
- contamination/exclusion counts and repository/task strata;
- exact-head, CI, human-review, merge/reopen/revert evidence outside worker completion; and
- that any claimed cost was explicitly emitted as numeric telemetry.

Keep the experiment off when those checks are incomplete. Retention and telemetry-file cleanup
remain operator-owned under the existing observability policy; this feature adds no deletion path.
