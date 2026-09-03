---
tracker:
  kind: linear
  project_slug: "symphony-0c79b11b75ea"
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
observability:
  # Compact, versioned fleet events are retained for rolling 30-day reports.
  telemetry_retention_days: 30
  # Compact session logs are eligible for explicit, dry-run-first maintenance.
  session_retention_days: 30
  # Raw protocol traces are gzip-compressed and retained for failures for 7 days.
  raw_trace_retention_days: 7
  raw_trace_policy: failures # none | failures | sampled | all
  raw_trace_sample_rate: 0.01
  raw_trace_debug: false
  session_compaction_enabled: true
  benign_notification_debug: false
  # Incident-only final prompt rendering with typed provenance boundaries.
  # Content is redacted and bounded; keep disabled during normal operation.
  prompt_debug: false
  prompt_debug_max_bytes: 32000
  # Additional credential names; mandatory defaults below always apply
  # and also match snake_case, kebab-case, and camelCase spellings.
  redact_fields:
    - authorization
    - api_key
    - token
    - access_token
    - refresh_token
    - cookie
    - set-cookie
    - password
    - secret
    - client_secret
    - private_key
    - x-api-key
hooks:
  # Symphony consumes mandatory standalone udp-gh auth before routed repository
  # lifecycle hooks; consumer workflows must not mint their own bot token.
  after_create: |
    git clone --depth 1 https://github.com/openai/symphony .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  # session_start runs before each Codex app-server session, including when an
  # existing workspace/branch is resumed. It is informational: failures are
  # logged and included in the first-turn task context but do not block the agent.
  session_start: |
    if [ -x scripts/hooks/session-start.sh ]; then
      scripts/hooks/session-start.sh
    fi
  # before_handoff runs before a Linear issue moves from In Progress to In Review.
  # In multi-repo mode Symphony first fetches the configured base branch and
  # skips this expensive hook when newer base changes overlap the candidate or
  # change the workflow/hook files needed to run the gate safely.
  # It never rebases, resets, or stashes a dirty worktree automatically.
  # Repositories can use it to block handoff until repo-local gates pass, for example:
  # before_handoff: |
  #   scripts/hooks/before-handoff.sh
  # Async protocol invocations receive SYMPHONY_HANDOFF_GATE_PROTOCOL=1. Polls
  # reuse before_handoff with SYMPHONY_HANDOFF_GATE_JOB_ID and skip repeated
  # GitHub auth and issue-context preparation, so the command should branch to
  # its cheap durable-job read before normal setup. Symphony persists the
  # attempted mutation before initial startup so infrastructure retries rerun
  # this hook directly instead of opening another model session. A retry first
  # revalidates the base and returns to the agent if the gate runtime changed.
  # These limits are independent of other lifecycle hooks.
  before_handoff_timeout_ms: 60000
  before_handoff_stale_ms: 120000
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
# Automated-review packet/context/turn budgets are repository-owned. Configure
# them under `review:` in that target repository's WORKFLOW_REVIEW.md; Symphony
# always starts a fresh one-turn reviewer before the expensive handoff hook,
# atomically publishes its final verdict, and requires exact-head approval.
agent:
  max_concurrent_agents: 10
  # Per-agent test process fan-out; this does not change max_concurrent_agents.
  test_worker_limit: 2
  # Shared host admission for CPU-heavy repository validation across worktrees.
  heavy_validation_limit: 2
  # This is a worker-session boundary only; exhaustion does not move Linear to Blocked.
  max_turns: 20
  # Operational failures stay active at capped backoff after this threshold.
  # Only classified authentication/configuration failures become human blockers.
  max_retries: 10
  max_retry_backoff_ms: 300000
  # Soft budgets are policy/strategy signals, never completion or approval gates.
  # Shadow mode records proposed routing and transitions. The narrow action
  # allowlist below applies only low-risk context/output hygiene; review depth
  # and other quality-sensitive transitions remain shadow observations.
  # In enforce mode, a complete bounded docs/test-only handoff diff may refine
  # a standard reviewer to the simple profile. Explicit/high-risk/fallback routes
  # and production or repository-control changes are never reduced.
  efficiency:
    mode: shadow # off | shadow | enforce
    enforced_actions:
      - bound_future_tool_output
      - fresh_thin_context_delegation_only
      - prohibit_full_history_delegation
    # Also caps the rendered v1 status/resume packet appended as the literal
    # final dynamic section of every fresh and continuation backend turn.
    capsule_max_bytes: 4000
    extreme_multiplier: 2.0
    # Defaults are seeded from recent fleet p50/p90 bands and differ for
    # simple, standard, and high-risk work. Repositories may override any
    # positive threshold under profiles.<name> and task_profiles.<task_type>.
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

