defmodule Burrow.Server.PublicHandler do
  @moduledoc """
  Handles public connections on tunnel ports.
  Forwards data between public clients and the tunnel client.
  """

  use ThousandIsland.Handler
  require Logger

  # Write directly to file for debugging
  defp log_to_file(msg) do
    File.write!("/tmp/burrow_debug.log", "#{msg}\n", [:append])
  end

  @impl ThousandIsland.Handler
  def handle_connection(_socket, state) do
    # State might be a keyword list (handler_options) or a map
    # Extract options from the appropriate source
    opts = get_handler_options(state)
    client_id = opts[:client_id]
    tunnel_id = opts[:tunnel_id]
    port = opts[:port] || 0

    Logger.info("[PublicHandler] Connection on port #{port}, tunnel_id=#{inspect(tunnel_id)}, client_id=#{inspect(client_id)}")
    log_to_file("[PublicHandler] Connection on port #{port}, tunnel_id=#{inspect(tunnel_id)}, client_id=#{inspect(client_id)}")

    # Ensure we have a map for state
    base_state = if is_map(state), do: state, else: %{}

    # Get the control handler for this client
    result = Burrow.Server.get_client_for_tunnel(port)
    Logger.info("[PublicHandler] get_client_for_tunnel(#{port}) = #{inspect(result)}")
    log_to_file("[PublicHandler] get_client_for_tunnel(#{port}) = #{inspect(result)}")

    case result do
      {:ok, control_pid, ^tunnel_id} ->
        # Generate connection ID
        connection_id = :erlang.unique_integer([:positive])

        Logger.info("[PublicHandler] Notifying control handler of new connection #{connection_id}")
        log_to_file("[PublicHandler] Notifying control handler, connection=#{connection_id}, control_pid=#{inspect(control_pid)}")

        # Notify control handler of new connection
        send(control_pid, {:new_connection, tunnel_id, connection_id, self()})

        {:continue, Map.merge(base_state, %{
          control_pid: control_pid,
          tunnel_id: tunnel_id,
          connection_id: connection_id,
          client_id: client_id,
          port: port
        })}

      {:ok, _control_pid, other_tunnel_id} ->
        Logger.warning("[PublicHandler] Tunnel ID mismatch: expected #{inspect(tunnel_id)}, got #{inspect(other_tunnel_id)}")
        log_to_file("[PublicHandler] MISMATCH: expected tunnel_id=#{inspect(tunnel_id)}, got #{inspect(other_tunnel_id)}")
        {:close, :tunnel_mismatch}

      other ->
        Logger.warning("[PublicHandler] No client for port #{port}: #{inspect(other)}")
        log_to_file("[PublicHandler] NO CLIENT for port #{port}: #{inspect(other)}")
        {:close, :no_client}
    end
  end

  @impl ThousandIsland.Handler
  def handle_data(data, _socket, state) do
    Logger.info("[PublicHandler] Forwarding #{byte_size(data)} bytes to control handler")
    log_to_file("[PublicHandler] DATA: #{byte_size(data)} bytes, tunnel=#{state.tunnel_id}, conn=#{state.connection_id}")
    # Forward to control handler
    send(state.control_pid, {:tunnel_data, state.tunnel_id, state.connection_id, data})
    {:continue, state}
  end

  @impl ThousandIsland.Handler
  def handle_close(_socket, state) do
    if is_map(state) and Map.has_key?(state, :control_pid) do
      send(state.control_pid, {:tunnel_closed, state.tunnel_id, state.connection_id})
    end
    :ok
  end

  @impl ThousandIsland.Handler
  def handle_shutdown(_socket, state) do
    if is_map(state) and Map.has_key?(state, :control_pid) do
      send(state.control_pid, {:tunnel_closed, state.tunnel_id, state.connection_id})
    end
    :ok
  end

  # Handle data from client (via control handler)
  # ThousandIsland handle_info/2 receives {socket, state} tuple as second arg
  def handle_info({:client_data, data}, {socket, state}) do
    ThousandIsland.Socket.send(socket, data)
    {:continue, state}
  end

  def handle_info(:close, {_socket, _state}) do
    {:close, :client_closed}
  end

  def handle_info(_msg, {_socket, state}) do
    {:continue, state}
  end

  # Extract handler options from state (might be keyword list or map)
  defp get_handler_options(state) when is_list(state), do: state
  defp get_handler_options(state) when is_map(state) do
    Map.get(state, :handler_options, [])
  end
end
