# Bounded quality and efficiency rollout

Deploy the harness changes through the normal service rollout. A local code change is not proof
that existing workers use that build: compare the worker run manifests' Symphony build and effective
configuration digests before comparing incidents or cohorts. Do not increase repository concurrency
while measuring the initial change.

For a small, explicitly labelled cohort, add this to the consumer repository's workflow front matter:

```yaml
agent:
  efficiency:
    mode: enforce
    enforce_labels: [efficiency:pilot]
    hygiene_only: true
    enforced_actions:
      - bound_future_tool_output
      - fresh_thin_context_delegation_only
      - prohibit_full_history_delegation
```

Add `efficiency:pilot` only to the selected issues. Other issues remain in shadow. Set
`mode: off` to stop enforcement; shadow mode can still apply explicitly allowlisted actions. This pilot preserves reviewer models, effort, packet bounds,
iteration limits and lenses. Compare comparable task families, normal exits, substantive review
acceptance, accepted handoffs and tokens per accepted handoff. Missing post-merge outcomes are
unknown, so collect independent merge/regression evidence before claiming a quality improvement.

For a dependency on particular repository content, request:

```json
{
  "reason": "Wait for the test-runner stabilization used by this candidate",
  "condition": {
    "type": "git_ref_changed",
    "ref": "refs/heads/develop",
    "paths": ["vitest.config.ts", "scripts/test-runner"]
  }
}
```

Paths are 1–32 literal relative file or directory names, at most 320 bytes each. Globs and git
pathspec magic are not interpreted. Traversal and control characters are rejected. Symphony may
fetch commit objects to inspect the remote tree; the checkout, index, branch and FETCH_HEAD are
preserved. Include every relevant configuration/dependency path or use a concrete PR-check wait;
incomplete path selection can miss a prerequisite. For a real prerequisite ticket, use Linear's
`blocks_current: true` on typed `linear_issue create_follow_up`, then `linear_dependencies_resolved`
on the parent ticket. The prerequisite inherits routing/pickup labels and enters Todo only after its
blocking relation is confirmed. The parent stays parked while blockers are active, with their
pickup status visible. Existing path waits are not automatically migrated.

Before measuring, inspect `workflow_policy` in each new run manifest. Restarting the host does not
update an old issue branch's workflow. `stale` means the loaded policy matches the merge base while
the fetched base changed; `candidate_change` identifies branch edits against an unchanged base;
`diverged` requires comparison. Sync branch policy through normal review, or explicitly select
`repos[].efficiency_policy_source: base` for base efficiency settings on new attempts. This opt-in
preserves hooks, prompts, routing and reviewer policy and fails if base policy is unavailable.
Telemetry reports expose policy status counts and actual hygiene-only enforcement. Compare these
with substantive first-review acceptance and tokens per accepted handoff; do not lower model effort
or concurrency based solely on worker exits or a single stuck issue.

Verify the following on the next cohort:

- A closed PR parks once with its observed state and releases the execution slot. Reopening it wakes
  the issue; replacing the attachment requires an explicit wait resume.
- A delivery failure preserves a validated approval in durable control state. A fresh local worker
  retries follow-up/PR delivery without model sessions when all reuse inputs remain identical. A
  failed tracker mutation retains the delivery intent and revalidates before retrying. Changed or
  unavailable evidence invalidates reuse and emits the reason; checkpoints expire after 24 hours.
- Follow-up creation works without a source project and names a missing source, team or Backlog
  state. Existing deterministic follow-up IDs keep a delivery retry from creating duplicate issues.
- Irrelevant commits do not wake path-filtered waits. Relevant additions, deletions and tree changes do.
- Behavioral evidence covers the reported failure and applicable interactions before final review.

The September audit identified operational work that needs separate ticket-level disposition:
revalidate UDPE-7474 against the deployed packet contract, resolve UDPE-7053's documented product
boundary before its missing bootstrap/legacy-occupancy regression, and set UDPE-6480's actual
prerequisite relation or precise path wait. These harness changes do not change those ticket states,
PRs, consumer settings, or deploy running workers.
