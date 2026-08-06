defmodule SymphonyElixir.ReviewGate do
  @moduledoc """
  Runs a full reviewer agent at the `In Progress -> In Review` handoff.

  When a consumer repo ships a `WORKFLOW_REVIEW.md` (loaded by
  `AgentRunner` alongside its `WORKFLOW.md`), the handoff tool call first
  verifies that the deterministic `before_handoff` shell hook passes, then
  records the requested Linear `issueUpdate` mutation and returns control to
  the implementor turn. `AgentRunner` runs this review gate after that turn
  closes and *before* applying the recorded mutation that would move the
  issue out of `In Progress`. The gate spawns a fresh Codex session in the
  implementor's own worktree, driven by the review prompt, and reads a JSON
  verdict the reviewer writes to a known path.

    * `approve` -> `{:approved, evidence}`. The caller may proceed only when
      that evidence is pinned to the exact current head.
    * `request_changes` (and the per-issue iteration budget is not yet
      spent) -> `{:request_changes, remediation, evidence}`. `DynamicTool` turns
      that into a failed tool result whose `error.remediation` the
      `AgentRunner` feeds into the implementor's next turn — the same
      block/remediation/loop machinery the shell `before_handoff` gate
      already uses. The implementor fixes the findings and re-attempts the
      handoff, which runs the reviewer again.
    * Budget exhausted (`max_iterations` request-changes passes) ->
      `{:budget_exhausted_with_findings, evidence}` with a one-time Linear
      escalation note. The deferred handoff remains blocked until a human
      resolves the findings or a new candidate is reviewed.
    * Missing or malformed reviewer output ->
      `{:automation_inconclusive, evidence}`. Reviewer session/tool/auth/timeout
      failures -> `{:infrastructure_unavailable, evidence}`. Neither outcome
      is approval and neither applies the deferred handoff mutation.

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
        max_iterations: 3                  # request-changes passes before human escalation
        verdict_path: .artifacts/symphony-review/verdict.json
        packet_path: .artifacts/symphony-review/packet.v1.json
        packet_max_bytes: 48000            # deterministic hard bound
        context_budget_tokens: 12000       # packet + review instructions
        turn_budget: 1                     # clamped to one fresh turn
        turn_timeout_ms: 900000
        tool_output_max_bytes: 4000
        model: gpt-5.5                      # optional reviewer override
        reasoning_effort: high             # optional reviewer override
        require_pr: true                   # no PR at handoff -> automation_inconclusive
        pr_section_enabled: true           # write the human-review PR section
        section_heading: "## 🤖 How to review this PR"
  """

  require Logger

  alias SymphonyElixir.{
    AgentEfficiency,
    BaseDrift,
    Cardinality,
    Codex.AppServer,
    Codex.DynamicTool,
    Config,
    Github.PrReviewSection,
    Linear.Client,
    Linear.Issue,
    PromptBuilder,
    ReviewOutcome,
    ReviewPacket,
    ReviewTelemetry,
    Telemetry,
    TestWorkerBudget,
    Tracker
  }

  @telemetry_event [:symphony_elixir, :gate, :review]
  @max_verdict_attempts 2
  @context_bytes_per_token 3

  @iteration_key {__MODULE__, :iteration}
  @latest_outcome_key {__MODULE__, :latest_outcome}
  @terminal_outcome_key {__MODULE__, :terminal_outcome}
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
  @type result ::
          {:approved, ReviewOutcome.t()}
          | {:request_changes, String.t(), ReviewOutcome.t()}
          | {:automation_inconclusive, ReviewOutcome.t()}
          | {:infrastructure_unavailable, ReviewOutcome.t()}
          | {:budget_exhausted_with_findings, ReviewOutcome.t()}
  @type review_key ::
          {:pull_request, String.t(), String.t(), String.t() | nil}
          | {:workspace, String.t(), String.t() | nil}

  @doc """
  Resolve and pin the code revision a deferred review will inspect.

  The returned options reuse the resolved PR inside `run/5`, so lifecycle
  registration and the reviewer operate on the same PR head.
  """
  @spec prepare_review(Path.t(), Issue.t(), keyword()) :: {review_key(), keyword()}
  def prepare_review(workspace, %Issue{} = issue, opts) when is_binary(workspace) do
    pr_opts = review_pr_opts(issue, opts)
    pr_result = PrReviewSection.resolve_pr(workspace, pr_opts)
    {review_key(workspace, issue, pr_result), Keyword.put(pr_opts, :resolved_pr_result, pr_result)}
  end

  @doc "Resolve the current code revision key for a deferred review."
  @spec current_review_key(Path.t(), Issue.t(), keyword()) :: review_key()
  def current_review_key(workspace, %Issue{} = issue, opts) when is_binary(workspace) do
    {key, _opts} = prepare_review(workspace, issue, Keyword.delete(opts, :resolved_pr_result))
    key
  end

  @doc "True only when approval evidence is pinned to the exact current candidate head."
  @spec authoritative_for_current_head?(
          Path.t(),
          Issue.t(),
          review_key(),
          keyword(),
          ReviewOutcome.t()
        ) :: boolean()
  def authoritative_for_current_head?(
        workspace,
        %Issue{} = issue,
        review_key,
        opts,
        %ReviewOutcome{outcome: :approved} = outcome
      )
      when is_binary(workspace) do
    outcome.authoritative and review_key_pinned?(review_key) and
      outcome.reviewed_sha == review_key_sha(review_key) and
      current_review_key(workspace, issue, opts) == review_key
  end

  def authoritative_for_current_head?(_workspace, _issue, _review_key, _opts, _outcome),
    do: false

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
    * `:review_packet_builder` — seven-argument function matching
      `ReviewPacket.build/7`. Defaults to the production packet builder and
      permits deterministic packet-boundary tests.
    * `:on_message` — callback for reviewer Codex events. The orchestrator uses
      these events as a reviewer-specific heartbeat while the implementor is
      paused.
    * `:comment_fn` — `fn issue_id, body -> :ok | {:error, term()} end` for
      the budget/skip notes. Defaults to `&Tracker.create_comment/2`.
  """
  @spec run(Path.t(), Issue.t(), term(), map(), keyword()) :: result()
  def run(workspace, %Issue{id: issue_id} = issue, worker_host, review_workflow, opts)
      when is_binary(workspace) and is_binary(issue_id) and is_map(review_workflow) do
    settings =
      review_workflow
      |> Config.review_settings()
      |> AgentEfficiency.review_settings(Keyword.get(opts, :efficiency_decision))

    iteration = current_iteration(issue_id)
    pr_opts = review_pr_opts(issue, opts)

    pr_result =
      Keyword.get_lazy(pr_opts, :resolved_pr_result, fn ->
        PrReviewSection.resolve_pr(workspace, pr_opts)
      end)

    context = %{
      workspace: workspace,
      issue: issue,
      worker_host: worker_host,
      review_workflow: review_workflow,
      settings: settings,
      iteration: iteration,
      opts: pr_opts
    }

    dispatch_review(context, pr_result)
  end

  # Invalid gate input is not approval. This clause is primarily defensive;
  # normal callers always provide a normalized issue and loaded workflow.
  def run(_workspace, _issue, _worker_host, _review_workflow, _opts) do
    outcome =
      inconclusive_outcome(
        Config.review_settings(nil),
        0,
        nil,
        :invalid_review_context,
        "Repair the review workflow context, then start a fresh orchestration run and re-attempt the gated handoff."
      )

    {:automation_inconclusive, outcome}
  end

  defp dispatch_review(%{settings: %{require_pr: true}} = context, {:skip, reason}) do
    required_pr_outcome(context, reason)
  end

  defp dispatch_review(context, pr_result) do
    pr = pr_or_nil(pr_result)
    reviewed_sha = candidate_sha(context.workspace, pr)
    context = Map.merge(context, %{pr: pr, reviewed_sha: reviewed_sha})

    base_drift_result =
      case Keyword.get(context.opts, :base_drift_decision) do
        %{action: action} = decision
        when action in ["disabled", "allow_fresh_base", "allow_irrelevant_drift"] ->
          {:ok, decision}

        _missing_or_non_allowing_decision ->
          BaseDrift.assess(
            context.workspace,
            context.issue,
            Keyword.get(context.opts, :base_drift_ref),
            base_drift_opts(context)
          )
      end

    case base_drift_result do
      {:ok, _decision} ->
        case terminal_outcome(context.issue.id, reviewed_sha) do
          %ReviewOutcome{} = outcome -> {outcome.outcome, outcome}
          nil -> run_unlatched_review(context)
        end

      {:defer, prompt, decision} ->
        outcome = base_drift_outcome(context, decision)
        {:request_changes, prompt, outcome}

      {:error, reason} ->
        conclude_inconclusive(
          context.issue,
          context,
          1,
          {:base_drift_check_unavailable, reason},
          "Restore remote-base visibility, refresh the candidate deliberately, and re-attempt the handoff; no automatic rebase was attempted."
        )
    end
  end

  defp base_drift_opts(context) do
    [worker_host: context.worker_host]
    |> maybe_put_base_drift_runner(:git_runner, Keyword.get(context.opts, :base_drift_git_runner))
    |> maybe_put_base_drift_runner(:ssh_runner, Keyword.get(context.opts, :base_drift_ssh_runner))
  end

  defp maybe_put_base_drift_runner(opts, key, runner) when is_function(runner),
    do: Keyword.put(opts, key, runner)

  defp maybe_put_base_drift_runner(opts, _key, _runner), do: opts

  defp base_drift_outcome(context, decision) do
    findings =
      Enum.map(decision.overlap_paths, fn path ->
        %{
          severity: "blocking",
          file: path,
          line: nil,
          body: "The configured base advanced on a path overlapping this candidate; refresh before final gates."
        }
      end)

    %ReviewOutcome{
      outcome: :request_changes,
      iteration: context.iteration,
      max_iterations: context.settings.max_iterations,
      reviewed_sha: context.reviewed_sha,
      summary: "Final gates deferred because the candidate overlaps newer base changes.",
      failure_reason: :overlapping_base_drift,
      resume_condition: "Refresh against the current base without discarding dirty work, then re-attempt the handoff.",
      review_effort: :thorough,
      authoritative: false,
      findings: findings,
      inspected: decision.overlap_paths,
      severity_counts: %{"blocking" => length(findings)}
    }
  end

  defp required_pr_outcome(%{issue: %Issue{} = issue} = context, reason) do
    case terminal_outcome(issue.id, nil) do
      %ReviewOutcome{} = outcome ->
        {outcome.outcome, outcome}

      nil ->
        create_required_pr_outcome(context, reason)
    end
  end

  defp create_required_pr_outcome(%{issue: %Issue{} = issue} = context, reason) do
    failure_reason = {:no_pr, reason}

    outcome =
      inconclusive_outcome(
        context.settings,
        context.iteration,
        nil,
        failure_reason,
        "Attach a pull request with a pinned head SHA, then start a fresh orchestration run and re-attempt the gated handoff."
      )

    put_terminal_outcome(issue.id, outcome)
    Logger.warning("review.gate inconclusive #{issue_context(issue)} reason=#{inspect(failure_reason)}")
    note_nonapproval(issue, outcome, context.opts)
    emit_outcome_telemetry(issue, outcome)
    {:automation_inconclusive, outcome}
  end

  defp run_unlatched_review(%{iteration: iteration, settings: settings} = context)
       when iteration >= settings.max_iterations do
    outcome =
      budget_outcome(
        settings,
        iteration,
        context.reviewed_sha,
        latest_outcome(context.issue.id)
      )

    put_terminal_outcome(context.issue.id, outcome)

    maybe_write_section(
      context.workspace,
      context.pr,
      :thorough,
      budget_human_review(iteration),
      settings,
      context.opts
    )

    note_budget_exhausted(context.issue, outcome, context.opts)
    emit_outcome_telemetry(context.issue, outcome)
    {:budget_exhausted_with_findings, outcome}
  end

  defp run_unlatched_review(context) do
    prior_outcome = latest_outcome(context.issue.id)
    packet_builder = Keyword.get(context.opts, :review_packet_builder, &ReviewPacket.build/7)

    case packet_builder.(
           context.workspace,
           context.issue,
           context.pr,
           context.reviewed_sha,
           prior_outcome,
           context.settings,
           context.opts
         ) do
      {:ok, packet_result} ->
        review_context =
          context
          |> Map.put(:packet_result, packet_result)
          |> Map.put(:packet_builder, packet_builder)
          |> Map.put(:prior_outcome, prior_outcome)

        run_iteration(review_context, 1, nil)

      {:error, reason} ->
        conclude_infrastructure_failure(
          context.issue,
          context,
          1,
          {:review_packet_unavailable, reason},
          context.opts
        )
    end
  end

  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  defp review_pr_opts(%Issue{} = issue, opts) do
    case attached_pr_url(issue) do
      nil -> opts
      url -> Keyword.put_new(opts, :pr_url, url)
    end
  end

  defp attached_pr_url(%Issue{} = issue) do
    issue
    |> Cardinality.pr_urls()
    |> List.first()
  end

  defp pr_or_nil({:ok, pr}), do: pr
  defp pr_or_nil(_pr_result), do: nil

  defp candidate_sha(_workspace, %{head_oid: head_oid}) when is_binary(head_oid) and head_oid != "",
    do: head_oid

  defp candidate_sha(_workspace, %{}), do: nil
  defp candidate_sha(workspace, nil), do: workspace_head_oid(workspace)

  defp review_key(_workspace, %Issue{id: issue_id}, {:ok, pr}) do
    pr_identity = Map.get(pr, :id) || Integer.to_string(pr.number)
    {:pull_request, issue_id, pr_identity, Map.get(pr, :head_oid)}
  end

  defp review_key(workspace, %Issue{id: issue_id}, _pr_result) do
    {:workspace, issue_id, workspace_head_oid(workspace)}
  end

  defp review_key_pinned?({:pull_request, _issue_id, _pr_identity, head_oid}),
    do: present_sha?(head_oid)

  defp review_key_pinned?({:workspace, _issue_id, head_oid}), do: present_sha?(head_oid)
  defp review_key_pinned?(_review_key), do: false

  defp review_key_sha({:pull_request, _issue_id, _pr_identity, head_oid}), do: head_oid
  defp review_key_sha({:workspace, _issue_id, head_oid}), do: head_oid
  defp review_key_sha(_review_key), do: nil

  defp workspace_head_oid(workspace) do
    case System.cmd("git", ["-C", workspace, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  rescue
    _error -> nil
  end

  defp run_iteration(
         %{
           workspace: workspace,
           issue: %Issue{} = issue,
           worker_host: worker_host
         } = review_context,
         attempt,
         previous_reason
       ) do
    verdict_path = Path.join(workspace, review_context.settings.verdict_path)
    prepare_verdict_path(verdict_path)

    case prepare_review_prompt(review_context, attempt, previous_reason) do
      {:ok, prompt, fitted_context} ->
        packet_result = Map.fetch!(fitted_context, :packet_result)
        settings = fitted_context.settings
        opts = fitted_context.opts

        {telemetry_handle, on_message} =
          ReviewTelemetry.start(issue, packet_result.packet, Keyword.get(opts, :on_message))

        ctx = %{
          workspace: workspace,
          issue: issue,
          worker_host: worker_host,
          prompt: prompt,
          packet: packet_result.packet,
          packet_path: packet_result.path,
          reviewed_sha: fitted_context.reviewed_sha,
          verdict_path: verdict_path,
          tool_executor:
            review_tool_executor(
              Keyword.get(opts, :linear_client),
              settings.tool_output_max_bytes
            ),
          on_message: on_message,
          review_settings: settings
        }

        case run_review_session(ctx, opts) do
          {:ok, session} ->
            evaluate_verdict(verdict_path, fitted_context, attempt, telemetry_handle, session)

          {:error, reason} ->
            ReviewTelemetry.finish(telemetry_handle, :session_failed)
            handle_review_session_failure(fitted_context, attempt, reason)
        end

      {:packet_error, reason} ->
        conclude_infrastructure_failure(
          issue,
          review_context,
          attempt,
          {:review_packet_unavailable, reason},
          review_context.opts
        )

      {:error, reason} ->
        conclude_inconclusive(
          issue,
          review_context,
          1,
          {:review_prompt_unavailable, reason},
          "Repair the review prompt/workflow, then start a fresh orchestration run and re-attempt review for the candidate SHA."
        )
    end
  end

  defp prepare_review_prompt(review_context, attempt, previous_reason) do
    case render_review_prompt_for_context(review_context, attempt, previous_reason) do
      {:ok, prompt} ->
        {:ok, prompt, review_context}

      {:error, {:review_context_budget_exceeded, actual_bytes, max_bytes} = reason} ->
        refit_review_packet(review_context, attempt, previous_reason, actual_bytes, max_bytes, reason)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp refit_review_packet(
         review_context,
         attempt,
         previous_reason,
         actual_bytes,
         max_bytes,
         original_reason
       ) do
    packet_result = Map.fetch!(review_context, :packet_result)
    prompt_overhead_bytes = actual_bytes - byte_size(packet_result.encoded)
    available_packet_bytes = max_bytes - prompt_overhead_bytes
    packet_max_bytes = min(review_context.settings.packet_max_bytes, available_packet_bytes)

    if packet_max_bytes <= 0 or packet_max_bytes >= review_context.settings.packet_max_bytes do
      {:error, original_reason}
    else
      settings = %{review_context.settings | packet_max_bytes: packet_max_bytes}

      case review_context.packet_builder.(
             review_context.workspace,
             review_context.issue,
             review_context.pr,
             review_context.reviewed_sha,
             review_context.prior_outcome,
             settings,
             review_context.opts
           ) do
        {:ok, fitted_packet_result} ->
          prepare_fitted_review_prompt(
            review_context,
            fitted_packet_result,
            settings,
            attempt,
            previous_reason
          )

        {:error, reason} ->
          {:packet_error, reason}
      end
    end
  end

  defp prepare_fitted_review_prompt(
         review_context,
         fitted_packet_result,
         settings,
         attempt,
         previous_reason
       ) do
    fitted_context =
      review_context
      |> Map.put(:packet_result, fitted_packet_result)
      |> Map.put(:settings, settings)

    case render_review_prompt_for_context(fitted_context, attempt, previous_reason) do
      {:ok, prompt} -> {:ok, prompt, fitted_context}
      {:error, reason} -> {:error, reason}
    end
  end

  defp render_review_prompt_for_context(review_context, attempt, previous_reason) do
    render_review_prompt(
      review_context.issue,
      review_context.review_workflow,
      attempt,
      previous_reason,
      review_context.settings.verdict_path,
      review_context.packet_result,
      review_context.settings
    )
  end

  defp handle_review_session_failure(%{issue: %Issue{} = issue, opts: opts} = review_context, attempt, reason) do
    if attempt < @max_verdict_attempts do
      Logger.warning("review.gate session failed #{issue_context(issue)} reason=#{inspect(reason)} attempt=#{attempt}; retrying")

      run_iteration(review_context, attempt + 1, {:review_session_failed, reason})
    else
      conclude_infrastructure_failure(
        issue,
        review_context,
        attempt,
        {:review_session_failed, reason},
        opts
      )
    end
  end

  # On both verdicts we refresh the PR's human-review section from the reviewer's
  # review_effort tier + prose (effort is orthogonal to the verdict — a change
  # needing a thorough review can still approve). Keeping it fresh through the
  # request_changes loop means the final pass's assessment wins.
  defp evaluate_verdict(
         verdict_path,
         %{workspace: workspace, issue: %Issue{} = issue, settings: settings, pr: pr, opts: opts} = review_context,
         attempt,
         telemetry_handle,
         _session
       ) do
    packet = review_context.packet_result.packet

    case read_verdict(
           verdict_path,
           review_context.reviewed_sha,
           packet.packet_id,
           packet.diff.mode
         ) do
      {:ok, %{verdict: :approve} = verdict} ->
        ReviewTelemetry.finish(telemetry_handle, :approved, verdict)
        outcome = approved_outcome(review_context, verdict, attempt)
        clear_latest_outcome(issue.id)
        maybe_write_section(workspace, pr, verdict.review_effort, verdict.human_review, settings, opts)
        emit_outcome_telemetry(issue, outcome)
        {:approved, outcome}

      {:ok, %{verdict: :request_changes} = verdict} ->
        ReviewTelemetry.finish(telemetry_handle, :request_changes, verdict)
        conclude_request_changes(review_context, verdict, attempt)

      {:error, reason} ->
        ReviewTelemetry.finish(telemetry_handle, :automation_inconclusive)

        if attempt < @max_verdict_attempts do
          Logger.warning("review.gate verdict unreadable #{issue_context(issue)} reason=#{inspect(reason)} attempt=#{attempt}; retrying")

          run_iteration(review_context, attempt + 1, reason)
        else
          conclude_inconclusive(
            issue,
            review_context,
            attempt,
            {:verdict_unreadable, reason},
            "Repair verdict production, then start a fresh orchestration run and re-attempt the gated handoff for the candidate SHA."
          )
        end
    end
  end

  defp conclude_request_changes(%{issue: %Issue{} = issue, iteration: iteration} = context, verdict, attempt) do
    next_iteration = iteration + 1
    request_outcome = request_changes_outcome(context, verdict, next_iteration, attempt)
    put_iteration(issue.id, next_iteration)
    put_latest_outcome(issue.id, request_outcome)
    finalize_request_changes(context, verdict, request_outcome)
  end

  defp finalize_request_changes(context, _verdict, request_outcome)
       when request_outcome.iteration >= request_outcome.max_iterations do
    outcome =
      budget_outcome(
        context.settings,
        request_outcome.iteration,
        context.reviewed_sha,
        request_outcome
      )

    put_terminal_outcome(context.issue.id, outcome)

    maybe_write_section(
      context.workspace,
      context.pr,
      :thorough,
      budget_human_review(outcome.iteration),
      context.settings,
      context.opts
    )

    note_budget_exhausted(context.issue, outcome, context.opts)
    emit_outcome_telemetry(context.issue, outcome)
    {:budget_exhausted_with_findings, outcome}
  end

  defp finalize_request_changes(context, verdict, outcome) do
    maybe_write_section(
      context.workspace,
      context.pr,
      verdict.review_effort,
      verdict.human_review,
      context.settings,
      context.opts
    )

    emit_outcome_telemetry(context.issue, outcome)

    {:request_changes, remediation_prompt(verdict, outcome.iteration, outcome.max_iterations), outcome}
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
    Automated review ran #{iterations} change-request #{pluralize(iterations, "pass", "passes")} without converging. The handoff was **withheld and remains unapproved by automation**. A human must resolve or explicitly accept the latest findings before a fresh orchestration run may review the resulting candidate. Treat this PR as elevated risk and review carefully end-to-end. The unresolved findings are preserved in the run transcript and the linked issue escalation note.
    """
    |> String.trim()
  end

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_n, _singular, plural), do: plural

  # --- reviewer session ----------------------------------------------------

  defp run_review_session(ctx, opts) do
    runner = Keyword.get(opts, :session_runner, &default_session_runner/1)
    runner.(ctx)
  rescue
    error ->
      {:error, {:reviewer_exception, %{exception: error.__struct__, message: Exception.message(error)}}}
  catch
    kind, reason ->
      {:error, {:reviewer_crash, kind, reason}}
  end

  defp default_session_runner(%{
         workspace: workspace,
         issue: issue,
         worker_host: worker_host,
         prompt: prompt,
         tool_executor: tool_executor,
         on_message: on_message,
         review_settings: settings
       }) do
    opts =
      [
        worker_host: worker_host,
        tool_executor: tool_executor,
        ephemeral: true,
        overrides: review_overrides(settings),
        turn_timeout_ms: settings.turn_timeout_ms
      ]
      |> maybe_put_on_message(on_message)

    AppServer.run(workspace, prompt, issue, opts)
  end

  defp review_overrides(settings) do
    %{}
    |> maybe_put_override(:model, settings.model)
    |> maybe_put_override(:reasoning_effort, settings.reasoning_effort)
  end

  defp maybe_put_override(overrides, _key, nil), do: overrides
  defp maybe_put_override(overrides, key, value), do: Map.put(overrides, key, value)

  defp maybe_put_on_message(opts, on_message) when is_function(on_message, 1),
    do: Keyword.put(opts, :on_message, on_message)

  defp maybe_put_on_message(opts, _on_message), do: opts

  # The reviewer talks to Linear read-only and without a handoff gate context:
  # read-only blocks any `issueUpdate`/mutation so the reviewer cannot move the
  # issue itself. The absent gate context stops the reviewer's own
  # tool calls from re-entering this gate (recursion guard, the analog of UDP's
  # `UDP_NESTED_CODEX` skip in before-handoff.sh).
  defp review_tool_executor(linear_client, max_output_bytes) do
    client = linear_client || (&Client.graphql/3)

    read_only_client = fn query, variables, request_opts ->
      if mutation_query?(query) do
        {:error, :review_session_read_only}
      else
        client.(query, variables, request_opts)
      end
    end

    fn tool, arguments ->
      tool
      |> DynamicTool.execute(arguments, linear_client: read_only_client)
      |> compact_successful_tool_response(max_output_bytes, tool)
    end
  end

  defp compact_successful_tool_response(%{"success" => true, "output" => output} = response, max_bytes, tool)
       when is_binary(output) and is_integer(max_bytes) and byte_size(output) > max_bytes do
    compacted = compacted_tool_output(output, max_bytes, tool)

    response
    |> Map.put("output", compacted)
    |> Map.update("contentItems", [], fn items ->
      Enum.map(items, fn
        %{"text" => ^output} = item -> Map.put(item, "text", compacted)
        item -> item
      end)
    end)
  end

  defp compact_successful_tool_response(response, _max_bytes, _tool), do: response

  defp compacted_tool_output(output, max_bytes, tool) do
    metadata = %{
      "compacted" => true,
      "original_bytes" => byte_size(output),
      "max_bytes" => max_bytes,
      "recovery" => "Re-run #{tool} with a narrower query/selection set or request a specific raw artifact; do not infer omitted data."
    }

    fit_tool_preview(output, metadata, max_bytes, 0, byte_size(output), "")
    |> case do
      "" -> Jason.encode!(Map.take(metadata, ["compacted", "original_bytes", "recovery"]))
      compacted -> compacted
    end
  end

  defp fit_tool_preview(_output, _metadata, _max_bytes, low, high, best) when low > high,
    do: best

  defp fit_tool_preview(output, metadata, max_bytes, low, high, best) do
    midpoint = div(low + high, 2)
    candidate = metadata |> Map.put("preview", utf8_prefix(output, midpoint)) |> Jason.encode!()

    if byte_size(candidate) <= max_bytes do
      fit_tool_preview(output, metadata, max_bytes, midpoint + 1, high, candidate)
    else
      fit_tool_preview(output, metadata, max_bytes, low, midpoint - 1, best)
    end
  end

  defp utf8_prefix(_output, 0), do: ""

  defp utf8_prefix(output, bytes) do
    prefix = binary_part(output, 0, bytes)

    case :unicode.characters_to_binary(prefix) do
      value when is_binary(value) -> value
      _invalid -> utf8_prefix(output, bytes - 1)
    end
  rescue
    _error -> utf8_prefix(output, max(bytes - 1, 0))
  end

  defp mutation_query?(query) when is_binary(query) do
    query
    |> String.trim_leading()
    |> String.downcase()
    |> String.starts_with?("mutation")
  end

  defp mutation_query?(_query), do: false

  defp render_review_prompt(
         %Issue{} = issue,
         review_workflow,
         attempt,
         previous_reason,
         verdict_path,
         packet_result,
         settings
       ) do
    thin_issue = %{
      issue
      | description: "Exact issue outcome and acceptance criteria are in the bounded Symphony review packet.",
        comments: [],
        children: [],
        attachment_urls: []
    }

    prompt =
      PromptBuilder.build_prompt(thin_issue, per_repo_workflow: review_workflow) <>
        "\n\n" <> TestWorkerBudget.prompt_section().content

    prompt = add_review_packet_contract(prompt, packet_result, settings)
    prompt = add_review_runtime_stability_guard(prompt)
    prompt = add_review_tool_output_guard(prompt)
    prompt = add_verdict_reliability_guard(prompt, verdict_path)
    prompt = maybe_add_verdict_retry_instructions(prompt, attempt, previous_reason, verdict_path)

    validate_review_prompt_budget(prompt, settings)
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp validate_review_prompt_budget(prompt, settings) do
    max_bytes = settings.context_budget_tokens * @context_bytes_per_token

    cond do
      String.trim(prompt) == "" -> {:error, :empty_review_prompt}
      byte_size(prompt) > max_bytes -> {:error, {:review_context_budget_exceeded, byte_size(prompt), max_bytes}}
      true -> {:ok, prompt}
    end
  end

  defp add_review_packet_contract(prompt, packet_result, settings) do
    """
    #{prompt}

    ## Symphony exact-candidate review packet

    This is a fresh reviewer thread. It does not contain and must not request the implementor's
    conversation transcript. The complete bounded packet is at `#{packet_result.path}` and is
    reproduced below. Packet id: `#{packet_result.packet.packet_id}`; schema version:
    `#{packet_result.packet.schema_version}`; exact head: `#{packet_result.packet.candidate.head_sha || "unavailable"}`.

    ```json
    #{packet_result.encoded}
    ```

    The packet is bounded to #{settings.packet_max_bytes} bytes and this review has a
    #{settings.context_budget_tokens}-token context budget (enforced conservatively as at most
    #{@context_bytes_per_token} rendered UTF-8 bytes per token), #{settings.turn_budget} Codex turn, a
    #{settings.turn_timeout_ms}ms timeout, and #{settings.tool_output_max_bytes} bytes per successful
    tool-output summary. Compact successful output as the budget approaches. Never silently truncate
    or sample the candidate: use the packet's authoritative full-diff commands and independently
    inspect the complete meaningful change. If evidence is insufficient, request/read the raw
    artifact or return a non-approval verdict.

    Any delegated lens must start with `fork_turns: "none"` and receive only the packet path, exact
    head, requested lens, budget, and relevant repository-rule paths. Do not fork the parent review
    transcript. Every lens must report what it inspected, its exact head, findings, model/reasoning
    effort when known, and attestations it reused or reran.

    The final verdict JSON must include `packet_id`, `reviewed_sha` equal to the packet exact head, a
    non-empty `inspected` array describing the complete diff/areas actually read, and `attestations`
    with `reused` and `rerun` arrays. A changed or missing identity is inconclusive, never approval.
    High-risk `high_risk_final_full_diff` mode additionally requires `full_diff_inspected: true`
    after a final complete base-to-head diff pass following delta reconciliation.
    """
  end

  defp add_review_runtime_stability_guard(prompt) do
    """
    #{prompt}

    ## Symphony automated-review runtime guard

    This review is running inside an unattended Symphony gate. Complete the review within this
    Codex turn. If the repository review workflow asks for sub-agents or delegated lenses, you may
    use those tools when they are available and expected to complete promptly. You remain
    responsible for reconciling their findings and writing the final verdict file before your final
    message.

    Do not run package-manager validation commands such as `pnpm test`, `pnpm lint`, `pnpm
    typecheck`, or app/browser checks during this automated gate unless the command is essential to
    decide a concrete blocker and is expected to finish quickly. Prefer existing PR checks, the
    implementor's recorded validation, and narrow file inspection. If validation cannot be completed
    within this turn, say that in the final verdict and choose `request_changes` only when the
    missing evidence meets the workflow severity bar.
    """
  end

  defp add_review_tool_output_guard(prompt) do
    """
    #{prompt}

    ## Symphony review tool-output guard

    Keep review command output bounded. Do not run broad searches in `node_modules`, `.git`,
    generated assets, source maps, build output, coverage output, or framework caches. Default
    searches should exclude those trees, for example:

    ```sh
    rg -n "pattern" --glob '!node_modules/**' --glob '!dist/**' --glob '!build/**' --glob '!coverage/**' --glob '!*.map'
    ```

    If dependency internals are essential, inspect a specific file or tight path and cap the
    output with a narrow pattern, `--max-count`, `head`, or a small `sed -n` range. Do not run a
    long check in parallel with a command that may produce large output. If a command returns
    unexpectedly large output, stop broad searching and write the verdict from the evidence already
    gathered, using `request_changes` when the uncertainty meets the review severity bar.
    """
  end

  defp add_verdict_reliability_guard(prompt, verdict_path) do
    """
    #{prompt}

    ## Symphony verdict reliability guard

    Before starting any long-running command or broad validation check, create the verdict directory
    and write a valid interim verdict to `#{verdict_path}`. The interim verdict must include
    `"symphony_interim": true`. If you do not yet have enough evidence to approve, that interim
    verdict must be `"request_changes"` and explain the missing evidence or unresolved risk. Replace
    it with your final verdict before your final message, and either omit `symphony_interim` or set
    it to `false`.

    Do not make a slow check the last thing standing between Symphony and the verdict file. If a
    validation command is interrupted, times out, or returns partial evidence, keep or write the
    verdict from the evidence already gathered, using `"request_changes"` when uncertainty meets
    the review severity bar.
    """
  end

  defp maybe_add_verdict_retry_instructions(prompt, attempt, _previous_reason, _verdict_path)
       when attempt <= 1 do
    prompt
  end

  defp maybe_add_verdict_retry_instructions(prompt, attempt, previous_reason, verdict_path) do
    """
    #{prompt}

    ## Symphony retry guard

    A previous reviewer session for this same handoff ended without a readable verdict file
    (reason: `#{inspect(previous_reason)}`). This is retry attempt #{attempt} of #{@max_verdict_attempts}.

    Before doing anything else, create the verdict directory:

    ```sh
    mkdir -p #{Path.dirname(verdict_path)}
    ```

    Complete a concise review under the original instructions above, then write valid JSON
    to `#{verdict_path}` before your final message. You may use workflow-authorized sub-agents if
    they are available and expected to finish within this retry, but do not start long-running
    checks unless they are essential to decide the verdict. If remaining uncertainty meets the
    severity bar, use `"request_changes"` rather than ending without a verdict.
    """
  end

  defp prepare_verdict_path(verdict_path) do
    _ = File.rm_rf(verdict_path)
    _ = File.mkdir_p(Path.dirname(verdict_path))
    :ok
  end

  # --- verdict parsing -----------------------------------------------------

  defp read_verdict(verdict_path, expected_sha, expected_packet_id, review_mode) do
    with {:ok, raw} <- File.read(verdict_path),
         {:ok, decoded} <- Jason.decode(raw),
         :ok <- reject_interim_verdict(decoded),
         {:ok, verdict} <- normalize_verdict(decoded),
         :ok <- validate_verdict_candidate(verdict, expected_sha, expected_packet_id, review_mode) do
      {:ok, verdict}
    end
  end

  defp validate_verdict_candidate(verdict, expected_sha, expected_packet_id, review_mode)
       when is_binary(expected_sha) and expected_sha != "" do
    cond do
      verdict.packet_id != expected_packet_id ->
        {:error, {:verdict_packet_mismatch, %{expected: expected_packet_id, reported: verdict.packet_id}}}

      verdict.reviewed_sha != expected_sha ->
        {:error, {:verdict_head_mismatch, %{expected: expected_sha, reported: verdict.reviewed_sha}}}

      verdict.inspected == [] ->
        {:error, :verdict_missing_inspected_scope}

      not verdict.attestation_contract? ->
        {:error, :verdict_missing_attestation_report}

      review_mode == "high_risk_final_full_diff" and not verdict.full_diff_inspected ->
        {:error, :verdict_missing_high_risk_full_diff_attestation}

      true ->
        :ok
    end
  end

  defp validate_verdict_candidate(_verdict, _expected_sha, _expected_packet_id, _review_mode),
    do: :ok

  defp reject_interim_verdict(%{"symphony_interim" => true}), do: {:error, :interim_verdict}

  defp reject_interim_verdict(decoded) when is_map(decoded) do
    if legacy_interim_verdict?(decoded) do
      {:error, :interim_verdict}
    else
      :ok
    end
  end

  defp reject_interim_verdict(_decoded), do: :ok

  defp legacy_interim_verdict?(decoded) do
    text =
      [
        Map.get(decoded, "summary"),
        Map.get(decoded, "human_review"),
        decoded
        |> Map.get("comments")
        |> interim_comment_text()
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
      |> String.downcase()

    String.contains?(text, "interim") and
      (String.contains?(text, "review is in progress") or
         String.contains?(text, "interim placeholder") or
         String.contains?(text, "final review has not completed"))
  end

  defp interim_comment_text(comments) when is_list(comments) do
    Enum.map_join(comments, "\n", fn
      %{"body" => body} when is_binary(body) -> body
      %{body: body} when is_binary(body) -> body
      body when is_binary(body) -> body
      _ -> ""
    end)
  end

  defp interim_comment_text(_comments), do: nil

  defp normalize_verdict(decoded) when is_map(decoded) do
    case normalize_verdict_value(Map.get(decoded, "verdict")) do
      {:ok, verdict_atom} ->
        {:ok,
         %{
           verdict: verdict_atom,
           summary: string_or_default(Map.get(decoded, "summary"), ""),
           review_effort: normalize_effort(Map.get(decoded, "review_effort") || Map.get(decoded, "risk")),
           human_review: string_or_default(Map.get(decoded, "human_review"), ""),
           comments: normalize_comments(Map.get(decoded, "comments")),
           packet_id: string_or_nil(Map.get(decoded, "packet_id")),
           reviewed_sha: string_or_nil(Map.get(decoded, "reviewed_sha")),
           inspected: normalize_string_list(Map.get(decoded, "inspected")),
           attestations: normalize_attestation_report(Map.get(decoded, "attestations")),
           attestation_contract?: valid_attestation_report?(Map.get(decoded, "attestations")),
           full_diff_inspected: Map.get(decoded, "full_diff_inspected") == true
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

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_string_list(_values), do: []

  defp normalize_attestation_report(report) when is_map(report) do
    %{
      reused: normalize_string_list(Map.get(report, "reused") || Map.get(report, :reused)),
      rerun: normalize_string_list(Map.get(report, "rerun") || Map.get(report, :rerun))
    }
  end

  defp normalize_attestation_report(_report), do: %{reused: [], rerun: []}

  defp valid_attestation_report?(report) when is_map(report) do
    is_list(Map.get(report, "reused") || Map.get(report, :reused)) and
      is_list(Map.get(report, "rerun") || Map.get(report, :rerun))
  end

  defp valid_attestation_report?(_report), do: false

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

    Keep the issue in In Progress. Address the comments above — update code, tests, or docs, or post a justified pushback in the workpad — then re-attempt the handoff. The reviewer will run again on your next attempt. After #{max_iterations} request-change passes Symphony stops automated review and escalates the unresolved findings for an explicit human decision; it does not treat budget exhaustion as approval.
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

  defp approved_outcome(
         %{settings: settings, iteration: iteration, reviewed_sha: reviewed_sha} = context,
         verdict,
         attempt
       ) do
    %ReviewOutcome{
      outcome: :approved,
      iteration: iteration + 1,
      max_iterations: settings.max_iterations,
      reviewed_sha: reviewed_sha,
      packet_id: context_packet_id(context),
      summary: verdict.summary,
      review_effort: verdict.review_effort,
      attempts: attempt,
      authoritative: present_sha?(reviewed_sha),
      findings: verdict.comments,
      inspected: verdict.inspected,
      attestation_report: verdict.attestations,
      severity_counts: severity_counts(verdict.comments),
      resume_condition: "Apply the deferred handoff only if this reviewed SHA is still the exact candidate head."
    }
  end

  defp request_changes_outcome(
         %{settings: settings, reviewed_sha: reviewed_sha} = context,
         verdict,
         iteration,
         attempt
       ) do
    %ReviewOutcome{
      outcome: :request_changes,
      iteration: iteration,
      max_iterations: settings.max_iterations,
      reviewed_sha: reviewed_sha,
      packet_id: context_packet_id(context),
      summary: verdict.summary,
      review_effort: verdict.review_effort,
      attempts: attempt,
      findings: verdict.comments,
      inspected: verdict.inspected,
      attestation_report: verdict.attestations,
      severity_counts: severity_counts(verdict.comments),
      resume_condition: "Resolve or explicitly rebut every blocking finding, update the candidate head if needed, and re-attempt automated review."
    }
  end

  defp context_packet_id(context), do: get_in(context, [:packet_result, :packet, :packet_id])

  defp inconclusive_outcome(settings, iteration, reviewed_sha, reason, resume_condition) do
    %ReviewOutcome{
      outcome: :automation_inconclusive,
      iteration: iteration + 1,
      max_iterations: settings.max_iterations,
      reviewed_sha: reviewed_sha,
      failure_reason: reason,
      resume_condition: resume_condition
    }
  end

  defp infrastructure_outcome(settings, iteration, reviewed_sha, reason, resume_condition, attempts) do
    %ReviewOutcome{
      outcome: :infrastructure_unavailable,
      iteration: iteration + 1,
      max_iterations: settings.max_iterations,
      reviewed_sha: reviewed_sha,
      failure_reason: reason,
      attempts: attempts,
      resume_condition: resume_condition
    }
  end

  defp budget_outcome(settings, iteration, reviewed_sha, %ReviewOutcome{} = latest) do
    %ReviewOutcome{
      outcome: :budget_exhausted_with_findings,
      iteration: iteration,
      max_iterations: settings.max_iterations,
      reviewed_sha: latest.reviewed_sha || reviewed_sha,
      packet_id: latest.packet_id,
      summary: latest.summary,
      failure_reason: :review_budget_exhausted,
      review_effort: :thorough,
      findings: latest.findings,
      inspected: latest.inspected,
      attestation_report: latest.attestation_report,
      severity_counts: latest.severity_counts,
      resume_condition:
        "A human must resolve or explicitly accept the listed findings. After that decision and any required code/head change, start a fresh orchestration run for a new exact-head review."
    }
  end

  defp budget_outcome(settings, iteration, reviewed_sha, _latest) do
    %ReviewOutcome{
      outcome: :budget_exhausted_with_findings,
      iteration: iteration,
      max_iterations: settings.max_iterations,
      reviewed_sha: reviewed_sha,
      failure_reason: :review_budget_exhausted,
      review_effort: :thorough,
      resume_condition:
        "A human must inspect the run evidence and record a decision. After that decision and any required code/head change, start a fresh orchestration run for a new exact-head review."
    }
  end

  defp conclude_inconclusive(issue, review_context, attempt, reason, resume_condition) do
    outcome =
      review_context.settings
      |> inconclusive_outcome(
        review_context.iteration,
        review_context.reviewed_sha,
        reason,
        resume_condition
      )
      |> Map.put(:packet_id, context_packet_id(review_context))
      |> Map.put(:attempts, attempt)

    Logger.warning("review.gate inconclusive #{issue_context(issue)} reason=#{inspect(reason)}; withholding handoff")
    note_nonapproval(issue, outcome, review_context.opts)
    put_terminal_outcome(issue.id, outcome)
    emit_outcome_telemetry(issue, outcome)
    {:automation_inconclusive, outcome}
  end

  defp conclude_infrastructure_failure(issue, review_context, attempt, reason, opts) do
    classified = SymphonyElixir.AgentFailure.classify(reason, backend: "codex")

    outcome =
      infrastructure_outcome(
        review_context.settings,
        review_context.iteration,
        review_context.reviewed_sha,
        %{class: classified.class, reason: reason},
        "Restore reviewer tool/auth/runtime availability, then start a fresh orchestration run and re-attempt review for the candidate SHA.",
        attempt
      )
      |> Map.put(:packet_id, context_packet_id(review_context))

    Logger.warning("review.gate infrastructure unavailable #{issue_context(issue)} reason=#{inspect(reason)}; withholding handoff")
    note_nonapproval(issue, outcome, opts)
    put_terminal_outcome(issue.id, outcome)
    emit_outcome_telemetry(issue, outcome)
    {:infrastructure_unavailable, outcome}
  end

  defp note_budget_exhausted(%Issue{} = issue, %ReviewOutcome{} = outcome, opts) do
    note_once(@budget_noted_key, issue, outcome.outcome, opts, fn ->
      """
      #{@budget_marker}
      Automated review outcome: `budget_exhausted_with_findings` (not approved).

      Candidate SHA: `#{sha_label(outcome.reviewed_sha)}`
      Change-request passes: #{outcome.iteration} of #{outcome.max_iterations}
      Severity counts: #{format_severity_counts(outcome.severity_counts)}

      Latest reviewer summary:
      #{blank_to_placeholder(outcome.summary, "(no summary provided)")}

      Unresolved findings:
      #{format_comments(outcome.findings)}

      Resume/escalation condition: #{outcome.resume_condition}
      """
    end)

    Logger.warning("review.gate budget exhausted #{issue_context(issue)} iterations=#{outcome.iteration}; withholding handoff for human decision")
    :ok
  end

  defp note_nonapproval(%Issue{} = issue, %ReviewOutcome{} = outcome, opts) do
    note_once(@skip_noted_key, issue, outcome.outcome, opts, fn ->
      """
      #{@skip_marker}
      Automated review outcome: `#{outcome.outcome}` (not approved).

      Candidate SHA: `#{sha_label(outcome.reviewed_sha)}`
      Review iteration: #{outcome.iteration} of #{outcome.max_iterations}
      Failure reason: `#{inspect(outcome.failure_reason)}`
      Severity counts: #{format_severity_counts(outcome.severity_counts)}

      Preserved findings:
      #{format_comments(outcome.findings)}

      Resume/escalation condition: #{outcome.resume_condition}
      """
    end)
  end

  # Post a Linear note at most once per run per issue (the gate can be hit on
  # repeated handoff attempts within a single run).
  defp note_once(flag_key, %Issue{id: issue_id}, discriminator, opts, body_fun) do
    seen = Process.get(flag_key, MapSet.new())
    note_key = {issue_id, discriminator}

    if MapSet.member?(seen, note_key) do
      :ok
    else
      Process.put(flag_key, MapSet.put(seen, note_key))
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

  defp latest_outcome(issue_id) do
    @latest_outcome_key
    |> Process.get(%{})
    |> Map.get(issue_id)
  end

  defp put_latest_outcome(issue_id, %ReviewOutcome{} = outcome) do
    outcomes = Process.get(@latest_outcome_key, %{})
    Process.put(@latest_outcome_key, Map.put(outcomes, issue_id, outcome))
    :ok
  end

  defp clear_latest_outcome(issue_id) do
    outcomes = Process.get(@latest_outcome_key, %{})
    Process.put(@latest_outcome_key, Map.delete(outcomes, issue_id))
    :ok
  end

  defp terminal_outcome(issue_id, reviewed_sha) do
    case Process.get(@terminal_outcome_key, %{}) |> Map.get(issue_id) do
      %ReviewOutcome{reviewed_sha: ^reviewed_sha} = outcome -> outcome
      _outcome -> nil
    end
  end

  defp put_terminal_outcome(issue_id, %ReviewOutcome{} = outcome) do
    outcomes = Process.get(@terminal_outcome_key, %{})
    Process.put(@terminal_outcome_key, Map.put(outcomes, issue_id, outcome))
    :ok
  end

  # --- telemetry -----------------------------------------------------------

  defp emit_outcome_telemetry(%Issue{} = issue, %ReviewOutcome{} = outcome) do
    metadata = %{
      subtype: "review",
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      parent_issue_id: issue.parent_id,
      from_state: issue.state,
      iteration: outcome.iteration,
      max_iterations: outcome.max_iterations,
      outcome: outcome.outcome,
      packet_id: outcome.packet_id,
      reviewed_sha: outcome.reviewed_sha,
      authoritative: outcome.authoritative,
      severity_counts: outcome.severity_counts,
      failure_reason: outcome.failure_reason,
      review_effort: outcome.review_effort,
      attestation_report: outcome.attestation_report
    }

    :telemetry.execute(
      @telemetry_event,
      %{
        count: 1,
        iteration: outcome.iteration,
        comments: length(outcome.findings),
        unresolved_findings: length(outcome.findings)
      },
      Map.put(metadata, :event, "gate.review")
    )

    Telemetry.emit(:review, metadata)

    if map_size(outcome.severity_counts) > 0 do
      Telemetry.emit(:quality_outcome, %{
        outcome: "human_blocking_findings",
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        parent_issue_id: issue.parent_id,
        reviewed_sha: outcome.reviewed_sha,
        packet_id: outcome.packet_id,
        severity_counts: outcome.severity_counts
      })
    end

    Logger.info(
      "gate.review #{issue_context(issue)} iteration=#{outcome.iteration} outcome=#{outcome.outcome} reviewed_sha=#{sha_label(outcome.reviewed_sha)} findings=#{length(outcome.findings)} severity_counts=#{inspect(outcome.severity_counts)} review_effort=#{inspect(outcome.review_effort)}"
    )
  end

  # --- small helpers -------------------------------------------------------

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

  defp severity_counts(findings) when is_list(findings) do
    Enum.reduce(findings, %{}, fn finding, counts ->
      severity =
        finding
        |> Map.get(:severity, "comment")
        |> to_string()
        |> String.trim()
        |> String.downcase()
        |> case do
          "" -> "comment"
          value -> value
        end

      Map.update(counts, severity, 1, &(&1 + 1))
    end)
  end

  defp format_severity_counts(counts) when map_size(counts) == 0, do: "none recorded"

  defp format_severity_counts(counts) do
    counts
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(", ", fn {severity, count} -> "#{severity}=#{count}" end)
  end

  defp present_sha?(value), do: is_binary(value) and String.trim(value) != ""
  defp sha_label(value) when is_binary(value) and value != "", do: value
  defp sha_label(_value), do: "unavailable"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{identifier || "n/a"}"
  end
end
