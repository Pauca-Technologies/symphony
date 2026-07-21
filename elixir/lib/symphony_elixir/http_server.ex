defmodule SymphonyElixir.HttpServer do
  @moduledoc """
  Compatibility facade that starts the Phoenix observability endpoint when enabled.
  """

  require Logger

  alias SymphonyElixir.{Config, Orchestrator}
  alias SymphonyElixirWeb.Endpoint

  @secret_key_bytes 48

  @hostname_pattern ~r/^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$/

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    case Keyword.get(opts, :port, Config.server_port()) do
      port when is_integer(port) and port >= 0 ->
        host = Keyword.get(opts, :host, Config.settings!().server.host)
        orchestrator = Keyword.get(opts, :orchestrator, Orchestrator)
        snapshot_timeout_ms = Keyword.get(opts, :snapshot_timeout_ms, 15_000)

        with {:ok, ip, url_host} <- resolve_host(host) do
          endpoint_opts = [
            server: true,
            http: [ip: ip, port: port],
            url: [host: url_host],
            orchestrator: orchestrator,
            snapshot_timeout_ms: snapshot_timeout_ms,
            secret_key_base: secret_key_base()
          ]

          endpoint_config =
            :symphony_elixir
            |> Application.get_env(Endpoint, [])
            |> Keyword.merge(endpoint_opts)

          Application.put_env(:symphony_elixir, Endpoint, endpoint_config)

          children = [Endpoint | loopback_listener(ip, port)]
          Supervisor.start_link(children, strategy: :one_for_one)
        end

      _ ->
        :ignore
    end
  end

  # When the dashboard is bound to a host that does not already accept loopback
  # traffic (e.g. a LAN or Tailscale host such as `raul-vps.taild2bbf9.ts.net`),
  # the primary listener only accepts connections destined to that IP, so
  # `localhost:<port>` would be refused. Start an extra Bandit listener on the
  # loopback interface — serving the same Phoenix endpoint as a plug — so the
  # dashboard is *always* reachable via `localhost`/`127.0.0.1` in addition to
  # the configured host, without exposing it on every interface. Skipped when
  # the primary already covers `127.0.0.1` (a `127.0.0.1` or wildcard bind, where
  # an extra listener would also collide on the shared port) or when the port is
  # ephemeral (`0`), where the two listeners could not share a fixed port.
  defp loopback_listener(ip, port) when is_integer(port) and port > 0 do
    if covers_ipv4_loopback?(ip) do
      []
    else
      [
        Supervisor.child_spec(
          {Bandit, plug: Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: port},
          id: __MODULE__.Loopback
        )
      ]
    end
  end

  defp loopback_listener(_ip, _port), do: []

  # Addresses whose listener already accepts IPv4 loopback (`127.0.0.1`) traffic.
  defp covers_ipv4_loopback?({127, 0, 0, 1}), do: true
  defp covers_ipv4_loopback?({0, 0, 0, 0}), do: true
  defp covers_ipv4_loopback?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp covers_ipv4_loopback?(_), do: false

  @spec bound_port(term()) :: non_neg_integer() | nil
  def bound_port(_server \\ __MODULE__) do
    case Bandit.PhoenixAdapter.server_info(Endpoint, :http) do
      {:ok, {_ip, port}} when is_integer(port) -> port
      _ -> nil
    end
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  # Resolve the configured host to a bind address. A well-formed hostname that
  # fails DNS resolution (e.g. a Tailscale MagicDNS name while `tailscaled` is
  # logged out) must not prevent the orchestrator from booting: fall back to
  # the loopback interface with a warning so the dashboard stays reachable via
  # `localhost` until the name resolves again. Malformed hosts are still
  # rejected — those are config errors, not transient environment failures.
  defp resolve_host(host) do
    case parse_host(host) do
      {:ok, ip} ->
        {:ok, ip, normalize_host(host)}

      {:error, reason} ->
        if is_binary(host) and host =~ @hostname_pattern do
          Logger.warning(
            "Dashboard host #{inspect(host)} does not resolve (#{inspect(reason)}); " <>
              "binding to 127.0.0.1 instead. Fix DNS for the host (e.g. `tailscale up`) " <>
              "and restart Symphony to bind it again."
          )

          {:ok, {127, 0, 0, 1}, "127.0.0.1"}
        else
          {:error, reason}
        end
    end
  end

  defp parse_host({_, _, _, _} = ip), do: {:ok, ip}
  defp parse_host({_, _, _, _, _, _, _, _} = ip), do: {:ok, ip}

  defp parse_host(host) when is_binary(host) do
    charhost = String.to_charlist(host)

    case :inet.parse_address(charhost) do
      {:ok, ip} ->
        {:ok, ip}

      {:error, _reason} ->
        case :inet.getaddr(charhost, :inet) do
          {:ok, ip} -> {:ok, ip}
          {:error, _reason} -> :inet.getaddr(charhost, :inet6)
        end
    end
  end

  defp normalize_host(host) when host in ["", nil], do: "127.0.0.1"
  defp normalize_host(host) when is_binary(host), do: host
  defp normalize_host(host), do: to_string(host)

  defp secret_key_base do
    Base.encode64(:crypto.strong_rand_bytes(@secret_key_bytes), padding: false)
  end
end
