defmodule Burrow.Metrics.Prometheus do
  @moduledoc """
  Prometheus metrics exporter for Burrow.

  Exposes metrics at `/metrics` endpoint in Prometheus text format.

  ## Usage

      # Add to supervision tree
      {Burrow.Metrics.Prometheus, port: 9090}

  ## Metrics Exported

  - `burrow_connections_total` - Total connections
  - `burrow_connections_current` - Current active connections
  - `burrow_tunnels_total` - Total tunnels created
  - `burrow_tunnels_current` - Current active tunnels
  - `burrow_bytes_sent_total` - Total bytes sent
  - `burrow_bytes_received_total` - Total bytes received
  - `burrow_auth_failures_total` - Authentication failures
  - `burrow_rate_limited_total` - Rate limited connections
  - `burrow_tunnel_latency_seconds` - Tunnel latency histogram

  """

  use Supervisor
  require Logger

  @default_port 9090

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, @default_port)

    # Initialize metrics state
    :ets.new(:burrow_metrics, [:named_table, :public, :set])
    init_counters()

    # Attach telemetry handlers
    attach_handlers()

    children = [
      {Plug.Cowboy, scheme: :http, plug: Burrow.Metrics.Prometheus.Plug, options: [port: port]}
    ]

    Logger.info("[Burrow.Metrics.Prometheus] Metrics available at http://localhost:#{port}/metrics")

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp init_counters do
    counters = [
      :connections_total,
      :connections_current,
      :tunnels_total,
      :tunnels_current,
      :bytes_sent_total,
      :bytes_received_total,
      :auth_failures_total,
      :rate_limited_total
    ]

    Enum.each(counters, fn name ->
      :ets.insert(:burrow_metrics, {name, 0})
    end)

    # Initialize histogram buckets for latency
    :ets.insert(:burrow_metrics, {:latency_buckets, %{}})
  end

  defp attach_handlers do
    events = [
      {[:burrow, :server, :client_connected], &handle_client_connected/4},
      {[:burrow, :server, :client_disconnected], &handle_client_disconnected/4},
      {[:burrow, :client, :connected], &handle_connected/4},
      {[:burrow, :client, :disconnected], &handle_disconnected/4},
      {[:burrow, :client, :tunnel_opened], &handle_tunnel_opened/4},
      {[:burrow, :client, :bytes_received], &handle_bytes_received/4}
    ]

    Enum.each(events, fn {event, handler} ->
      :telemetry.attach(
        "burrow-prometheus-#{Enum.join(event, "-")}",
        event,
        handler,
        nil
      )
    end)
  end

  # Telemetry handlers

  defp handle_client_connected(_event, _measurements, _metadata, _config) do
    increment(:connections_total)
    increment(:connections_current)
  end

  defp handle_client_disconnected(_event, _measurements, _metadata, _config) do
    decrement(:connections_current)
  end

  defp handle_connected(_event, _measurements, _metadata, _config) do
    increment(:connections_total)
    increment(:connections_current)
  end

  defp handle_disconnected(_event, _measurements, _metadata, _config) do
    decrement(:connections_current)
  end

  defp handle_tunnel_opened(_event, _measurements, _metadata, _config) do
    increment(:tunnels_total)
    increment(:tunnels_current)
  end

  defp handle_bytes_received(_event, _measurements, %{bytes: bytes}, _config) do
    add(:bytes_received_total, bytes)
  end

  defp handle_bytes_received(_event, _measurements, _metadata, _config) do
    :ok
  end

  # Counter operations

  defp increment(name) do
    :ets.update_counter(:burrow_metrics, name, 1, {name, 0})
  end

  defp decrement(name) do
    :ets.update_counter(:burrow_metrics, name, -1, {name, 0})
  end

  defp add(name, value) when is_integer(value) do
    :ets.update_counter(:burrow_metrics, name, value, {name, 0})
  end

  @doc """
  Increment a custom counter.
  """
  def inc(name, value \\ 1) do
    :ets.update_counter(:burrow_metrics, name, value, {name, 0})
  end

  @doc """
  Record a latency measurement.
  """
  def observe_latency(latency_ms) do
    bucket = latency_bucket(latency_ms)

    case :ets.lookup(:burrow_metrics, :latency_buckets) do
      [{:latency_buckets, buckets}] ->
        new_count = Map.get(buckets, bucket, 0) + 1
        new_buckets = Map.put(buckets, bucket, new_count)
        :ets.insert(:burrow_metrics, {:latency_buckets, new_buckets})

      _ ->
        :ok
    end
  end

  defp latency_bucket(ms) when ms <= 5, do: "0.005"
  defp latency_bucket(ms) when ms <= 10, do: "0.01"
  defp latency_bucket(ms) when ms <= 25, do: "0.025"
  defp latency_bucket(ms) when ms <= 50, do: "0.05"
  defp latency_bucket(ms) when ms <= 100, do: "0.1"
  defp latency_bucket(ms) when ms <= 250, do: "0.25"
  defp latency_bucket(ms) when ms <= 500, do: "0.5"
  defp latency_bucket(ms) when ms <= 1000, do: "1"
  defp latency_bucket(ms) when ms <= 2500, do: "2.5"
  defp latency_bucket(ms) when ms <= 5000, do: "5"
  defp latency_bucket(_), do: "+Inf"

  @doc """
  Get all current metrics.
  """
  def get_metrics do
    :ets.tab2list(:burrow_metrics)
    |> Map.new()
  end
