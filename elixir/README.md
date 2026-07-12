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

During app-server sessions, Symphony also serves a client-side `linear_graphql` tool so that repo
skills can make raw Linear GraphQL calls. Handoff state changes must use this gated tool; Symphony
does not auto-approve native Linear MCP `save_issue` calls because they cannot run
`hooks.before_handoff` or the automated review gate.

When a target repo provides `WORKFLOW_REVIEW.md`, Symphony runs that review workflow during gated
`In Progress` to review-state handoffs. The handoff tool call records the requested Linear
mutation, the active implementor turn closes, and Symphony runs the reviewer before applying that
mutation. If the Linear issue has an attached GitHub PR URL, the review gate uses that PR directly
for the human-review section; otherwise it falls back to the current workspace branch's PR.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
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

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

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
- `agent.backend` selects the coding-agent backend: `codex` (default, the Codex app-server described
  above), `acp` (the Agent Client Protocol, e.g. `opencode acp`), or `claude_code` (native Claude Code
  `claude -p` stream-json). All backends honor the same handoff gate and observability transcript.
  See [docs/acp.md](docs/acp.md) for the ACP setup and the `acp` config block, and
  [docs/claude-code.md](docs/claude-code.md) for the Claude Code setup and the `claude_code` config
  block. Both alternative backends share the same local-only gate / non-intercepted `fs`/`terminal`
  limitations as ACP.
- `agent.pre_command` is an optional shell snippet run (joined with `&&`) in the launch shell —
  inside the per-issue workspace cwd — **before every backend's** agent process (Codex, ACP, Claude
  Code alike). Use it to source a per-worktree env file (e.g. a generated GitHub-App session:
  `pre_command: . .artifacts/github-app-auth/session.env`) so all three backends get the same
  environment without duplicating the wrapper in each backend's `command`. Any `.env` file it sources
  is run through the same sanitizer as a command-sourced file. Unset ⇒ launches are byte-for-byte
  unchanged. (With it set, you can drop the `sh -lc '… && exec …'` sourcing wrapper from
  `codex.command` and leave just the bare agent invocation.)
- `agent.label_presets` chooses the backend (and model) **per task** from the issue's Linear labels,
  overriding the global `agent.backend` for matching issues. It is an ordered list; the first preset
  whose `label` is present on the issue wins (positional precedence — list order, first match), and
  an unmatched issue falls through to `agent.backend`. Each preset has `label` (a Linear label name,
  matched exactly — see the label-group note below), `backend` (`codex` | `acp` | `claude_code`), and an optional `model` (passed to
  the chosen backend — `OPENCODE_CONFIG_CONTENT` for ACP/OpenCode, `--model` for Claude Code; ignored
  for `codex`, which has no per-task model). Resolution happens once at run start, so a relabel takes
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
  The observability dashboard surfaces the **actual** backend and model each run is using — an
  "Agent" column in the running-issues list and an "Agent" card on the issue detail page — taken from
  the resolved backend module and the model handed to (or reported by) the running agent, not
  re-derived from the issue's labels. The model is the live resolved one where the agent reports it
  (Codex's `thread/start` response and Claude Code's `system/init`) and the configured/override value
  otherwise.
- **Label groups.** A Linear label nested in a label *group* (e.g. the leaf `opencode:kimi2.7` under
  group `agent`) is flattened to `<group>:<leaf>` (`agent:opencode:kimi2.7`) before matching — Symphony
  fetches the label's `parent` and joins them. So `label_presets` and repo-routing labels are written
  in the **`group:leaf`** form. Ungrouped (flat) labels keep their bare name. A grouped label and a
  legacy flat label with the same qualified name (e.g. group `repo`/`udp-dashboard-v2` vs a flat
  `repo:udp-dashboard-v2`) collapse to one entry, so you can migrate issues onto the grouped label
  without changing config.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- Use `hooks.session_start` to run non-blocking repo-local startup discovery before every fresh or
  resumed Codex session. Symphony captures generated Markdown links under
  `docs/agent-workpad/<branch>/` and prepends them to the first turn as an advisory system message.
  The hook emits `[:symphony_elixir, :gate, :session_start]` telemetry with total duration and any
  per-script timings reported by the hook output.
- Use `hooks.before_handoff` to run a repo-local gate before an agent moves a Linear issue from
  `In Progress` to a review handoff state such as `In Review`. A non-zero exit blocks the status
  transition and the parsed gate remediation is included in the next agent turn.
- If the target repo provides `WORKFLOW_REVIEW.md`, Symphony runs that reviewer after the
  implementor turn that requested the handoff has closed, and applies the captured Linear
  transition only after the reviewer approves or the configured review budget is exhausted.
  The issue remains claimed in a distinct `handoff_pending_review` lifecycle while that reviewer
  runs, so the completed implementor is not mistaken for a stalled turn. Reviewer events emit a
  minimal, job-scoped heartbeat that refreshes worker activity without replacing implementor
  session or token accounting; a silent reviewer is timed out with a review-specific log and retry.
  Symphony also pins the reviewed PR head and rechecks it before applying the transition, so a push
  during review requires a fresh handoff review.
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
- Codex session transcripts are written as NDJSON files under `./log/codex_sessions` by default,
  or under `<logs-root>/log/codex_sessions` when `--logs-root` is set. The issue JSON endpoint
  includes the current known transcript paths for that issue.
- To render a transcript in a human-readable terminal format, run
  `bin/codex-session-log log/codex_sessions/<session-file>.ndjson`.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

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
