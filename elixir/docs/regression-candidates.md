# Offline regression candidate evaluation

Symphony can project retained compact fleet telemetry into a bounded, privacy-safe corpus of
candidate regression cases. This is an operator-run offline workflow. It does not add a runtime
process, poller, ticket creator, fixture approver, retention policy, or cleanup job.

## Scan and inspect

The default command scans the exact seven-day UTC window ending today and prints a concise dry-run:

```bash
mix telemetry.regression_candidates
mix telemetry.regression_candidates --days 30 --through 2026-09-03
```

`--days` accepts only `7` or `30`. `--through YYYY-MM-DD` makes the inclusive window reproducible.
The source defaults to `SymphonyElixir.Telemetry.root_dir/0`; an operator may select another
absolute compact-telemetry directory with `--telemetry-root`. JSON output is still a dry run:

```bash
mix telemetry.regression_candidates --days 7 --through 2026-09-03 --json
```

Human output contains only candidate IDs, fixed selection reason enums, retained reproduction field
names, generated safe evidence references, and fixed scan/cap diagnostics. JSON contains the same
pending corpus and diagnostics. Neither output reproduces original telemetry rows.

The streaming reader selects at most one daily source for each date, preferring an active
`YYYY-MM-DD.jsonl` over `YYYY-MM-DD.jsonl.gz`. It stops after 50,000 rows, 60 files, 256 MiB of source
bytes, or 256 MiB of expanded bytes. Individual lines are capped at 16 KiB and a corpus at 1 MiB.
Completed rows before a byte limit are retained. Malformed, legacy, unsafe, overlong, or unsupported
rows produce fixed diagnostics or are ignored; they do not block a usable partial scan.

## Export pending candidates

Export is explicit and writes only `state=pending_review`. Create an operator-owned staging
directory outside the Symphony source tree first:

```bash
mkdir -m 700 /absolute/staging-dir
mix telemetry.regression_candidates --days 7 --through 2026-09-03 \
  --export /absolute/staging-dir
```

Symphony does not create the directory. It requires an existing regular directory with exact mode
`0700` and no symlink path component. The deterministic pending filename is published without
replacement and mode `0600`; an identical existing file is reported unchanged, while different
bytes at the same name are a conflict. Staging retention and removal remain operator-managed.

## External review and accepted fixtures

Generated assertions are proposals or `unknown`; they are not expected outcomes. A reviewer must
inspect the embedded allowlisted evidence, optionally verify it against an independent authoritative
source, copy the pending file to an operator-controlled reviewed fixture, and explicitly:

1. change `state` to `accepted`;
2. add an `assertions` object to each retained candidate using only supported fixed process and
   task-outcome values; and
3. replace pending review metadata with the current policy's `approved` human or independent review
   record (`method`, bounded `approval_ref`, a 64-hex `reviewer_sha256`, and canonical UTC
   `approved_at`).

There is deliberately no CLI approve or promote command. Review metadata records process evidence;
it is not a cryptographic signature, MAC, or proof of reviewer identity. The deterministic corpus
digest protects the generated candidate/evidence core against accidental modification, while human
review state and assertions remain separately validated. Only that reviewed safe accepted fixture,
not a pending export or telemetry/trace file, is eligible for a separately reviewed repository
commit; the task never copies or commits a fixture automatically.

Verify a reviewed fixture offline before using it in CI or an evaluation harness:

```bash
mix telemetry.regression_candidates --verify /absolute/staging-dir/rgc-corpus-<digest>.json
```

Verification reads at most 1 MiB from one regular, safely named file, checks the current v1 policy,
replays the generated candidate core from its embedded safe evidence, and requires externally
reviewed accepted assertions. A generated pending export cannot pass this command.

## Privacy boundary

Candidate generation reads only compact telemetry events from the fixed allowlist:
`run_manifest`, `failure`, failing `run_end`, extreme `budget_transition`, version 1 shadow
`no_progress_loop` alerts, authoritative `task_outcome`, and bounded review outcomes. It retains
only fixed enums, counts, digests, generated references, and these non-secret manifest provenance
fields when valid: backend, model, reasoning effort, task family, configuration/prompt/workflow
digests, Symphony SHA, and repository-head SHA.

The corpus never ingests protocol/session transcripts by default and never retains prompt bodies,
issue/workpad bodies, arbitrary user text, tool arguments or output, raw failure/reviewer prose,
credentials, or secret values. Selection is deterministic: events are grouped by safe run identity,
deduplicated by generated evidence reference, clustered by fixed failure/task/no-progress/prompt/
configuration/outcome dimensions, sampled by stable hashes, and capped at 100 candidates, two runs
per candidate, and ten evidence references per candidate.
