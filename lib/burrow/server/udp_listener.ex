defmodule Burrow.Server.UDPListener do
  @moduledoc """
  GenServer that handles public UDP connections for a tunnel.

  Unlike TCP connections which are handled per-connection by ThousandIsland,
  UDP is connectionless, so we use a single GenServer to manage all UDP
  traffic for a given port.

  ## Session Management

  Since UDP has no connection state, we create virtual "sessions" based on
  the source address (IP + port). Each unique source gets a connection ID
  that persists until the session times out due to inactivity.

  ## State Structure

      %{
        socket: udp_socket,
        port: 53,
        tunnel_id: 1,
        control_pid: pid,
        sessions: %{
          {{192,168,1,100}, 54321} => %{
            connection_id: 42,
            last_activity: timestamp,
            bytes_in: 1024,
            bytes_out: 512
          }
        },
        idle_timeout: 60_000,
        next_connection_id: 43
      }

  """

  use GenServer
  require Logger

  @default_idle_timeout 60_000
  @cleanup_interval 30_000

  defstruct [
    :socket,
    :port,
    :tunnel_id,
    :control_pid,
    :client_id,
    :sessions,
    :idle_timeout,
    :next_connection_id
  ]

  # Client API

  @doc """
  Start a UDP listener for a tunnel.

  Options:
  - `:port` - UDP port to listen on (required)
  - `:tunnel_id` - Tunnel ID for this listener (required)
  - `:control_pid` - PID of the control handler (required)
  - `:client_id` - Client ID (for logging)
  - `:idle_timeout` - Session idle timeout in ms (default: 60000)
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Send data to a specific UDP session.

  Called by the control handler when receiving data from the client.
  """
  def send_data(listener, connection_id, data) do
    GenServer.cast(listener, {:send_data, connection_id, data})
  end

  @doc """
  Get listener stats.
  """
  def stats(listener) do
    GenServer.call(listener, :stats)
  end

  @doc """
  Stop the listener.
  """
  def stop(listener) do
    GenServer.stop(listener)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    port = Keyword.fetch!(opts, :port)
    tunnel_id = Keyword.fetch!(opts, :tunnel_id)
    control_pid = Keyword.fetch!(opts, :control_pid)
    client_id = Keyword.get(opts, :client_id)
    idle_timeout = Keyword.get(opts, :idle_timeout, @default_idle_timeout)

    # Open UDP socket
    case :gen_udp.open(port, [:binary, {:active, true}]) do
      {:ok, socket} ->
        Logger.info("[UDPListener] Listening on UDP port #{port} for tunnel #{tunnel_id}")

        # Schedule periodic cleanup
        schedule_cleanup()

        state = %__MODULE__{
          socket: socket,
          port: port,
          tunnel_id: tunnel_id,
          control_pid: control_pid,
          client_id: client_id,
          sessions: %{},
          idle_timeout: idle_timeout,
          next_connection_id: 1
        }

        {:ok, state}

      {:error, reason} ->
        Logger.error("[UDPListener] Failed to open UDP port #{port}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:send_data, connection_id, data}, state) do
    # Find the session with this connection ID
    case find_session_by_connection_id(state.sessions, connection_id) do
      {address, session} ->
        # Send data to the source address
        {ip, port} = address
        :gen_udp.send(state.socket, ip, port, data)

        # Update session stats
        updated_session = %{session |
          last_activity: System.monotonic_time(:millisecond),
          bytes_out: session.bytes_out + byte_size(data)
        }

        new_sessions = Map.put(state.sessions, address, updated_session)
        {:noreply, %{state | sessions: new_sessions}}

      nil ->
        Logger.warning("[UDPListener] Unknown connection ID #{connection_id}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      port: state.port,
      tunnel_id: state.tunnel_id,
      active_sessions: map_size(state.sessions),
      sessions: Enum.map(state.sessions, fn {{ip, port}, session} ->
        %{
          address: format_address(ip, port),
          connection_id: session.connection_id,
          bytes_in: session.bytes_in,
          bytes_out: session.bytes_out,
          idle_ms: System.monotonic_time(:millisecond) - session.last_activity
        }
      end)
    }

    {:reply, stats, state}
  end

  # Handle incoming UDP data
  @impl true
  def handle_info({:udp, socket, ip, port, data}, %{socket: socket} = state) do
    address = {ip, port}
    now = System.monotonic_time(:millisecond)

    {session, state} = get_or_create_session(state, address, now)

    # Update session activity
    updated_session = %{session |
      last_activity: now,
      bytes_in: session.bytes_in + byte_size(data)
    }

    new_sessions = Map.put(state.sessions, address, updated_session)
    state = %{state | sessions: new_sessions}

    # Forward data to control handler
    send(state.control_pid, {:tunnel_data, state.tunnel_id, session.connection_id, data})

    # Emit telemetry
    :telemetry.execute(
      [:burrow, :tunnel, :bytes_received],
      %{bytes: byte_size(data)},
      %{tunnel_id: state.tunnel_id, protocol: :udp}
    )

    {:noreply, state}
  end

  # Handle cleanup timer
  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - state.idle_timeout

    # Find and remove idle sessions
    {active, expired} =
      Enum.split_with(state.sessions, fn {_addr, session} ->
        session.last_activity >= cutoff
      end)

    # Notify control handler about closed sessions
    Enum.each(expired, fn {_addr, session} ->
      send(state.control_pid, {:tunnel_closed, state.tunnel_id, session.connection_id})
    end)

    if length(expired) > 0 do
      Logger.debug("[UDPListener] Cleaned up #{length(expired)} idle UDP sessions")
    end

    schedule_cleanup()

    {:noreply, %{state | sessions: Map.new(active)}}
  end

  @impl true
  def handle_info({:udp_closed, socket}, %{socket: socket} = state) do
    Logger.warning("[UDPListener] UDP socket closed")
    {:stop, :socket_closed, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.socket do
      :gen_udp.close(state.socket)
    end

    # Notify control handler about all sessions closing
    Enum.each(state.sessions, fn {_addr, session} ->
      send(state.control_pid, {:tunnel_closed, state.tunnel_id, session.connection_id})
    end)

    :ok
  end

  # Private functions

  defp get_or_create_session(state, address, now) do
    case Map.get(state.sessions, address) do
      nil ->
        # Create new session
        session = %{
          connection_id: state.next_connection_id,
          last_activity: now,
          bytes_in: 0,
          bytes_out: 0
        }

        Logger.debug("[UDPListener] New UDP session #{state.next_connection_id} from #{format_address(elem(address, 0), elem(address, 1))}")

        # Notify control handler about new connection
        send(state.control_pid, {:new_connection, state.tunnel_id, session.connection_id, self()})

        state = %{state |
          sessions: Map.put(state.sessions, address, session),
          next_connection_id: state.next_connection_id + 1
        }

        {session, state}

      session ->
        {session, state}
    end
  end

  defp find_session_by_connection_id(sessions, connection_id) do
    Enum.find_value(sessions, fn {address, session} ->
      if session.connection_id == connection_id do
        {address, session}
      end
    end)
  end

  defp format_address(ip, port) when is_tuple(ip) do
    ip_str = ip |> Tuple.to_list() |> Enum.join(".")
    "#{ip_str}:#{port}"
  end

  defp format_address(ip, port), do: "#{inspect(ip)}:#{port}"

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
