defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
    live("/history", HistoryLive, :index)
    live("/issues/:issue_identifier", DashboardLive, :issue)
  end

  scope "/", SymphonyElixirWeb do
    get("/api/v1/state", ObservabilityApiController, :state)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/drain", ObservabilityApiController, :drain)
    match(:*, "/api/v1/drain", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/resume", ObservabilityApiController, :resume)
    match(:*, "/api/v1/resume", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/shutdown-policy/preserve", ObservabilityApiController, :preserve_workers)
    match(:*, "/api/v1/shutdown-policy/preserve", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/shutdown-policy/terminate", ObservabilityApiController, :terminate_workers)
    match(:*, "/api/v1/shutdown-policy/terminate", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/waits/:issue_identifier/resume", ObservabilityApiController, :resume_wait)
    match(:*, "/api/v1/waits/:issue_identifier/resume", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/waits/:issue_identifier/cancel", ObservabilityApiController, :cancel_wait)
    match(:*, "/api/v1/waits/:issue_identifier/cancel", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
