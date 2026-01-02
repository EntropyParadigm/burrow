defmodule Burrow.Client do
  @moduledoc """
  Burrow tunnel client - connects to a relay server and establishes tunnels.

  ## Usage

      {:ok, client} = Burrow.Client.start_link(
        host: "relay.example.com",
        port: 4000,
        token: "secret",
        tunnels: [
          [name: "web", local: 8080, remote: 80],
          [name: "gopher", local: 70, remote: 70]
        ]
      )

  ## Options

  - `:host` - Server hostname (required)
  - `:port` - Server port (required)
  - `:token` - Authentication token (required)
  - `:tunnels` - List of tunnel configurations (required)
  - `:reconnect` - Auto-reconnect on disconnect (default: `true`)
  - `:reconnect_interval` - Ms between reconnect attempts (default: `5000`)
  - `:heartbeat_interval` - Ms between keepalive pings (default: `30000`)
  """

  use GenServer
  require Logger

  alias Burrow.Protocol

  @default_reconnect_interval 5_000
  @default_heartbeat_interval 30_000

  defstruct [
    :host,
    :port,
    :token,
    :socket,
    :tunnels,
    :tunnel_configs,
    :client_id,
    :reconnect,
    :reconnect_interval,
    :heartbeat_interval,
    :heartbeat_ref,
    :buffer,
    :connected_at,
    :next_tunnel_id,
    :next_connection_id,
    :local_connections,
    :tls,
    :tls_opts,
    :transport
  ]

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Get the current status of the client.
  """
  def status(client) do
    GenServer.call(client, :status)
  end

  @doc """
  Add a new tunnel dynamically.
  """
  def add_tunnel(client, tunnel_config) do
    GenServer.call(client, {:add_tunnel, tunnel_config})
  end

  @doc """
  Remove a tunnel by name.
  """
  def remove_tunnel(client, name) do
    GenServer.call(client, {:remove_tunnel, name})
  end

  @doc """
  Disconnect from the server.
  """
  def disconnect(client) do
    GenServer.call(client, :disconnect)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    host = Keyword.fetch!(opts, :host)
    port = Keyword.fetch!(opts, :port)
    token = Keyword.fetch!(opts, :token)
    tunnel_configs = Keyword.fetch!(opts, :tunnels)
    reconnect = Keyword.get(opts, :reconnect, true)
    reconnect_interval = Keyword.get(opts, :reconnect_interval, @default_reconnect_interval)
    heartbeat_interval = Keyword.get(opts, :heartbeat_interval, @default_heartbeat_interval)

    # TLS configuration
    tls = Keyword.get(opts, :tls, false)
    tls_opts = build_tls_opts(opts)

    state = %__MODULE__{
      host: host,
      port: port,
      token: token,
      socket: nil,
      tunnels: %{},
      tunnel_configs: normalize_tunnel_configs(tunnel_configs),
      client_id: nil,
      reconnect: reconnect,
      reconnect_interval: reconnect_interval,
      heartbeat_interval: heartbeat_interval,
      heartbeat_ref: nil,
      buffer: <<>>,
      connected_at: nil,
      next_tunnel_id: 1,
      next_connection_id: 1,
      local_connections: %{},
      tls: tls,
      tls_opts: tls_opts,
      transport: if(tls, do: :ssl, else: :gen_tcp)
    }

    # Connect immediately
    send(self(), :connect)

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      connected: state.socket != nil,
      client_id: state.client_id,
      server: "#{state.host}:#{state.port}",
      tunnels: Map.values(state.tunnels),
      uptime: calculate_uptime(state.connected_at),
      local_connections: map_size(state.local_connections)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call({:add_tunnel, config}, _from, state) do
    config = normalize_tunnel_config(config, state.next_tunnel_id)

    if state.socket do
      frame = Protocol.encode_tunnel_req(
        config.id,
        config.name,
        config.remote,
        config.protocol
      )

      send_data(state.transport, state.socket, frame)

      new_configs = [config | state.tunnel_configs]
      {:reply, :ok, %{state | tunnel_configs: new_configs, next_tunnel_id: state.next_tunnel_id + 1}}
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  @impl true
  def handle_call({:remove_tunnel, name}, _from, state) do
    case Enum.find(state.tunnels, fn {_id, t} -> t.name == name end) do
      {tunnel_id, _tunnel} ->
        # Send close for all connections on this tunnel
        frame = Protocol.encode_close(tunnel_id, 0)
        if state.socket, do: send_data(state.transport, state.socket, frame)

        new_tunnels = Map.delete(state.tunnels, tunnel_id)
        new_configs = Enum.reject(state.tunnel_configs, &(&1.name == name))

        {:reply, :ok, %{state | tunnels: new_tunnels, tunnel_configs: new_configs}}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:disconnect, _from, state) do
    state = do_disconnect(state, :requested)
    {:reply, :ok, %{state | reconnect: false}}
  end

  @impl true
  def handle_info(:connect, state) do
    case do_connect(state) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning("[Burrow.Client] Connection failed: #{inspect(reason)}")

        if state.reconnect do
          Process.send_after(self(), :connect, state.reconnect_interval)
        end

        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:heartbeat, state) do
    if state.socket do
      frame = Protocol.encode_ping()
      send_data(state.transport, state.socket, frame)
    end

    ref = Process.send_after(self(), :heartbeat, state.heartbeat_interval)
    {:noreply, %{state | heartbeat_ref: ref}}
  end

  # Handle TCP data
  @impl true
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    state = process_data(state, data)
    {:noreply, state}
  end

  # Handle SSL data
  @impl true
  def handle_info({:ssl, socket, data}, %{socket: socket} = state) do
    state = process_data(state, data)
    {:noreply, state}
  end

  # Handle TCP closed
  @impl true
  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    Logger.warning("[Burrow.Client] Connection closed")
    state = do_disconnect(state, :closed)

    if state.reconnect do
      Process.send_after(self(), :connect, state.reconnect_interval)
    end

    {:noreply, state}
  end

  # Handle SSL closed
  @impl true
  def handle_info({:ssl_closed, socket}, %{socket: socket} = state) do
    Logger.warning("[Burrow.Client] TLS connection closed")
    state = do_disconnect(state, :closed)

    if state.reconnect do
      Process.send_after(self(), :connect, state.reconnect_interval)
    end

    {:noreply, state}
  end

  # Handle TCP error
  @impl true
  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    Logger.error("[Burrow.Client] Connection error: #{inspect(reason)}")
    state = do_disconnect(state, reason)

    if state.reconnect do
      Process.send_after(self(), :connect, state.reconnect_interval)
    end

    {:noreply, state}
  end

  # Handle SSL error
  @impl true
  def handle_info({:ssl_error, socket, reason}, %{socket: socket} = state) do
    Logger.error("[Burrow.Client] TLS connection error: #{inspect(reason)}")
    state = do_disconnect(state, reason)

    if state.reconnect do
      Process.send_after(self(), :connect, state.reconnect_interval)
    end

    {:noreply, state}
  end

  # Handle data from local service connections
  @impl true
  def handle_info({:tcp, local_socket, data}, state) do
    case find_connection(state, local_socket) do
      {tunnel_id, connection_id} ->
        frame = Protocol.encode_data(tunnel_id, connection_id, data)
        if state.socket, do: send_data(state.transport, state.socket, frame)
        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:tcp_closed, local_socket}, state) do
    case find_connection(state, local_socket) do
      {tunnel_id, connection_id} ->
        frame = Protocol.encode_close(tunnel_id, connection_id)
        if state.socket, do: send_data(state.transport, state.socket, frame)

        new_connections = Map.delete(state.local_connections, {tunnel_id, connection_id})
        {:noreply, %{state | local_connections: new_connections}}

      nil ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp do_connect(state) do
    host = String.to_charlist(state.host)
    base_opts = [:binary, {:active, true}, {:packet, :raw}]

    connect_result =
      if state.tls do
        tls_opts = base_opts ++ state.tls_opts
        Logger.info("[Burrow.Client] Connecting to #{state.host}:#{state.port} (TLS)...")
        :ssl.connect(host, state.port, tls_opts, 10_000)
      else
        Logger.info("[Burrow.Client] Connecting to #{state.host}:#{state.port}...")
        :gen_tcp.connect(host, state.port, base_opts, 10_000)
      end

    case connect_result do
      {:ok, socket} ->
        transport = state.transport
        Logger.info("[Burrow.Client] Connected to #{state.host}:#{state.port}#{if state.tls, do: " (TLS)", else: ""}")

        # Send authentication
        frame = Protocol.encode_auth(state.token)
        send_data(transport, socket, frame)

        # Start heartbeat
        ref = Process.send_after(self(), :heartbeat, state.heartbeat_interval)

        {:ok, %{state |
          socket: socket,
          heartbeat_ref: ref,
          buffer: <<>>,
          connected_at: DateTime.utc_now()
        }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_disconnect(state, _reason) do
    if state.socket do
      close_socket(state.transport, state.socket)
    end

    if state.heartbeat_ref do
      Process.cancel_timer(state.heartbeat_ref)
    end

    # Close all local connections
    Enum.each(state.local_connections, fn {_key, socket} ->
      :gen_tcp.close(socket)
    end)

    emit_telemetry(:disconnected, state)

    %{state |
      socket: nil,
      heartbeat_ref: nil,
      tunnels: %{},
      local_connections: %{},
      connected_at: nil,
      client_id: nil
    }
  end

  defp process_data(state, data) do
    buffer = state.buffer <> data
    process_frames(state, buffer)
  end

  defp process_frames(state, buffer) do
    case Protocol.decode(buffer) do
      {:ok, type, payload, rest} ->
        state = handle_frame(state, type, payload)
        process_frames(state, rest)

      {:incomplete, remaining} ->
        %{state | buffer: remaining}

      {:error, reason} ->
        Logger.error("[Burrow.Client] Protocol error: #{inspect(reason)}")
        %{state | buffer: <<>>}
    end
  end

  defp handle_frame(state, :auth_ok, %{client_id: client_id}) do
    Logger.info("[Burrow.Client] Authenticated as #{client_id}")
    emit_telemetry(:connected, state)

    # Request all configured tunnels
    Enum.each(state.tunnel_configs, fn config ->
      frame = Protocol.encode_tunnel_req(config.id, config.name, config.remote, config.protocol)
      send_data(state.transport, state.socket, frame)
    end)

    %{state | client_id: client_id}
  end

  defp handle_frame(state, :auth_fail, %{reason: reason}) do
    Logger.error("[Burrow.Client] Authentication failed: #{reason}")
    do_disconnect(state, {:auth_failed, reason})
  end

  defp handle_frame(state, :tunnel_ok, %{tunnel_id: tid, port: port}) do
    case Enum.find(state.tunnel_configs, &(&1.id == tid)) do
      nil ->
        state

      config ->
        Logger.info("[Burrow.Client] Tunnel '#{config.name}' established on remote port #{port}")

        tunnel = %{
          id: tid,
          name: config.name,
          local: config.local,
          remote: port,
          protocol: config.protocol
        }

        emit_telemetry(:tunnel_opened, tunnel)
        %{state | tunnels: Map.put(state.tunnels, tid, tunnel)}
    end
  end

  defp handle_frame(state, :tunnel_fail, %{tunnel_id: tid, reason: reason}) do
    case Enum.find(state.tunnel_configs, &(&1.id == tid)) do
      nil ->
        state

      config ->
        Logger.error("[Burrow.Client] Tunnel '#{config.name}' failed: #{reason}")
        state
    end
  end

  defp handle_frame(state, :data, %{tunnel_id: tid, connection_id: cid, data: data}) do
    case Map.get(state.local_connections, {tid, cid}) do
      nil ->
        # New connection - open local socket (always plain TCP for local)
        case Map.get(state.tunnels, tid) do
          nil ->
            state

          tunnel ->
            case :gen_tcp.connect(~c"127.0.0.1", tunnel.local, [:binary, active: true], 5000) do
              {:ok, local_socket} ->
                :gen_tcp.send(local_socket, data)
                new_connections = Map.put(state.local_connections, {tid, cid}, local_socket)
                %{state | local_connections: new_connections}

              {:error, _reason} ->
                # Send close back to server
                frame = Protocol.encode_close(tid, cid)
                send_data(state.transport, state.socket, frame)
                state
            end
        end

      local_socket ->
        # Local connections are always plain TCP
        :gen_tcp.send(local_socket, data)
        emit_telemetry(:bytes_received, %{tunnel_id: tid, bytes: byte_size(data)})
        state
    end
  end

  defp handle_frame(state, :pong, %{timestamp: ts}) do
    latency = System.monotonic_time(:millisecond) - ts
    Logger.debug("[Burrow.Client] Pong received, latency: #{latency}ms")
    state
  end

  defp handle_frame(state, :ping, %{timestamp: ts}) do
    frame = Protocol.encode_pong(ts)
    if state.socket, do: send_data(state.transport, state.socket, frame)
    state
  end

  defp handle_frame(state, :close, %{tunnel_id: tid, connection_id: cid}) do
    case Map.get(state.local_connections, {tid, cid}) do
      nil ->
        state

      local_socket ->
        :gen_tcp.close(local_socket)
        new_connections = Map.delete(state.local_connections, {tid, cid})
        %{state | local_connections: new_connections}
    end
  end

  defp handle_frame(state, :shutdown, %{reason: reason}) do
    Logger.warning("[Burrow.Client] Server shutdown: #{reason}")
    do_disconnect(state, {:server_shutdown, reason})
  end

  defp handle_frame(state, type, payload) do
    Logger.warning("[Burrow.Client] Unknown frame: #{inspect(type)} - #{inspect(payload)}")
    state
  end

  defp normalize_tunnel_configs(configs) do
    configs
    |> Enum.with_index(1)
    |> Enum.map(fn {config, idx} -> normalize_tunnel_config(config, idx) end)
  end

  defp normalize_tunnel_config(config, id) do
    %{
      id: id,
      name: Keyword.get(config, :name, "tunnel_#{id}"),
      local: Keyword.fetch!(config, :local),
      remote: Keyword.fetch!(config, :remote),
      protocol: Keyword.get(config, :protocol, :tcp)
    }
  end

  defp find_connection(state, socket) do
    Enum.find_value(state.local_connections, fn
      {key, ^socket} -> key
      _ -> nil
    end)
  end

  defp calculate_uptime(nil), do: 0
  defp calculate_uptime(connected_at) do
    DateTime.diff(DateTime.utc_now(), connected_at, :second)
  end

  defp emit_telemetry(event, data) do
    :telemetry.execute([:burrow, :client, event], %{}, data)
  end

  # Transport helper functions

  defp send_data(:ssl, socket, data), do: :ssl.send(socket, data)
  defp send_data(:gen_tcp, socket, data), do: :gen_tcp.send(socket, data)
  defp send_data(nil, socket, data), do: :gen_tcp.send(socket, data)

  defp close_socket(:ssl, socket), do: :ssl.close(socket)
  defp close_socket(:gen_tcp, socket), do: :gen_tcp.close(socket)
  defp close_socket(nil, socket), do: :gen_tcp.close(socket)

  defp build_tls_opts(opts) do
    tls_opts = Keyword.get(opts, :tls_opts, [])

    base_opts = [
      verify: :verify_peer,
      depth: 3,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]

    # Allow overriding verification (e.g., for self-signed certs)
    case Keyword.get(opts, :tls_verify) do
      :verify_none ->
        Keyword.merge(base_opts, [verify: :verify_none]) ++ tls_opts

      _ ->
        Keyword.merge(base_opts, tls_opts)
    end
  end
end
