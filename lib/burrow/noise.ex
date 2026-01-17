defmodule Burrow.Noise do
  @moduledoc """
  Noise protocol encryption for Burrow.

  Provides end-to-end encryption using the Noise_IK pattern, similar to
  what WireGuard uses. All data between client and server is encrypted
  with ChaCha20-Poly1305 after a 1-RTT handshake.

  ## Features

  - **Noise_IK pattern**: 1-RTT handshake, client knows server pubkey beforehand
  - **X25519 key exchange**: Fast, modern elliptic curve DH
  - **ChaCha20-Poly1305**: AEAD encryption for all data
  - **Forward secrecy**: Ephemeral keys protect past sessions

  ## Usage

  ### Generate Server Keys

      # Generate and save a keypair
      {:ok, keypair} = Burrow.Noise.generate_keypair()
      Burrow.Noise.Keys.save(keypair, "/etc/burrow/server.key")

      # Get public key to distribute to clients
      pubkey = Burrow.Noise.Keys.public_key_base64(keypair)

  ### Server Setup

      # Load keypair and start server with Noise
      keypair = Burrow.Noise.Keys.load!("/etc/burrow/server.key")
      {:ok, server} = Burrow.listen(4000,
        token: "secret",
        encryption: :noise,
        noise_keypair: keypair
      )

  ### Client Setup

      # Connect with Noise encryption
      {:ok, client} = Burrow.connect("server:4000",
        token: "secret",
        encryption: :noise,
        noise_server_pubkey: "base64_server_public_key",
        tunnels: [[name: "web", local: 8080, remote: 80]]
      )

  ## Protocol Integration

  Noise encryption wraps the existing Burrow binary protocol:
  1. TCP connection established
  2. Noise handshake performed (1 round-trip)
  3. All subsequent frames encrypted with Noise transport

  The handshake occurs BEFORE protocol authentication, so the token
  is always transmitted encrypted.
  """

  alias Burrow.Noise.{Keys, Handshake, Transport}

  @doc """
  Generate a new keypair for Noise protocol.

  This is a convenience wrapper around `Burrow.Noise.Keys.generate/0`.
  """
  @spec generate_keypair() :: {:ok, Keys.keypair()}
  defdelegate generate_keypair(), to: Keys, as: :generate

  @doc """
  Perform a client-side (initiator) Noise handshake over a socket.

  This performs the full Noise_IK handshake:
  1. Generate ephemeral key
  2. Send first message (e, es, s, ss)
  3. Receive response (e, ee, se)
  4. Extract transport ciphers

  Returns `{:ok, transport}` where transport is a `Burrow.Noise.Transport`
  that encrypts/decrypts all data.
  """
  @spec client_handshake(:gen_tcp.socket() | :ssl.sslsocket(), Keys.keypair(), binary()) ::
          {:ok, Transport.t()} | {:error, term()}
  def client_handshake(socket, client_keypair, server_pubkey) do
    with {:ok, hs} <- Handshake.new_initiator(client_keypair, server_pubkey),
         {:ok, msg1, hs} <- Handshake.write_message(hs, <<>>),
         :ok <- socket_send(socket, msg1),
         {:ok, msg2} <- socket_recv(socket),
         {:ok, _payload, hs} <- Handshake.read_message(hs, msg2),
         true <- Handshake.complete?(hs) do
      Transport.new(socket, hs)
    else
      false -> {:error, :handshake_incomplete}
      {:error, _} = error -> error
    end
  end

  @doc """
  Perform a server-side (responder) Noise handshake over a socket.

  This handles the responding side of the Noise_IK handshake:
  1. Receive first message
  2. Generate ephemeral key
  3. Send response
  4. Extract transport ciphers

  Returns `{:ok, transport, client_pubkey}` where:
  - transport: `Burrow.Noise.Transport` for encrypted communication
  - client_pubkey: The client's static public key (for identification)
  """
  @spec server_handshake(:gen_tcp.socket() | :ssl.sslsocket(), Keys.keypair()) ::
          {:ok, Transport.t(), binary()} | {:error, term()}
  def server_handshake(socket, server_keypair) do
    with {:ok, hs} <- Handshake.new_responder(server_keypair),
         {:ok, msg1} <- socket_recv(socket),
         {:ok, _payload, hs} <- Handshake.read_message(hs, msg1),
         {:ok, msg2, hs} <- Handshake.write_message(hs, <<>>),
         :ok <- socket_send(socket, msg2),
         true <- Handshake.complete?(hs),
         {:ok, client_pubkey} <- Handshake.remote_static(hs) do
      {:ok, transport} = Transport.new(socket, hs)
      {:ok, transport, client_pubkey}
    else
      false -> {:error, :handshake_incomplete}
      {:error, _} = error -> error
    end
  end

  @doc """
  Encrypt a frame for transmission.

  Used when integrating Noise with the existing protocol.
  """
  @spec encrypt_frame(Transport.t(), binary()) :: {:ok, binary(), Transport.t()} | {:error, term()}
  defdelegate encrypt_frame(transport, plaintext), to: Transport, as: :encrypt

  @doc """
  Decrypt a received frame.
  """
  @spec decrypt_frame(Transport.t(), binary()) :: {:ok, binary(), Transport.t()} | {:error, term()}
  defdelegate decrypt_frame(transport, ciphertext), to: Transport, as: :decrypt

  @doc """
  Send encrypted data.
  """
  @spec send(Transport.t(), binary()) :: {:ok, Transport.t()} | {:error, term()}
  defdelegate send(transport, data), to: Transport

  @doc """
  Receive and decrypt data.
  """
  @spec recv(Transport.t()) :: {:ok, binary(), Transport.t()} | {:error, term()}
  defdelegate recv(transport), to: Transport

  @doc """
  Receive with timeout.
  """
  @spec recv(Transport.t(), timeout()) :: {:ok, binary(), Transport.t()} | {:error, term()}
  defdelegate recv(transport, timeout), to: Transport

  @doc """
  Process incoming async data for decryption.
  """
  @spec process_data(Transport.t(), binary()) :: {:ok, [binary()], Transport.t()} | {:error, term()}
  defdelegate process_data(transport, data), to: Transport

  @doc """
  Close the encrypted transport.
  """
  @spec close(Transport.t()) :: :ok
  defdelegate close(transport), to: Transport

  # Private socket helpers for handshake

  defp socket_send(socket, data) do
    # Prefix message with length for handshake
    length = byte_size(data)
    message = <<length::16, data::binary>>

    case detect_transport(socket) do
      :ssl -> :ssl.send(socket, message)
      :gen_tcp -> :gen_tcp.send(socket, message)
    end
  end

  defp socket_recv(socket, timeout \\ 10_000) do
    # Read length-prefixed handshake message
    case recv_exact(socket, 2, timeout) do
      {:ok, <<length::16>>} ->
        recv_exact(socket, length, timeout)

      {:error, _} = error ->
        error
    end
  end

  defp recv_exact(socket, length, timeout) do
    case detect_transport(socket) do
      :ssl -> :ssl.recv(socket, length, timeout)
      :gen_tcp -> :gen_tcp.recv(socket, length, timeout)
    end
  end

  defp detect_transport({:sslsocket, _, _}), do: :ssl
  defp detect_transport(_), do: :gen_tcp
end
