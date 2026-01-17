defmodule Burrow.Noise.Transport do
  @moduledoc """
  Encrypted transport layer using Noise protocol ciphers.

  This module wraps a raw TCP socket with encryption, providing
  a simple send/receive interface for encrypted communication.

  ## Message Format

  Each encrypted message has the format:
  - Length (2 bytes, big-endian): Length of encrypted payload
  - Encrypted payload: ChaCha20-Poly1305 encrypted data

  The maximum plaintext size per message is 65535 - 16 (AEAD tag) = 65519 bytes.

  ## Usage

      # After handshake completion, create transport
      {:ok, transport} = Transport.new(socket, handshake_state)

      # Send encrypted data
      :ok = Transport.send(transport, "hello")

      # Receive encrypted data
      {:ok, data, transport} = Transport.recv(transport)

  """

  require Logger

  alias Burrow.Noise.Handshake

  @max_plaintext_size 65519
  @length_size 2

  defstruct [
    :socket,
    :transport_mod,   # :gen_tcp or :ssl
    :handshake,       # Handshake state with Decibel ref
    :recv_buffer
  ]

  @type t :: %__MODULE__{}
  @type socket :: :gen_tcp.socket() | :ssl.sslsocket()

  @doc """
  Create a new encrypted transport.

  Takes a socket and a completed handshake state.
  """
  @spec new(socket(), Handshake.t()) :: {:ok, t()}
  def new(socket, handshake) do
    transport_mod = detect_transport(socket)

    {:ok, %__MODULE__{
      socket: socket,
      transport_mod: transport_mod,
      handshake: handshake,
      recv_buffer: <<>>
    }}
  end

  @doc """
  Send encrypted data over the transport.

  Encrypts the plaintext and sends it with a length prefix.
  Large messages are automatically chunked.
  """
  @spec send(t(), binary()) :: {:ok, t()} | {:error, term()}
  def send(%__MODULE__{} = transport, plaintext) when is_binary(plaintext) do
    # Chunk large messages
    chunks = chunk_plaintext(plaintext)
    send_chunks(transport, chunks)
  end

  @doc """
  Receive and decrypt data from the transport.

  Blocks until a complete message is received.
  Returns `{:ok, plaintext, updated_transport}` or `{:error, reason}`.
  """
  @spec recv(t()) :: {:ok, binary(), t()} | {:error, term()}
  def recv(%__MODULE__{} = transport) do
    recv_message(transport)
  end

  @doc """
  Receive with a timeout.
  """
  @spec recv(t(), timeout()) :: {:ok, binary(), t()} | {:error, term()}
  def recv(%__MODULE__{} = transport, timeout) do
    recv_message(transport, timeout)
  end

  @doc """
  Encrypt data without sending (for integration with existing protocols).

  Returns the encrypted message with length prefix.
  """
  @spec encrypt(t(), binary()) :: {:ok, binary(), t()} | {:error, term()}
  def encrypt(%__MODULE__{handshake: hs} = transport, plaintext)
      when byte_size(plaintext) <= @max_plaintext_size do
    case Handshake.encrypt(hs, plaintext) do
      {:ok, ciphertext, new_hs} ->
        length = byte_size(ciphertext)
        message = <<length::16>> <> ciphertext
        {:ok, message, %{transport | handshake: new_hs}}

      {:error, _} = error ->
        error
    end
  end

  def encrypt(_, _), do: {:error, :plaintext_too_large}

  @doc """
  Decrypt data without receiving (for integration with existing protocols).

  Input should be raw ciphertext without length prefix.
  """
  @spec decrypt(t(), binary()) :: {:ok, binary(), t()} | {:error, term()}
  def decrypt(%__MODULE__{handshake: hs} = transport, ciphertext) do
    case Handshake.decrypt(hs, ciphertext) do
      {:ok, plaintext, new_hs} ->
        {:ok, plaintext, %{transport | handshake: new_hs}}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Get the underlying socket.
  """
  @spec socket(t()) :: socket()
  def socket(%__MODULE__{socket: socket}), do: socket

  @doc """
  Close the transport and underlying socket.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{socket: socket, transport_mod: mod}) do
    mod.close(socket)
  end

  @doc """
  Set socket to active mode for async receiving.
  """
  @spec set_active(t(), boolean() | :once) :: :ok | {:error, term()}
  def set_active(%__MODULE__{socket: socket, transport_mod: :gen_tcp}, active) do
    :inet.setopts(socket, active: active)
  end

  def set_active(%__MODULE__{socket: socket, transport_mod: :ssl}, active) do
    :ssl.setopts(socket, active: active)
  end

  @doc """
  Process incoming data (for active mode sockets).

  Takes raw TCP data and attempts to decrypt complete messages.
  Returns `{:ok, messages, updated_transport}` where messages is
  a list of decrypted plaintexts.
  """
  @spec process_data(t(), binary()) :: {:ok, [binary()], t()} | {:error, term()}
  def process_data(%__MODULE__{} = transport, data) do
    buffer = transport.recv_buffer <> data
    extract_messages(transport, buffer, [])
  end

  # Private functions

  defp detect_transport({:sslsocket, _, _}), do: :ssl
  defp detect_transport(_), do: :gen_tcp

  defp chunk_plaintext(data) do
    chunk_plaintext(data, [])
  end

  defp chunk_plaintext(<<>>, acc), do: Enum.reverse(acc)

  defp chunk_plaintext(data, acc) when byte_size(data) <= @max_plaintext_size do
    Enum.reverse([data | acc])
  end

  defp chunk_plaintext(data, acc) do
    <<chunk::binary-size(@max_plaintext_size), rest::binary>> = data
    chunk_plaintext(rest, [chunk | acc])
  end

  defp send_chunks(transport, []), do: {:ok, transport}

  defp send_chunks(transport, [chunk | rest]) do
    case encrypt_and_send(transport, chunk) do
      {:ok, new_transport} -> send_chunks(new_transport, rest)
      {:error, _} = error -> error
    end
  end

  defp encrypt_and_send(%__MODULE__{} = transport, plaintext) do
    case encrypt(transport, plaintext) do
      {:ok, message, new_transport} ->
        case raw_send(new_transport, message) do
          :ok -> {:ok, new_transport}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp raw_send(%__MODULE__{socket: socket, transport_mod: mod}, data) do
    mod.send(socket, data)
  end

  defp recv_message(transport, timeout \\ 30_000) do
    # First, try to extract from buffer
    buffer = transport.recv_buffer

    case try_extract_message(buffer) do
      {:ok, ciphertext, rest} ->
        case decrypt(transport, ciphertext) do
          {:ok, plaintext, new_transport} ->
            {:ok, plaintext, %{new_transport | recv_buffer: rest}}

          {:error, _} = error ->
            error
        end

      :incomplete ->
        # Need more data
        case raw_recv(transport, timeout) do
          {:ok, data} ->
            new_buffer = buffer <> data
            recv_message(%{transport | recv_buffer: new_buffer}, timeout)

          {:error, _} = error ->
            error
        end
    end
  end

  defp raw_recv(%__MODULE__{socket: socket, transport_mod: mod}, timeout) do
    case mod do
      :gen_tcp -> :gen_tcp.recv(socket, 0, timeout)
      :ssl -> :ssl.recv(socket, 0, timeout)
    end
  end

  defp try_extract_message(buffer) when byte_size(buffer) < @length_size do
    :incomplete
  end

  defp try_extract_message(<<length::16, rest::binary>> = _buffer) do
    if byte_size(rest) >= length do
      <<ciphertext::binary-size(length), remaining::binary>> = rest
      {:ok, ciphertext, remaining}
    else
      :incomplete
    end
  end

  defp extract_messages(transport, buffer, messages) do
    case try_extract_message(buffer) do
      {:ok, ciphertext, rest} ->
        case decrypt(transport, ciphertext) do
          {:ok, plaintext, new_transport} ->
            extract_messages(new_transport, rest, [plaintext | messages])

          {:error, _} = error ->
            error
        end

      :incomplete ->
        {:ok, Enum.reverse(messages), %{transport | recv_buffer: buffer}}
    end
  end
end
