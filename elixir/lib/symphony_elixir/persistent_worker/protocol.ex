defmodule SymphonyElixir.PersistentWorker.Protocol do
  @moduledoc false

  @version 1

  @doc false
  @spec version() :: pos_integer()
  def version, do: @version

  @doc false
  @spec send_message(port(), term()) :: :ok | {:error, term()}
  def send_message(socket, message) when is_port(socket) do
    :gen_tcp.send(socket, :erlang.term_to_binary(message, [:compressed]))
  end

  @doc false
  @spec decode(binary()) :: {:ok, term()} | {:error, :invalid_message}
  def decode(payload) when is_binary(payload) do
    {:ok, :erlang.binary_to_term(payload, [:safe])}
  rescue
    ArgumentError -> {:error, :invalid_message}
  end

  @doc false
  @spec decode_authenticated(binary()) :: {:ok, term()} | {:error, :invalid_message}
  def decode_authenticated(payload) when is_binary(payload) do
    # Authenticated peers may be running different application builds. Allow
    # atoms from either build after the private worker token has established
    # the trust boundary; `[:safe]` would reject atoms unknown to the new VM.
    {:ok, :erlang.binary_to_term(payload)}
  rescue
    ArgumentError -> {:error, :invalid_message}
  end
end
