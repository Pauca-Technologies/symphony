# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

Automated handoff reviews use fresh, thin-context reviewer threads rather than copying an
implementor's full history. A bounded, versioned packet pins every review to the exact base/head
candidate while keeping the complete diff and security rules independently accessible; follow-up
passes receive open findings plus a delta, and high-risk changes receive a final full-diff pass.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

Before each outer agent dispatch, the reference implementation builds a canonical task context from
the current issue details, a bounded Linear comment window, and annotated repository startup
artifacts. That context precedes the repository workflow, so workpads and human unblock decisions
are deterministic agent input without exposing the tracker credential to repository code.

Routed repositories can also version issue-aware Codex profiles in their own `WORKFLOW.md`. A small,
classification-only turn chooses the execution profile from bounded issue context, while
repositories retain a quality fallback for ambiguous, risky, or failed classifications. The
selected execution model and reasoning effort are visible in Symphony's dashboard.

The reference implementation also maintains a compact, versioned fleet analytics layer. It
reconciles cumulative usage by actual parent and delegated threads, retains rolling lifecycle and
failure history, and keeps complete recursively redacted compressed protocol traces selectively for
failed/sampled sessions while compacting high-frequency semantic streams by tool/message identity.
This makes weekly token/time/quality reports bounded without discarding incident evidence.

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
