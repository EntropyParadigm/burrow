defmodule Burrow.Server do
  @moduledoc """
  Burrow tunnel server - accepts client connections and manages tunnels.

  ## Usage

      {:ok, server} = Burrow.Server.start_link(
        port: 4000,
        token: "secret"
      )

  ## Options

  - `:port` - Listen port (required)
  - `:token` - Authentication token (required, unless using token_hash)
  - `:token_hash` - Argon2 hash of token (alternative to plain token)
  - `:max_connections` - Max concurrent clients (default: `100`)
  - `:tls` - TLS configuration keyword list (optional)
    - `:certfile` - Path to TLS certificate (required for TLS)
    - `:keyfile` - Path to TLS private key (required for TLS)
    - `:cacertfile` - Path to CA certificate (optional, for client verification)
    - `:verify` - `:verify_peer` or `:verify_none` (default: `:verify_none`)
  - `:on_connect` - Callback when client connects (optional)
  - `:on_disconnect` - Callback when client disconnects (optional)

  ## TLS Example

      {:ok, server} = Burrow.Server.start_link(
        port: 4000,
        token: "secret",
        tls: [
          certfile: "/path/to/cert.pem",
          keyfile: "/path/to/key.pem"
        ]
      )
  """

  use GenServer
  require Logger

  # Aliases used via module references in start_link calls
  # alias Burrow.Protocol
  # alias Burrow.Server.{ControlHandler, PublicListener}

  defstruct [
    :port,
    :token,
    :listener,
    :max_connections,
    :on_connect,
    :on_disconnect,
    :clients,
    :tunnels,
    :public_listeners,
    :next_client_id,
    :tls,
    :tls_opts,
    :draining,
    :drain_start
  ]

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  List all connected clients.
  """
  def clients(server \\ __MODULE__) do
    GenServer.call(server, :list_clients)
  end

  @doc """
  Get server metrics.
  """
  def metrics(server \\ __MODULE__) do
    GenServer.call(server, :metrics)
  end

  @doc """
  Disconnect a specific client.
  """
  def disconnect_client(server \\ __MODULE__, client_id) do
    GenServer.call(server, {:disconnect_client, client_id})
  end

  @doc """
  Gracefully shutdown the server.

  Options:
  - `:drain_timeout` - Time in ms to wait for connections to drain (default: 30000)
  - `:notify_clients` - Whether to notify clients before shutdown (default: true)

  ## Example

      Burrow.Server.shutdown(drain_timeout: 30_000)

  """
  def shutdown(server \\ __MODULE__, opts \\ []) do
    GenServer.call(server, {:shutdown, opts}, :infinity)
  end

  @doc """
  Check if the server is draining (shutting down gracefully).
  """
  def draining?(server \\ __MODULE__) do
    GenServer.call(server, :draining?)
  end

  # Callbacks for internal use
  def client_authenticated(client_pid, client_id) do
    GenServer.cast(__MODULE__, {:client_authenticated, client_pid, client_id})
  end

  def client_disconnected(client_id) do
    GenServer.cast(__MODULE__, {:client_disconnected, client_id})
  end

  def register_tunnel(client_id, tunnel_id, port, name, protocol) do
    GenServer.call(__MODULE__, {:register_tunnel, client_id, tunnel_id, port, name, protocol})
  end

  def unregister_tunnel(client_id, tunnel_id) do
    GenServer.cast(__MODULE__, {:unregister_tunnel, client_id, tunnel_id})
  end

  def get_client_for_tunnel(port) do
    GenServer.call(__MODULE__, {:get_client_for_tunnel, port})
  end

  # Server callbacks

  @impl true
  def init(opts) do
    port = Keyword.fetch!(opts, :port)
    token = Keyword.get(opts, :token)
    token_hash = Keyword.get(opts, :token_hash)
    max_connections = Keyword.get(opts, :max_connections, 100)
    on_connect = Keyword.get(opts, :on_connect)
    on_disconnect = Keyword.get(opts, :on_disconnect)

    # Validate token configuration
    unless token || token_hash do
      raise ArgumentError, "either :token or :token_hash is required"
    end

    # Set token in application env for handlers
    if token_hash do
      Application.put_env(:burrow, :server_token_hash, token_hash)
      Application.delete_env(:burrow, :server_token)
    else
      Application.put_env(:burrow, :server_token, token)
      Application.delete_env(:burrow, :server_token_hash)
    end

    # TLS configuration
    tls_opts = Keyword.get(opts, :tls)
    tls_enabled = tls_opts != nil

    state = %__MODULE__{
      port: port,
      token: token,
      listener: nil,
      max_connections: max_connections,
      on_connect: on_connect,
      on_disconnect: on_disconnect,
      clients: %{},
      tunnels: %{},
      public_listeners: %{},
      next_client_id: 1,
      tls: tls_enabled,
      tls_opts: tls_opts,
      draining: false,
      drain_start: nil
    }

    # Start the control connection listener
    case start_control_listener(port, tls_opts) do
      {:ok, listener} ->
        tls_info = if tls_enabled, do: " (TLS)", else: ""
        Logger.info("[Burrow.Server] Listening on port #{port}#{tls_info}")
        {:ok, %{state | listener: listener}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:list_clients, _from, state) do
    clients = Enum.map(state.clients, fn {id, info} ->
      %{
        id: id,
        tunnels: Map.get(state.tunnels, id, []),
        connected_at: info.connected_at
      }
    end)

    {:reply, clients, state}
  end

  @impl true
  def handle_call(:metrics, _from, state) do
    metrics = %{
      clients: map_size(state.clients),
      tunnels: state.tunnels |> Map.values() |> List.flatten() |> length(),
      public_listeners: map_size(state.public_listeners)
    }

    {:reply, metrics, state}
  end

  @impl true
  def handle_call({:disconnect_client, client_id}, _from, state) do
    case Map.get(state.clients, client_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{pid: pid} ->
        send(pid, :disconnect)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:shutdown, opts}, _from, state) do
    drain_timeout = Keyword.get(opts, :drain_timeout, 30_000)
    notify_clients = Keyword.get(opts, :notify_clients, true)

    Logger.info("[Burrow.Server] Initiating graceful shutdown (drain_timeout: #{drain_timeout}ms)")

    # Stop accepting new connections
    if state.listener do
      ThousandIsland.stop(state.listener)
    end

    # Notify all clients about shutdown
    if notify_clients do
      notify_clients_of_shutdown(state.clients, "server_shutdown")
    end

    # Start draining
    state = %{state |
      draining: true,
      drain_start: System.monotonic_time(:millisecond),
      listener: nil
    }

    # If no clients, shutdown immediately
    if map_size(state.clients) == 0 do
      Logger.info("[Burrow.Server] No clients to drain, shutting down immediately")
      {:reply, :ok, state}
    else
      # Wait for clients to disconnect or timeout
      client_count = map_size(state.clients)
      Logger.info("[Burrow.Server] Waiting for #{client_count} clients to drain...")

      # Schedule drain completion check
      send(self(), {:check_drain_complete, drain_timeout})
      {:reply, :draining, state}
    end
  end

  @impl true
  def handle_call(:draining?, _from, state) do
    {:reply, state.draining, state}
  end

  @impl true
  def handle_call({:register_tunnel, client_id, tunnel_id, requested_port, name, protocol}, _from, state) do
    # Reject new tunnels if draining
    if state.draining do
      {:reply, {:error, :server_draining}, state}
    else
      # Try to bind to the requested port
      case start_public_listener(requested_port, client_id, tunnel_id) do
        {:ok, listener, actual_port} ->
          tunnel_info = %{
            id: tunnel_id,
            port: actual_port,
            name: name,
            protocol: protocol
          }

          client_tunnels = Map.get(state.tunnels, client_id, [])
          new_tunnels = Map.put(state.tunnels, client_id, [tunnel_info | client_tunnels])
          new_listeners = Map.put(state.public_listeners, actual_port, %{
            listener: listener,
            client_id: client_id,
            tunnel_id: tunnel_id
          })

          Logger.info("[Burrow.Server] Tunnel '#{name}' opened on port #{actual_port} for client #{client_id}")

          {:reply, {:ok, actual_port}, %{state | tunnels: new_tunnels, public_listeners: new_listeners}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call({:get_client_for_tunnel, port}, _from, state) do
    case Map.get(state.public_listeners, port) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{client_id: client_id, tunnel_id: tunnel_id} ->
        case Map.get(state.clients, client_id) do
          nil ->
            {:reply, {:error, :client_gone}, state}

          %{pid: pid} ->
            {:reply, {:ok, pid, tunnel_id}, state}
        end
    end
  end

  @impl true
  def handle_cast({:client_authenticated, pid, client_id}, state) do
    Process.monitor(pid)

    client_info = %{
      pid: pid,
      connected_at: DateTime.utc_now()
    }

    if state.on_connect do
      state.on_connect.(%{id: client_id})
    end

    emit_telemetry(:client_connected, %{client_id: client_id})
    Logger.info("[Burrow.Server] Client #{client_id} connected")

    {:noreply, %{state | clients: Map.put(state.clients, client_id, client_info)}}
  end

  @impl true
  def handle_cast({:client_disconnected, client_id}, state) do
    state = cleanup_client(state, client_id)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:unregister_tunnel, client_id, tunnel_id}, state) do
    # Find and stop the public listener for this tunnel
    {port, _} = Enum.find(state.public_listeners, {nil, nil}, fn {_port, info} ->
      info.client_id == client_id && info.tunnel_id == tunnel_id
    end)

    state =
      if port do
        case Map.get(state.public_listeners, port) do
          %{listener: listener} ->
            ThousandIsland.stop(listener)
            %{state | public_listeners: Map.delete(state.public_listeners, port)}

          nil ->
            state
        end
      else
        state
      end

    # Remove from tunnels
    client_tunnels = Map.get(state.tunnels, client_id, [])
    new_tunnels = Enum.reject(client_tunnels, &(&1.id == tunnel_id))

    {:noreply, %{state | tunnels: Map.put(state.tunnels, client_id, new_tunnels)}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Find and cleanup the disconnected client
    case Enum.find(state.clients, fn {_id, info} -> info.pid == pid end) do
      {client_id, _info} ->
        state = cleanup_client(state, client_id)

        # Check if drain is complete
        if state.draining and map_size(state.clients) == 0 do
          Logger.info("[Burrow.Server] All clients drained, shutdown complete")
        end

        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:check_drain_complete, timeout}, state) do
    if state.draining do
      elapsed = System.monotonic_time(:millisecond) - (state.drain_start || 0)
      remaining_clients = map_size(state.clients)

      cond do
        remaining_clients == 0 ->
          Logger.info("[Burrow.Server] All clients drained successfully")
          {:noreply, state}

        elapsed >= timeout ->
          Logger.warning("[Burrow.Server] Drain timeout reached, forcing disconnect of #{remaining_clients} clients")
          force_disconnect_all_clients(state.clients)
          {:noreply, state}

        true ->
          # Check again in 1 second
          Process.send_after(self(), {:check_drain_complete, timeout}, 1000)
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp start_control_listener(port, nil) do
    # Plain TCP
    ThousandIsland.start_link(
      port: port,
      handler_module: Burrow.Server.ControlHandler,
      handler_options: []
    )
  end

  defp start_control_listener(port, tls_opts) when is_list(tls_opts) do
    # TLS enabled
    transport_opts = build_transport_opts(tls_opts)

    ThousandIsland.start_link(
      port: port,
      handler_module: Burrow.Server.ControlHandler,
      handler_options: [],
      transport_module: ThousandIsland.Transports.SSL,
      transport_options: transport_opts
    )
  end

  defp build_transport_opts(tls_opts) do
    base_opts = [
      certfile: Keyword.fetch!(tls_opts, :certfile),
      keyfile: Keyword.fetch!(tls_opts, :keyfile),
      versions: [:"tlsv1.3", :"tlsv1.2"]
    ]

    # Optional CA cert for client verification
    base_opts =
      case Keyword.get(tls_opts, :cacertfile) do
        nil -> base_opts
        path -> Keyword.put(base_opts, :cacertfile, path)
      end

    # Verification mode
    verify = Keyword.get(tls_opts, :verify, :verify_none)
    Keyword.put(base_opts, :verify, verify)
  end

  defp start_public_listener(requested_port, client_id, tunnel_id) do
    # Try requested port, or find an available one
    port = if requested_port > 0, do: requested_port, else: find_available_port()

    case ThousandIsland.start_link(
      port: port,
      handler_module: Burrow.Server.PublicHandler,
      handler_options: [client_id: client_id, tunnel_id: tunnel_id, port: port]
    ) do
      {:ok, pid} ->
        {:ok, pid, port}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_available_port do
    # Let the OS assign a port
    {:ok, socket} = :gen_tcp.listen(0, [:binary])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp cleanup_client(state, client_id) do
    if state.on_disconnect do
      state.on_disconnect.(%{id: client_id}, :disconnected)
    end

    emit_telemetry(:client_disconnected, %{client_id: client_id})
    Logger.info("[Burrow.Server] Client #{client_id} disconnected")

    # Stop all public listeners for this client
    state.public_listeners
    |> Enum.filter(fn {_port, info} -> info.client_id == client_id end)
    |> Enum.each(fn {_port, %{listener: listener}} ->
      ThousandIsland.stop(listener)
    end)

    new_listeners = state.public_listeners
    |> Enum.reject(fn {_port, info} -> info.client_id == client_id end)
    |> Map.new()

    %{state |
      clients: Map.delete(state.clients, client_id),
      tunnels: Map.delete(state.tunnels, client_id),
      public_listeners: new_listeners
    }
  end

  defp notify_clients_of_shutdown(clients, reason) do
    Enum.each(clients, fn {_id, %{pid: pid}} ->
      send(pid, {:shutdown_notice, reason})
    end)
  end

  defp force_disconnect_all_clients(clients) do
    Enum.each(clients, fn {_id, %{pid: pid}} ->
      send(pid, :force_disconnect)
    end)
  end

  defp emit_telemetry(event, data) do
    :telemetry.execute([:burrow, :server, event], %{}, data)
  end
end
