defmodule Burrow.Metrics do
  @moduledoc """
  Telemetry metrics collector for Burrow.

  Tracks:
  - Client connections/disconnections
  - Tunnel creation/destruction
  - Bytes transferred
  - Connection counts
  """

  use GenServer
  require Logger

  defstruct [
    :started_at,
    bytes_in: 0,
    bytes_out: 0,
    connections_total: 0,
    connections_current: 0,
    tunnels_total: 0,
    tunnels_current: 0
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get current metrics.
  """
  def get do
    GenServer.call(__MODULE__, :get)
  end

  @doc """
  Reset all metrics.
  """
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  # Callbacks

  @impl true
  def init(_opts) do
    # Attach telemetry handlers
    attach_handlers()

    {:ok, %__MODULE__{started_at: DateTime.utc_now()}}
  end

  @impl true
  def handle_call(:get, _from, state) do
    metrics = %{
      uptime_seconds: DateTime.diff(DateTime.utc_now(), state.started_at, :second),
      bytes_in: state.bytes_in,
      bytes_out: state.bytes_out,
      connections_total: state.connections_total,
      connections_current: state.connections_current,
      tunnels_total: state.tunnels_total,
      tunnels_current: state.tunnels_current
    }

    {:reply, metrics, state}
  end

  @impl true
  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %__MODULE__{started_at: DateTime.utc_now()}}
  end

  @impl true
  def handle_cast({:client_connected}, state) do
    {:noreply, %{state |
      connections_total: state.connections_total + 1,
      connections_current: state.connections_current + 1
    }}
  end

  @impl true
  def handle_cast({:client_disconnected}, state) do
    {:noreply, %{state |
      connections_current: max(0, state.connections_current - 1)
    }}
  end

  @impl true
  def handle_cast({:tunnel_opened}, state) do
    {:noreply, %{state |
      tunnels_total: state.tunnels_total + 1,
      tunnels_current: state.tunnels_current + 1
    }}
  end

  @impl true
  def handle_cast({:tunnel_closed}, state) do
    {:noreply, %{state |
      tunnels_current: max(0, state.tunnels_current - 1)
    }}
  end

  @impl true
  def handle_cast({:bytes_in, bytes}, state) do
    {:noreply, %{state | bytes_in: state.bytes_in + bytes}}
  end

  @impl true
  def handle_cast({:bytes_out, bytes}, state) do
    {:noreply, %{state | bytes_out: state.bytes_out + bytes}}
  end

  # Private functions

  defp attach_handlers do
    events = [
      [:burrow, :client, :connected],
      [:burrow, :client, :disconnected],
      [:burrow, :client, :tunnel_opened],
      [:burrow, :client, :bytes_received],
      [:burrow, :server, :client_connected],
      [:burrow, :server, :client_disconnected]
    ]

    :telemetry.attach_many(
      "burrow-metrics",
      events,
      &handle_event/4,
      nil
    )
  end

  defp handle_event([:burrow, :client, :connected], _measurements, _metadata, _config) do
    GenServer.cast(__MODULE__, {:client_connected})
  end

  defp handle_event([:burrow, :client, :disconnected], _measurements, _metadata, _config) do
    GenServer.cast(__MODULE__, {:client_disconnected})
  end

  defp handle_event([:burrow, :client, :tunnel_opened], _measurements, _metadata, _config) do
    GenServer.cast(__MODULE__, {:tunnel_opened})
  end

  defp handle_event([:burrow, :client, :bytes_received], _measurements, %{bytes: bytes}, _config) do
    GenServer.cast(__MODULE__, {:bytes_in, bytes})
  end

  defp handle_event([:burrow, :server, :client_connected], _measurements, _metadata, _config) do
    GenServer.cast(__MODULE__, {:client_connected})
  end

  defp handle_event([:burrow, :server, :client_disconnected], _measurements, _metadata, _config) do
    GenServer.cast(__MODULE__, {:client_disconnected})
  end

  defp handle_event(_event, _measurements, _metadata, _config) do
    :ok
  end
end
