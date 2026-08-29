# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

The reference scheduler is repository-aware: global and state limits are supplemented by
per-repository ceilings and changed-path overlap risk. Disjoint work can use available capacity,
while high-overlap work is deterministically ordered to avoid repeated rebases and invalidated
validation. Before handoff it checks the current base and withholds expensive final gates only when
newer base changes overlap the candidate or the repository-owned handoff runtime; it never rewrites
dirty work automatically.
Long-running exact-head gates can return a durable pending job: Symphony pauses model work, polls
that job without spending turns or tokens, and applies the deferred handoff only after the exact
current candidate passes. Pending jobs survive orchestrator restarts and remain visible in runtime
status instead of being misclassified as stalled agents. The attempted handoff is also persisted
before initial gate startup, so a pre-job infrastructure retry reruns the hook without launching a
replacement model session. Those retries revalidate the current base first, so a branch cannot loop
on an obsolete repository hook after its workflow or hook script was fixed upstream.

Automated handoff reviews use fresh, thin-context reviewer threads rather than copying an
implementor's full history. A bounded, versioned packet pins every review to the exact base/head
candidate while keeping the complete diff and security rules independently accessible; follow-up
passes receive open findings plus a delta, and high-risk changes receive a final full-diff pass.
When enforcement is enabled, a fully inspectable bounded documentation/test-only candidate may
refine a standard reviewer route to the repository's simple profile; explicit overrides,
quality fallbacks, control files, production paths, and high-risk work retain their original depth.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

Before each outer agent dispatch, the reference implementation builds a canonical task context from
the current issue details, a bounded Linear comment window, and annotated repository startup
artifacts. That context precedes the repository workflow, so workpads and human unblock decisions
are deterministic agent input without exposing the tracker credential to repository code. Later
turns receive only added or updated activity, and equivalent repeated automation outcomes are
collapsed while human comments and the workpad remain verbatim. Typed current-issue operations and
server-captured wait baselines keep routine tracker writes and external waits out of ad-hoc agent
GraphQL and polling loops.

Routed repositories can also version issue-aware Codex profiles in their own `WORKFLOW.md`. A small,
classification-only turn chooses the execution profile from bounded issue context, while
repositories retain a quality fallback for ambiguous, risky, or failed classifications. The
selected execution model and reasoning effort are visible in Symphony's dashboard.

The Elixir implementation isolates each live run in a detached worker process. The orchestrator can
restart for a deployment and reconnect to those workers without terminating their coding-agent
sessions. A persisted, reversible drain mode pauses new dispatch while existing work continues, so
operators can choose either a fully drained rollout or a reconnecting restart. A separate persisted
shutdown policy lets operators choose whether Ctrl+C preserves those workers for reconnection or
terminates their complete process trees.
Agents can also park work on typed external conditions; durable non-model watchers release the
agent slot, deduplicate probes, and resume the issue through the normal priority scheduler when the
condition changes.

The reference implementation also maintains a compact, versioned fleet analytics layer. It
reconciles cumulative usage by actual parent and delegated threads, retains rolling lifecycle and
failure history, and keeps complete recursively redacted compressed protocol traces selectively for
failed/sampled sessions while compacting high-frequency semantic streams by tool/message identity.
This makes weekly token/time/quality reports bounded without discarding incident evidence.

Repositories can turn that telemetry into task-specific soft budgets. Shadow mode records proposed
task/model/review routes and one-shot strategy transitions before enforcement; enforce mode applies
bounded resume capsules at continuation boundaries. Parent and delegated usage is reconciled across
turns through a bounded high-water collector instead of queuing full protocol events in the runner,
while security validation, unresolved findings, and exact-head review approval remain unchanged
quality requirements even when a high-risk task explicitly exceeds its budget.

Prompt construction uses typed, provenance-aware sections. The canonical Task context owns issue
details and live activity, so exact copies of issue prose in repository workflow templates are not
injected twice. Only explicit ownership matches and formatting-only equivalents are suppressed;
ambiguous safety, tenant/auth, validation, acceptance, and handoff rules fail open and remain in the
prompt. Continuations reference unchanged section versions/hashes in bounded resume capsules, while
fleet telemetry records section sizes and decisions without persisting raw prompt content.

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
