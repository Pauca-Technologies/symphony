defmodule SymphonyElixir.ReviewGate do
  @moduledoc """
  Runs a full reviewer agent at the `In Progress -> In Review` handoff.

  When a consumer repo ships a `WORKFLOW_REVIEW.md` (loaded by
  `AgentRunner` alongside its `WORKFLOW.md`), this gate fires immediately
  after the deterministic `before_handoff` shell hook passes and *before*
  the Linear `issueUpdate` mutation that would move the issue out of
  `In Progress`. It spawns a fresh Codex session in the implementor's own
  worktree, driven by the review prompt, and reads a JSON verdict the
  reviewer writes to a known path.

    * `approve` -> `:ok`, the handoff proceeds.
    * `request_changes` (and the per-issue iteration budget is not yet
      spent) -> `{:blocked, remediation, comments}`. `DynamicTool` turns
      that into a failed tool result whose `error.remediation` the
      `AgentRunner` feeds into the implementor's next turn — the same
      block/remediation/loop machinery the shell `before_handoff` gate
      already uses. The implementor fixes the findings and re-attempts the
      handoff, which runs the reviewer again.
    * Budget exhausted (`max_iterations` request-changes passes) -> `:ok`,
      with a one-time Linear note, so a human reviewer takes it from there
      instead of looping forever.

  Fail-open by design (per product decision): a reviewer that errors, times
  out, or produces no readable verdict never wedges the pipeline — the gate
  logs, posts a "review skipped" note, and allows the handoff.

  The iteration counter lives in the process dictionary of the `AgentRunner`
  run process (the same place the handoff-gate prompt is stashed), so it
  persists across the run's turns and resets when the orchestrator picks the
  issue up again in a fresh run.

  ## Human-review PR section

  Beyond the gate verdict, the reviewer also sets a `review_effort` tier
  (`review_effort: "none" | "skim" | "focused" | "thorough"` in the verdict
  JSON — how hard a human should review the change) and writes `human_review`
  markdown. `Github.PrReviewSection` upserts that, as a deterministic
  marker-delimited section with an enum-rendered badge, onto the GitHub PR body
  — overwriting it in place on every pass. `review_effort` is orthogonal to the
  verdict: a change needing a `thorough` review can still `approve`. On budget
  exhaustion the section is refreshed to `thorough` / "did not converge ->
  elevated risk" so the riskiest case never ships stale guidance.

  ## Configuration (the consumer repo's `WORKFLOW_REVIEW.md` front matter)

      review:
        max_iterations: 3                  # request-changes passes before allowing the handoff
        verdict_path: .artifacts/symphony-review/verdict.json
        require_pr: true                   # no PR at handoff -> skip the reviewer entirely
        pr_section_enabled: true           # write the human-review PR section
        section_heading: "## 🤖 How to review this PR"
  """

  require Logger

  alias SymphonyElixir.{
    Codex.AppServer,
    Codex.DynamicTool,
    Github.PrReviewSection,
    Linear.Client,
    Linear.Issue,
    PromptBuilder,
    Tracker
  }

  @telemetry_event [:symphony_elixir, :gate, :review]
  @default_max_iterations 3
  @default_verdict_path ".artifacts/symphony-review/verdict.json"
  @default_section_heading "## 🤖 How to review this PR"

  @iteration_key {__MODULE__, :iteration}
  @budget_noted_key {__MODULE__, :budget_noted}
  @skip_noted_key {__MODULE__, :skip_noted}

  @budget_marker "<!-- symphony:review-budget-exhausted -->"
  @skip_marker "<!-- symphony:review-skipped -->"

  @type review_effort :: :none | :skim | :focused | :thorough
  @type verdict :: %{
          verdict: :approve | :request_changes,
          summary: String.t(),
          review_effort: review_effort(),
          human_review: String.t(),
          comments: [map()]
        }
  @type result :: :ok | {:blocked, String.t(), [map()]}

  @doc """
  Run the reviewer gate for an `In Progress -> In Review` handoff.

  `review_workflow` is the loaded `WORKFLOW_REVIEW.md` (the
  `SymphonyElixir.Workflow.load/1` map: `%{config: ..., prompt_template:
  ...}`). Options:

    * `:linear_client` — forwarded to the reviewer's (read-only) Linear tool
      executor; defaults to `&Client.graphql/3`.
    * `:session_runner` — `fn ctx -> {:ok, term()} | {:error, term()} end`
      that runs the reviewer Codex session. Defaults to the real
      `AppServer`-backed runner. Injected in tests.
    * `:comment_fn` — `fn issue_id, body -> :ok | {:error, term()} end` for
      the budget/skip notes. Defaults to `&Tracker.create_comment/2`.
  """
  @spec run(Path.t(), Issue.t(), term(), map(), keyword()) :: result()
  def run(workspace, %Issue{id: issue_id} = issue, worker_host, review_workflow, opts)
      when is_binary(workspace) and is_binary(issue_id) and is_map(review_workflow) do
    settings = review_settings(review_workflow)
    iteration = current_iteration(issue_id)

    case PrReviewSection.resolve_pr(workspace, opts) do
      {:skip, reason} when settings.require_pr ->
        # No PR at the In Review handoff: skip the reviewer entirely (product
        # decision). The whole feature — review + PR annotation — is PR-centric
        # here; set `require_pr: false` to review on the diff anyway and just
        # no-op the annotation.
        note_review_skipped(issue, {:no_pr, reason}, opts)
        emit_telemetry(issue, iteration, :skipped, 0, nil)
        :ok

      pr_result ->
        pr = pr_or_nil(pr_result)

        if iteration >= settings.max_iterations do
          # Budget spent: allow the handoff, but refresh the human-facing
          # section to "did not converge -> elevated risk" so the riskiest case
          # is never described by stale request-changes prose.
          maybe_write_section(workspace, pr, :thorough, budget_human_review(iteration), settings, opts)
          note_budget_exhausted(issue, iteration, opts)
          emit_telemetry(issue, iteration, :budget_exhausted, 0, :thorough)
          :ok
        else
          run_iteration(workspace, issue, worker_host, review_workflow, settings, iteration, pr, opts)
        end
    end
  end

  # Missing issue id / not a review workflow / bad workspace -> fail open.
  def run(_workspace, _issue, _worker_host, _review_workflow, _opts), do: :ok

  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  defp pr_or_nil({:ok, pr}), do: pr
  defp pr_or_nil(_pr_result), do: nil

  defp run_iteration(workspace, %Issue{} = issue, worker_host, review_workflow, settings, iteration, pr, opts) do
    verdict_path = Path.join(workspace, settings.verdict_path)
    prepare_verdict_path(verdict_path)

    case render_review_prompt(issue, review_workflow) do
      {:ok, prompt} ->
        ctx = %{
          workspace: workspace,
          issue: issue,
          worker_host: worker_host,
          prompt: prompt,
          verdict_path: verdict_path,
          tool_executor: review_tool_executor(Keyword.get(opts, :linear_client))
        }

        case run_review_session(ctx, opts) do
          {:ok, _session} -> evaluate_verdict(workspace, verdict_path, issue, settings, iteration, pr, opts)
          {:error, reason} -> fail_open(issue, iteration, {:review_session_failed, reason}, opts)
        end

      {:error, reason} ->
        fail_open(issue, iteration, {:review_prompt_unavailable, reason}, opts)
    end
  end

  # On both verdicts we refresh the PR's human-review section from the reviewer's
  # review_effort tier + prose (effort is orthogonal to the verdict — a change
  # needing a thorough review can still approve). Keeping it fresh through the
  # request_changes loop means the final pass's assessment wins.
  defp evaluate_verdict(workspace, verdict_path, %Issue{} = issue, settings, iteration, pr, opts) do
    case read_verdict(verdict_path) do
      {:ok, %{verdict: :approve} = verdict} ->
        maybe_write_section(workspace, pr, verdict.review_effort, verdict.human_review, settings, opts)
        emit_telemetry(issue, iteration, :approve, length(verdict.comments), verdict.review_effort)
        :ok

      {:ok, %{verdict: :request_changes} = verdict} ->
        next_iteration = iteration + 1
        put_iteration(issue.id, next_iteration)
        maybe_write_section(workspace, pr, verdict.review_effort, verdict.human_review, settings, opts)
        emit_telemetry(issue, iteration, :request_changes, length(verdict.comments), verdict.review_effort)
        {:blocked, remediation_prompt(verdict, next_iteration, settings.max_iterations), verdict.comments}

      {:error, reason} ->
        fail_open(issue, iteration, {:verdict_unreadable, reason}, opts)
    end
  end

  # --- PR human-review section ---------------------------------------------

  defp maybe_write_section(_workspace, nil, _effort, _human_review, _settings, _opts), do: :ok

  defp maybe_write_section(workspace, pr, effort, human_review, settings, opts) do
    if settings.pr_section_enabled do
      write_opts = Keyword.put(opts, :section_heading, settings.section_heading)
      outcome = PrReviewSection.upsert(workspace, pr, effort, human_review, write_opts)
      Logger.info("review.gate pr-section pr=##{pr.number} review_effort=#{effort} outcome=#{outcome}")
      outcome
    else
      :ok
    end
  end

  defp budget_human_review(iterations) do
    """
    Automated review ran #{iterations} change-request #{pluralize(iterations, "pass", "passes")} without converging, so this PR was allowed through **without a clean approval**. Treat it as elevated risk and review carefully end-to-end. The latest unresolved reviewer findings are in the run transcript and the `## Codex Workpad` comment on the linked issue.
    """
    |> String.trim()
  end

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_n, _singular, plural), do: plural

  # --- reviewer session ----------------------------------------------------

  defp run_review_session(ctx, opts) do
    runner = Keyword.get(opts, :session_runner, &default_session_runner/1)
    runner.(ctx)
  end

  defp default_session_runner(%{workspace: workspace, issue: issue, worker_host: worker_host, prompt: prompt, tool_executor: tool_executor}) do
    AppServer.run(workspace, prompt, issue, worker_host: worker_host, tool_executor: tool_executor)
  end

  # The reviewer talks to Linear read-only and without a handoff gate
  # context: read-only blocks any `issueUpdate`/mutation so the reviewer
  # cannot move the issue itself, and the absent gate context stops the
  # reviewer's own tool calls from re-entering this gate (recursion guard,
  # the analog of UDP's `UDP_NESTED_CODEX` skip in before-handoff.sh).
  defp review_tool_executor(linear_client) do
    client = linear_client || (&Client.graphql/3)

    read_only_client = fn query, variables, request_opts ->
      if mutation_query?(query) do
        {:error, :review_session_read_only}
      else
        client.(query, variables, request_opts)
      end
    end

    fn tool, arguments ->
      DynamicTool.execute(tool, arguments, linear_client: read_only_client)
    end
  end

  defp mutation_query?(query) when is_binary(query) do
    query
    |> String.trim_leading()
    |> String.downcase()
    |> String.starts_with?("mutation")
  end

  defp mutation_query?(_query), do: false

  defp render_review_prompt(%Issue{} = issue, review_workflow) do
    prompt = PromptBuilder.build_prompt(issue, per_repo_workflow: review_workflow)

    if String.trim(prompt) == "" do
      {:error, :empty_review_prompt}
    else
      {:ok, prompt}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp prepare_verdict_path(verdict_path) do
    _ = File.rm_rf(verdict_path)
    _ = File.mkdir_p(Path.dirname(verdict_path))
    :ok
  end

  # --- verdict parsing -----------------------------------------------------

  defp read_verdict(verdict_path) do
    with {:ok, raw} <- File.read(verdict_path),
         {:ok, decoded} <- Jason.decode(raw) do
      normalize_verdict(decoded)
    end
  end

  defp normalize_verdict(decoded) when is_map(decoded) do
    case normalize_verdict_value(Map.get(decoded, "verdict")) do
      {:ok, verdict_atom} ->
        {:ok,
         %{
           verdict: verdict_atom,
           summary: string_or_default(Map.get(decoded, "summary"), ""),
           review_effort: normalize_effort(Map.get(decoded, "review_effort") || Map.get(decoded, "risk")),
           human_review: string_or_default(Map.get(decoded, "human_review"), ""),
           comments: normalize_comments(Map.get(decoded, "comments"))
         }}

      :error ->
        {:error, {:unknown_verdict, Map.get(decoded, "verdict")}}
    end
  end

  defp normalize_verdict(_decoded), do: {:error, :verdict_not_a_map}

  # `review_effort` is human-facing and never blocks: absent -> :focused
  # silently; present but unknown -> :focused with a log. Never downgrade to
  # :none by accident. Legacy "safe/medium/high" values are still accepted.
  defp normalize_effort(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      v when v in ["none", "safe", "no_review", "no-review"] -> :none
      v when v in ["skim", "light"] -> :skim
      v when v in ["focused", "medium", "moderate", "careful"] -> :focused
      v when v in ["thorough", "high", "deep", "risky", "danger", "dangerous"] -> :thorough
      other -> log_unknown_effort(other)
    end
  end

  defp normalize_effort(nil), do: :focused
  defp normalize_effort(other), do: log_unknown_effort(other)

  defp log_unknown_effort(value) do
    Logger.warning("review.gate unknown review_effort tier #{inspect(value)}; defaulting to :focused")
    :focused
  end

  defp normalize_verdict_value(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      v when v in ["approve", "approved", "lgtm", "pass", "ok"] -> {:ok, :approve}
      v when v in ["request_changes", "request-changes", "changes_requested", "reject", "fail"] -> {:ok, :request_changes}
      _ -> :error
    end
  end

  defp normalize_verdict_value(_value), do: :error

  defp normalize_comments(comments) when is_list(comments) do
    comments
    |> Enum.map(&normalize_comment/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_comments(_comments), do: []

  defp normalize_comment(comment) when is_map(comment) do
    body = string_or_default(Map.get(comment, "body") || Map.get(comment, "message"), "")

    if String.trim(body) == "" do
      nil
    else
      %{
        severity: string_or_default(Map.get(comment, "severity"), "comment"),
        file: string_or_nil(Map.get(comment, "file") || Map.get(comment, "path")),
        line: Map.get(comment, "line"),
        body: body
      }
    end
  end

  defp normalize_comment(comment) when is_binary(comment) do
    if String.trim(comment) == "" do
      nil
    else
      %{severity: "comment", file: nil, line: nil, body: comment}
    end
  end

  defp normalize_comment(_comment), do: nil

  # --- remediation / notes -------------------------------------------------

  defp remediation_prompt(%{summary: summary, comments: comments}, iteration, max_iterations) do
    """
    System message:

    An automated reviewer agent reviewed your changes before the In Progress -> In Review handoff and requested changes (review pass #{iteration} of #{max_iterations}).

    Reviewer summary:
    #{blank_to_placeholder(summary, "(no summary provided)")}

    Reviewer comments:
    #{format_comments(comments)}

    Keep the issue in In Progress. Address the comments above — update code, tests, or docs, or post a justified pushback in the workpad — then re-attempt the handoff. The reviewer will run again on your next attempt; after #{max_iterations} passes the handoff proceeds to In Review for a human regardless.
    """
    |> String.trim()
  end

  defp format_comments([]), do: "- (reviewer requested changes but listed no specific comments)"

  defp format_comments(comments) do
    Enum.map_join(comments, "\n", fn comment ->
      "- #{comment_location(comment)}[#{comment.severity}] #{String.trim(to_string(comment.body))}"
    end)
  end

  defp comment_location(%{file: file, line: line}) when is_binary(file) and file != "" do
    case line do
      line when is_integer(line) -> "#{file}:#{line} "
      _ -> "#{file} "
    end
  end

  defp comment_location(_comment), do: ""

  defp fail_open(%Issue{} = issue, iteration, reason, opts) do
    Logger.warning("review.gate fail-open #{issue_context(issue)} reason=#{inspect(reason)}; allowing handoff")
    note_review_skipped(issue, reason, opts)
    emit_telemetry(issue, iteration, :skipped, 0, nil)
    :ok
  end

  defp note_budget_exhausted(%Issue{} = issue, iteration, opts) do
    note_once(@budget_noted_key, issue, opts, fn ->
      """
      #{@budget_marker}
      Automated review reached #{iteration} change-request passes without converging. Proceeding to In Review for human review; the latest reviewer comments are in the run transcript for `#{issue.identifier}`.
      """
    end)

    Logger.info("review.gate budget exhausted #{issue_context(issue)} iterations=#{iteration}; allowing handoff")
    :ok
  end

  defp note_review_skipped(%Issue{} = issue, reason, opts) do
    note_once(@skip_noted_key, issue, opts, fn ->
      """
      #{@skip_marker}
      Automated review was skipped before this In Review handoff (reason: `#{inspect(reason)}`). The handoff was allowed without an automated review pass; review manually.
      """
    end)
  end

  # Post a Linear note at most once per run per issue (the gate can be hit on
  # repeated handoff attempts within a single run).
  defp note_once(flag_key, %Issue{id: issue_id}, opts, body_fun) do
    seen = Process.get(flag_key, MapSet.new())

    if MapSet.member?(seen, issue_id) do
      :ok
    else
      Process.put(flag_key, MapSet.put(seen, issue_id))
      comment_fn = Keyword.get(opts, :comment_fn, &Tracker.create_comment/2)

      case comment_fn.(issue_id, String.trim(body_fun.()) <> "\n") do
        :ok -> :ok
        {:error, reason} -> Logger.warning("review.gate note failed issue_id=#{issue_id} reason=#{inspect(reason)}")
      end
    end
  end

  # --- iteration counter (process-dict, per AgentRunner run) ---------------

  defp current_iteration(issue_id) do
    @iteration_key
    |> Process.get(%{})
    |> Map.get(issue_id, 0)
  end

  defp put_iteration(issue_id, iteration) do
    counters = Process.get(@iteration_key, %{})
    Process.put(@iteration_key, Map.put(counters, issue_id, iteration))
    :ok
  end

  # --- settings ------------------------------------------------------------

  defp review_settings(%{config: config}) when is_map(config) do
    raw = Map.get(config, "review", %{}) || %{}

    %{
      max_iterations: positive_integer(raw, "max_iterations", @default_max_iterations),
      verdict_path: string_or_default(Map.get(raw, "verdict_path"), @default_verdict_path),
      require_pr: boolean_or_default(raw, "require_pr", true),
      pr_section_enabled: boolean_or_default(raw, "pr_section_enabled", true),
      section_heading: string_or_default(Map.get(raw, "section_heading"), @default_section_heading)
    }
  end

  defp review_settings(_review_workflow) do
    %{
      max_iterations: @default_max_iterations,
      verdict_path: @default_verdict_path,
      require_pr: true,
      pr_section_enabled: true,
      section_heading: @default_section_heading
    }
  end

  # --- telemetry -----------------------------------------------------------

  defp emit_telemetry(%Issue{} = issue, iteration, outcome, comment_count, review_effort) do
    :telemetry.execute(
      @telemetry_event,
      %{count: 1, iteration: iteration, comments: comment_count},
      %{
        event: "gate.review",
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        from_state: issue.state,
        iteration: iteration,
        outcome: outcome,
        review_effort: review_effort
      }
    )

    Logger.info("gate.review #{issue_context(issue)} iteration=#{iteration} outcome=#{outcome} comments=#{comment_count} review_effort=#{inspect(review_effort)}")
  end

  # --- small helpers -------------------------------------------------------

  defp positive_integer(map, key, default) do
    case Map.get(map, key) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp boolean_or_default(map, key, default) do
    case Map.get(map, key) do
      value when is_boolean(value) -> value
      _ -> default
    end
  end

  defp string_or_default(value, _default) when is_binary(value) and value != "", do: value
  defp string_or_default(_value, default), do: default

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil

  defp blank_to_placeholder(value, placeholder) do
    case String.trim(to_string(value)) do
      "" -> placeholder
      trimmed -> trimmed
    end
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{identifier || "n/a"}"
  end
end
