defmodule Burrow.ConfigManager.FileWatcher do
  @moduledoc """
  File change detection for configuration hot reload.

  Uses the `file_system` library to watch for changes to config files.
  When a change is detected, notifies the ConfigManager.

  ## Debouncing

  File changes are debounced to avoid rapid reloads when editors
  save files multiple times (e.g., backup files, swap files).
  """

  use GenServer
  require Logger

  @debounce_ms 500

  defstruct [
    :path,
    :notify_pid,
    :watcher_pid,
    :pending_notify
  ]

  # Client API

  @doc """
  Start the file watcher.

  Options:
  - `:path` - Path to watch (required)
  - `:notify` - PID to notify on changes (required)
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Stop the file watcher.
  """
  def stop(pid) do
    GenServer.stop(pid)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    notify_pid = Keyword.fetch!(opts, :notify)

    # Get the directory containing the file
    dir = Path.dirname(path)
    _filename = Path.basename(path)

    # Start file_system watcher for the directory
    case FileSystem.start_link(dirs: [dir]) do
      {:ok, watcher_pid} ->
        FileSystem.subscribe(watcher_pid)

        state = %__MODULE__{
          path: path,
          notify_pid: notify_pid,
          watcher_pid: watcher_pid,
          pending_notify: nil
        }

        Logger.debug("[FileWatcher] Watching #{path}")
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, events}}, state) do
    # Check if this is our file
    if Path.basename(path) == Path.basename(state.path) and
       relevant_event?(events) do
      # Debounce: cancel pending notify and schedule new one
      if state.pending_notify do
        Process.cancel_timer(state.pending_notify)
      end

      timer_ref = Process.send_after(self(), :do_notify, @debounce_ms)
      {:noreply, %{state | pending_notify: timer_ref}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    Logger.warning("[FileWatcher] File system watcher stopped")
    {:noreply, state}
  end

  @impl true
  def handle_info(:do_notify, state) do
    Logger.debug("[FileWatcher] File changed: #{state.path}")
    send(state.notify_pid, {:file_changed, state.path})
    {:noreply, %{state | pending_notify: nil}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.watcher_pid do
      # FileSystem watcher is a GenServer, stop it properly
      GenServer.stop(state.watcher_pid, :normal, 5000)
    end
    :ok
  end

  # Private functions

  defp relevant_event?(events) do
    # Only trigger on actual content changes
    Enum.any?(events, fn event ->
      event in [:modified, :created, :renamed]
    end)
  end
end
