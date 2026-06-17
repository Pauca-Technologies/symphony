defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns = assign(assigns, :csrf_token, Plug.CSRFProtection.get_csrf_token())

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Symphony Observability</title>
        <script defer src="/vendor/phoenix_html/phoenix_html.js"></script>
        <script defer src="/vendor/phoenix/phoenix.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.js"></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            // Render every <time datetime="…"> as an absolute, human-readable
            // timestamp in the browser's timezone (date shown only when it is
            // not today). Idempotent so it can re-run on every LiveView patch.
            function formatTime(el) {
              var iso = el.getAttribute("datetime");
              if (!iso) return;
              var d = new Date(iso);
              if (isNaN(d.getTime())) return;
              var sameDay = d.toDateString() === new Date().toDateString();
              var time = d.toLocaleTimeString(undefined, {hour: "2-digit", minute: "2-digit", second: "2-digit"});
              var str = sameDay
                ? time
                : d.toLocaleDateString(undefined, {month: "short", day: "numeric"}) + ", " + time;
              if (el.textContent !== str) el.textContent = str;
              var title = d.toLocaleString();
              if (el.getAttribute("title") !== title) el.setAttribute("title", title);
            }

            function formatTimes() {
              document.querySelectorAll("time[datetime]").forEach(formatTime);
            }

            formatTimes();
            // LiveView re-renders rewrite the server-side fallback text; reformat
            // whenever the DOM changes. `characterData` is essential: LiveView
            // patches an unchanged-structure node by rewriting its text node in
            // place (a characterData mutation), which a childList-only observer
            // misses — so the timestamp would revert to UTC and stay there.
            // Guarded writes above avoid mutation loops.
            new MutationObserver(formatTimes).observe(document.body, {
              childList: true,
              subtree: true,
              characterData: true
            });

            if (!window.Phoenix || !window.LiveView) return;

            var Hooks = {
              // <details> open/closed state lives in the DOM, so LiveView patches
              // strip it on every re-render. Capture the user's intent on toggle
              // and re-apply it after each patch so the panel stays as they left it.
              Collapsible: {
                mounted: function () {
                  var self = this;
                  this.el.addEventListener("toggle", function () {
                    self.open = self.el.open;
                  });
                },
                updated: function () {
                  if (this.open != null && this.el.open !== this.open) {
                    this.el.open = this.open;
                  }
                }
              }
            };

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken},
              hooks: Hooks
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="stylesheet" href="/dashboard.css" />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end
end
