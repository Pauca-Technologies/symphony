defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec drain(Conn.t(), map()) :: Conn.t()
  def drain(conn, _params), do: set_drain_mode(conn, true)

  @spec resume(Conn.t(), map()) :: Conn.t()
  def resume(conn, _params), do: set_drain_mode(conn, false)

  @spec preserve_workers(Conn.t(), map()) :: Conn.t()
  def preserve_workers(conn, _params), do: set_shutdown_policy(conn, :preserve_workers)

  @spec terminate_workers(Conn.t(), map()) :: Conn.t()
  def terminate_workers(conn, _params), do: set_shutdown_policy(conn, :terminate_workers)

  @spec resume_wait(Conn.t(), map()) :: Conn.t()
  def resume_wait(conn, %{"issue_identifier" => identifier}), do: set_wait_mode(conn, :resume, identifier)

  @spec cancel_wait(Conn.t(), map()) :: Conn.t()
  def cancel_wait(conn, %{"issue_identifier" => identifier}), do: set_wait_mode(conn, :cancel, identifier)

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp set_drain_mode(conn, enabled) do
    case Presenter.drain_payload(orchestrator(), enabled) do
      {:ok, mode} ->
        json(conn, %{mode: mode})

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")

      {:error, reason} ->
        error_response(conn, 500, "drain_state_write_failed", inspect(reason))
    end
  end

  defp set_shutdown_policy(conn, policy) do
    case Presenter.shutdown_policy_payload(orchestrator(), policy) do
      {:ok, mode} ->
        json(conn, %{mode: mode})

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")

      {:error, reason} ->
        error_response(conn, 500, "shutdown_policy_write_failed", inspect(reason))
    end
  end

  defp set_wait_mode(conn, action, identifier) do
    case Presenter.wait_control_payload(action, identifier, orchestrator()) do
      {:ok, payload} ->
        json(conn, %{wait: payload})

      {:error, :not_found} ->
        error_response(conn, 404, "wait_not_found", "Parked wait not found")

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
