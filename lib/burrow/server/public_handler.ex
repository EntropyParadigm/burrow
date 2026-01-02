defmodule Burrow.Server.PublicHandler do
  @moduledoc """
  Handles public connections on tunnel ports.
  Forwards data between public clients and the tunnel client.
  """

  use ThousandIsland.Handler
  require Logger

  @impl ThousandIsland.Handler
  def handle_connection(_socket, state) do
    # State might be a keyword list (handler_options) or a map
    # Extract options from the appropriate source
    opts = get_handler_options(state)
    client_id = opts[:client_id]
    tunnel_id = opts[:tunnel_id]
    port = opts[:port] || 0

    # Ensure we have a map for state
    base_state = if is_map(state), do: state, else: %{}

    # Get the control handler for this client
    case Burrow.Server.get_client_for_tunnel(port) do
      {:ok, control_pid, ^tunnel_id} ->
        # Generate connection ID
        connection_id = :erlang.unique_integer([:positive])

        # Notify control handler of new connection
        send(control_pid, {:new_connection, tunnel_id, connection_id, self()})

        {:continue, Map.merge(base_state, %{
          control_pid: control_pid,
          tunnel_id: tunnel_id,
          connection_id: connection_id,
          client_id: client_id,
          port: port
        })}

      _ ->
        {:close, :no_client}
    end
  end

  @impl ThousandIsland.Handler
  def handle_data(data, _socket, state) do
    # Forward to control handler
    send(state.control_pid, {:tunnel_data, state.tunnel_id, state.connection_id, data})
    {:continue, state}
  end

  @impl ThousandIsland.Handler
  def handle_close(_socket, state) do
    if Map.has_key?(state, :control_pid) do
      send(state.control_pid, {:tunnel_closed, state.tunnel_id, state.connection_id})
    end
    :ok
  end

  @impl ThousandIsland.Handler
  def handle_shutdown(_socket, state) do
    if Map.has_key?(state, :control_pid) do
      send(state.control_pid, {:tunnel_closed, state.tunnel_id, state.connection_id})
    end
    :ok
  end

  # Handle data from client (via control handler)
  # Note: handle_info/3 is supported by ThousandIsland.Handler but not part of the behaviour spec
  def handle_info({:client_data, data}, socket, state) do
    ThousandIsland.Socket.send(socket, data)
    {:continue, state}
  end

  def handle_info(:close, _socket, _state) do
    {:close, :client_closed}
  end

  def handle_info(_msg, _socket, state) do
    {:continue, state}
  end

  # Extract handler options from state (might be keyword list or map)
  defp get_handler_options(state) when is_list(state), do: state
  defp get_handler_options(state) when is_map(state) do
    Map.get(state, :handler_options, [])
  end
end
