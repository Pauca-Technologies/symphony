# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls Linear for candidate work
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During agent sessions, Symphony owns a canonical first-turn task context. It contains the issue's
identifier, title, state, labels, URL, and description followed by a bounded, most-recently-updated
Linear comment window fetched immediately before each outer dispatch. The current workpad and human
unblock decisions are therefore deterministic task input. Any Markdown files produced by
`hooks.session_start` appear next in an annotated startup-artifact section, followed by the rendered
repository workflow. A truncation marker tells the agent when an older focused lookup may still be
required. If the comment read fails, the worker attempt fails and retries rather than starting with
incomplete context.

Symphony writes the same issue and comment snapshot outside the agent-writable workspace and exposes
its path as `SYMPHONY_ISSUE_CONTEXT_FILE` to lifecycle hooks and the agent process. Version 2 adds
`issue.comments` and `issue.commentsTruncated`; the file never contains a Linear credential.
Consumer-repository scripts can therefore use current task context without receiving that
credential. `linear_graphql` remains available when newer live Linear data or an operation is
materially needed. Handoff state changes must use that gated tool; Symphony does not auto-approve
native Linear MCP `save_issue` calls because they cannot run `hooks.before_handoff` or the automated
review gate.

`hooks.before_handoff` may implement the version 1 asynchronous gate protocol. Symphony sets
`SYMPHONY_HANDOFF_GATE_PROTOCOL=1`; a `pending` or `running` report exits `3` and supplies a durable
job ID, exact candidate identity, heartbeat, progress, and next-poll delay. Symphony persists the
captured Linear mutation outside the agent-writable worktree, closes the active model turn, and
polls with `SYMPHONY_HANDOFF_GATE_JOB_ID` without consuming model turns or tokens. Only a `passed`
report for the original candidate can release the mutation. Failed and invalidated outcomes resume
the implementor once with compact remediation. Stale-heartbeat, malformed-protocol, and other
infrastructure outcomes fail the worker attempt and enter orchestrator backoff without consuming
more model turns or changing the issue to `Blocked`. A restart reattaches to the persisted job
rather than starting a duplicate gate.

When a target repo provides `WORKFLOW_REVIEW.md`, Symphony runs that review workflow during gated
`In Progress` to review-state handoffs. The handoff tool call records the requested Linear
mutation, the active implementor turn closes, and Symphony runs the reviewer before applying that
mutation. An accepted deferred review returns a successful `deferred_review_started` tool result
with explicit instructions to end the turn without retrying the mutation. If the Linear issue has
an attached GitHub PR URL, the review gate uses that PR directly for the human-review section;
otherwise it falls back to the current workspace branch's PR.

Each pass starts a fresh, ephemeral reviewer thread with no implementor transcript or canonical
issue-context file. Symphony gives it a versioned JSON packet pinned to the resolved base and head
SHAs and a diff fingerprint. The packet carries the compact issue contract, changed-file manifest,
area-specific repository rules, risk/lens rationale, exact-head validation attestations, prior open
findings with their reviewed SHA, and a bounded follow-up delta. Packet compaction never removes
the commands for reading the authoritative full diff or the applicable security/tenant/auth rule
paths. High-risk follow-ups must finish with another complete base-to-head pass.

The reviewer is fail-safe. Its terminal outcomes are `approved`, `request_changes`,
`automation_inconclusive`, `infrastructure_unavailable`, and
`budget_exhausted_with_findings`. Only `approved` for the exact pinned candidate SHA may apply the
captured Linear mutation. Missing or malformed verdicts, reviewer timeout/crash/tool/auth failures,
and unresolved findings at the iteration limit remain visibly unapproved. Symphony posts a
marker-delimited, note-once escalation containing the candidate SHA, passes attempted, failure
reason, severity counts, findings, and resume condition; the runtime API and dashboard expose the
same review state.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill can use `linear_graphql` for optional live reads and operations such as
     comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

`mix build` creates the internal `bin/symphony.escript`; start Symphony through the committed
`bin/symphony` launcher as shown above. The launcher converts terminal Ctrl+C into a graceful
application stop so the selected worker shutdown policy runs before the VM exits.

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

## GitHub App authentication

