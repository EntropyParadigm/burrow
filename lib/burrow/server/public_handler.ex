defmodule Burrow.Server.PublicHandler do
  @moduledoc """
  Handles public connections on tunnel ports.
  Forwards data between public clients and the tunnel client.
  """

  use ThousandIsland.Handler
  require Logger

  @impl ThousandIsland.Handler
  def handle_connection(_socket, state) do
    client_id = state.handler_options[:client_id]
    tunnel_id = state.handler_options[:tunnel_id]

    # Get the control handler for this client
    case Burrow.Server.get_client_for_tunnel(get_port(state)) do
      {:ok, control_pid, ^tunnel_id} ->
        # Generate connection ID
        connection_id = :erlang.unique_integer([:positive])

        # Notify control handler of new connection
        send(control_pid, {:new_connection, tunnel_id, connection_id, self()})

        {:continue, Map.merge(state, %{
          control_pid: control_pid,
          tunnel_id: tunnel_id,
          connection_id: connection_id,
          client_id: client_id
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
  @impl ThousandIsland.Handler
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

  defp get_port(state) do
    # This is a bit of a hack - we need to get the port we're listening on
    # The handler_options should contain it
    state.handler_options[:port] || 0
  end
end