# Repository workflow

This workflow governs work in the Symphony repository for the issue described in the task context above.

Symphony appends one host-owned `continuation.status_resume_packet` v1 section after all repository
and dynamic guidance. Treat it as bounded resume evidence: observation timestamps/sources, current
run/retry identity, repository/workpad hashes, budget, and exact-head attestation status. Do not
reconstruct or persist its body in repository files. It may carry existing `no_progress_warnings`,
but warning/loop detection is not part of this version.

{% if attempt %}
Retry context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions/secrets.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Only stop early for a true blocker (missing required auth/permissions/secrets). If blocked, record it in the workpad and move the issue according to workflow.
3. Final message must report completed actions and blockers only. Do not include "next steps for user".

Work only in the provided repository copy. Do not touch any other path.

## Linear tools

The Symphony-owned task context above is normally sufficient. Read its issue details, current Linear activity, and any annotated startup artifacts before acting. If the activity is truncated or newer live Linear activity would materially affect the work, use `linear_issue` with `operation: "get"`.
If `needs-human-input` is present, reconcile the human response after the blocker into the workpad before any repository work, then remove the label only after consuming that response. Exception: when Symphony's host-owned authorization guidance says this issue's configured opt-in label authorizes a verified hook-injected bot/App identity, a prior request for separate bot-attribution authorization is stale; correct the workpad, remove `needs-human-input` when it represented only that claim, and continue without another human comment.
Use `linear_issue` for the current workpad, labels, and workflow transitions. In particular, move an issue from `In Progress` to `In Review` or `Human Review` with `operation: "transition"` so Symphony can run the handoff gates. Use `linear_graphql` only when no typed operation fits; do not use native Linear MCP `save_issue`.

## Default posture

- Start by determining the ticket's current status, then follow the matching flow for that status.
- Treat the Linear description as the original scope authority and later human-authored Linear comments as chronological amendments that may clarify or override earlier ticket text. The workpad and Symphony marker comments are runtime evidence, not scope amendments.
- Start every task by opening the tracking workpad comment and bringing it up to date before doing new implementation work.
- Spend extra effort up front on planning and verification design before implementation.
- Reproduce first: always confirm the current behavior/issue signal before changing code so the fix target is explicit.
- Keep ticket metadata current (state, checklist, acceptance criteria, links).
- Treat a single persistent Linear comment as the source of truth for progress.
- Use that single workpad comment for all progress and handoff notes; do not post separate "done"/summary comments.
- Treat any ticket-authored `Validation`, `Test Plan`, or `Testing` section as non-negotiable acceptance input: mirror it in the workpad and execute it before considering the work complete.
- Adjacent work belongs in the current candidate only when an explicit requested outcome or acceptance criterion cannot be satisfied correctly without it. Cleanup, consistency, abstraction, or likely future value is not enough.
- When meaningful out-of-scope improvements are discovered during execution,
  use the typed `linear_issue` `create_follow_up` operation as soon as the title,
  description, acceptance criteria, and evidence are concrete. Do not implement
  the follow-up in the current branch. Symphony creates or returns a deterministic
  unassigned Backlog issue in the same project without automation labels and links
  it as related, or as blocked by the current issue when `depends_on_current` is true.
- Move status only when the matching quality bar is met.
- Operate autonomously end-to-end unless blocked by missing requirements, secrets, or permissions.
- Use the blocked-access escape hatch only for true external blockers (missing required tools/auth) after exhausting documented fallbacks.

## Related skills

- `linear`: interact with Linear.
- `commit`: produce clean, logical commits during implementation.
- `push`: keep remote branch current and publish updates.
- `pull`: keep branch updated with latest `origin/main` before handoff.
- `land`: when ticket reaches `Merging`, explicitly open and follow `.codex/skills/land/SKILL.md`, which includes the `land` loop.

## Status map

- `Backlog` -> out of scope for this workflow; do not modify.
- `Todo` -> queued; immediately transition to `In Progress` before active work.
  - Special case: if a PR is already attached, treat as feedback/rework loop (run full PR feedback sweep, address or explicitly push back, revalidate, return to `Human Review`).
