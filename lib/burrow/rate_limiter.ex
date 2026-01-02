defmodule Burrow.RateLimiter do
  @moduledoc """
  Rate limiting for Burrow server connections.

  Provides per-client rate limiting for:
  - Connection attempts (new client connections)
  - Tunnels per client
  - Bandwidth usage

  ## Usage

      # Start the rate limiter
      {:ok, _} = Burrow.RateLimiter.start_link()

      # Check if a connection is allowed
      case Burrow.RateLimiter.check_connection(client_ip) do
        :ok -> # Allow connection
        {:error, :rate_limited} -> # Reject
      end

  ## Configuration

      config :burrow, :rate_limit,
        enabled: true,
        max_connections_per_minute: 10,
        max_tunnels_per_client: 5,
        max_bandwidth_mbps: 100

  """

  use GenServer
  require Logger

  @default_config %{
    enabled: false,
    max_connections_per_minute: 10,
    max_tunnels_per_client: 5,
    max_bandwidth_bytes_per_second: 100 * 1024 * 1024,  # 100 MB/s
    window_ms: 60_000,
    cleanup_interval_ms: 60_000
  }

  defstruct [
    config: @default_config,
    connections: %{},      # ip -> [timestamps]
    tunnels: %{},          # client_id -> count
    bandwidth: %{},        # client_id -> {bytes, last_reset}
    violations: %{}        # ip -> count
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if a new connection from an IP is allowed.

  Returns `:ok` or `{:error, :rate_limited}`.
  """
  @spec check_connection(String.t() | tuple()) :: :ok | {:error, :rate_limited}
  def check_connection(ip) do
    if enabled?() do
      GenServer.call(__MODULE__, {:check_connection, normalize_ip(ip)})
    else
      :ok
    end
  end

  @doc """
  Record a new connection from an IP.
  """
  @spec record_connection(String.t() | tuple()) :: :ok
  def record_connection(ip) do
    if enabled?() do
      GenServer.cast(__MODULE__, {:record_connection, normalize_ip(ip)})
    end
    :ok
  end

  @doc """
  Check if a client can create another tunnel.
  """
  @spec check_tunnel(String.t()) :: :ok | {:error, :max_tunnels}
  def check_tunnel(client_id) do
    if enabled?() do
      GenServer.call(__MODULE__, {:check_tunnel, client_id})
    else
      :ok
    end
  end

  @doc """
  Record a new tunnel for a client.
  """
  @spec record_tunnel(String.t()) :: :ok
  def record_tunnel(client_id) do
    if enabled?() do
      GenServer.cast(__MODULE__, {:record_tunnel, client_id})
    end
    :ok
  end

  @doc """
  Remove a tunnel from a client's count.
  """
  @spec release_tunnel(String.t()) :: :ok
  def release_tunnel(client_id) do
    if enabled?() do
      GenServer.cast(__MODULE__, {:release_tunnel, client_id})
    end
    :ok
  end

  @doc """
  Check if bandwidth limit allows more data.

  Returns `:ok` or `{:error, :bandwidth_exceeded}`.
  """
  @spec check_bandwidth(String.t(), non_neg_integer()) :: :ok | {:error, :bandwidth_exceeded}
  def check_bandwidth(client_id, bytes) do
    if enabled?() do
      GenServer.call(__MODULE__, {:check_bandwidth, client_id, bytes})
    else
      :ok
    end
  end

  @doc """
  Record bandwidth usage for a client.
  """
  @spec record_bandwidth(String.t(), non_neg_integer()) :: :ok
  def record_bandwidth(client_id, bytes) do
    if enabled?() do
      GenServer.cast(__MODULE__, {:record_bandwidth, client_id, bytes})
    end
    :ok
  end

  @doc """
  Get current rate limiting stats.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Clear all rate limiting state for a client.
  """
  @spec clear_client(String.t()) :: :ok
  def clear_client(client_id) do
    GenServer.cast(__MODULE__, {:clear_client, client_id})
  end

  @doc """
  Check if rate limiting is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    config = Application.get_env(:burrow, :rate_limit, %{})
    Map.get(config, :enabled, false)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    config = load_config(opts)
    state = %__MODULE__{config: config}

    # Schedule periodic cleanup
    if config.enabled do
      schedule_cleanup(config.cleanup_interval_ms)
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:check_connection, ip}, _from, state) do
    now = System.monotonic_time(:millisecond)
    window_start = now - state.config.window_ms

    # Get recent connections from this IP
    timestamps = Map.get(state.connections, ip, [])
    recent = Enum.filter(timestamps, &(&1 > window_start))

    if length(recent) >= state.config.max_connections_per_minute do
      Logger.warning("[RateLimiter] Connection rate limit exceeded for #{ip}")
      {:reply, {:error, :rate_limited}, record_violation(state, ip)}
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:check_tunnel, client_id}, _from, state) do
    count = Map.get(state.tunnels, client_id, 0)

    if count >= state.config.max_tunnels_per_client do
      Logger.warning("[RateLimiter] Max tunnels exceeded for client #{client_id}")
      {:reply, {:error, :max_tunnels}, state}
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:check_bandwidth, client_id, bytes}, _from, state) do
    now = System.monotonic_time(:second)
    {current_bytes, last_reset} = Map.get(state.bandwidth, client_id, {0, now})

    # Reset if more than 1 second has passed
    current_bytes =
      if now > last_reset do
        0
      else
        current_bytes
      end

    if current_bytes + bytes > state.config.max_bandwidth_bytes_per_second do
      Logger.debug("[RateLimiter] Bandwidth limit exceeded for client #{client_id}")
      {:reply, {:error, :bandwidth_exceeded}, state}
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      enabled: state.config.enabled,
      active_connections: map_size(state.connections),
      active_clients: map_size(state.tunnels),
      violations: state.violations
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:record_connection, ip}, state) do
    now = System.monotonic_time(:millisecond)
    timestamps = Map.get(state.connections, ip, [])
    new_timestamps = [now | timestamps] |> Enum.take(100)  # Keep last 100

    {:noreply, %{state | connections: Map.put(state.connections, ip, new_timestamps)}}
  end

  @impl true
  def handle_cast({:record_tunnel, client_id}, state) do
    count = Map.get(state.tunnels, client_id, 0)
    {:noreply, %{state | tunnels: Map.put(state.tunnels, client_id, count + 1)}}
  end

  @impl true
  def handle_cast({:release_tunnel, client_id}, state) do
    count = Map.get(state.tunnels, client_id, 0)
    new_count = max(0, count - 1)

    new_tunnels =
      if new_count == 0 do
        Map.delete(state.tunnels, client_id)
      else
        Map.put(state.tunnels, client_id, new_count)
      end

    {:noreply, %{state | tunnels: new_tunnels}}
  end

  @impl true
  def handle_cast({:record_bandwidth, client_id, bytes}, state) do
    now = System.monotonic_time(:second)
    {current_bytes, last_reset} = Map.get(state.bandwidth, client_id, {0, now})

    # Reset if more than 1 second has passed
    {current_bytes, last_reset} =
      if now > last_reset do
        {0, now}
      else
        {current_bytes, last_reset}
      end

    new_bandwidth = Map.put(state.bandwidth, client_id, {current_bytes + bytes, last_reset})
    {:noreply, %{state | bandwidth: new_bandwidth}}
  end

  @impl true
  def handle_cast({:clear_client, client_id}, state) do
    {:noreply, %{state |
      tunnels: Map.delete(state.tunnels, client_id),
      bandwidth: Map.delete(state.bandwidth, client_id)
    }}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)
    window_start = now - state.config.window_ms

    # Clean up old connection timestamps
    new_connections =
      state.connections
      |> Enum.map(fn {ip, timestamps} ->
        {ip, Enum.filter(timestamps, &(&1 > window_start))}
      end)
      |> Enum.reject(fn {_ip, timestamps} -> timestamps == [] end)
      |> Map.new()

    # Clean up stale bandwidth entries
    bandwidth_cutoff = System.monotonic_time(:second) - 60
    new_bandwidth =
      state.bandwidth
      |> Enum.reject(fn {_id, {_bytes, last_reset}} -> last_reset < bandwidth_cutoff end)
      |> Map.new()

    schedule_cleanup(state.config.cleanup_interval_ms)

    {:noreply, %{state | connections: new_connections, bandwidth: new_bandwidth}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp load_config(opts) do
    app_config = Application.get_env(:burrow, :rate_limit, %{})
    merged = Map.merge(@default_config, Enum.into(app_config, %{}))
    Map.merge(merged, Enum.into(opts, %{}))
  end

  defp normalize_ip(ip) when is_binary(ip), do: ip
  defp normalize_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp normalize_ip({a, b, c, d, e, f, g, h}), do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  defp normalize_ip(ip), do: inspect(ip)

  defp record_violation(state, ip) do
    count = Map.get(state.violations, ip, 0)
    %{state | violations: Map.put(state.violations, ip, count + 1)}
  end

  defp schedule_cleanup(interval) do
    Process.send_after(self(), :cleanup, interval)
  end
end