Every Symphony run targets a GitHub repository, so GitHub App authentication is a mandatory host
capability rather than a repository hook. The independently maintained
[`udp-gh`](https://github.com/Pauca-Technologies/udp-gh) CLI owns repository discovery, JWT signing,
installation-token caching, and the refreshing `gh` shim.
Symphony invokes `udp-gh prepare --cwd <workspace>`, validates its versioned token-free JSON
contract, and injects the returned environment into lifecycle hooks and agent backends. A preflight
failure aborts the attempt as `authentication_configuration`; it is never deferred until the first
`gh` command or reported as a generic agent-process exit.

Configure the service environment with:

- `GITHUB_APP_ID`
- either `GITHUB_APP_PRIVATE_KEY_FILE` or `GITHUB_APP_PRIVATE_KEY` (escaped `\\n` newlines are
  accepted for inline keys)
- optionally `GITHUB_APP_INSTALLATION_ID`; when omitted, `udp-gh` resolves the installation for the
  current repository
- optionally `UDP_AGENT_COMMIT_NAME` and `UDP_AGENT_COMMIT_EMAIL`; when both are present `udp-gh`
  exports matching Git author and committer identity

Install `udp-gh` on the service `PATH`, or place it beside `bin/symphony.escript`. It is a static
executable with no Symphony, Elixir, Node.js, or repository-package runtime dependency:

```bash
git clone git@github.com:Pauca-Technologies/udp-gh.git
make -C udp-gh install PREFIX="$HOME/.local"
```

Installation tokens are cached per worktree under `.artifacts/udp-gh/` with mode `0600`. The
injected `gh` shim refreshes tokens before their one-hour expiry, so long sessions do not depend on
a startup token remaining valid. Tokens are passed only to the real `gh` child; they are not
exported into the general hook or agent shell. Any inherited `GH_TOKEN`, `GITHUB_TOKEN`, or
enterprise equivalent is explicitly removed so an operator's login cannot override the App
identity.

Interactive use requires only the installed `udp-gh` executable, not Symphony:

```bash
# Validate credentials and the App installation for the current checkout.
udp-gh check

# Activate the bot identity in an interactive shell, then restore prior values.
eval "$(udp-gh on)"
gh auth status
eval "$(udp-gh off)"

# Or run one App-authenticated GitHub CLI command without changing this shell.
udp-gh gh pr list
```

`udp-gh` adds `/.artifacts/` to the checkout's local Git exclude so auth state cannot be
accidentally staged in repositories that do not globally ignore that directory. It does not create
or source a shell `session.env`; machine consumers receive explicit `set` and `unset` collections.

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
  session_start: |
    scripts/hooks/session-start.sh
  before_handoff: |
    scripts/hooks/before-handoff.sh
  before_handoff_timeout_ms: 60000
  before_handoff_stale_ms: 120000
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- Symphony composes the first turn from typed, hashed sections. The host-owned Task context is
  authoritative for issue details and current activity; an exact or formatting-equivalent copy of
  the issue description rendered by the repository template is replaced with a reference to that
  canonical section. Similar or distinct repository rules are preserved and reported as ambiguous
  overlap rather than being deleted heuristically. Continuations reuse version/hash identities in
  a bounded capsule and include changed current candidate metadata plus only current open findings.
- When an issue carries the host-configured Linear opt-in label, the host-owned constraints state
  that repository-hook-injected bot/App credentials are authorized for that unattended run. A
  verified injected bot identity resolves a stale GitHub-attribution blocker without requiring a
  second human comment or personal `gh` login; genuinely missing or insufficient credentials can
  still block after in-session recovery is exhausted.
- In multi-repository mode, each `repos[]` entry in host-owned
  `~/.symphony/config.yml` has a repository concurrency and overlap policy:

  ```yaml
  repos:
    - id: udp-dashboard-v2
      label: repo:dashboard-v2
      repo_url: git@github.com:example/udp-dashboard-v2.git
      base_branch: develop
      max_concurrent: 3
      overlap_policy: serialize       # serialize | advisory | off
      overlap_threshold: 0.5          # (0, 1]
      scheduling_override_label: symphony:overlap-override
      path_hints:
        area:auth: [app/auth/**, test/auth/**]
        component:billing: [app/billing/**]
  ```

  Symphony starts with issue `path:<repo-relative-path>` labels and configured
  label hints, upgrades predictions from backend plan updates, then replaces
  them with the actual git changed-file manifest. `serialize` queues candidates
  whose overlap meets the threshold while allowing disjoint work up to
  `max_concurrent`; the override label bypasses overlap serialization but never
  the repository ceiling. Dependency order is enforced for every active state,
  then Linear priority (Urgent, High, Medium, Low, and finally unprioritized),
  creation time, and identifier provide deterministic fairness. Reservations exist only for live
  workers, so terminal, stalled, or blocked work releases them and a restart cannot resurrect a
  stale lease.
- For a routed worktree, Symphony fetches and compares the configured base on
  the local or SSH worker that owns it immediately before `before_handoff`. An
  irrelevant base advance proceeds. An
  overlapping advance blocks before final validation or automated review and
  returns compact remediation. The check never rebases, resets, or stashes; a
  dirty worktree is preserved for deliberate agent judgment. The exact passing
  decision is handed to the immediately following review gate so it is not
  fetched twice, while every later handoff attempt performs a new fetch.
- On redispatch, a routed worktree is reset to the latest pushed issue branch
  (or the configured base when no issue branch exists). Symphony first saves
  tracked local changes under `symphony/rescue/*`. If an interrupted rebase,
  merge, cherry-pick, or revert left unmerged files, Symphony captures their
  exact working-tree contents with a temporary index, quits the stale Git
  operation, and then resets. If either preservation or operation cleanup
  fails, Symphony leaves the worktree untouched and fails the attempt.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
  The first turn receives the canonical task context followed by the rendered repository workflow;
  later turns on the same live thread receive
  only compact continuation guidance plus any actionable handoff or reviewer findings. Symphony
  records prompt character/byte counts and included section names without storing raw prompt text.
  It also records SHA-256 hashes for the complete prompt and each injected section, allowing prompt
  reuse/duplication analysis without retaining task or workflow prose.
  A newly started backend thread still receives the full first-turn prompt, including on retries,
  because it cannot safely rely on context retained by a previous process. Reaching `max_turns`
  ends only that worker session; it does not change the Linear state or add `needs-human-input`.
- Agents can call Symphony's typed `wait_for` tool when useful work is blocked only on an external
  state change: GitHub Actions recovery, PR-check changes, a git ref advancing, or Linear
  issue/comment activity. The worker then exits cleanly and releases its concurrency slot while
  a non-LLM watcher persists the wait in `~/.symphony/waits.json`. Identical conditions share one
  probe with bounded exponential backoff. When the condition changes, the issue re-enters the
  normal priority/concurrency scheduler with a compact state-change prompt. The terminal dashboard
  exposes a dedicated Waiting count and row section; the web dashboard adds an above-the-fold
  Waiting badge linked to the detailed rows plus **Resume now** and **Cancel wait**. Cancelling the
  wait returns the issue to normal scheduling rather than abandoning the assigned Linear issue.
  A GitHub Actions recovery wait wakes when the Actions component becomes operational or when every
  active incident affecting Actions formally reaches the `monitoring`/`resolved` phase, allowing one
  controlled retry as soon as GitHub reports mitigation rather than waiting for the component badge.
  The tool rejects clock waits and must not be used for local resource pressure, another validation,
  or local process/port contention; independently bounded validations are allowed to overlap.
  PR-check waits treat GitHub's terminal `SKIPPED` checks as neutral, so passed checks plus intentional
  skips resolve to `pass` instead of remaining parked as `pending`.
- Run failures are classified before they reach retry scheduling. Stable classes distinguish agent
  or protocol errors, timeout/stall, transient infrastructure, authentication/configuration,
  provider rate limits, provider usage/quota limits, and handoff/reviewer/gate failures. The local
  JSONL telemetry records the failure class and retry-policy action (`scheduled`, `suppressed`,
  `parked`, or `probed`) rather than requiring operators to parse exception text. A retry blocked
  by an open circuit emits `suppressed` immediately before it enters the persistent parked queue.
  When failures cross `agent.max_retries`, operational failures remain active at capped backoff;
  only classified authentication/configuration failures are automatically moved to `Blocked` for
  human action.
- Agent-requested transitions to `Blocked` require a structured blocker kind and summary. The
  accepted kinds are missing required tool, authentication, permission, or product decision;
  Symphony, reviewer, handoff, CI, and other operational failures remain active for retry.
- An authoritative Codex `usageLimitExceeded` result opens a Codex account quota circuit. The
  account boundary is the execution credential boundary (`local` or the specific SSH worker host),
  so a circuit on one worker does not suppress the same backend on a worker using another account.
  Symphony parks already-claimed retries without incrementing `failure_counts`, suppresses new
  Codex work, and continues dispatching issues explicitly routed to other backends. At the provider reset time
  (or a bounded fallback deadline when no usable reset is supplied), exactly one parked issue is
  admitted as a probe. A successful probe or a newer rate-limit update that positively reports
  available capacity closes the circuit and releases parked issues in FIFO order. Ambiguous errors
  never open the circuit and continue through the normal bounded per-issue retry path.
- Active quota circuits are checkpointed to `~/.symphony/quota-circuits.json`. This deliberately
  small snapshot preserves outage deadlines and parked issue order across an orchestrator restart;
  it does not persist the general retry queue. Circuit state, reset/probe deadlines, account scope,
  and parked counts are exposed by the runtime API and status dashboard.
- Each dispatched issue runs in a detached, authenticated worker BEAM registered under
  `~/.symphony/workers`. That worker owns the backend process and its stdio port; the main
  orchestrator owns only a reconnecting relay. Restarting or crashing the orchestrator therefore
  preserves active Codex, ACP, and Claude Code sessions, including remote sessions reached through
  SSH. A replacement orchestrator adopts the workers and replays their latest acknowledged runtime
  checkpoint plus any events produced while disconnected. Completed records are reclaimed rather
  than adopted, so a cleanly stopped worker cannot become a synthetic failed run after restart;
  per-worker logs live under `~/.symphony/worker-logs`. Worker BEAMs use a small
  scheduler pool because model and repository work runs in external processes.
- Eligible issues and continuations that cannot run because the global, per-state, repository, or
  worker-host capacity is occupied remain visible in the scheduling queue. Capacity checks use the
  normal polling cadence and do not increment retry attempts or emit agent-failure telemetry.
- Drain mode pauses new candidate dispatch, retries, and quota probes without stopping active
  workers. Its state is saved in `~/.symphony/drain-state.json`, so it remains active through the
  restart it is intended to protect. Enable it with `POST /api/v1/drain` or the dashboard button;
  cancel it with `POST /api/v1/resume` or **Cancel drain**. Cancelling schedules an immediate poll.
- The independent shutdown policy controls what Ctrl+C does to active workers. The default,
  `preserve_workers`, leaves detached agents running for reconnection. Select `terminate_workers`
  to stop tracked workers and their subprocess trees before Symphony exits. The choice is saved in
  `~/.symphony/shutdown-policy.json` and can be changed from the dashboard or with
  `POST /api/v1/shutdown-policy/preserve` and `POST /api/v1/shutdown-policy/terminate`. Changing this
  policy does not enable or cancel drain mode.
- Backend turn wall-clock ceilings are disabled by default (`codex.turn_timeout_ms: 0` and
  `prompt_timeout_ms: 0` for ACP/Claude Code), so an active agent may work for multiple hours.
  The separate five-minute `stall_timeout_ms` watchdog remains enabled and is refreshed by backend
  activity. Set a positive turn/prompt timeout only when an operator wants an additional absolute
  ceiling; streamed activity does not reset that opt-in ceiling.
- `agent.backend` selects the coding-agent backend: `codex` (default, the Codex app-server described
  above), `acp` (the Agent Client Protocol, e.g. `opencode acp`), or `claude_code` (native Claude Code
  `claude -p` stream-json). All backends honor the same handoff gate and observability transcript.
  See [docs/acp.md](docs/acp.md) for the ACP setup and the `acp` config block, and
  [docs/claude-code.md](docs/claude-code.md) for the Claude Code setup and the `claude_code` config
  block. Both alternative backends share the same local-only gate / non-intercepted `fs`/`terminal`
  limitations as ACP.
- `agent.pre_command` remains available for non-authentication, host-wide shell preparation. It runs
  (joined with `&&`) in the per-issue workspace cwd before every backend process. GitHub App auth
  does not belong here: Symphony injects the validated `udp-gh` environment natively. Any `.env`
  file a custom pre-command sources is sanitized before launch. For Codex, Symphony disables the
  per-thread shell snapshot when a pre-command is configured so a profile reload cannot undo
  intentional `PATH` changes.
- `agent.test_worker_limit` (default `2`) bounds test-runner fan-out inside each agent without
  changing `agent.max_concurrent_agents`. Every backend receives
  `SYMPHONY_TEST_WORKER_LIMIT`; the first-turn prompt directs agents to pass
  [`--maxWorkers=<limit>`](https://vitest.dev/config/maxworkers) to Vitest and
  [`--workers=<limit>`](https://playwright.dev/docs/test-parallel#limit-workers) to Playwright (or
  read the neutral variable from repository runner config). The same neutral limit is exported to
  outer lifecycle hooks such as `before_handoff`, so detached validation cannot silently regain the
  host's full CPU count.
- `agent.heavy_validation_limit` (default `2`) is exported as
  `SYMPHONY_HEAVY_VALIDATION_LIMIT` to agents and lifecycle hooks so repository harnesses can admit
  CPU-heavy validation across worktrees independently of per-command test worker fan-out.
- Detached `handoff_pending_gate` and `handoff_pending_review` lifecycles keep their issue claim and
  path-overlap reservation, but no longer consume global, per-state, per-host, or per-repository
  implementation capacity. Disjoint implementation can therefore continue while a completed
  candidate validates or is reviewed without allowing overlapping work into reserved paths.
- `agent.label_presets` chooses the backend (and model) **per task** from the issue's Linear labels,
  overriding the global `agent.backend` for matching issues. It is an ordered list; the first preset
  whose `label` is present on the issue wins (positional precedence — list order, first match), and
  an unmatched issue falls through to `agent.backend`. Each preset has `label` (a Linear label name,
  matched exactly — see the label-group note below), `backend` (`codex` | `acp` | `claude_code`), and an optional `model` (passed to
  the chosen backend — Codex `thread/start`, `OPENCODE_CONFIG_CONTENT` for ACP/OpenCode, or `--model`
  for Claude Code). Resolution happens once at run start, so a relabel takes
  effect on the next run. Example:
  ```yaml
  agent:
    backend: codex            # default for unmatched issues
    label_presets:
      - label: "agent:fast"
        backend: acp
        model: opencode/north-mini-code-free
      - label: "agent:deep"
        backend: claude_code
        model: opus
  ```
  In multi-repo mode, a routed repository can instead define issue-aware Codex execution profiles
  under `agent.routing` in its own `WORKFLOW.md`. The block requires a small classifier model,
  `default_profile`, `fallback_profile`, and a non-empty `profiles` map. Each profile supplies a
  Codex model, reasoning effort (`none` | `low` | `medium` | `high` | `xhigh` | `max`), and a concise
  description used by the classifier. Example:

  ```yaml
  agent:
    routing:
      classifier:
        backend: codex
        model: gpt-5.6-luna
        reasoning_effort: max
        timeout_ms: 120000
      default_profile: standard
      fallback_profile: deep
      profiles:
        standard:
          backend: codex
          model: gpt-5.6-sol
          reasoning_effort: high
          description: Clear, bounded work with a straightforward validation path.
        deep:
          backend: codex
          model: gpt-5.6-sol
          reasoning_effort: xhigh
          description: Risky, cross-cutting, ambiguous, or architecture-sensitive work.
  ```

  For an unlabelled issue, Symphony runs an ephemeral structured classifier turn over a bounded
  issue snapshot, with Symphony dynamic tools disabled and repository project-doc loading set to
  zero bytes. A classifier result with high risk, complexity, or ambiguity is promoted to
  `fallback_profile`; a classifier failure also fails closed to that profile. A single
  `agent:<profile>` issue label bypasses classification, while multiple matching profile labels use
  the fallback. Existing host `agent.label_presets` remain the highest-precedence override. Routing
  is active directly. The classifier also records a task class (`simple_direct`, `ui`,
  `security_tenant`, `data_schema`, `concurrency_liveness`, or `broad_architecture`), confidence,
  bounded input metadata, reasons, and override provenance for efficiency routing.

  Soft fleet budgets live separately under repository-owned `agent.efficiency`. They default to
  `shadow`, so proposed transitions are observable before prompts change. `enforce` applies each
  threshold transition once at the next continuation boundary; `off` retains the decision record
  without transition enforcement. Defaults use distinct simple/standard/high-risk profiles seeded
  from recent fleet percentile bands, and every positive threshold is overrideable:

  ```yaml
  agent:
    efficiency:
      mode: shadow                 # off | shadow | enforce
      capsule_max_bytes: 4000
      extreme_multiplier: 2.0
      task_profiles:
        simple_direct: simple
        ui: standard
        security_tenant: high_risk
        data_schema: high_risk
        concurrency_liveness: high_risk
        broad_architecture: high_risk
      profiles:
        simple:
          total_tokens: 250000
          delegated_tokens: 75000
          per_thread_tokens: 150000
          per_turn_growth_tokens: 100000
          uncached_input_tokens: 125000
          cached_input_tokens: 500000
          tool_output_bytes: 250000
          elapsed_phase_ms: 900000
          review_packet_bytes: 32000
          reviewer_lenses: 2
          review_iterations: 2
          reviewer_reasoning_effort: medium
          review_lenses: [correctness, test_evidence]
  ```

  `budget:<profile>` is the explicit per-issue budget override. A typo/unknown profile or multiple
  valid budget profiles fails toward `high_risk` with inspectable provenance. Token state is
  reconstructed from actual parent/delegated thread high waters and remains live across continuation
  turns. Backend callbacks coalesce their small cumulative signals directly into a bounded collector;
  full protocol events never accumulate in the runner's budget mailbox, and a turn-boundary barrier
  includes callbacks that began before the backend returned. Tool bytes count terminal Codex, ACP,
  and Claude tool results, not streaming deltas. A crossing emits one compact `budget_transition`;
  enforce mode adds one bounded resume capsule directing future work toward thin-context delegation,
  exact-head artifact reuse, bounded tool output, and open-finding synthesis. Extreme outliers get a
  complete-resume-packet escalation. None of these transitions can approve a review, mark work
  complete, skip required security validation, or suppress findings. High-risk profiles may exceed
  their budgets explicitly while preserving or strengthening reviewer effort, lens coverage, packet
  capacity, and iteration count.

  The observability dashboard surfaces the **actual** backend, model, reasoning effort, and selected
  profile each run is using. Its "Agent" column in the running-issues list and "Agent" card on the
  issue detail page take values from the resolved backend module and the model handed to (or
  reported by) the running agent, rather than re-deriving them from issue labels. The model is the
  live resolved one where the agent reports it (Codex's `thread/start` response and Claude Code's
  `system/init`) and the configured/override value otherwise.
  Repository scheduling waits are exposed separately with queue reason, bounded overlap paths,
  queue time, base age, bounded suggested order plus its omitted count, policy, and override state. Running entries expose their
  repository, path source/manifest, candidate/current base SHAs, base age, and dirty flag. Fleet
  telemetry reports overlap decisions, queue time, rebase/conflict rate, irrelevant versus
  overlapping base drift, and expensive gates avoided.
- **Label groups.** A Linear label nested in a label *group* (e.g. the leaf `opencode:kimi2.7` under
  group `agent`) is flattened to `<group>:<leaf>` (`agent:opencode:kimi2.7`) before matching — Symphony
  fetches the label's `parent` and joins them. So `label_presets` and repo-routing labels are written
  in the **`group:leaf`** form. Ungrouped (flat) labels keep their bare name. A grouped label and a
  legacy flat label with the same qualified name (e.g. group `repo`/`udp-dashboard-v2` vs a flat
  `repo:udp-dashboard-v2`) collapse to one entry, so you can migrate issues onto the grouped label
  without changing config.
- If the Markdown body is blank, Symphony uses a default repository workflow prompt. The canonical
  task context supplies the issue details independently of that template.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- GitHub App auth is prepared before routed repository hooks and injected into `after_create`,
  `session_start`, `before_run`, `before_handoff`, and `after_run`. Repositories do not need to mint
  tokens or construct a bot environment. A non-zero routed `after_create` result is fatal and is
  returned unchanged instead of allowing agent startup to continue.
- Use `hooks.session_start` to run non-blocking repo-local startup discovery before every fresh or
  resumed Codex session. Symphony captures generated Markdown links under
  `docs/agent-workpad/<branch>/` and annotates them in the startup-artifact section of the canonical
  first-turn task context. Raw hook stdout is retained for diagnostics and is not copied into the
  prompt. A hook can own the meaning of its artifacts by emitting a one-line JSON report with an
  `artifacts` array of `path` and `description` objects; paths must remain under
  `docs/agent-workpad/`. Hooks without that report retain path-only discovery as a compatibility
  fallback.
  The hook emits `[:symphony_elixir, :gate, :session_start]` telemetry with total duration and any
  per-script timings reported by the hook output.
- Use `hooks.before_handoff` to run a repo-local gate before an agent moves a Linear issue from
  `In Progress` to a review handoff state such as `In Review`. A non-zero exit blocks the status
  transition and the parsed gate remediation is included in the next agent turn.
  Protocol-aware hooks receive `SYMPHONY_HANDOFF_GATE_PROTOCOL=1`. Exit `3` with a version 1
  `pending`/`running` JSON report to defer the mutation; subsequent lightweight polls receive
  `SYMPHONY_HANDOFF_GATE_JOB_ID`. Configure the hook invocation deadline independently with
  `before_handoff_timeout_ms` and the maximum accepted heartbeat age with
  `before_handoff_stale_ms`. The runtime APIs expose job/candidate identity, pending age,
  heartbeat age, progress stage, and next-poll delay while the issue is `handoff_pending_gate`.
  A terminal infrastructure/protocol verification result ends the worker attempt and uses
  orchestrator backoff rather than asking the implementor to repair platform infrastructure.
- If the target repo provides `WORKFLOW_REVIEW.md`, Symphony runs that reviewer after the
  implementor turn that requested the handoff has closed, and applies the captured Linear
  transition only after an authoritative approval for the exact candidate SHA. Request changes,
  inconclusive automation and review-budget exhaustion withhold the transition and preserve the
  latest evidence for human resolution. Reviewer infrastructure and packet-generation failures
  end the worker attempt and use orchestrator backoff without consuming remediation turns.
  The issue remains claimed in a distinct `handoff_pending_review` lifecycle while that reviewer
  runs, so the completed implementor is not mistaken for a stalled turn. Reviewer events emit a
  minimal, job-scoped heartbeat that refreshes worker activity without replacing implementor
  session or token accounting; a silent reviewer is timed out with a review-specific log and retry.
  Symphony also pins the reviewed PR head and rechecks it before applying the transition, so a push
  during review requires a fresh handoff review.
  Reviewer session/verdict failures receive one bounded retry and are then latched for that
  candidate during the current orchestration run; budget exhaustion is likewise latched and never
  spawns another reviewer in that run. To recover, repair reviewer tool/auth/runtime or verdict
  production, then start a fresh orchestration run (or attach/update the candidate head). For
  `budget_exhausted_with_findings`, a human must explicitly resolve or accept the recorded findings;
  Symphony never converts the cost limit into automated approval.
- Configure bounded review evidence and execution in the `review` front matter of the target
  repository's `WORKFLOW_REVIEW.md`:

  ```yaml
  review:
    max_iterations: 3
    verdict_path: .artifacts/symphony-review/verdict.json
    packet_path: .artifacts/symphony-review/packet.v1.json
    packet_max_bytes: 48000
    context_budget_tokens: 12000
    turn_budget: 1
    turn_timeout_ms: 900000
    tool_output_max_bytes: 4000
    model: gpt-5.5
    reasoning_effort: high
    require_pr: true
  ```

  Symphony clamps unsafe values and always enforces one Codex turn per fresh reviewer attempt.
  It enforces the context budget over the final rendered workflow, guards, and packet using a
  conservative three UTF-8 bytes per configured token. If composition exceeds that ceiling,
  Symphony rebuilds the reproducible packet once to the exact remaining budget; a prompt that
  still does not fit is explicitly inconclusive rather than truncated. Successful reviewer
  dynamic-tool responses larger than
  `tool_output_max_bytes` are replaced in both response text fields with a bounded preview plus the
  original size and narrow-query/raw-artifact recovery instructions. Failure responses remain
  intact so diagnostics are never hidden.
  The verdict must report the packet's exact `reviewed_sha`, a non-empty `inspected` list, and
  `attestations.reused` / `attestations.rerun`; missing or stale candidate evidence is
  `automation_inconclusive`. Parent reviewer and delegated lens threads emit independent local
  telemetry with packet/head identity, tokens, duration, model, reasoning effort, and findings.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- `tracker.project_slug` reads from `LINEAR_PROJECT_SLUG` when unset or when value is `$LINEAR_PROJECT_SLUG`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
  project_slug: $LINEAR_PROJECT_SLUG
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
  session_start: |
    if [ -x scripts/hooks/session-start.sh ]; then
      scripts/hooks/session-start.sh
    fi
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.
- Live dashboard change notifications are coalesced into short update windows. Issue pages seed a
  bounded tail of the active transcript and parse only appended NDJSON bytes on later updates, so a
  high-volume protocol stream cannot make every connected browser repeatedly load and render the
  complete session. The issue JSON endpoint remains the explicit full-history view.
- Session transcripts are written as compact, renderer-compatible NDJSON under
  `./log/codex_sessions` by default, or under `<logs-root>/log/codex_sessions` when `--logs-root`
  is set. Streaming text and tool-output chunks are bounded and coalesced by stream/tool identity;
  cumulative token notifications are omitted, cumulative ACP tool updates keep their latest merged
  state, and terminal Codex items replace their partial records. Terminal items, lifecycle, tools,
  errors, and other semantic records remain. The issue JSON endpoint includes the current
  known transcript paths for that issue. Existing NDJSON files and readers remain supported.
- A redacted gzip raw sidecar (`*.raw.ndjson.gz`) is staged while a session runs. By default it is
  retained for failed sessions and a deterministic 1% success sample, then pruned after seven days.
  Set `observability.raw_trace_debug: true` (or `raw_trace_policy: all`) temporarily for an incident;
  restore the default after diagnosis. `raw_trace_policy: none` disables successful-session
  retention, while `sampled` retains successful sessions at `raw_trace_sample_rate`. Failure traces
  are always retained for the configured window. Valid original protocol documents remain complete
  after recursive redaction (including provider-only fields); invalid originals retain only byte
  count/hash metadata. Raw traces never bypass `observability.redact_fields`, whose defaults cover
  authorization/token/cookie keys plus password, secret, client-secret, private-key, and API-key
  variants. Configured `redact_fields` extend these mandatory defaults and separator-insensitive
  matching covers snake_case, kebab-case, and camelCase spellings. The policy is snapshotted once
  per dispatched run, so a workflow reload applies to
  subsequent runs without reparsing configuration for every notification.
- Compact fleet events live in `~/.symphony/telemetry/<YYYY-MM-DD>.jsonl` for at least 30 days.
  `mix telemetry.report --from YYYY-MM-DD --to YYYY-MM-DD --json` reports fleet, repository,
  issue, parent/delegated-thread, phase, failure, gate, review, tool-output, percentile, and quality
  views without parsing transcripts. Percentiles use the conventional nearest-rank definition.
  Token totals use each actual thread's greatest cumulative
  snapshot; cached input and reasoning remain distinct and repeated absolute snapshots are not
  summed. Routing views include classifier inputs/result/confidence, budget profile/mode and
  overrides; efficiency views distinguish proposed/applied transitions and compare tokens, time,
  review findings, CI/human outcomes, and extreme outliers over the requested rolling window (use
  the prior 30 days for the rollout comparison). Unversioned telemetry JSONL remains readable as
  schema version 0.
- Benign protocol notifications and stdout chunks do not produce one debug-log line each by
  default. `observability.benign_notification_debug: true` is the short-lived log-level escape
  hatch; selective gzip raw traces are normally the more complete incident artifact.
- Prompt events contain per-section IDs, source/version, hashes, byte/token estimates, and
  reuse/suppression diagnostics, never raw prompt content. For an incident,
  `observability.prompt_debug: true` emits a bounded debug-log rendering with provenance boundaries;
  configured secret assignments are redacted and `prompt_debug_max_bytes` caps the rendering.
  Keep this mode disabled during normal operation.
- To render a transcript in a human-readable terminal format, run
  `bin/codex-session-log log/codex_sessions/<session-file>.ndjson`.
- Compact session-log retention is configured with `observability.session_retention_days` (default
  30). `mix session_logs.prune --root <codex_sessions-dir>` is always a dry run unless `--apply` is
  explicit, reports selected file/byte totals, and protects active marker paths. See the
  [safe rollout and cleanup runbook](docs/operations.md).

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap
- Active-backend usage cards grouped by provider account scope. Codex duration buckets and Claude
  Code's named subscription windows are normalized into 5-hour/weekly percentage-used and reset
  fields when their streams report them. Backends whose agent protocol does not expose subscription
  limits remain visible as unavailable rather than being reported as zero.

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