- `In Progress` -> implementation actively underway.
- `Blocked` -> inactive; waiting for a human response recorded in a separate Linear comment. A human reactivates the issue by moving it to `In Progress` after replying.
- `Human Review` -> PR is attached and validated; waiting on human approval.
- `Merging` -> approved by human; execute the `land` skill flow (do not call `gh pr merge` directly).
- `Rework` -> reviewer requested changes; planning + implementation required.
- `Done` -> terminal state; no further action required.

## Step 0: Determine current ticket state and route

1. Fetch the issue by explicit ticket ID.
2. Read the current state.
3. Route to the matching flow:
   - `Backlog` -> do not modify issue content/state; stop and wait for human to move it to `Todo`.
   - `Todo` -> immediately move to `In Progress`, then ensure bootstrap workpad comment exists (create if missing), then start execution flow.
     - If PR is already attached, start by reviewing all open PR comments and deciding required changes vs explicit pushback responses.
   - `In Progress` -> continue execution flow from current scratchpad comment.
   - `Human Review` -> wait and poll for decision/review updates.
   - `Merging` -> on entry, open and follow `.codex/skills/land/SKILL.md`; do not call `gh pr merge` directly.
   - `Rework` -> run rework flow.
   - `Done` -> do nothing and shut down.
4. Check whether a PR already exists for the current branch and whether it is closed.
   - If a branch PR exists and is `CLOSED` or `MERGED`, treat prior branch work as non-reusable for this run.
   - Create a fresh branch from `origin/main` and restart execution flow as a new attempt.
5. For `Todo` tickets, do startup sequencing in this exact order:
   - `update_issue(..., state: "In Progress")`
   - find/create `## Codex Workpad` bootstrap comment
   - only then begin analysis/planning/implementation work.
6. Add a short comment if state and issue content are inconsistent, then proceed with the safest flow.

## Step 1: Start/continue execution (Todo or In Progress)

1.  Find or create a single persistent scratchpad comment for the issue:
    - Search existing comments for a marker header: `## Codex Workpad`.
    - Ignore resolved comments while searching; only active/unresolved comments are eligible to be reused as the live workpad.
    - If found, reuse that comment; do not create a new workpad comment.
    - If not found, create one workpad comment and use it for all updates.
    - Persist the workpad comment ID and only write progress updates to that ID.
2.  If arriving from `Todo`, do not delay on additional status transitions: the issue should already be `In Progress` before this step begins.
3.  Immediately reconcile the workpad before new edits:
    - Check off items that are already done.
    - Expand/fix the plan so it is comprehensive for current scope.
    - Ensure `Acceptance Criteria` and `Validation` are current and still make sense for the task.
4.  Start work by writing/updating a hierarchical plan in the workpad comment.
5.  Ensure the workpad includes a compact environment stamp at the top as a code fence line:
    - Format: `<host>:<abs-workdir>@<short-sha>`
    - Example: `devbox-01:/home/dev-user/code/symphony-workspaces/MT-32@7bdde33bc`
    - Do not include metadata already inferable from Linear issue fields (`issue ID`, `status`, `branch`, `PR link`).
6.  Add explicit acceptance criteria and TODOs in checklist form in the same comment.
    - If changes are user-facing, include a UI walkthrough acceptance criterion that describes the end-to-end user path to validate.
    - If changes touch app files or app behavior, add explicit app-specific flow checks to `Acceptance Criteria` in the workpad (for example: launch path, changed interaction path, and expected result path).
    - If the ticket description/comment context includes `Validation`, `Test Plan`, or `Testing` sections, copy those requirements into the workpad `Acceptance Criteria` and `Validation` sections as required checkboxes (no optional downgrade).
7.  Run a principal-style self-review of the plan and refine it in the comment.
8.  Before implementing, capture a concrete reproduction signal and record it in the workpad `Notes` section (command/output, screenshot, or deterministic UI behavior).
9.  Run the `pull` skill to sync with latest `origin/main` before any code edits, then record the pull/sync result in the workpad `Notes`.
    - Include a `pull skill evidence` note with:
      - merge source(s),
      - result (`clean` or `conflicts resolved`),
      - resulting `HEAD` short SHA.
10. Compact context and proceed to execution.

## PR feedback sweep protocol (required)

When a ticket has an attached PR, run this protocol before moving to `Human Review`:

1. Identify the PR number from issue links/attachments.
2. Gather feedback from all channels:
   - Top-level PR comments (`gh pr view --comments`).
   - Inline review comments (`gh api repos/<owner>/<repo>/pulls/<pr>/comments`).
   - Review summaries/states (`gh pr view --json reviews`).
