defmodule Burrow.Server.ControlHandler do
  @moduledoc """
  Handles control connections from Burrow clients.
  """

  use ThousandIsland.Handler
  require Logger

  alias Burrow.Protocol

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    # Get client IP for filtering and rate limiting
    client_ip = get_client_ip(socket)

    # Ensure state is a map (handler_options might be a list or empty)
    base_state = if is_map(state), do: state, else: %{}

    # Check IP allowlist/blocklist first
    unless Burrow.IPFilter.allowed?(client_ip) do
      Logger.warning("[ControlHandler] Connection rejected (IP filtered): #{client_ip}")
      {:close, :ip_filtered}
    else
      # Check rate limit before allowing connection
      case Burrow.RateLimiter.check_connection(client_ip) do
        :ok ->
          Burrow.RateLimiter.record_connection(client_ip)
          {:continue, Map.merge(base_state, %{
            socket: socket,
            buffer: <<>>,
            authenticated: false,
            client_id: nil,
            client_ip: client_ip,
            next_connection_id: 1,
            remote_connections: %{}
          })}

        {:error, :rate_limited} ->
          Logger.warning("[ControlHandler] Connection rejected (rate limited): #{client_ip}")
          {:close, :rate_limited}
      end
    end
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    buffer = state.buffer <> data
    process_frames(socket, buffer, state)
  end

  @impl ThousandIsland.Handler
  def handle_close(_socket, state) do
    if state.client_id do
      Burrow.Server.client_disconnected(state.client_id)
      Burrow.RateLimiter.clear_client(state.client_id)
    end

    :ok
  end

  @impl ThousandIsland.Handler
  def handle_shutdown(_socket, state) do
    if state.client_id do
      Burrow.Server.client_disconnected(state.client_id)
      Burrow.RateLimiter.clear_client(state.client_id)
    end

    :ok
  end

  # Write directly to file for debugging
  defp log_to_file(msg) do
    File.write!("/tmp/burrow_debug.log", "#{msg}\n", [:append])
  end

  # Handle messages from public listeners
  # ThousandIsland uses GenServer callbacks for handle_info
  # Must return {:noreply, {socket, state}, timeout}
  @impl GenServer
  def handle_info({:tunnel_data, tunnel_id, connection_id, data}, {socket, state}) do
    log_to_file("[ControlHandler] Received tunnel_data: tunnel=#{tunnel_id}, conn=#{connection_id}, #{byte_size(data)} bytes")
    frame = Protocol.encode_data(tunnel_id, connection_id, data)
    case ThousandIsland.Socket.send(socket, frame) do
      :ok -> log_to_file("[ControlHandler] Sent frame to client")
      {:error, reason} -> log_to_file("[ControlHandler] Send FAILED: #{inspect(reason)}")
    end
    {:noreply, {socket, state}, socket.read_timeout}
  end

  @impl GenServer
  def handle_info({:tunnel_closed, tunnel_id, connection_id}, {socket, state}) do
    log_to_file("[ControlHandler] tunnel_closed: tunnel=#{tunnel_id}, conn=#{connection_id}")
    frame = Protocol.encode_close(tunnel_id, connection_id)
    ThousandIsland.Socket.send(socket, frame)

    new_connections = Map.delete(state.remote_connections, {tunnel_id, connection_id})
    {:noreply, {socket, %{state | remote_connections: new_connections}}, socket.read_timeout}
  end

  @impl GenServer
  def handle_info({:new_connection, tunnel_id, connection_id, handler_pid}, {socket, state}) do
    log_to_file("[ControlHandler] new_connection: tunnel=#{tunnel_id}, conn=#{connection_id}, handler=#{inspect(handler_pid)}")
    new_connections = Map.put(state.remote_connections, {tunnel_id, connection_id}, handler_pid)
    {:noreply, {socket, %{state | remote_connections: new_connections}}, socket.read_timeout}
  end

  @impl GenServer
  def handle_info(msg, {socket, state}) do
    log_to_file("[ControlHandler] Unknown message: #{inspect(msg)}")
    {:noreply, {socket, state}, socket.read_timeout}
  end

  # Private functions

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
        Logger.error("[ControlHandler] Protocol error: #{inspect(reason)}")
        {:continue, %{state | buffer: <<>>}}
    end
  end

  defp handle_frame(:auth, %{token: token}, socket, state) do
    if verify_token(token) do
      client_id = generate_client_id()
      frame = Protocol.encode_auth_ok(client_id)
      ThousandIsland.Socket.send(socket, frame)

      Burrow.Server.client_authenticated(self(), client_id)

      {:ok, %{state | authenticated: true, client_id: client_id}}
    else
      frame = Protocol.encode_auth_fail("invalid_token")
      ThousandIsland.Socket.send(socket, frame)
      {:close, :auth_failed}
    end
  end

  defp handle_frame(:tunnel_req, payload, socket, state) do
    if state.authenticated do
      %{tunnel_id: tunnel_id, name: name, remote_port: remote_port, protocol: protocol} = payload

      # Check rate limit for tunnels
      case Burrow.RateLimiter.check_tunnel(state.client_id) do
        :ok ->
          case Burrow.Server.register_tunnel(state.client_id, tunnel_id, remote_port, name, protocol) do
            {:ok, actual_port} ->
              Burrow.RateLimiter.record_tunnel(state.client_id)
              frame = Protocol.encode_tunnel_ok(tunnel_id, actual_port)
              ThousandIsland.Socket.send(socket, frame)
              {:ok, state}

            {:error, reason} ->
              frame = Protocol.encode_tunnel_fail(tunnel_id, to_string(reason))
              ThousandIsland.Socket.send(socket, frame)
              {:ok, state}
          end

        {:error, :max_tunnels} ->
          frame = Protocol.encode_tunnel_fail(tunnel_id, "max_tunnels_exceeded")
          ThousandIsland.Socket.send(socket, frame)
          {:ok, state}
      end
    else
      {:close, :not_authenticated}
    end
  end

  defp handle_frame(:data, %{tunnel_id: tid, connection_id: cid, data: data}, _socket, state) do
    log_to_file("[ControlHandler] handle_frame(:data) from client: tunnel=#{tid}, conn=#{cid}, #{byte_size(data)} bytes")
    case Map.get(state.remote_connections, {tid, cid}) do
      nil ->
        # Unknown connection
        log_to_file("[ControlHandler] ERROR: Unknown connection {#{tid}, #{cid}}")
        {:ok, state}

      handler_pid ->
        log_to_file("[ControlHandler] Forwarding to handler #{inspect(handler_pid)}")
        send(handler_pid, {:client_data, data})
        {:ok, state}
    end
  end

  defp handle_frame(:ping, %{timestamp: ts}, socket, state) do
    frame = Protocol.encode_pong(ts)
    ThousandIsland.Socket.send(socket, frame)
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
    Logger.warning("[ControlHandler] Unknown frame: #{inspect(type)} - #{inspect(payload)}")
    {:ok, state}
  end

  defp verify_token(provided_token) do
    # Check for hashed token first, then plain token
    case Application.get_env(:burrow, :server_token_hash) do
      nil ->
        # Plain token comparison
        expected = Application.get_env(:burrow, :server_token, "default_token")
        # Use constant-time comparison for security
        secure_compare(provided_token, expected)

      hash ->
        # Verify against Argon2 hash
        Burrow.Token.verify?(provided_token, hash)
    end
  end

  # Constant-time string comparison to prevent timing attacks
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
end
