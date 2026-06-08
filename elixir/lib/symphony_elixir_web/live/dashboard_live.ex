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
                <h1 class="hero-title">
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
                <h1 class="hero-title">
                  <%= @issue_payload.issue_identifier %>
                </h1>
                <p class="hero-copy">
                  Live issue detail view with the latest reconstructed Codex transcript for this workspace.
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
              <p class="metric-value">
                <%= @issue_payload.transcript.session_id || @issue_payload.running && @issue_payload.running.session_id || "n/a" %>
              </p>
              <p class="metric-detail">
                Turns: <%= @issue_payload.running && @issue_payload.running.turn_count || 0 %>
              </p>
            </article>

            <article class="metric-card">
              <p class="metric-label">Runtime</p>
              <p class="metric-value numeric">
                <%= issue_runtime(@issue_payload, @now) %>
              </p>
              <p class="metric-detail">
                Started <%= issue_started_at(@issue_payload) || "n/a" %>
              </p>
            </article>

            <article class="metric-card">
              <p class="metric-label">Total tokens</p>
              <p class="metric-value numeric"><%= issue_total_tokens(@issue_payload) %></p>
              <p class="metric-detail numeric">
                <%= issue_token_detail(@issue_payload) %>
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

            <div class="detail-stack">
              <div>
                <span class="muted event-meta">Workspace</span>
                <pre class="code-panel"><%= @issue_payload.workspace.path || "n/a" %></pre>
              </div>
              <div>
                <span class="muted event-meta">Worker host</span>
                <pre class="code-panel"><%= @issue_payload.workspace.host || "local" %></pre>
              </div>
              <div :if={@issue_payload.last_error}>
                <span class="muted event-meta">Latest retry error</span>
                <pre class="code-panel"><%= @issue_payload.last_error %></pre>
              </div>
            </div>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Codex Transcript</h2>
                <p class="section-copy">
                  Reconstructed assistant text, commands, and command output from the latest session transcript.
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
                <article :for={block <- transcript_blocks(@issue_payload.transcript)}>
                  <div class="muted event-meta">
                    <strong><%= transcript_kind_label(block.kind) %></strong>
                    <%= if block.at do %>
                      · <span class="mono numeric"><%= block.at %></span>
                    <% end %>
                  </div>
                  <%= if markdown_transcript_kind?(block.kind) do %>
                    <div class="transcript-markdown"><%= Phoenix.HTML.raw(markdown_to_html(block.text)) %></div>
                  <% else %>
                    <pre class="code-panel transcript-code"><code><%= block.text %></code></pre>
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
              <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
            </article>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Rate limits</h2>
                <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
              </div>
            </div>

            <pre class="code-panel"><%= pretty_value(@dashboard_payload.rate_limits) %></pre>
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
                    <col style="width: 8.5rem;" />
                    <col />
                    <col style="width: 10rem;" />
                  </colgroup>
                  <thead>
                    <tr>
                      <th>Issue</th>
                      <th>State</th>
                      <th>Session</th>
                      <th>Runtime / turns</th>
                      <th>Codex update</th>
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
                          <.link class="issue-link" navigate={issue_path(entry.issue_identifier)}>
                            Issue details
                          </.link>
                          <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
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
                              · <span class="mono numeric"><%= entry.last_event_at %></span>
                            <% end %>
                          </span>
                        </div>
                      </td>
                      <td>
                        <div class="token-stack numeric">
                          <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                          <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
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
                          <.link class="issue-link" navigate={issue_path(entry.issue_identifier)}>
                            Issue details
                          </.link>
                          <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                        </div>
                      </td>
                      <td><%= entry.attempt %></td>
                      <td class="mono"><%= entry.due_at || "n/a" %></td>
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
  end

  defp load_issue_page(socket, issue_identifier) when is_binary(issue_identifier) do
    issue_payload =
      case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
        {:ok, payload} ->
          payload

        {:error, :issue_not_found} ->
          %{error: %{code: "issue_not_found", message: "Issue not found"}}
      end

    socket
    |> assign(:issue_payload, issue_payload)
    |> assign(:issue_identifier, issue_identifier)
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

  defp issue_total_tokens(%{running: %{tokens: %{total_tokens: total_tokens}}}), do: format_int(total_tokens)
  defp issue_total_tokens(_issue_payload), do: "n/a"

  defp issue_token_detail(%{running: %{tokens: %{input_tokens: input_tokens, output_tokens: output_tokens}}}) do
    "In #{format_int(input_tokens)} / Out #{format_int(output_tokens)}"
  end

  defp issue_token_detail(_issue_payload), do: "n/a"

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

  defp transcript_blocks(%{blocks: blocks}) when is_list(blocks), do: blocks
  defp transcript_blocks(_transcript), do: []

  defp transcript_kind_label("agent"), do: "Agent"
  defp transcript_kind_label("command"), do: "Command"
  defp transcript_kind_label("output"), do: "Output"
  defp transcript_kind_label(_kind), do: "Event"

  defp markdown_transcript_kind?(kind), do: kind in ["agent", "user"]

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

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
