defmodule SymphonyElixir.PersistentWorker.Client do
  @moduledoc false

  alias SymphonyElixir.PersistentWorker.{Protocol, Registry}

  @connect_timeout_ms 1_000
  @connect_retry_ms 200
  @attach_deadline_ms 30_000
  @orchestrator_timeout_ms 30_000

  @doc "Attach to a detached worker and relay its ordered event stream."
  @spec run(Registry.manifest(), pid()) :: no_return()
  def run(manifest, orchestrator) when is_map(manifest) and is_pid(orchestrator) do
    recipient_ref = Process.monitor(orchestrator)
    connect_loop(manifest, orchestrator, recipient_ref, deadline())
  end

  @doc "Ask an attached worker to stop without terminating the client abruptly."
  @spec stop(pid(), timeout()) :: :ok
  def stop(pid, timeout \\ 5_000) when is_pid(pid) do
    ref = make_ref()
    send(pid, {:persistent_worker_stop, self(), ref})

    receive do
      {:persistent_worker_stopping, ^ref} -> :ok
      {:DOWN, _monitor_ref, :process, ^pid, _reason} -> :ok
    after
      timeout -> :ok
    end
  end

  defp connect_loop(manifest, orchestrator, recipient_ref, deadline_ms) do
    cond do
      not Process.alive?(orchestrator) ->
        exit(:normal)

      System.monotonic_time(:millisecond) >= deadline_ms ->
        unless Registry.worker_alive?(manifest) do
          _ = Registry.cleanup(manifest, manifest.worker_id)
        end

        exit({:persistent_worker_unavailable, manifest.worker_id})

      true ->
        connect_and_attach(manifest, orchestrator, recipient_ref, deadline_ms)
    end
  end

  defp connect_and_attach(manifest, orchestrator, recipient_ref, deadline_ms) do
    case connect(manifest) do
      {:ok, socket, attachment, refreshed_manifest} ->
        finish_attachment(socket, attachment, refreshed_manifest, orchestrator, recipient_ref)

      {:error, _reason} ->
        wait_before_reconnect(manifest, orchestrator, recipient_ref, deadline_ms)
    end
  end

  defp finish_attachment(socket, attachment, manifest, orchestrator, recipient_ref) do
    case install_checkpoint(orchestrator, manifest.worker_id, attachment) do
      :ok -> connected_loop(socket, manifest, orchestrator, recipient_ref)
      :stale_worker -> stop_and_exit(socket)
      {:error, _reason} -> reconnect(socket, manifest, orchestrator, recipient_ref)
    end
  end

  defp connect(manifest) do
    with {:ok, refreshed} <- Registry.load_manifest(manifest.manifest_path),
         true <- refreshed.worker_id == manifest.worker_id,
         port when is_integer(port) and port > 0 <- refreshed.port,
         {:ok, socket} <-
           :gen_tcp.connect(
             {127, 0, 0, 1},
             port,
             [:binary, packet: 4, active: false],
             @connect_timeout_ms
           ),
         :ok <- Protocol.send_message(socket, {:hello, Protocol.version(), refreshed.auth_token}),
         {:ok, payload} <- :gen_tcp.recv(socket, 0, @connect_timeout_ms),
         {:ok, {:attached, version, attachment}} <- Protocol.decode_authenticated(payload),
         true <- version == Protocol.version() do
      {:ok, socket, attachment, refreshed}
    else
      false -> {:error, :worker_id_or_protocol_mismatch}
      nil -> {:error, :worker_not_ready}
      {:ok, {:attach_error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_worker_handshake}
    end
  end

  defp install_checkpoint(orchestrator, worker_id, attachment) do
    call_orchestrator(
      orchestrator,
      {:persistent_worker_checkpoint, worker_id, attachment.checkpoint_seq, attachment.checkpoint}
    )
  end

  defp connected_loop(socket, manifest, orchestrator, recipient_ref) do
    :ok = :inet.setopts(socket, active: true)

    receive do
      {:tcp, ^socket, payload} ->
        handle_server_payload(
          Protocol.decode_authenticated(payload),
          socket,
          manifest,
          orchestrator,
          recipient_ref
        )

      {:tcp_closed, ^socket} ->
        connect_loop(manifest, orchestrator, recipient_ref, deadline())

      {:tcp_error, ^socket, _reason} ->
        reconnect(socket, manifest, orchestrator, recipient_ref)

      {:persistent_worker_stop, caller, ref} ->
        _ = Protocol.send_message(socket, :stop)
        send(caller, {:persistent_worker_stopping, ref})
        :gen_tcp.close(socket)
        exit(:normal)

      {:DOWN, ^recipient_ref, :process, ^orchestrator, _reason} ->
        :gen_tcp.close(socket)
        exit(:normal)
    end
  end

  defp handle_server_payload(
         {:ok, {:event, seq, event}},
         socket,
         manifest,
         orchestrator,
         recipient_ref
       ) do
    orchestrator
    |> deliver_event(manifest.worker_id, seq, event)
    |> handle_event_delivery(seq, socket, manifest, orchestrator, recipient_ref)
  end

  defp handle_server_payload({:ok, :worker_finished}, socket, _manifest, _orchestrator, _recipient_ref) do
    :gen_tcp.close(socket)
    exit(:normal)
  end

  defp handle_server_payload(_message, socket, manifest, orchestrator, recipient_ref) do
    connected_loop(socket, manifest, orchestrator, recipient_ref)
  end

  defp handle_event_delivery(
         {:ok, checkpoint},
         seq,
         socket,
         manifest,
         orchestrator,
         recipient_ref
       ) do
    case Protocol.send_message(socket, {:ack, seq, checkpoint}) do
      :ok -> connected_loop(socket, manifest, orchestrator, recipient_ref)
      {:error, _reason} -> reconnect(socket, manifest, orchestrator, recipient_ref)
    end
  end

  defp handle_event_delivery(
         {:terminal, checkpoint},
         seq,
         socket,
         _manifest,
         _orchestrator,
         _recipient_ref
       ) do
    _ = Protocol.send_message(socket, {:ack, seq, checkpoint})
    :gen_tcp.close(socket)
    exit(:normal)
  end

  defp handle_event_delivery(:stale_worker, _seq, socket, _manifest, _orchestrator, _recipient_ref),
    do: stop_and_exit(socket)

  defp handle_event_delivery(
         {:error, _reason},
         _seq,
         socket,
         manifest,
         orchestrator,
         recipient_ref
       ),
       do: reconnect(socket, manifest, orchestrator, recipient_ref)

  defp deliver_event(orchestrator, worker_id, seq, event) do
    call_orchestrator(orchestrator, {:persistent_worker_event, worker_id, seq, event})
  end

  defp call_orchestrator(orchestrator, message) do
    GenServer.call(orchestrator, message, @orchestrator_timeout_ms)
  catch
    :exit, reason -> {:error, reason}
  end

  defp wait_before_reconnect(manifest, orchestrator, recipient_ref, deadline_ms) do
    receive do
      {:persistent_worker_stop, caller, ref} ->
        send(caller, {:persistent_worker_stopping, ref})
        exit(:normal)

      {:DOWN, ^recipient_ref, :process, ^orchestrator, _reason} ->
        exit(:normal)
    after
      @connect_retry_ms -> connect_loop(manifest, orchestrator, recipient_ref, deadline_ms)
    end
  end

  defp reconnect(socket, manifest, orchestrator, recipient_ref) do
    :gen_tcp.close(socket)
    connect_loop(manifest, orchestrator, recipient_ref, deadline())
  end

  defp stop_and_exit(socket) do
    _ = Protocol.send_message(socket, :stop)
    :gen_tcp.close(socket)
    exit(:normal)
  end

  defp deadline, do: System.monotonic_time(:millisecond) + @attach_deadline_ms
end
