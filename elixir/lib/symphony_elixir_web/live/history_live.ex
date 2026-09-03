defmodule SymphonyElixirWeb.HistoryLive do
  @moduledoc """
  Bounded historical harness-evaluation cockpit backed by compact telemetry.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.Presenter

  @filter_keys ~w(repository task_family model prompt_version config_digest)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:window_days, 7)
     |> assign(:filters, %{})
     |> assign(:evaluation, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    window_days = parse_window(params["window"])
    filters = normalize_filters(params)

    {:noreply,
     socket
     |> assign(:window_days, window_days)
     |> assign(:filters, filters)
     |> assign(:evaluation, Presenter.evaluation_payload(window_days, filters))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Symphony Observability</p>
            <h1 class="hero-title">Historical Evaluation</h1>
            <p class="hero-copy">
              Bounded retained evidence for worker execution and verified task delivery. A completed worker run is not, by itself, an accepted handoff or a downstream success.
            </p>
          </div>
          <div class="status-stack">
            <.link class="subtle-button" navigate="/">Back to live dashboard</.link>
            <.link class="subtle-button" navigate={history_path(7, @filters)}>7 days</.link>
            <.link class="subtle-button" navigate={history_path(30, @filters)}>30 days</.link>
          </div>
        </div>
      </header>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Cohort filters</h2>
            <p class="section-copy">
              The selected window and every filter are represented in the URL. Empty values include all retained events.
            </p>
          </div>
        </div>
        <form action="/history" method="get" class="field-list">
          <label>
            <span class="field-label">Window</span>
            <select name="window">
              <option value="7" selected={@window_days == 7}>7 days</option>
              <option value="30" selected={@window_days == 30}>30 days</option>
            </select>
          </label>
          <label :for={key <- filter_keys()}>
            <span class="field-label"><%= filter_label(key) %></span>
            <select name={key}>
              <option value="">All</option>
              <option
                :for={value <- @evaluation.filter_options[String.to_existing_atom(key)]}
                value={value}
                selected={@filters[key] == value}
              >
                <%= value %>
              </option>
            </select>
          </label>
          <div><button type="submit" class="subtle-button">Apply filters</button></div>
        </form>
      </section>

      <section class="metric-grid">
        <.metric
          label="Worker-run completion"
          value={format_rate(@evaluation.fleet.worker_run_completion_rate)}
          detail={"#{@evaluation.fleet.worker_runs_ended} ended / #{@evaluation.fleet.worker_runs_started} started; lifecycle only"}
        />
        <.metric
          label="Normal worker exits"
          value={format_rate(@evaluation.fleet.worker_normal_completion_rate)}
          detail="Successful transport/runner exits, not verified task outcomes"
        />
        <.metric
          label="Material progress"
          value={format_integer(@evaluation.fleet.material_progress_runs)}
          detail="Runs with an observed commit or hash-only worktree delta"
        />
        <.metric
          label="Accepted exact-head handoffs"
          value={format_integer(@evaluation.fleet.accepted_handoffs)}
          detail={"#{format_rate(@evaluation.fleet.accepted_handoff_rate)} of terminal handoff attempts"}
        />
        <.metric
          label="Post-handoff reliability"
          value={format_rate(@evaluation.fleet.post_handoff.reliability_rate)}
          detail={"#{@evaluation.fleet.post_handoff.reliable} reliable / #{@evaluation.fleet.post_handoff.evaluated} evaluated; #{@evaluation.fleet.post_handoff.unknown} unknown"}
        />
        <.metric
          label="Tokens / accepted handoff"
          value={format_number(@evaluation.fleet.tokens_per_accepted_handoff)}
          detail={"p50 #{format_number(@evaluation.fleet.tokens_p50)} · p90 #{format_number(@evaluation.fleet.tokens_p90)} per reported thread"}
        />
        <.metric
          label="Cost / accepted handoff"
          value={format_cost(@evaluation.fleet.cost_per_accepted_handoff_usd)}
          detail="Unavailable unless an explicit numeric cumulative USD value was emitted"
        />
        <.metric
          label="Worker duration"
          value={format_duration(@evaluation.fleet.duration_ms_p50)}
          detail={"p50 · p90 #{format_duration(@evaluation.fleet.duration_ms_p90)}"}
        />
      </section>

      <section class="metric-grid">
        <.outcome_count label="CI passed" count={@evaluation.outcomes.summary.ci_passed} />
        <.outcome_count label="CI failed" count={@evaluation.outcomes.summary.ci_failed} />
        <.outcome_count label="Human review passed" count={@evaluation.outcomes.summary.human_review_passed} />
        <.outcome_count label="Human review failed" count={@evaluation.outcomes.summary.human_review_failed} />
        <.outcome_count label="Pull requests merged" count={@evaluation.outcomes.summary.merged} />
        <.outcome_count label="Pull requests reopened" count={@evaluation.outcomes.summary.reopened} />
        <.outcome_count label="Pull requests reverted" count={@evaluation.outcomes.summary.reverted} />
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Shadow no-progress observations</h2>
            <p class="section-copy">
              Advisory post-turn evidence only. These observations never interrupt, retry, or block a worker.
            </p>
          </div>
        </div>
        <section class="metric-grid">
          <.metric
            label="Loop alerts"
            value={format_integer(@evaluation.no_progress.alerts)}
            detail="Deduplicated shadow warning observations"
          />
          <.metric
            label="Suppressed by progress"
            value={format_integer(@evaluation.no_progress.progress_suppressions)}
            detail="Qualified patterns suppressed by an observed progress change"
          />
          <.metric
            label="Progress unavailable"
            value={format_integer(@evaluation.no_progress.progress_unavailable)}
            detail="Qualified patterns withheld because no progress channel was comparable"
          />
          <.metric
            label="Episodes reset"
            value={format_integer(@evaluation.no_progress.resets)}
            detail="Previously latched shadow episodes cleared by observed progress"
          />
          <.breakdown title="Alert kinds" rows={top_rows(@evaluation.no_progress.by_kind)} />
          <.breakdown title="Alert result classes" rows={top_rows(@evaluation.no_progress.by_result_class)} />
          <.breakdown title="Alert tool classes" rows={top_rows(@evaluation.no_progress.by_tool_class)} />
        </section>
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Recent worker runs</h2>
            <p class="section-copy">
              At most 100 retained run groups. Outcome-only records remain in the outcome timeline and are not presented as worker runs.
            </p>
          </div>
        </div>
        <p :if={@evaluation.runs == []} class="empty-state">No matching worker runs in this window.</p>
        <div :if={@evaluation.runs != []} class="table-wrap">
          <table class="data-table">
            <thead>
              <tr>
                <th>Issue</th>
                <th>Repository / task</th>
                <th>Model / prompt</th>
                <th>Worker result</th>
                <th>Verified outcomes</th>
                <th>Tokens / duration</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={run <- @evaluation.runs}>
                <td>
                  <.link :if={run.issue_identifier} class="issue-id" navigate={issue_path(run.issue_identifier)}>
                    <%= run.issue_identifier %>
                  </.link>
                  <span :if={!run.issue_identifier} class="muted">unknown</span>
                  <div class="muted mono"><%= run.run_id || run.identity %></div>
                </td>
                <td><%= run.repository || "unknown" %><div class="muted"><%= run.task_family || "unknown" %></div></td>
                <td><%= run.model || "unknown" %><div class="muted mono"><%= run.prompt_version || "unknown" %></div></td>
                <td><%= run.worker_outcome || "incomplete/unknown" %><div class="muted"><%= run.failure_class || "no reported failure" %></div></td>
                <td><%= outcome_labels(run.outcomes) %></td>
                <td class="numeric"><%= format_number(run.tokens) %> · <%= format_duration(run.duration_ms) %></td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Task outcome timeline</h2>
            <p class="section-copy">
              CI, human-review, merge, reopen, and revert states stay unknown until explicit authoritative telemetry is present. Legacy handoff evidence is labeled separately.
            </p>
          </div>
        </div>
        <p :if={@evaluation.outcomes.timeline == []} class="empty-state">No explicit task outcomes in this window.</p>
        <div :if={@evaluation.outcomes.timeline != []} class="table-wrap">
          <table class="data-table">
            <thead><tr><th>Time</th><th>Issue</th><th>Stage</th><th>Status</th><th>Evidence</th></tr></thead>
            <tbody>
              <tr :for={outcome <- Enum.take(@evaluation.outcomes.timeline, 100)}>
                <td class="mono"><%= outcome.ts || "unknown" %></td>
                <td><%= outcome.issue_identifier || outcome.issue_id || "unknown" %></td>
                <td><%= outcome.stage %></td>
                <td><%= outcome.status %></td>
                <td><%= if outcome.authoritative, do: "authoritative", else: "legacy/non-authoritative" %></td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="metric-grid">
        <.breakdown title="Top failure classes" rows={top_rows(@evaluation.failures.by_class)} />
        <.breakdown title="Tool categories" rows={top_rows(@evaluation.tools.by_category)} />
        <.breakdown title="Review outcomes" rows={top_rows(@evaluation.reviews.verdicts)} />
        <.breakdown title="Prompt sections" rows={prompt_rows(@evaluation.prompts.by_section)} />
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Extreme trajectories</h2>
            <p class="section-copy">Runs that emitted an explicit extreme budget transition; capped at 20 rows.</p>
          </div>
        </div>
        <p :if={@evaluation.extreme_trajectories == []} class="empty-state">No matching extreme trajectories.</p>
        <div :for={run <- @evaluation.extreme_trajectories} class="field-list">
          <div><span class="field-label"><%= run.issue_identifier || "unknown issue" %></span><pre class="code-panel"><%= run.run_id || run.identity %> · <%= format_number(run.tokens) %> tokens</pre></div>
        </div>
      </section>

      <p class="muted">
        Requested <%= @evaluation.window.days %> days; retained effective window <%= @evaluation.window.effective_days %> days (<%= @evaluation.window.from %> through <%= @evaluation.window.to %> UTC).
      </p>
    </section>
    """
  end

  defp metric(assigns) do
    ~H"""
    <article class="metric-card">
      <p class="metric-label"><%= @label %></p>
      <p class="metric-value numeric"><%= @value %></p>
      <p class="metric-detail"><%= @detail %></p>
    </article>
    """
  end

  defp breakdown(assigns) do
    ~H"""
    <article class="metric-card">
      <p class="metric-label"><%= @title %></p>
      <p :if={@rows == []} class="metric-detail">No reported data.</p>
      <div :for={{label, count} <- @rows} class="metric-detail"><%= label %>: <span class="numeric"><%= count %></span></div>
    </article>
    """
  end

  defp outcome_count(assigns) do
    ~H"""
    <article class="metric-card">
      <p class="metric-label"><%= @label %></p>
      <p class="metric-value numeric"><%= @count %></p>
      <p class="metric-detail"><%= if @count == 0, do: "Unobserved in this cohort", else: "Explicit outcome events" %></p>
    </article>
    """
  end

  defp parse_window("30"), do: 30
  defp parse_window(_value), do: 7

  defp normalize_filters(params) do
    Map.new(@filter_keys, fn key -> {key, normalize_filter(params[key])} end)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp normalize_filter(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_filter(_value), do: nil

  defp history_path(window, filters) do
    query = filters |> Map.put("window", Integer.to_string(window)) |> URI.encode_query()
    "/history?#{query}"
  end

  defp issue_path(identifier), do: "/issues/#{URI.encode_www_form(identifier)}"
  defp filter_keys, do: @filter_keys

  defp filter_label("task_family"), do: "Task family"
  defp filter_label("prompt_version"), do: "Prompt version"
  defp filter_label("config_digest"), do: "Config digest"
  defp filter_label(value), do: String.capitalize(value)

  defp format_rate(nil), do: "unknown"
  defp format_rate(value) when is_number(value), do: "#{Float.round(value * 100, 1)}%"
  defp format_number(nil), do: "unknown"
  defp format_number(value) when is_float(value), do: value |> Float.round(1) |> to_string()
  defp format_number(value) when is_integer(value), do: Integer.to_string(value)
  defp format_integer(value) when is_integer(value), do: Integer.to_string(value)
  defp format_cost(nil), do: "unavailable"
  defp format_cost(value) when is_number(value), do: "$#{:erlang.float_to_binary(value / 1, decimals: 2)}"
  defp format_duration(nil), do: "unknown"
  defp format_duration(value) when is_number(value), do: "#{Float.round(value / 1_000, 1)}s"

  defp top_rows(map) when is_map(map) do
    map |> Enum.sort_by(fn {_label, count} -> -count end) |> Enum.take(10)
  end

  defp prompt_rows(map) when is_map(map) do
    map
    |> Enum.map(fn {section, metrics} -> {section, metrics.renders} end)
    |> Enum.sort_by(fn {_section, count} -> -count end)
    |> Enum.take(10)
  end

  defp outcome_labels([]), do: "none reported"

  defp outcome_labels(outcomes) do
    outcomes
    |> Enum.map_join(", ", &"#{&1.stage}:#{&1.status}")
  end
end