3. Treat every actionable reviewer comment (human or bot), including inline review comments, as blocking until one of these is true:
   - code/test/docs updated to address it, or
   - explicit, justified pushback reply is posted on that thread.
4. Update the workpad plan/checklist to include each feedback item and its resolution status.
5. Re-run validation after feedback-driven changes and push updates.
6. Repeat this sweep until there are no outstanding actionable comments.

## Blocked-access escape hatch (required behavior)

Use this only when completion is blocked by missing required tools or missing auth/permissions that cannot be resolved in-session.

- GitHub is **not** a valid blocker by default. Always try fallback strategies first (alternate remote/auth mode, then continue publish/review flow).
- If useful work can continue only after GitHub Actions recovers, PR checks change, a git ref advances, or this ticket's Linear activity changes, call Symphony's `wait_for` tool once and end the turn. Do not repeatedly poll an unchanged external condition; Symphony will release the agent slot and resume the issue after the condition changes. Cross-issue prerequisites belong in Linear's `blocks` relation; never park on a tracking follow-up created during the run. Never use `wait_for` for local CPU or memory pressure, another validation running, local process or port contention, a time delay, or a Symphony-owned handoff job; Symphony polls accepted handoff jobs itself. Continue useful work and allow independently bounded validations to overlap.
- Do not move to `Human Review` for GitHub access/auth until all fallback strategies have been attempted and documented in the workpad.
- If a non-GitHub required tool is missing, required non-GitHub auth is unavailable, or a product decision is required, add `needs-human-input` and move the ticket to `Blocked` with a short blocker brief in the workpad that includes:
  - what is missing,
  - why it blocks required acceptance/validation,
  - exact human action needed to unblock.
- A `linear_issue` transition that moves an issue to `Blocked` must include a top-level `blocker` object with a concise `summary` and one of these `kind` values: `missing_required_tool`, `missing_authentication`, `missing_permission`, or `product_decision`. Raw `linear_graphql` workflow transitions are rejected. Symphony, reviewer, handoff, CI, and other operational failures are not valid blocker kinds; leave the issue active for orchestrator retry.
- Keep the brief concise and action-oriented; do not add extra top-level comments outside the workpad. The human response belongs in a separate Linear comment; on redispatch, reconcile it into the workpad and remove `needs-human-input` before resuming.

## Step 2: Execution phase (Todo -> In Progress -> Human Review)

1.  Determine current repo state (`branch`, `git status`, `HEAD`) and verify the kickoff `pull` sync result is already recorded in the workpad before implementation continues.
2.  If current issue state is `Todo`, move it to `In Progress`; otherwise leave the current state unchanged.
3.  Load the existing workpad comment and treat it as the active execution checklist.
    - Edit it liberally whenever reality changes (scope, risks, validation approach, discovered tasks).
4.  Implement against the hierarchical TODOs and keep the comment current:
    - Check off completed items.
    - Add newly discovered items in the appropriate section.
    - Keep parent/child structure intact as scope evolves.
    - Update the workpad immediately after each meaningful milestone (for example: reproduction complete, code change landed, validation run, review feedback addressed).
    - Never leave completed work unchecked in the plan.
    - For tickets that started as `Todo` with an attached PR, run the full PR feedback sweep protocol immediately after kickoff and before new feature work.
5.  Run validation/tests required for the scope.
    - Mandatory gate: execute all ticket-provided `Validation`/`Test Plan`/ `Testing` requirements when present; treat unmet items as incomplete work.
    - Prefer a targeted proof that directly demonstrates the behavior you changed.
    - You may make temporary local proof edits to validate assumptions (for example: tweak a local build input for `make`, or hardcode a UI account / response path) when this increases confidence.
    - Revert every temporary proof edit before commit/push.
    - Document these temporary proof steps and outcomes in the workpad `Validation`/`Notes` sections so reviewers can follow the evidence.
    - If app-touching, run `launch-app` validation and capture/upload media via `github-pr-media` before handoff.
6.  Re-check all acceptance criteria and close any gaps.
7.  Before every `git push` attempt, run the required validation for your scope and confirm it passes; if it fails, address issues and rerun until green, then commit and push changes.
8.  Attach PR URL to the issue (prefer attachment; use the workpad comment only if attachment is unavailable).
    - Ensure the GitHub PR has label `symphony` (add it if missing).
