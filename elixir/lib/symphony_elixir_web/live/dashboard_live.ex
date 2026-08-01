defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:dashboard_payload, %{})
      |> assign(:issue_payload, nil)
      |> assign(:issue_identifier, nil)
      |> assign(:transcript_cache, %{})
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"issue_identifier" => issue_identifier}, _uri, socket) do
    {:noreply, load_issue_page(socket, issue_identifier)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, load_dashboard_page(socket)}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> reload_current_page()
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <%= if @live_action == :issue do %>
        <%= if @issue_payload[:error] do %>
          <header class="hero-card">
            <div class="hero-grid">
              <div>
                <p class="eyebrow">
                  Symphony Observability
                </p>
                <h1 class="hero-title hero-title-sm">
                  <%= @issue_identifier %>
                </h1>
                <p class="hero-copy">
                  Issue details are currently unavailable.
                </p>
              </div>

              <div class="status-stack">
                <.link class="subtle-button" navigate="/">
                  Back to Dashboard
                </.link>
              </div>
            </div>
          </header>

          <section class="error-card">
            <h2 class="error-title">
              Issue unavailable
            </h2>
            <p class="error-copy">
              <strong><%= @issue_payload.error.code %>:</strong> <%= @issue_payload.error.message %>
            </p>
          </section>
        <% else %>
          <header class="hero-card">
            <div class="hero-grid">
              <div>
                <p class="eyebrow">
                  Symphony Observability
                </p>
                <h1 class="hero-title hero-title-sm">
                  <%= @issue_payload.title || @issue_payload.issue_identifier %>
                </h1>
                <p :if={@issue_payload.title} class="hero-subtitle mono">
                  <%= @issue_payload.issue_identifier %>
                </p>
                <p class="hero-copy">
                  Live issue detail with the latest reconstructed agent transcript for this workspace.
                </p>
              </div>

              <div class="status-stack">
                <.link class="subtle-button" navigate="/">
                  Back to Dashboard
                </.link>
                <a class="subtle-button" href={"/api/v1/#{@issue_payload.issue_identifier}"}>JSON details</a>
              </div>
            </div>
          </header>

          <section class="metric-grid">
            <article class="metric-card">
              <p class="metric-label">Status</p>
              <p class="metric-value"><%= String.capitalize(@issue_payload.status) %></p>
              <p class="metric-detail">
                <%= if @issue_payload.running do %>
                  <span class={state_badge_class(@issue_payload.running.state)}>
                    <%= @issue_payload.running.state %>
                  </span>
                <% else %>
                  Active retry window.
                <% end %>
              </p>
            </article>

            <article class="metric-card">
              <p class="metric-label">Session</p>
              <p class="metric-value metric-value-id mono" title={issue_session_id(@issue_payload)}>
                <%= issue_session_id(@issue_payload) %>
              </p>
              <p class="metric-detail">
                Turns: <%= @issue_payload.running && @issue_payload.running.turn_count || 0 %>
              </p>
            </article>

            <article class="metric-card">
              <p class="metric-label">Agent</p>
              <p class="metric-value metric-value-text"><%= agent_backend_label(@issue_payload.agent.backend) %></p>
              <p class="metric-detail mono" title={@issue_payload.agent.model}>
                <%= @issue_payload.agent.model || "model n/a" %>
              </p>
              <p :if={@issue_payload.agent.reasoning_effort} class="metric-detail mono">
                effort <%= @issue_payload.agent.reasoning_effort %><%= if @issue_payload.agent.profile, do: " · #{@issue_payload.agent.profile}" %>
              </p>
            </article>

            <article class="metric-card">
              <p class="metric-label">Runtime</p>
              <p class="metric-value numeric">
                <%= issue_runtime(@issue_payload, @now) %>
              </p>
              <p class="metric-detail">
                <%= if started = issue_started_at(@issue_payload) do %>
                  Started <time datetime={started} title={full_time(started)}><%= full_time(started) %></time>
                <% else %>
                  Started n/a
                <% end %>
              </p>
            </article>

            <article class="metric-card">
              <p class="metric-label">Total tokens</p>
              <p class="metric-value numeric"><%= issue_total_tokens(@issue_payload) %></p>
              <p class="metric-detail numeric">
                <%= issue_token_detail(@issue_payload) %>
              </p>
            </article>

            <article class="metric-card">
              <p class="metric-label">Context filled</p>
              <p class="metric-value numeric"><%= issue_context_fill(@issue_payload) %></p>
              <% ctx_pct = issue_context_percent(@issue_payload) %>
              <div :if={ctx_pct} class={"meter #{context_meter_level(ctx_pct)}"}>
                <div class="meter-fill" style={"width: #{ctx_pct}%"}></div>
              </div>
              <p class="metric-detail numeric">
                <%= issue_context_detail(@issue_payload) %>
              </p>
            </article>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Issue Context</h2>
                <p class="section-copy">Current session and workspace metadata for this issue.</p>
              </div>
            </div>

            <div class="field-list">
              <div>
                <span class="field-label">Workspace</span>
                <pre class="code-panel"><%= @issue_payload.workspace.path || "n/a" %></pre>
              </div>
              <div>
                <span class="field-label">Worker host</span>
                <pre class="code-panel"><%= @issue_payload.workspace.host || "local" %></pre>
              </div>
              <div :if={@issue_payload.last_error}>
                <span class="field-label">Latest retry error</span>
                <pre class="code-panel"><%= @issue_payload.last_error %></pre>
              </div>
            </div>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Transcript</h2>
                <p class="section-copy">
                  Reconstructed assistant text, reasoning, tool calls, and command output from the latest session.
                </p>
              </div>
            </div>

            <%= if transcript_blocks(@issue_payload.transcript) == [] do %>
              <p class="empty-state">
                No transcript text is available yet.
                <%= if @issue_payload.running && @issue_payload.running.last_message do %>
                  Latest update: <%= @issue_payload.running.last_message %>
                <% end %>
              </p>
            <% else %>
              <div class="transcript-stack">
                <article
                  :for={{block, index} <- Enum.with_index(display_transcript_blocks(transcript_blocks(@issue_payload.transcript)))}
                  class={transcript_block_class(block.kind, block[:subagent])}
                >
                  <%= cond do %>
                    <% markdown_transcript_kind?(block.kind) -> %>
                      <div class="transcript-block-head">
                        <span class={transcript_chip_class(block.kind)}><%= transcript_kind_label(block.kind) %></span>
                        <span :if={block[:subagent]} class="transcript-subagent-badge">↳ Subagent<%= subagent_suffix(block[:thread_id]) %></span>
                        <time :if={block.at} class="transcript-block-time" datetime={block.at} title={full_time(block.at)}><%= full_time(block.at) %></time>
                      </div>
                      <div class="transcript-markdown"><%= Phoenix.HTML.raw(markdown_to_html(block.text)) %></div>
                    <% collapsible_transcript_kind?(block.kind) -> %>
                      <details class="transcript-collapsible" id={"transcript-block-#{index}"} phx-hook="Collapsible">
                        <summary class="transcript-summary">
                          <span class={transcript_chip_class(block.kind)}><%= transcript_kind_label(block.kind) %></span>
                          <span :if={block[:subagent]} class="transcript-subagent-badge">↳ Subagent<%= subagent_suffix(block[:thread_id]) %></span>
                          <span class="transcript-summary-text mono" title={transcript_preview(block)}><%= transcript_preview(block) %></span>
                          <time :if={block.at} class="transcript-block-time" datetime={block.at} title={full_time(block.at)}><%= full_time(block.at) %></time>
                        </summary>
                        <%= if block.text == "" do %>
                          <p class="transcript-empty muted"><%= empty_collapsible_message(block.kind) %></p>
                        <% else %>
                          <pre class="code-panel transcript-code"><code><%= block.text %></code></pre>
                        <% end %>
                      </details>
                    <% true -> %>
                      <div class="transcript-block-head">
                        <span class={transcript_chip_class(block.kind)}><%= transcript_kind_label(block.kind) %></span>
                        <span :if={block[:subagent]} class="transcript-subagent-badge">↳ Subagent<%= subagent_suffix(block[:thread_id]) %></span>
                        <time :if={block.at} class="transcript-block-time" datetime={block.at} title={full_time(block.at)}><%= full_time(block.at) %></time>
                      </div>
                      <pre class="code-panel transcript-code transcript-command"><code><%= block.text %></code></pre>
                  <% end %>
                </article>
              </div>
            <% end %>
          </section>
        <% end %>
      <% else %>
        <header class="hero-card">
          <div class="hero-grid">
            <div>
              <p class="eyebrow">
                Symphony Observability
              </p>
              <h1 class="hero-title">
                Operations Dashboard
              </h1>
              <p class="hero-copy">
                Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
              </p>
            </div>

            <div class="status-stack">
              <span class="status-badge status-badge-live">
                <span class="status-badge-dot"></span>
                Live
              </span>
              <span class="status-badge status-badge-offline">
                <span class="status-badge-dot"></span>
                Offline
              </span>
            </div>
          </div>
        </header>

        <%= if @dashboard_payload[:error] do %>
          <section class="error-card">
            <h2 class="error-title">
              Snapshot unavailable
            </h2>
            <p class="error-copy">
              <strong><%= @dashboard_payload.error.code %>:</strong> <%= @dashboard_payload.error.message %>
            </p>
          </section>
        <% else %>
          <section class="metric-grid">
            <article class="metric-card">
              <p class="metric-label">Running</p>
              <p class="metric-value numeric"><%= @dashboard_payload.counts.running %></p>
              <p class="metric-detail">Active issue sessions in the current runtime.</p>
            </article>

            <article class="metric-card">
              <p class="metric-label">Retrying</p>
              <p class="metric-value numeric"><%= @dashboard_payload.counts.retrying %></p>
              <p class="metric-detail">Issues waiting for the next retry window.</p>
            </article>

            <article class="metric-card">
              <p class="metric-label">Total tokens</p>
              <p class="metric-value numeric"><%= format_int(@dashboard_payload.codex_totals.total_tokens) %></p>
              <p class="metric-detail numeric">
                In <%= format_int(@dashboard_payload.codex_totals.input_tokens) %> / Out <%= format_int(@dashboard_payload.codex_totals.output_tokens) %>
              </p>
            </article>

            <article class="metric-card">
              <p class="metric-label">Runtime</p>
              <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@dashboard_payload, @now)) %></p>
              <p class="metric-detail">Total agent runtime across completed and active sessions.</p>
            </article>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Rate limits</h2>
                <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
              </div>
            </div>

            <%= if rate_limits_present?(@dashboard_payload.rate_limits) do %>
              <div class="rate-limit-grid">
                <div class="rate-limit-tile">
                  <span class="rate-limit-label">Window</span>
                  <span class="rate-limit-value"><%= rate_limit_window(@dashboard_payload.rate_limits) %></span>
                </div>
                <div class="rate-limit-tile">
                  <span class="rate-limit-label">Primary</span>
                  <span class="rate-limit-value"><%= rate_limit_bucket(@dashboard_payload.rate_limits, "primary") %></span>
                </div>
                <div class="rate-limit-tile">
                  <span class="rate-limit-label">Secondary</span>
                  <span class="rate-limit-value"><%= rate_limit_bucket(@dashboard_payload.rate_limits, "secondary") %></span>
                </div>
                <div class="rate-limit-tile">
                  <span class="rate-limit-label">Credits</span>
                  <span class="rate-limit-value"><%= rate_limit_credits(@dashboard_payload.rate_limits) %></span>
                </div>
              </div>
            <% else %>
              <p class="empty-state">No rate-limit snapshot available yet.</p>
            <% end %>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Running sessions</h2>
                <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
              </div>
            </div>

            <%= if @dashboard_payload.running == [] do %>
              <p class="empty-state">No active sessions.</p>
            <% else %>
              <div class="table-wrap">
                <table class="data-table data-table-running">
                  <colgroup>
                    <col style="width: 14rem;" />
                    <col style="width: 8rem;" />
                    <col style="width: 7.5rem;" />
                    <col style="width: 10rem;" />
                    <col style="width: 8.5rem;" />
                    <col />
                    <col style="width: 10rem;" />
                  </colgroup>
                  <thead>
                    <tr>
                      <th>Issue</th>
                      <th>State</th>
                      <th>Session</th>
                      <th>Agent</th>
                      <th>Runtime / turns</th>
                      <th>Last activity</th>
                      <th>Tokens</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={entry <- @dashboard_payload.running}>
                      <td>
                        <div class="issue-stack">
                          <.link class="issue-id" navigate={issue_path(entry.issue_identifier)}>
                            <%= entry.issue_identifier %>
                          </.link>
                          <span :if={entry.title} class="issue-title"><%= entry.title %></span>
                          <div class="issue-links">
                            <.link class="issue-link" navigate={issue_path(entry.issue_identifier)}>
                              Issue details
                            </.link>
                            <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                          </div>
                        </div>
                      </td>
                      <td>
                        <span class={state_badge_class(entry.state)}>
                          <%= entry.state %>
                        </span>
                      </td>
                      <td>
                        <div class="session-stack">
                          <%= if entry.session_id do %>
                            <button
                              type="button"
                              class="subtle-button"
                              data-label="Copy ID"
                              data-copy={entry.session_id}
                              onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                            >
                              Copy ID
                            </button>
                          <% else %>
                            <span class="muted">n/a</span>
                          <% end %>
                        </div>
                      </td>
                      <td>
                        <div class="agent-stack">
                          <span class="agent-backend"><%= agent_backend_label(entry.agent.backend) %></span>
                          <span :if={entry.agent.model} class="muted agent-model mono" title={entry.agent.model}>
                            <%= entry.agent.model %>
                          </span>
                          <span :if={entry.agent.reasoning_effort} class="muted agent-model mono">
                            effort <%= entry.agent.reasoning_effort %><%= if entry.agent.profile, do: " · #{entry.agent.profile}" %>
                          </span>
                        </div>
                      </td>
                      <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                      <td>
                        <div class="detail-stack">
                          <span
                            class="event-text"
                            title={entry.last_message || to_string(entry.last_event || "n/a")}
                          ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                          <span class="muted event-meta">
                            <%= entry.last_event || "n/a" %>
                            <%= if entry.last_event_at do %>
                              · <time class="event-time-stamp" datetime={entry.last_event_at} title={full_time(entry.last_event_at)}><%= full_time(entry.last_event_at) %></time>
                            <% end %>
                          </span>
                        </div>
                      </td>
                      <td>
                        <div class="token-stack numeric">
                          <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                          <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                          <% ctx_pct = context_fill_percent(entry.context) %>
                          <span class="muted" title={context_fill_title(entry.context)}>Ctx <%= context_fill_label(entry.context) %></span>
                          <div :if={ctx_pct} class={"meter meter-sm #{context_meter_level(ctx_pct)}"}>
                            <div class="meter-fill" style={"width: #{ctx_pct}%"}></div>
                          </div>
                        </div>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Retry queue</h2>
                <p class="section-copy">Issues waiting for the next retry window.</p>
              </div>
            </div>

            <%= if @dashboard_payload.retrying == [] do %>
              <p class="empty-state">No issues are currently backing off.</p>
            <% else %>
              <div class="table-wrap">
                <table class="data-table" style="min-width: 680px;">
                  <thead>
                    <tr>
                      <th>Issue</th>
                      <th>Attempt</th>
                      <th>Due at</th>
                      <th>Error</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={entry <- @dashboard_payload.retrying}>
                      <td>
                        <div class="issue-stack">
                          <.link class="issue-id" navigate={issue_path(entry.issue_identifier)}>
                            <%= entry.issue_identifier %>
                          </.link>
                          <span :if={entry.title} class="issue-title"><%= entry.title %></span>
                          <div class="issue-links">
                            <.link class="issue-link" navigate={issue_path(entry.issue_identifier)}>
                              Issue details
                            </.link>
                            <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                          </div>
                        </div>
                      </td>
                      <td><%= entry.attempt %></td>
                      <td>
                        <%= if entry.due_at do %>
                          <time class="event-time-stamp" datetime={entry.due_at} title={full_time(entry.due_at)}><%= full_time(entry.due_at) %></time>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </td>
                      <td><%= entry.error || "n/a" %></td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          </section>
        <% end %>
      <% end %>
    </section>
    """
  end

  defp load_dashboard_page(socket) do
    socket
    |> assign(:dashboard_payload, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
    |> assign(:issue_payload, nil)
    |> assign(:issue_identifier, nil)
    |> assign(:transcript_cache, %{})
  end

  defp load_issue_page(socket, issue_identifier) when is_binary(issue_identifier) do
    transcript_cache = socket.assigns[:transcript_cache] || %{}

    {issue_payload, transcript_cache} =
      case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms(), transcript_cache) do
        {:ok, payload, new_cache} ->
          {payload, new_cache}

        {:error, :issue_not_found} ->
          {%{error: %{code: "issue_not_found", message: "Issue not found"}}, %{}}
      end

    socket
    |> assign(:issue_payload, issue_payload)
    |> assign(:issue_identifier, issue_identifier)
    |> assign(:transcript_cache, transcript_cache)
  end

  defp reload_current_page(%{assigns: %{live_action: :issue, issue_identifier: issue_identifier}} = socket)
       when is_binary(issue_identifier) do
    load_issue_page(socket, issue_identifier)
  end

  defp reload_current_page(socket), do: load_dashboard_page(socket)

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp issue_runtime(%{running: %{started_at: started_at}}, now) do
    runtime_seconds_from_started_at(started_at, now)
    |> format_runtime_seconds()
  end

  defp issue_runtime(_issue_payload, _now), do: "n/a"

  defp issue_started_at(%{running: %{started_at: started_at}}), do: started_at
  defp issue_started_at(_issue_payload), do: nil

  defp issue_session_id(payload) do
    payload.transcript.session_id || (payload.running && payload.running.session_id) || "n/a"
  end

  defp issue_total_tokens(%{running: %{tokens: %{total_tokens: total_tokens}}}), do: format_int(total_tokens)
  defp issue_total_tokens(_issue_payload), do: "n/a"

  defp issue_token_detail(%{running: %{tokens: %{input_tokens: input_tokens, output_tokens: output_tokens}}}) do
    "In #{format_int(input_tokens)} / Out #{format_int(output_tokens)}"
  end

  defp issue_token_detail(_issue_payload), do: "n/a"

  defp issue_context_fill(%{running: %{context: context}}), do: context_fill_label(context)
  defp issue_context_fill(_issue_payload), do: "n/a"

  defp issue_context_detail(%{running: %{context: context}}), do: context_fill_title(context)
  defp issue_context_detail(_issue_payload), do: "n/a"

  defp issue_context_percent(%{running: %{context: context}}), do: context_fill_percent(context)
  defp issue_context_percent(_issue_payload), do: nil

  # Integer percentage (0–100) of the model context window currently filled,
  # or nil when the fill ratio is unknown. Drives the meter bars.
  defp context_fill_percent(%{fill_ratio: ratio}) when is_float(ratio), do: round(ratio * 100)
  defp context_fill_percent(_context), do: nil

  defp context_meter_level(pct) when is_integer(pct) and pct >= 85, do: "meter-danger"
  defp context_meter_level(pct) when is_integer(pct) and pct >= 65, do: "meter-warn"
  defp context_meter_level(_pct), do: ""

  # Main-agent context window occupancy (current prompt tokens / model window).
  defp context_fill_label(%{fill_ratio: ratio}) when is_float(ratio) do
    "#{Float.round(ratio * 100, 1)}%"
  end

  defp context_fill_label(_context), do: "n/a"

  defp context_fill_title(%{tokens: tokens, window: window})
       when is_integer(tokens) and is_integer(window) and window > 0 do
    "#{format_int(tokens)} / #{format_int(window)} tokens"
  end

  defp context_fill_title(_context), do: "n/a"

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  # Humanize the actual backend the run resolved to. `nil` until the run reports
  # it (e.g. an issue still spinning up, or one only in the retry queue).
  defp agent_backend_label("codex"), do: "Codex"
  defp agent_backend_label("acp"), do: "ACP / OpenCode"
  defp agent_backend_label("claude_code"), do: "Claude Code"
  defp agent_backend_label(name) when is_binary(name) and name != "", do: name
  defp agent_backend_label(_name), do: "n/a"

  defp transcript_blocks(%{blocks: blocks}) when is_list(blocks), do: blocks
  defp transcript_blocks(_transcript), do: []

  # Fold command/tool output into the activity that produced it. Native Codex
  # streams can interleave a long-running command's output with agent messages,
  # so adjacency is not a reliable association; item/tool ids are. The legacy
  # adjacent fallback keeps older logs without ids readable.
  defp display_transcript_blocks(blocks) when is_list(blocks) do
    output_by_key =
      Enum.reduce(blocks, %{}, fn
        %{kind: "output"} = output, acc ->
          case transcript_activity_key(output) do
            nil -> acc
            key -> Map.put(acc, key, output)
          end

        _block, acc ->
          acc
      end)

    activity_keys =
      blocks
      |> Enum.filter(&(Map.get(&1, :kind) in ["command", "tool"]))
      |> Enum.map(&transcript_activity_key/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    fold_activity_blocks(blocks, output_by_key, activity_keys, [])
  end

  defp fold_activity_blocks([], _output_by_key, _activity_keys, acc), do: Enum.reverse(acc)

  defp fold_activity_blocks(
         [%{kind: "command"} = command | rest],
         output_by_key,
         activity_keys,
         acc
       ) do
    case transcript_activity_key(command) do
      nil ->
        {output_text, remaining} = collect_command_output(rest, [])
        folded = command |> Map.put(:title, command.text) |> Map.put(:text, output_text)
        fold_activity_blocks(remaining, output_by_key, activity_keys, [folded | acc])

      key ->
        output_text = output_by_key |> Map.get(key, %{}) |> Map.get(:text, "")
        folded = command |> Map.put(:title, command.text) |> Map.put(:text, output_text)
        fold_activity_blocks(rest, output_by_key, activity_keys, [folded | acc])
    end
  end

  defp fold_activity_blocks(
         [%{kind: "tool"} = tool | rest],
         output_by_key,
         activity_keys,
         acc
       ) do
    output = Map.get(output_by_key, transcript_activity_key(tool))
    fold_activity_blocks(rest, output_by_key, activity_keys, [fold_tool_output(tool, output) | acc])
  end

  defp fold_activity_blocks(
         [%{kind: "output"} = output | rest],
         output_by_key,
         activity_keys,
         acc
       ) do
    if MapSet.member?(activity_keys, transcript_activity_key(output)) do
      fold_activity_blocks(rest, output_by_key, activity_keys, acc)
    else
      fold_activity_blocks(rest, output_by_key, activity_keys, [output | acc])
    end
  end

  defp fold_activity_blocks([block | rest], output_by_key, activity_keys, acc),
    do: fold_activity_blocks(rest, output_by_key, activity_keys, [block | acc])

  defp fold_tool_output(tool, nil), do: tool

  defp fold_tool_output(tool, %{text: output_text}) do
    text =
      [
        if(tool.text == "", do: nil, else: "Arguments:\n#{tool.text}"),
        if(output_text == "", do: nil, else: "Output:\n#{output_text}")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    Map.put(tool, :text, text)
  end

  defp transcript_activity_key(%{item_id: id} = block) when is_binary(id),
    do: {:item, Map.get(block, :thread_id), id}

  defp transcript_activity_key(%{tool_call_id: id} = block) when is_binary(id),
    do: {:tool, Map.get(block, :thread_id), id}

  defp transcript_activity_key(_block), do: nil

  defp collect_command_output([%{kind: "output", text: text} | rest], acc),
    do: collect_command_output(rest, [text | acc])

  defp collect_command_output(blocks, acc), do: {acc |> Enum.reverse() |> Enum.join("\n"), blocks}

  defp transcript_kind_label("agent"), do: "Agent"
  defp transcript_kind_label("command"), do: "Command"
  defp transcript_kind_label("output"), do: "Output"
  defp transcript_kind_label("tool"), do: "Tool"
  defp transcript_kind_label("reasoning"), do: "Reasoning"
  defp transcript_kind_label("user"), do: "User"
  defp transcript_kind_label("compaction"), do: "Compaction"
  defp transcript_kind_label("plan"), do: "Plan"
  defp transcript_kind_label(_kind), do: "Event"

  # ACP `plan` updates render as markdown checklists, like agent text.
  defp markdown_transcript_kind?(kind), do: kind in ["agent", "user", "plan"]

  defp collapsible_transcript_kind?(kind), do: kind in ["command", "output", "tool", "reasoning"]

  defp empty_collapsible_message("tool"), do: "No arguments."
  defp empty_collapsible_message(_kind), do: "No output."

  defp transcript_block_class(kind, subagent?) do
    base = "transcript-block transcript-block-#{transcript_kind_slug(kind)}"
    if subagent?, do: base <> " transcript-block-subagent", else: base
  end

  defp transcript_chip_class(kind), do: "transcript-chip transcript-chip-#{transcript_kind_slug(kind)}"

  defp subagent_suffix(thread_id) when is_binary(thread_id) and byte_size(thread_id) >= 4,
    do: " · " <> binary_part(thread_id, byte_size(thread_id) - 4, 4)

  defp subagent_suffix(_thread_id), do: ""

  defp transcript_kind_slug(kind) when kind in ["agent", "command", "output", "tool", "reasoning", "user", "compaction", "plan"], do: kind
  defp transcript_kind_slug(_kind), do: "event"

  defp transcript_preview(block) when is_map(block) do
    case Map.get(block, :title) do
      title when is_binary(title) and title != "" -> title
      _ -> block |> Map.get(:text, "") |> first_line_preview()
    end
  end

  defp first_line_preview(text) when is_binary(text) do
    text
    |> String.split("\n", trim: true)
    |> List.first()
    |> case do
      nil -> "(empty)"
      line -> String.slice(line, 0, 100)
    end
  end

  defp first_line_preview(_text), do: "(empty)"

  defp markdown_to_html(text) when is_binary(text) do
    text
    |> normalize_markdown_text()
    |> String.split("\n", trim: false)
    |> markdown_blocks_to_html([])
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp markdown_to_html(_text), do: ""

  defp markdown_blocks_to_html([], acc), do: acc

  defp markdown_blocks_to_html([line | rest], acc) do
    cond do
      String.trim(line) == "" ->
        markdown_blocks_to_html(rest, acc)

      fence_line?(line) ->
        {language, code_lines, remaining} = collect_fenced_code(rest, fence_language(line), [])
        markdown_blocks_to_html(remaining, [render_fenced_code(language, code_lines) | acc])

      heading_line?(line) ->
        markdown_blocks_to_html(rest, [render_heading(line) | acc])

      unordered_list_line?(line) ->
        {items, remaining} = collect_list(rest, [list_item_text(line, :unordered)], :unordered)
        markdown_blocks_to_html(remaining, [render_list(:unordered, items) | acc])

      ordered_list_line?(line) ->
        {items, remaining} = collect_list(rest, [list_item_text(line, :ordered)], :ordered)
        markdown_blocks_to_html(remaining, [render_list(:ordered, items) | acc])

      blockquote_line?(line) ->
        {lines, remaining} = collect_blockquote(rest, [blockquote_text(line)])
        markdown_blocks_to_html(remaining, [render_blockquote(lines) | acc])

      true ->
        {lines, remaining} = collect_paragraph(rest, [line])
        markdown_blocks_to_html(remaining, [render_paragraph(lines) | acc])
    end
  end

  defp collect_fenced_code([], language, acc), do: {language, Enum.reverse(acc), []}

  defp collect_fenced_code([line | rest], language, acc) do
    if fence_line?(line) do
      {language, Enum.reverse(acc), rest}
    else
      collect_fenced_code(rest, language, [line | acc])
    end
  end

  defp collect_list([], acc, _kind), do: {Enum.reverse(acc), []}

  defp collect_list([line | rest], acc, :unordered) do
    cond do
      unordered_list_line?(line) -> collect_list(rest, [list_item_text(line, :unordered) | acc], :unordered)
      String.trim(line) == "" -> {Enum.reverse(acc), rest}
      true -> {Enum.reverse(acc), [line | rest]}
    end
  end

  defp collect_list([line | rest], acc, :ordered) do
    cond do
      ordered_list_line?(line) -> collect_list(rest, [list_item_text(line, :ordered) | acc], :ordered)
      String.trim(line) == "" -> {Enum.reverse(acc), rest}
      true -> {Enum.reverse(acc), [line | rest]}
    end
  end

  defp collect_blockquote([], acc), do: {Enum.reverse(acc), []}

  defp collect_blockquote([line | rest], acc) do
    cond do
      blockquote_line?(line) -> collect_blockquote(rest, [blockquote_text(line) | acc])
      String.trim(line) == "" -> {Enum.reverse(acc), rest}
      true -> {Enum.reverse(acc), [line | rest]}
    end
  end

  defp collect_paragraph([], acc), do: {Enum.reverse(acc), []}

  defp collect_paragraph([line | rest], acc) do
    cond do
      String.trim(line) == "" ->
        {Enum.reverse(acc), rest}

      markdown_block_start?(line) ->
        {Enum.reverse(acc), [line | rest]}

      true ->
        collect_paragraph(rest, [line | acc])
    end
  end

  defp markdown_block_start?(line) do
    fence_line?(line) or heading_line?(line) or unordered_list_line?(line) or ordered_list_line?(line) or
      blockquote_line?(line)
  end

  defp render_fenced_code(language, lines) do
    class =
      case language do
        "" -> ""
        language -> " class=\"language-#{escape_attr(language)}\""
      end

    "<pre><code#{class}>#{escape_html(Enum.join(lines, "\n"))}</code></pre>"
  end

  defp render_heading(line) do
    [markers, text] = Regex.run(~r/^\s{0,3}([#]{1,6})\s+(.+?)\s*#*\s*$/, line, capture: :all_but_first)
    level = markers |> String.length() |> min(4)
    "<h#{level}>#{inline_markdown_to_html(text)}</h#{level}>"
  end

  defp render_list(:unordered, items) do
    "<ul>#{Enum.map_join(items, "", &"<li>#{inline_markdown_to_html(&1)}</li>")}</ul>"
  end

  defp render_list(:ordered, items) do
    "<ol>#{Enum.map_join(items, "", &"<li>#{inline_markdown_to_html(&1)}</li>")}</ol>"
  end

  defp render_blockquote(lines) do
    "<blockquote>#{render_paragraph(lines)}</blockquote>"
  end

  defp render_paragraph(lines) do
    "<p>#{lines |> Enum.map_join("\n", &String.trim/1) |> inline_markdown_to_html()}</p>"
  end

  defp inline_markdown_to_html(text) do
    text
    |> String.split("`")
    |> Enum.with_index()
    |> Enum.map_join(fn {segment, index} ->
      if rem(index, 2) == 1 do
        "<code>#{escape_html(segment)}</code>"
      else
        segment
        |> escape_html()
        |> render_inline_links()
        |> render_inline_strong()
        |> String.replace("\n", "<br>")
      end
    end)
  end

  defp render_inline_links(text) do
    Regex.replace(~r/\[([^\]\n]+)\]\(([^)\s]+)\)/, text, fn _match, label, href ->
      if safe_href?(href) do
        "<a href=\"#{escape_attr(href)}\" rel=\"noreferrer\">#{label}</a>"
      else
        label
      end
    end)
  end

  defp render_inline_strong(text) do
    Regex.replace(~r/\*\*([^*\n]+)\*\*/, text, "<strong>\\1</strong>")
  end

  defp fence_line?(line), do: String.match?(line, ~r/^\s*```/)
  defp fence_language(line), do: line |> String.replace(~r/^\s*```\s*/, "") |> String.trim() |> sanitize_language()
  defp heading_line?(line), do: String.match?(line, ~r/^\s{0,3}[#]{1,6}\s+\S/)
  defp unordered_list_line?(line), do: String.match?(line, ~r/^\s{0,3}[-*+]\s+\S/)
  defp ordered_list_line?(line), do: String.match?(line, ~r/^\s{0,3}\d+[.)]\s+\S/)
  defp blockquote_line?(line), do: String.match?(line, ~r/^\s{0,3}>\s?/)

  defp list_item_text(line, :unordered), do: String.replace(line, ~r/^\s{0,3}[-*+]\s+/, "")
  defp list_item_text(line, :ordered), do: String.replace(line, ~r/^\s{0,3}\d+[.)]\s+/, "")
  defp blockquote_text(line), do: String.replace(line, ~r/^\s{0,3}>\s?/, "")

  defp safe_href?(href) do
    String.starts_with?(href, ["http://", "https://", "mailto:", "/", "#"])
  end

  defp sanitize_language(language) do
    language
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_+-]/, "")
  end

  defp normalize_markdown_text(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.trim()
  end

  defp escape_html(value) when is_binary(value) do
    value
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp escape_attr(value) when is_binary(value), do: escape_html(value)

  defp issue_path(issue_identifier) when is_binary(issue_identifier), do: "/issues/#{issue_identifier}"

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp full_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
      _ -> iso
    end
  end

  defp full_time(_iso), do: "n/a"

  defp rate_limits_present?(rate_limits) when is_map(rate_limits), do: map_size(rate_limits) > 0
  defp rate_limits_present?(_rate_limits), do: false

  defp rate_limit_window(rate_limits) do
    case rl_value(rate_limits, ["limit_id", "limit_name"]) do
      value when is_binary(value) and value != "" -> value
      _ -> "default"
    end
  end

  defp rate_limit_bucket(rate_limits, key) do
    case rl_value(rate_limits, [key]) do
      bucket when is_map(bucket) -> format_rate_limit_bucket(bucket)
      _ -> "n/a"
    end
  end

  defp format_rate_limit_bucket(bucket) do
    remaining = rl_value(bucket, ["remaining"])
    limit = rl_value(bucket, ["limit"])

    reset =
      rl_value(bucket, ["reset_in_seconds", "resetInSeconds", "reset_at", "resetAt", "resets_at", "resetsAt"])

    base =
      cond do
        is_number(remaining) and is_number(limit) -> "#{format_int(round(remaining))} / #{format_int(round(limit))} left"
        is_number(remaining) -> "#{format_int(round(remaining))} left"
        is_number(limit) -> "limit #{format_int(round(limit))}"
        true -> "n/a"
      end

    if is_nil(reset), do: base, else: "#{base} · resets #{format_reset_value(reset)}"
  end

  defp format_reset_value(value) when is_integer(value), do: "#{value}s"
  defp format_reset_value(value) when is_binary(value), do: value
  defp format_reset_value(value), do: to_string(value)

  defp rate_limit_credits(rate_limits) do
    case rl_value(rate_limits, ["credits"]) do
      credits when is_map(credits) ->
        balance = rl_value(credits, ["balance"])

        cond do
          rl_value(credits, ["unlimited"]) == true -> "Unlimited"
          is_number(balance) -> format_int(round(balance))
          rl_value(credits, ["has_credits"]) == true -> "Available"
          true -> "None"
        end

      _ ->
        "n/a"
    end
  end

  defp rl_value(map, keys) when is_map(map) and is_list(keys), do: Enum.find_value(keys, &rl_get(map, &1))
  defp rl_value(_map, _keys), do: nil

  defp rl_get(map, key) when is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> atom_key_get(map, key)
    end
  end

  defp atom_key_get(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end
end
