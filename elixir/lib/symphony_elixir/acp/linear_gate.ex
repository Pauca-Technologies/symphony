defmodule SymphonyElixir.Acp.LinearGate do
  @moduledoc """
  In-VM MCP endpoint that exposes Symphony's gated `linear_graphql` tool to an
  ACP agent — the load-bearing piece of the ACP handoff gate
  (`docs/acp-support-plan.md` §5.5).

  ACP has no equivalent of Codex `dynamicTools`; an agent reaches custom tools
  through an MCP server listed in `session/new.mcpServers`. So each ACP session
  spins up a tiny per-session HTTP listener here, speaking the MCP
  Streamable-HTTP transport, and advertises it to the agent as the **only**
  sanctioned Linear path. When the agent calls `linear_graphql`, the request
  lands on this endpoint and is dispatched **back into the owning session
  process** (`dispatch_tool_call/4`), where `SymphonyElixir.Codex.DynamicTool`
  runs the before_handoff + reviewer gates with the run's
  `handoff_gate_context` and process-dictionary state intact — exactly as the
  Codex path does. The HTTP handler never executes the gate itself; it only
  signals the in-process turn loop.

  Security model (§5.5): the gate holds because the agent has **no Linear
  credentials of its own** (`Acp.Client` scrubs them from the agent env) and no
  native Linear MCP server — only this gated channel, whose token Symphony
  keeps server-side. A path token authenticates the endpoint as
  defense-in-depth; the credential-withholding is the hard guarantee.
  """

  require Logger

  alias SymphonyElixir.Codex.DynamicTool

  @type t :: %{
          pid: pid(),
          port: non_neg_integer(),
          token: String.t(),
          url: String.t(),
          server_name: String.t()
        }

  @default_server_name "symphony-linear"
  # The model may run a slow turn before invoking the tool; the dispatch itself
  # blocks the HTTP request on the session process, so allow a generous ceiling.
  @default_tool_timeout_ms 600_000
  @token_bytes 24

  @doc """
  Start a per-session MCP listener bound to loopback on an OS-assigned port.

  Options:
    * `:session_pid` — the process that runs the ACP turn loop and executes the
      tool (defaults to the caller).
    * `:token` — path token (generated if omitted).
    * `:server_name` — the `mcpServers[].name` the agent sees; OpenCode
      namespaces the tool as `<server_name>_linear_graphql`.
    * `:tool_timeout_ms` — how long a tool dispatch may block.
  """
  @spec start(keyword()) :: {:ok, t()} | {:error, term()}
  def start(opts \\ []) do
    token = Keyword.get(opts, :token) || generate_token()
    session_pid = Keyword.get(opts, :session_pid, self())
    server_name = Keyword.get(opts, :server_name, @default_server_name)
    tool_timeout_ms = Keyword.get(opts, :tool_timeout_ms, @default_tool_timeout_ms)

    plug_opts = %{
      token: token,
      session_pid: session_pid,
      server_name: server_name,
      tool_timeout_ms: tool_timeout_ms
    }

    bandit_opts = [
      plug: {__MODULE__.McpPlug, plug_opts},
      scheme: :http,
      ip: {127, 0, 0, 1},
      port: 0,
      startup_log: false
    ]

    with {:ok, pid} <- Bandit.start_link(bandit_opts),
         {:ok, {_address, port}} when is_integer(port) <- ThousandIsland.listener_info(pid) do
      url = "http://127.0.0.1:#{port}/mcp/#{token}"

      {:ok,
       %{pid: pid, port: port, token: token, url: url, server_name: server_name}}
    else
      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:gate_listener_failed, other}}
    end
  end

  @doc "Tear down a started gate listener (best effort)."
  @spec stop(t() | nil) :: :ok
  def stop(%{pid: pid}) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        ThousandIsland.stop(pid)
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def stop(_gate), do: :ok

  @doc """
  The `session/new.mcpServers[]` entry advertising this gate to the agent.
  `headers` is required by OpenCode's strict schema (empty list is fine).
  """
  @spec mcp_server_entry(t()) :: map()
  def mcp_server_entry(%{url: url, server_name: server_name}) do
    %{
      "type" => "http",
      "name" => server_name,
      "url" => url,
      "headers" => []
    }
  end

  @doc """
  Dispatch a tool call into the owning session process and await its result.

  This is the *in-VM* hop that makes the gate hold: the tool executes in the
  process that owns the run's `handoff_gate_context` and deferred-review /
  iteration counters (the process dictionary), never in the HTTP handler.
  """
  @spec dispatch_tool_call(pid(), String.t() | nil, term(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def dispatch_tool_call(session_pid, tool_name, arguments, timeout)
      when is_pid(session_pid) do
    if Process.alive?(session_pid) do
      ref = make_ref()
      monitor_ref = Process.monitor(session_pid)
      send(session_pid, {:acp_tool_call, ref, self(), tool_name, arguments})

      receive do
        {:acp_tool_result, ^ref, result} ->
          Process.demonitor(monitor_ref, [:flush])
          {:ok, result}

        {:DOWN, ^monitor_ref, :process, ^session_pid, reason} ->
          {:error, {:session_down, reason}}
      after
        timeout ->
          Process.demonitor(monitor_ref, [:flush])
          {:error, :tool_dispatch_timeout}
      end
    else
      {:error, :session_not_running}
    end
  end

  def dispatch_tool_call(_session_pid, _tool_name, _arguments, _timeout),
    do: {:error, :session_not_running}

  @doc "The MCP `tools/list` payload (the gated `linear_graphql` tool spec)."
  @spec tool_specs() :: [map()]
  def tool_specs, do: DynamicTool.tool_specs()

  defp generate_token do
    @token_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defmodule McpPlug do
    @moduledoc """
    Plain Plug implementing the MCP Streamable-HTTP server for a single ACP
    session. Mounted by `LinearGate.start/1` on a per-session Bandit listener.
    """

    @behaviour Plug

    import Plug.Conn

    alias SymphonyElixir.Acp.LinearGate

    @max_body_bytes 8_000_000

    @impl true
    def init(opts) when is_map(opts), do: opts
    def init(opts), do: Map.new(opts)

    @impl true
    def call(%Plug.Conn{method: "POST", path_info: ["mcp", token]} = conn, opts) do
      if authorized?(token, opts.token) do
        handle_post(conn, opts)
      else
        send_resp(conn, 404, "")
      end
    end

    # MCP Streamable HTTP also defines a GET for a server->client SSE stream.
    # Phase 2 does not push server-initiated messages, so decline it; OpenCode
    # tolerates a non-200 here (verified in the Phase-0 spike).
    def call(%Plug.Conn{method: "GET", path_info: ["mcp", _token]} = conn, _opts) do
      send_resp(conn, 405, "")
    end

    def call(conn, _opts), do: send_resp(conn, 404, "")

    defp handle_post(conn, opts) do
      case read_full_body(conn) do
        {:ok, body, conn} ->
          case Jason.decode(body) do
            {:ok, decoded} -> respond(conn, decoded, opts)
            {:error, _reason} -> json(conn, 200, error_response(nil, -32_700, "Parse error"))
          end

        {:error, conn} ->
          json(conn, 200, error_response(nil, -32_600, "Request body too large"))
      end
    end

    # A JSON-RPC batch: process each, drop the notification no-replies.
    defp respond(conn, messages, opts) when is_list(messages) do
      responses =
        messages
        |> Enum.map(&handle_message(&1, opts))
        |> Enum.reject(&is_nil/1)

      case responses do
        [] -> send_resp(conn, 202, "")
        replies -> json(conn, 200, replies)
      end
    end

    defp respond(conn, message, opts) when is_map(message) do
      case handle_message(message, opts) do
        nil -> send_resp(conn, 202, "")
        reply -> json(conn, 200, reply)
      end
    end

    defp respond(conn, _message, _opts) do
      json(conn, 200, error_response(nil, -32_600, "Invalid Request"))
    end

    # Requests carry an "id"; notifications do not (return nil -> 202).
    defp handle_message(%{"method" => method, "id" => id} = message, opts) do
      result_for(method, message, opts) |> wrap(id)
    end

    defp handle_message(%{"method" => _method}, _opts), do: nil
    defp handle_message(_message, _opts), do: nil

    defp result_for("initialize", message, _opts) do
      requested = get_in(message, ["params", "protocolVersion"])

      {:ok,
       %{
         "protocolVersion" => if(is_binary(requested), do: requested, else: "2025-06-18"),
         "capabilities" => %{"tools" => %{"listChanged" => false}},
         "serverInfo" => %{"name" => "symphony-linear-gate", "version" => "0.1.0"}
       }}
    end

    defp result_for("tools/list", _message, _opts) do
      {:ok, %{"tools" => LinearGate.tool_specs()}}
    end

    defp result_for("tools/call", message, opts) do
      params = Map.get(message, "params") || %{}
      tool_name = Map.get(params, "name")
      arguments = Map.get(params, "arguments") || %{}

      case LinearGate.dispatch_tool_call(opts.session_pid, tool_name, arguments, opts.tool_timeout_ms) do
        {:ok, dynamic_result} ->
          {:ok, tool_call_content(dynamic_result)}

        {:error, reason} ->
          {:ok,
           tool_call_content(%{
             "success" => false,
             "output" => Jason.encode!(%{"error" => %{"message" => "linear_graphql dispatch failed", "reason" => inspect(reason)}})
           })}
      end
    end

    defp result_for("ping", _message, _opts), do: {:ok, %{}}

    defp result_for("notifications/" <> _rest, _message, _opts), do: :noreply

    defp result_for(method, _message, _opts) do
      {:error, {-32_601, "Method not found: #{method}"}}
    end

    defp tool_call_content(%{"success" => success} = result) do
      output = Map.get(result, "output") || ""

      %{
        "content" => [%{"type" => "text", "text" => to_string(output)}],
        "isError" => success != true
      }
    end

    defp tool_call_content(result) do
      %{
        "content" => [%{"type" => "text", "text" => inspect(result)}],
        "isError" => true
      }
    end

    defp wrap(:noreply, _id), do: nil

    defp wrap({:ok, result}, id) do
      %{"jsonrpc" => "2.0", "id" => id, "result" => result}
    end

    defp wrap({:error, {code, message}}, id) do
      error_response(id, code, message)
    end

    defp error_response(id, code, message) do
      %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
    end

    defp authorized?(token, expected) when is_binary(token) and is_binary(expected) do
      Plug.Crypto.secure_compare(token, expected)
    end

    defp authorized?(_token, _expected), do: false

    defp read_full_body(conn, acc \\ "") do
      case read_body(conn, length: 1_000_000, read_length: 1_000_000) do
        {:ok, chunk, conn} ->
          {:ok, acc <> chunk, conn}

        {:more, chunk, conn} ->
          next = acc <> chunk

          if byte_size(next) > @max_body_bytes do
            {:error, conn}
          else
            read_full_body(conn, next)
          end

        {:error, _reason} ->
          {:error, conn}
      end
    end

    defp json(conn, status, payload) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(payload))
    end
  end
end