9.  Merge latest `origin/main` into branch, resolve conflicts, and rerun checks.
10. Update the workpad comment with final checklist status and validation notes.
    - Mark completed plan/acceptance/validation checklist items as checked.
    - Add final handoff notes (commit + validation summary) in the same workpad comment.
    - Do not include PR URL in the workpad comment; keep PR linkage on the issue via attachment/link fields.
    - Add a short `### Confusions` section at the bottom when any part of task execution was unclear/confusing, with concise bullets.
    - Do not post any additional completion summary comment.
11. Before moving to `Human Review`, poll PR feedback and checks:
    - Read the PR `Manual QA Plan` comment (when present) and use it to sharpen UI/runtime test coverage for the current change.
    - Run the full PR feedback sweep protocol.
    - Confirm PR checks are passing (green) after the latest changes.
    - Confirm every required ticket-provided validation/test-plan item is explicitly marked complete in the workpad.
    - Repeat this check-address-verify loop until no outstanding comments remain and checks are fully passing.
    - Re-open and refresh the workpad before state transition so `Plan`, `Acceptance Criteria`, and `Validation` exactly match completed work.
12. Only then move issue to `Human Review`.
    - Exception: if blocked by missing required non-GitHub tools/auth or product input per the blocked-access escape hatch, move to `Blocked` with the blocker brief and explicit unblock actions.
13. For `Todo` tickets that already had a PR attached at kickoff:
    - Ensure all existing PR feedback was reviewed and resolved, including inline review comments (code changes or explicit, justified pushback response).
    - Ensure branch was pushed with any required updates.
    - Then move to `Human Review`.

## Step 3: Human Review and merge handling

1. When the issue is in `Human Review`, do not code or change ticket content.
2. Poll for updates as needed, including GitHub PR review comments from humans and bots.
3. If review feedback requires changes, move the issue to `Rework` and follow the rework flow.
4. If approved, human moves the issue to `Merging`.
5. When the issue is in `Merging`, open and follow `.codex/skills/land/SKILL.md`, then run the `land` skill in a loop until the PR is merged. Do not call `gh pr merge` directly.
6. After merge is complete, move the issue to `Done`.

## Step 4: Rework handling

1. Treat `Rework` as a full approach reset, not incremental patching.
2. Re-read the full issue body and all human comments; explicitly identify what will be done differently this attempt.
3. Close the existing PR tied to the issue.
4. Remove the existing `## Codex Workpad` comment from the issue.
5. Create a fresh branch from `origin/main`.
6. Start over from the normal kickoff flow:
   - If current issue state is `Todo`, move it to `In Progress`; otherwise keep the current state.
   - Create a new bootstrap `## Codex Workpad` comment.
   - Build a fresh plan/checklist and execute end-to-end.

## Completion bar before Human Review

- Step 1/2 checklist is fully complete and accurately reflected in the single workpad comment.
- Acceptance criteria and required ticket-provided validation items are complete.
- Validation/tests are green for the latest commit.
- PR feedback sweep is complete and no actionable comments remain.
- PR checks are green, branch is pushed, and PR is linked on the issue.
- Required PR metadata is present (`symphony` label).
- If app-touching, runtime validation/media requirements from `App runtime validation (required)` are complete.

## Guardrails

- If the branch PR is already closed/merged, do not reuse that branch or prior implementation state for continuation.
- For closed/merged branch PRs, create a new branch from `origin/main` and restart from reproduction/planning as if starting fresh.
- If issue state is `Backlog`, do not modify it; wait for human to move to `Todo`.
- Do not edit the issue body/description for planning or progress tracking.
- Use exactly one persistent workpad comment (`## Codex Workpad`) per issue.
- If comment editing is unavailable in-session, use the update script. Only report blocked if both MCP editing and script-based editing are unavailable.
- Temporary proof edits are allowed only for local verification and must be reverted before commit.
- If out-of-scope improvements are found, leave them out of this candidate and
  create the separate issue through typed `linear_issue create_follow_up`; record
  the returned identifier in the workpad.
- Do not move to `Human Review` unless the `Completion bar before Human Review` is satisfied.
- In `Human Review`, do not make changes; wait and poll.
- If state is terminal (`Done`), do nothing and shut down.
- Keep issue text concise, specific, and reviewer-oriented.
- If blocked and no workpad exists yet, add one blocker comment describing blocker, impact, and next unblock action.

## Workpad template

Use this exact structure for the persistent workpad comment and keep it updated in place throughout execution:

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1\. Parent task
  - [ ] 1.1 Child task
  - [ ] 1.2 Child task
- [ ] 2\. Parent task

### Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

### Validation

- [ ] targeted tests: `<command>`

### Notes

- <short progress note with timestamp>

### Confusions

- <only include when something was confusing during execution>
````
