defmodule Burrow.AccessLog do
  @moduledoc """
  Access logging for Burrow server.

  Logs connection events, tunnel activity, and data transfer to a file.
  Supports JSON and text formats.

  ## Configuration

      config :burrow, :access_log,
        enabled: true,
        file: "/var/log/burrow/access.log",
        format: :json,  # or :text
        rotate: true,
        max_size_mb: 100

  ## Usage

      # Start in supervision tree
      {Burrow.AccessLog, []}

      # Or start manually
      Burrow.AccessLog.start_link()

      # Log events
      Burrow.AccessLog.log(:connection, %{client_id: "abc", ip: "1.2.3.4"})

  """

  use GenServer
  require Logger

  @default_config %{
    enabled: false,
    file: "burrow_access.log",
    format: :json,
    rotate: true,
    max_size_mb: 100
  }

  defstruct [
    :config,
    :file_handle,
    :current_size
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Log a connection event.
  """
  def log_connection(client_id, client_ip, opts \\ []) do
    log(:connection, %{
      client_id: client_id,
      client_ip: client_ip,
      tls: Keyword.get(opts, :tls, false)
    })
  end

  @doc """
  Log a disconnection event.
  """
  def log_disconnection(client_id, reason \\ :normal, opts \\ []) do
    log(:disconnection, %{
      client_id: client_id,
      reason: to_string(reason),
      duration_ms: Keyword.get(opts, :duration_ms)
    })
  end

  @doc """
  Log a tunnel event.
  """
  def log_tunnel(event, client_id, tunnel_name, port, opts \\ []) do
    log(:tunnel, %{
      event: to_string(event),
      client_id: client_id,
      tunnel_name: tunnel_name,
      port: port,
      protocol: Keyword.get(opts, :protocol, :tcp)
    })
  end

  @doc """
  Log data transfer.
  """
  def log_transfer(client_id, tunnel_name, bytes_in, bytes_out, opts \\ []) do
    log(:transfer, %{
      client_id: client_id,
      tunnel_name: tunnel_name,
      bytes_in: bytes_in,
      bytes_out: bytes_out,
      duration_ms: Keyword.get(opts, :duration_ms)
    })
  end

  @doc """
  Log an authentication event.
  """
  def log_auth(event, client_ip, opts \\ []) do
    log(:auth, %{
      event: to_string(event),
      client_ip: client_ip,
      reason: Keyword.get(opts, :reason)
    })
  end

  @doc """
  Log a rate limit event.
  """
  def log_rate_limit(client_ip, limit_type) do
    log(:rate_limit, %{
      client_ip: client_ip,
      limit_type: to_string(limit_type)
    })
  end

  @doc """
  Log a generic event.
  """
  def log(event_type, data) do
    if enabled?() do
      GenServer.cast(__MODULE__, {:log, event_type, data})
    end
  end

  @doc """
  Check if access logging is enabled.
  """
  def enabled? do
    config = Application.get_env(:burrow, :access_log, %{})
    Map.get(config, :enabled, false)
  end

  @doc """
  Flush and rotate the log file.
  """
  def rotate do
    GenServer.call(__MODULE__, :rotate)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    config = load_config(opts)

    if config.enabled do
      case open_log_file(config.file) do
        {:ok, handle, size} ->
          # Attach telemetry handlers
          attach_telemetry_handlers()

          {:ok, %__MODULE__{
            config: config,
            file_handle: handle,
            current_size: size
          }}

        {:error, reason} ->
          Logger.error("[AccessLog] Failed to open log file #{config.file}: #{inspect(reason)}")
          {:ok, %__MODULE__{config: %{config | enabled: false}, file_handle: nil, current_size: 0}}
      end
    else
      {:ok, %__MODULE__{config: config, file_handle: nil, current_size: 0}}
    end
  end

  @impl true
  def handle_cast({:log, event_type, data}, state) do
    if state.config.enabled and state.file_handle do
      entry = format_entry(event_type, data, state.config.format)
      entry_size = byte_size(entry)

      # Check if rotation is needed
      state = maybe_rotate(state, entry_size)

      # Write entry
      case IO.write(state.file_handle, entry) do
        :ok ->
          {:noreply, %{state | current_size: state.current_size + entry_size}}

        {:error, reason} ->
          Logger.error("[AccessLog] Write error: #{inspect(reason)}")
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:rotate, _from, state) do
    state = do_rotate(state)
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.file_handle do
      File.close(state.file_handle)
    end
    :ok
  end

  # Private functions

  defp load_config(opts) do
    app_config = Application.get_env(:burrow, :access_log, %{})
    merged = Map.merge(@default_config, Enum.into(app_config, %{}))
    Map.merge(merged, Enum.into(opts, %{}))
  end

  defp open_log_file(path) do
    path = Path.expand(path)

    # Ensure directory exists
    path |> Path.dirname() |> File.mkdir_p()

    case File.open(path, [:append, :utf8]) do
      {:ok, handle} ->
        size = case File.stat(path) do
          {:ok, %{size: s}} -> s
          _ -> 0
        end
        {:ok, handle, size}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_entry(event_type, data, :json) do
    entry = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      event: event_type,
      data: data
    }

    Jason.encode!(entry) <> "\n"
  end

  defp format_entry(event_type, data, :text) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    data_str = data
    |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)
    |> Enum.join(" ")

    "[#{timestamp}] #{event_type} #{data_str}\n"
  end

  defp format_entry(event_type, data, _), do: format_entry(event_type, data, :json)

  defp maybe_rotate(state, additional_size) do
    max_bytes = state.config.max_size_mb * 1024 * 1024

    if state.config.rotate and (state.current_size + additional_size) > max_bytes do
      do_rotate(state)
    else
      state
    end
  end

  defp do_rotate(state) do
    if state.file_handle do
      File.close(state.file_handle)
    end

    # Rename current log with timestamp
    path = Path.expand(state.config.file)
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d_%H%M%S")
    rotated_path = "#{path}.#{timestamp}"

    case File.rename(path, rotated_path) do
      :ok ->
        Logger.info("[AccessLog] Rotated log to #{rotated_path}")

      {:error, reason} ->
        Logger.warning("[AccessLog] Failed to rotate: #{inspect(reason)}")
    end

    # Open new log file
    case open_log_file(path) do
      {:ok, handle, size} ->
        %{state | file_handle: handle, current_size: size}

      {:error, reason} ->
        Logger.error("[AccessLog] Failed to open new log file: #{inspect(reason)}")
        %{state | file_handle: nil, current_size: 0}
    end
  end

  defp attach_telemetry_handlers do
    events = [
      {[:burrow, :server, :client_connected], &handle_telemetry_connected/4},
      {[:burrow, :server, :client_disconnected], &handle_telemetry_disconnected/4}
    ]

    Enum.each(events, fn {event, handler} ->
      :telemetry.attach(
        "burrow-access-log-#{Enum.join(event, "-")}",
        event,
        handler,
        nil
      )
    end)
  end

  defp handle_telemetry_connected(_event, _measurements, %{client_id: client_id} = metadata, _config) do
    log(:connection, %{
      client_id: client_id,
      client_ip: Map.get(metadata, :client_ip, "unknown")
    })
  end

  defp handle_telemetry_connected(_, _, _, _), do: :ok

  defp handle_telemetry_disconnected(_event, _measurements, %{client_id: client_id}, _config) do
    log(:disconnection, %{client_id: client_id})
  end

  defp handle_telemetry_disconnected(_, _, _, _), do: :ok
end
