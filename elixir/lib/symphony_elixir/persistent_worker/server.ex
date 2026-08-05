defmodule SymphonyElixir.PersistentWorker.Server do
  @moduledoc """
  Owns one live `AgentRunner` in a detached BEAM and exposes a reconnectable
  loopback control channel to the orchestrator.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.PersistentWorker.{Protocol, Registry}

  defmodule State do
    @moduledoc false
    defstruct [
      :spec,
      :listener,
      :acceptor,
      :runner_pid,
      :runner_ref,
      :connection,
      :connection_ref,
      :checkpoint,
      :terminal_seq,
      checkpoint_seq: 0,
      next_seq: 1,
      events: [],
      stop_requested: false
    ]
  end

  @type server :: GenServer.server()

  @doc "Start a persistent worker server from an immutable run spec."
  @spec start_link(Registry.run_spec(), keyword()) :: GenServer.on_start()
  def start_link(spec, opts \\ []) when is_map(spec) and is_list(opts) do
    GenServer.start_link(__MODULE__, {spec, opts})
  end

  @doc false
  @spec port(server()) :: non_neg_integer()
  def port(server), do: GenServer.call(server, :port)

  @impl true
  def init({spec, opts}) do
    with {:ok, listener} <-
           :gen_tcp.listen(0, [
             :binary,
             packet: 4,
             active: false,
             ip: {127, 0, 0, 1},
             reuseaddr: true
           ]),
         {:ok, {_address, port}} <- :inet.sockname(listener),
         {:ok, _manifest} <-
           Registry.update(spec.manifest_path, %{
             port: port,
             os_pid: os_pid(),
             status: "running"
           }) do
      server = self()
      acceptor = spawn_link(fn -> accept_loop(listener, server) end)
      state = %State{spec: spec, listener: listener, acceptor: acceptor}
      {:ok, state, {:continue, {:start_runner, opts}}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue({:start_runner, opts}, %State{} = state) do
    recipient = self()
    runner_fun = Keyword.get(opts, :runner_fun, fn worker_recipient -> run_agent(worker_recipient, state.spec) end)
    {runner_pid, runner_ref} = spawn_monitor(fn -> runner_fun.(recipient) end)
    {:noreply, %{state | runner_pid: runner_pid, runner_ref: runner_ref}}
  end

  @impl true
  def handle_call(:port, _from, %State{} = state) do
    {:ok, {_address, port}} = :inet.sockname(state.listener)
    {:reply, port, state}
  end

  def handle_call(
        {:attach, connection, token},
        _from,
        %State{spec: %{auth_token: expected}} = state
      )
      when is_pid(connection) and is_binary(token) do
    cond do
      byte_size(token) != byte_size(expected) or not Plug.Crypto.secure_compare(token, expected) ->
        {:reply, {:error, :unauthorized}, state}

      is_pid(state.connection) and state.connection != connection and
          Process.alive?(state.connection) ->
        {:reply, {:error, :already_attached}, state}

      true ->
        if is_reference(state.connection_ref), do: Process.demonitor(state.connection_ref, [:flush])
        ref = Process.monitor(connection)

        {:reply,
         {:ok,
          %{
            worker_id: state.spec.worker_id,
            checkpoint_seq: state.checkpoint_seq,
            checkpoint: state.checkpoint,
            events: state.events
          }}, %{state | connection: connection, connection_ref: ref}}
    end
  end

  def handle_call(
        {:agent_lifecycle, issue_id, lifecycle_state, metadata},
        _from,
        %State{} = state
      ) do
    event = {:agent_lifecycle, issue_id, lifecycle_state, metadata}
    {:reply, :ok, record_event(state, event)}
  end

  @impl true
  def handle_cast({:ack, connection, seq, checkpoint}, %State{connection: connection} = state)
      when is_integer(seq) and seq >= 0 do
    state = acknowledge(state, seq, checkpoint)

    if is_integer(state.terminal_seq) and seq >= state.terminal_seq do
      finish_worker(state, connection)
    else
      {:noreply, state}
    end
  end

  def handle_cast({:ack, _connection, _seq, _checkpoint}, state), do: {:noreply, state}

  def handle_cast({:stop, connection}, %State{connection: connection} = state) do
    state = %{state | stop_requested: true}
    _ = Registry.update(state.spec.manifest_path, %{status: "stopping"})

    if is_pid(state.runner_pid) and Process.alive?(state.runner_pid) do
      Process.exit(state.runner_pid, :shutdown)
      {:noreply, state}
    else
      finish_worker(state, connection)
    end
  end

  def handle_cast({:stop, _connection}, state), do: {:noreply, state}

  def handle_cast({:detach, connection}, %State{connection: connection} = state) do
    if is_reference(state.connection_ref), do: Process.demonitor(state.connection_ref, [:flush])
    {:noreply, %{state | connection: nil, connection_ref: nil}}
  end

  def handle_cast({:detach, _connection}, state), do: {:noreply, state}

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %State{runner_ref: ref} = state
      ) do
    reason = normalize_runner_exit(reason)
    state = record_event(%{state | runner_pid: nil, runner_ref: nil}, {:persistent_worker_completed, reason})
    state = %{state | terminal_seq: state.next_seq - 1}
    _ = Registry.update(state.spec.manifest_path, %{status: "completed"})

    if state.stop_requested do
      finish_worker(state, state.connection)
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %State{connection_ref: ref, connection: pid} = state
      ) do
    {:noreply, %{state | connection: nil, connection_ref: nil}}
  end

  def handle_info({:worker_runtime_info, _issue_id, _runtime_info} = event, state),
    do: {:noreply, record_event(state, event)}

  def handle_info({:worker_run_failure, _issue_id, _pid, _failure} = event, state),
    do: {:noreply, record_event(state, event)}

  def handle_info({:codex_worker_update, _issue_id, _update} = event, state),
    do: {:noreply, record_event(state, event)}

  def handle_info({:handoff_review_heartbeat, _issue_id, _pid, _job_id, _at} = event, state),
    do: {:noreply, record_event(state, event)}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %State{} = state) do
    if is_port(state.listener), do: :gen_tcp.close(state.listener)
    :ok
  end

  defp run_agent(recipient, spec) do
    AgentRunner.run(spec.issue, recipient,
      attempt: spec.attempt,
      worker_host: spec.worker_host
    )
  end

  defp record_event(%State{} = state, event) do
    seq = state.next_seq
    if is_pid(state.connection), do: send(state.connection, {:worker_event, seq, event})
    %{state | next_seq: seq + 1, events: state.events ++ [{seq, event}]}
  end

  defp acknowledge(%State{} = state, seq, checkpoint) do
    if is_map(checkpoint) and seq >= state.checkpoint_seq do
      %{
        state
        | checkpoint_seq: seq,
          checkpoint: checkpoint,
          events: Enum.reject(state.events, fn {event_seq, _event} -> event_seq <= seq end)
      }
    else
      state
    end
  end

  defp finish_worker(%State{} = state, connection) do
    _ = Registry.cleanup(state.spec.manifest_path, state.spec.worker_id)
    if is_pid(connection), do: send(connection, :worker_finished)
    {:stop, :normal, state}
  end

  defp accept_loop(listener, server) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        connection = spawn(fn -> await_connection_socket(server) end)
        :ok = :gen_tcp.controlling_process(socket, connection)
        send(connection, {:connection_socket, socket})
        accept_loop(listener, server)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        send(server, {:accept_failed, reason})
    end
  end

  defp await_connection_socket(server) do
    receive do
      {:connection_socket, socket} -> connection_loop(socket, server)
    end
  end

  defp connection_loop(socket, server) do
    case :gen_tcp.recv(socket, 0, 15_000) do
      {:ok, payload} -> authenticate_connection(socket, server, payload)
      _other -> :ok
    end
  after
    GenServer.cast(server, {:detach, self()})
    :gen_tcp.close(socket)
  end

  defp authenticate_connection(socket, server, payload) do
    with {:ok, {:hello, version, token}} <- Protocol.decode(payload),
         true <- version == Protocol.version(),
         {:ok, attachment} <- GenServer.call(server, {:attach, self(), token}) do
      :ok = Protocol.send_message(socket, {:attached, Protocol.version(), attachment})

      Enum.each(attachment.events, fn {seq, event} ->
        :ok = Protocol.send_message(socket, {:event, seq, event})
      end)

      :ok = :inet.setopts(socket, active: true)
      connected_loop(socket, server)
    else
      {:error, reason} -> Protocol.send_message(socket, {:attach_error, reason})
      false -> Protocol.send_message(socket, {:attach_error, :protocol_version_mismatch})
      _other -> Protocol.send_message(socket, {:attach_error, :invalid_handshake})
    end
  end

  defp connected_loop(socket, server) do
    receive do
      {:worker_event, seq, event} ->
        case Protocol.send_message(socket, {:event, seq, event}) do
          :ok -> connected_loop(socket, server)
          {:error, _reason} -> :ok
        end

      {:tcp, ^socket, payload} ->
        handle_client_message(socket, server, payload)
        connected_loop(socket, server)

      {:tcp_closed, ^socket} ->
        :ok

      {:tcp_error, ^socket, _reason} ->
        :ok

      :worker_finished ->
        _ = Protocol.send_message(socket, :worker_finished)
        :ok
    end
  end

  defp handle_client_message(_socket, server, payload) do
    case Protocol.decode_authenticated(payload) do
      {:ok, {:ack, seq, checkpoint}} -> GenServer.cast(server, {:ack, self(), seq, checkpoint})
      {:ok, :stop} -> GenServer.cast(server, {:stop, self()})
      _other -> :ok
    end
  end

  defp normalize_runner_exit(:normal), do: :normal
  defp normalize_runner_exit(:shutdown), do: :shutdown

  defp normalize_runner_exit(reason) do
    {:persistent_worker_exit, inspect(reason, limit: 50, printable_limit: 2_000)}
  end

  defp os_pid do
    case Integer.parse(System.pid()) do
      {pid, ""} when pid > 0 -> pid
      _other -> nil
    end
  end
end
