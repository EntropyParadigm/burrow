defmodule Burrow.Server.NoiseHandler do
  @moduledoc """
  ThousandIsland handler for Noise-encrypted control connections.

  This handler wraps the normal ControlHandler functionality with
  Noise protocol encryption. It:

  1. Performs Noise_IK handshake on connection
  2. Decrypts all incoming data before processing
  3. Encrypts all outgoing data before sending

  The Burrow protocol frames are transmitted encrypted, providing
  end-to-end encryption including the authentication token.
  """

  use ThousandIsland.Handler
  require Logger

  alias Burrow.Protocol
  alias Burrow.Noise
  alias Burrow.Noise.Transport

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    # Get server keypair from handler options
    opts = get_handler_options(state)
    keypair = opts[:noise_keypair]

    unless keypair do
      Logger.error("[NoiseHandler] No Noise keypair configured")
      {:close, :no_keypair}
    else
      # Get raw socket for handshake by accessing internal socket field
      raw_socket = socket.socket

      # Perform Noise handshake
      case perform_handshake(raw_socket, keypair) do
        {:ok, transport, client_pubkey} ->
          Logger.info("[NoiseHandler] Noise handshake complete, client: #{Base.encode64(client_pubkey)}")

          # Get client IP for filtering
          client_ip = get_client_ip(socket)

          # Check IP filter
          unless Burrow.IPFilter.allowed?(client_ip) do
            Logger.warning("[NoiseHandler] Connection rejected (IP filtered): #{client_ip}")
            Transport.close(transport)
            {:close, :ip_filtered}
          else
            # Check rate limit
            case Burrow.RateLimiter.check_connection(client_ip) do
              :ok ->
                Burrow.RateLimiter.record_connection(client_ip)

                base_state = if is_map(state), do: state, else: %{}

                {:continue, Map.merge(base_state, %{
                  socket: socket,
                  transport: transport,
                  client_pubkey: client_pubkey,
                  buffer: <<>>,
                  authenticated: false,
                  client_id: nil,
                  client_ip: client_ip,
                  next_connection_id: 1,
                  remote_connections: %{}
                })}

              {:error, :rate_limited} ->
                Logger.warning("[NoiseHandler] Connection rejected (rate limited): #{client_ip}")
                Transport.close(transport)
                {:close, :rate_limited}
            end
          end

        {:error, reason} ->
          Logger.warning("[NoiseHandler] Noise handshake failed: #{inspect(reason)}")
          {:close, {:handshake_failed, reason}}
      end
    end
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    # Decrypt incoming data
    case Transport.process_data(state.transport, data) do
      {:ok, messages, new_transport} ->
        state = %{state | transport: new_transport}

        # Process each decrypted message
        Enum.reduce_while(messages, {:continue, state}, fn message, {_, acc_state} ->
          buffer = acc_state.buffer <> message

          case process_frames(socket, buffer, acc_state) do
            {:continue, new_state} ->
              {:cont, {:continue, new_state}}

            {:close, reason} ->
              {:halt, {:close, reason}}
          end
        end)

      {:error, reason} ->
        Logger.error("[NoiseHandler] Decryption error: #{inspect(reason)}")
        {:close, {:decrypt_error, reason}}
    end
  end

  @impl ThousandIsland.Handler
  def handle_close(_socket, state) when is_map(state) do
    if state[:client_id] do
      Burrow.Server.client_disconnected(state.client_id)
      Burrow.RateLimiter.clear_client(state.client_id)
    end

    if state[:transport] do
      Transport.close(state.transport)
    end

    :ok
  end

  # Handle case where state is not a map (e.g., handshake failed)
  def handle_close(_socket, _state), do: :ok

  @impl ThousandIsland.Handler
  def handle_shutdown(_socket, state) when is_map(state) do
    if state[:client_id] do
      Burrow.Server.client_disconnected(state.client_id)
      Burrow.RateLimiter.clear_client(state.client_id)
    end

    if state[:transport] do
      Transport.close(state.transport)
    end

    :ok
  end

  # Handle case where state is not a map (e.g., handshake failed)
  def handle_shutdown(_socket, _state), do: :ok

  # Handle messages from public listeners
  @impl GenServer
  def handle_info({:tunnel_data, tunnel_id, connection_id, data}, {socket, state}) do
    frame = Protocol.encode_data(tunnel_id, connection_id, data)
    send_encrypted(socket, state.transport, frame)
    {:noreply, {socket, state}, socket.read_timeout}
  end

  @impl GenServer
  def handle_info({:tunnel_closed, tunnel_id, connection_id}, {socket, state}) do
    frame = Protocol.encode_close(tunnel_id, connection_id)
    send_encrypted(socket, state.transport, frame)

    new_connections = Map.delete(state.remote_connections, {tunnel_id, connection_id})
    {:noreply, {socket, %{state | remote_connections: new_connections}}, socket.read_timeout}
  end

  @impl GenServer
  def handle_info({:new_connection, tunnel_id, connection_id, handler_pid}, {socket, state}) do
    new_connections = Map.put(state.remote_connections, {tunnel_id, connection_id}, handler_pid)
    {:noreply, {socket, %{state | remote_connections: new_connections}}, socket.read_timeout}
  end

  @impl GenServer
  def handle_info(_msg, {socket, state}) do
    {:noreply, {socket, state}, socket.read_timeout}
  end

  # Private functions

  defp perform_handshake(raw_socket, keypair) do
    # Set socket to blocking mode for handshake
    :inet.setopts(raw_socket, active: false)

    result = Noise.server_handshake(raw_socket, keypair)

    # Restore active mode after handshake
    :inet.setopts(raw_socket, active: true)

    result
  end

  defp send_encrypted(socket, transport, frame) do
    case Transport.encrypt(transport, frame) do
      {:ok, encrypted, _new_transport} ->
        ThousandIsland.Socket.send(socket, encrypted)

      {:error, reason} ->
        Logger.error("[NoiseHandler] Encryption failed: #{inspect(reason)}")
    end
  end

  defp process_frames(socket, buffer, state) do
    case Protocol.decode(buffer) do
      {:ok, type, payload, rest} ->
        case handle_frame(type, payload, socket, state) do
          {:ok, new_state} ->
            process_frames(socket, rest, new_state)

          {:close, reason} ->
            {:close, reason}
        end

      {:incomplete, remaining} ->
        {:continue, %{state | buffer: remaining}}

      {:error, reason} ->
        Logger.error("[NoiseHandler] Protocol error: #{inspect(reason)}")
        {:continue, %{state | buffer: <<>>}}
    end
  end

  defp handle_frame(:auth, %{token: token}, socket, state) do
    if verify_token(token) do
      client_id = generate_client_id()
      frame = Protocol.encode_auth_ok(client_id)
      send_encrypted(socket, state.transport, frame)

      Burrow.Server.client_authenticated(self(), client_id)

      {:ok, %{state | authenticated: true, client_id: client_id}}
    else
      frame = Protocol.encode_auth_fail("invalid_token")
      send_encrypted(socket, state.transport, frame)
      {:close, :auth_failed}
    end
  end

  defp handle_frame(:tunnel_req, payload, socket, state) do
    if state.authenticated do
      %{tunnel_id: tunnel_id, name: name, remote_port: remote_port, protocol: protocol} = payload

      case Burrow.RateLimiter.check_tunnel(state.client_id) do
        :ok ->
          case Burrow.Server.register_tunnel(state.client_id, tunnel_id, remote_port, name, protocol) do
            {:ok, actual_port} ->
              Burrow.RateLimiter.record_tunnel(state.client_id)
              frame = Protocol.encode_tunnel_ok(tunnel_id, actual_port)
              send_encrypted(socket, state.transport, frame)
              {:ok, state}

            {:error, reason} ->
              frame = Protocol.encode_tunnel_fail(tunnel_id, to_string(reason))
              send_encrypted(socket, state.transport, frame)
              {:ok, state}
          end

        {:error, :max_tunnels} ->
          frame = Protocol.encode_tunnel_fail(tunnel_id, "max_tunnels_exceeded")
          send_encrypted(socket, state.transport, frame)
          {:ok, state}
      end
    else
      {:close, :not_authenticated}
    end
  end

  defp handle_frame(:data, %{tunnel_id: tid, connection_id: cid, data: data}, _socket, state) do
    case Map.get(state.remote_connections, {tid, cid}) do
      nil ->
        {:ok, state}

      handler_pid ->
        send(handler_pid, {:client_data, data})
        {:ok, state}
    end
  end

  defp handle_frame(:ping, %{timestamp: ts}, socket, state) do
    frame = Protocol.encode_pong(ts)
    send_encrypted(socket, state.transport, frame)
    {:ok, state}
  end

  defp handle_frame(:pong, _payload, _socket, state) do
    {:ok, state}
  end

  defp handle_frame(:close, %{tunnel_id: tid, connection_id: cid}, _socket, state) do
    case Map.get(state.remote_connections, {tid, cid}) do
      nil ->
        {:ok, state}

      handler_pid ->
        send(handler_pid, :close)
        new_connections = Map.delete(state.remote_connections, {tid, cid})
        {:ok, %{state | remote_connections: new_connections}}
    end
  end

  defp handle_frame(:shutdown, _payload, _socket, _state) do
    {:close, :client_shutdown}
  end

  defp handle_frame(type, payload, _socket, state) do
    Logger.warning("[NoiseHandler] Unknown frame: #{inspect(type)} - #{inspect(payload)}")
    {:ok, state}
  end

  defp verify_token(provided_token) do
    case Application.get_env(:burrow, :server_token_hash) do
      nil ->
        expected = Application.get_env(:burrow, :server_token, "default_token")
        secure_compare(provided_token, expected)

      hash ->
        Burrow.Token.verify?(provided_token, hash)
    end
  end

  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end

  defp secure_compare(_, _), do: false

  defp generate_client_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp get_client_ip(socket) do
    case ThousandIsland.Socket.peername(socket) do
      {:ok, {ip, _port}} -> format_ip(ip)
      _ -> "unknown"
    end
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({a, b, c, d, e, f, g, h}), do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  defp format_ip(ip), do: inspect(ip)

  defp get_handler_options(state) when is_list(state), do: state
  defp get_handler_options(state) when is_map(state), do: Map.get(state, :handler_options, [])
end