end

defmodule Burrow.Metrics.Prometheus.Plug do
  @moduledoc false

  import Plug.Conn

  def init(opts), do: opts

  def call(%{request_path: "/metrics"} = conn, _opts) do
    metrics = format_metrics()

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, metrics)
  end

  def call(%{request_path: "/health"} = conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, ~s({"status":"ok"}))
  end

  def call(conn, _opts) do
    conn
    |> send_resp(404, "Not found")
  end

  defp format_metrics do
    metrics = Burrow.Metrics.Prometheus.get_metrics()

    lines = [
      "# HELP burrow_connections_total Total number of connections",
      "# TYPE burrow_connections_total counter",
      "burrow_connections_total #{metrics[:connections_total] || 0}",
      "",
      "# HELP burrow_connections_current Current number of active connections",
      "# TYPE burrow_connections_current gauge",
      "burrow_connections_current #{metrics[:connections_current] || 0}",
      "",
      "# HELP burrow_tunnels_total Total number of tunnels created",
      "# TYPE burrow_tunnels_total counter",
      "burrow_tunnels_total #{metrics[:tunnels_total] || 0}",
      "",
      "# HELP burrow_tunnels_current Current number of active tunnels",
      "# TYPE burrow_tunnels_current gauge",
      "burrow_tunnels_current #{metrics[:tunnels_current] || 0}",
      "",
      "# HELP burrow_bytes_sent_total Total bytes sent",
      "# TYPE burrow_bytes_sent_total counter",
      "burrow_bytes_sent_total #{metrics[:bytes_sent_total] || 0}",
      "",
      "# HELP burrow_bytes_received_total Total bytes received",
      "# TYPE burrow_bytes_received_total counter",
      "burrow_bytes_received_total #{metrics[:bytes_received_total] || 0}",
      "",
      "# HELP burrow_auth_failures_total Total authentication failures",
      "# TYPE burrow_auth_failures_total counter",
      "burrow_auth_failures_total #{metrics[:auth_failures_total] || 0}",
      "",
      "# HELP burrow_rate_limited_total Total rate limited connections",
      "# TYPE burrow_rate_limited_total counter",
      "burrow_rate_limited_total #{metrics[:rate_limited_total] || 0}",
      ""
    ]

    # Add latency histogram
    latency_lines = format_latency_histogram(metrics[:latency_buckets] || %{})

    Enum.join(lines ++ latency_lines, "\n")
  end

  defp format_latency_histogram(buckets) do
    buckets_sorted = [
      {"0.005", Map.get(buckets, "0.005", 0)},
      {"0.01", Map.get(buckets, "0.01", 0)},
      {"0.025", Map.get(buckets, "0.025", 0)},
      {"0.05", Map.get(buckets, "0.05", 0)},
      {"0.1", Map.get(buckets, "0.1", 0)},
      {"0.25", Map.get(buckets, "0.25", 0)},
      {"0.5", Map.get(buckets, "0.5", 0)},
      {"1", Map.get(buckets, "1", 0)},
      {"2.5", Map.get(buckets, "2.5", 0)},
      {"5", Map.get(buckets, "5", 0)},
      {"+Inf", Map.get(buckets, "+Inf", 0)}
    ]

    # Calculate cumulative counts
    {bucket_lines, total, _} =
      Enum.reduce(buckets_sorted, {[], 0, 0}, fn {le, count}, {lines, sum, cumulative} ->
        new_cumulative = cumulative + count
        line = ~s(burrow_tunnel_latency_seconds_bucket{le="#{le}"} #{new_cumulative})
        {[line | lines], sum + count, new_cumulative}
      end)

    [
      "# HELP burrow_tunnel_latency_seconds Tunnel latency histogram",
      "# TYPE burrow_tunnel_latency_seconds histogram"
    ] ++ Enum.reverse(bucket_lines) ++ [
      "burrow_tunnel_latency_seconds_count #{total}",
      ""
    ]
  end
end
