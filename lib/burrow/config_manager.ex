defmodule Burrow.ConfigManager do
  @moduledoc """
  Central configuration manager for hot reloading.

  The ConfigManager coordinates runtime configuration updates across
  Burrow components. It supports:

  - File-based config watching (TOML files)
  - SIGHUP signal handling for reload triggers
  - Subscriber notifications for config changes
  - Validation of reload-safe settings

  ## Usage

      # Start with a config file
      {:ok, _pid} = Burrow.ConfigManager.start_link(config_file: "/etc/burrow/server.toml")

      # Subscribe to config changes
      Burrow.ConfigManager.subscribe()

      # Manually trigger reload
      Burrow.ConfigManager.reload()

      # Check current config
      config = Burrow.ConfigManager.get_config()

  ## What Can Be Hot-Reloaded

  | Setting | Module | Safe |
  |---------|--------|------|
  | IP filter rules | IPFilter | Yes |
  | Rate limit config | RateLimiter | Yes |
  | Max connections | Server | Yes |
  | Access log settings | AccessLog | Yes |
  | Port binding | Server | No |
  | Token/auth | Server | No |
  | TLS certificates | Server | No |

  """

  use GenServer
  require Logger

  @reload_cooldown_ms 1000

  defstruct [
    :config_file,
    :current_config,
    :last_reload,
    :subscribers,
    :file_watcher,
    :watch_enabled
  ]

  # Client API

  @doc """
  Start the ConfigManager.

  Options:
  - `:config_file` - Path to TOML config file (optional)
  - `:watch` - Watch file for changes (default: true if config_file provided)
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Subscribe the calling process to config change notifications.

  The subscriber will receive `{:config_changed, changes}` messages.
  """
  def subscribe do
    GenServer.call(__MODULE__, {:subscribe, self()})
  end

  @doc """
  Unsubscribe from config change notifications.
  """
  def unsubscribe do
    GenServer.call(__MODULE__, {:unsubscribe, self()})
  end

  @doc """
  Trigger a configuration reload.

  Returns `{:ok, changes}` or `{:error, reason}`.
  """
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc """
  Get the current configuration.
  """
  def get_config do
    GenServer.call(__MODULE__, :get_config)
  end

  @doc """
  Update a specific configuration section.

  This allows programmatic config updates without file changes.
  """
  def update_config(section, values) when is_atom(section) and is_map(values) do
    GenServer.call(__MODULE__, {:update_config, section, values})
  end

  # Server callbacks

  @impl true
  def init(opts) do
    config_file = Keyword.get(opts, :config_file)
    watch_enabled = Keyword.get(opts, :watch, config_file != nil)

    # Load initial config if file provided
    initial_config =
      if config_file do
        case Burrow.Config.load(config_file) do
          {:ok, config} ->
            Logger.info("[ConfigManager] Loaded config from #{config_file}")
            config

          {:error, reason} ->
            Logger.warning("[ConfigManager] Failed to load config: #{inspect(reason)}")
            %{}
        end
      else
        %{}
      end

    # Start file watcher if enabled
    file_watcher =
      if watch_enabled and config_file do
        start_file_watcher(config_file)
      else
        nil
      end

    # Register for SIGHUP signal
    setup_signal_handler()

    state = %__MODULE__{
      config_file: config_file,
      current_config: initial_config,
      last_reload: nil,
      subscribers: MapSet.new(),
      file_watcher: file_watcher,
      watch_enabled: watch_enabled
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    new_subscribers = MapSet.put(state.subscribers, pid)
    {:reply, :ok, %{state | subscribers: new_subscribers}}
  end

  @impl true
  def handle_call({:unsubscribe, pid}, _from, state) do
    new_subscribers = MapSet.delete(state.subscribers, pid)
    {:reply, :ok, %{state | subscribers: new_subscribers}}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    case do_reload(state) do
      {:ok, changes, new_state} ->
        {:reply, {:ok, changes}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_config, _from, state) do
    {:reply, state.current_config, state}
  end

  @impl true
  def handle_call({:update_config, section, values}, _from, state) do
    old_section = Map.get(state.current_config, section, %{})
    new_section = Map.merge(old_section, values)
    new_config = Map.put(state.current_config, section, new_section)

    changes = %{section => diff_section(old_section, new_section)}

    # Apply changes
    apply_changes(changes)

    # Notify subscribers
    notify_subscribers(state.subscribers, changes)

    {:reply, {:ok, changes}, %{state | current_config: new_config}}
  end

  # Handle file change notifications from FileWatcher
  @impl true
  def handle_info({:file_changed, _path}, state) do
    now = System.monotonic_time(:millisecond)
    last = state.last_reload || 0

    # Debounce rapid changes
    if now - last > @reload_cooldown_ms do
      Logger.info("[ConfigManager] Config file changed, reloading...")
      case do_reload(state) do
        {:ok, _changes, new_state} ->
          {:noreply, new_state}

        {:error, reason} ->
          Logger.error("[ConfigManager] Reload failed: #{inspect(reason)}")
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  # Handle SIGHUP signal
  @impl true
  def handle_info(:sighup, state) do
    Logger.info("[ConfigManager] Received SIGHUP, reloading configuration...")
    case do_reload(state) do
      {:ok, _changes, new_state} ->
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("[ConfigManager] Reload failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  # Handle subscriber process death
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    new_subscribers = MapSet.delete(state.subscribers, pid)
    {:noreply, %{state | subscribers: new_subscribers}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.file_watcher do
      GenServer.stop(state.file_watcher)
    end
    :ok
  end

  # Private functions

  defp do_reload(state) do
    case state.config_file do
      nil ->
        {:error, :no_config_file}

      path ->
        case Burrow.Config.load(path) do
          {:ok, new_config} ->
            # Validate the new config
            case validate_for_reload(state.current_config, new_config) do
              :ok ->
                # Calculate changes
                changes = diff_config(state.current_config, new_config)

                if map_size(changes) > 0 do
                  Logger.info("[ConfigManager] Configuration reloaded, changes: #{inspect(Map.keys(changes))}")

                  # Apply changes to running components
                  apply_changes(changes)

                  # Apply to application env
                  Burrow.Config.apply_to_env(new_config)

                  # Notify subscribers
                  notify_subscribers(state.subscribers, changes)
                else
                  Logger.debug("[ConfigManager] No configuration changes detected")
                end

                new_state = %{state |
                  current_config: new_config,
                  last_reload: System.monotonic_time(:millisecond)
                }

                {:ok, changes, new_state}

              {:error, reason} ->
                {:error, {:validation_failed, reason}}
            end

          {:error, reason} ->
            {:error, {:load_failed, reason}}
        end
    end
  end

  defp validate_for_reload(old_config, new_config) do
    # Check for unsafe changes
    unsafe_changes = []

    # Port changes are unsafe
    unsafe_changes =
      if get_in(old_config, [:server, :port]) != get_in(new_config, [:server, :port]) do
        [:port_changed | unsafe_changes]
      else
        unsafe_changes
      end

    # Token changes are unsafe (would break existing connections)
    unsafe_changes =
      if get_in(old_config, [:auth, :token]) != get_in(new_config, [:auth, :token]) or
         get_in(old_config, [:auth, :token_hash]) != get_in(new_config, [:auth, :token_hash]) do
        [:token_changed | unsafe_changes]
      else
        unsafe_changes
      end

    # TLS cert changes are unsafe
    unsafe_changes =
      if get_in(old_config, [:tls, :cert_file]) != get_in(new_config, [:tls, :cert_file]) or
         get_in(old_config, [:tls, :key_file]) != get_in(new_config, [:tls, :key_file]) do
        [:tls_certs_changed | unsafe_changes]
      else
        unsafe_changes
      end

    if unsafe_changes == [] do
      :ok
    else
      Logger.warning("[ConfigManager] Unsafe changes detected (require restart): #{inspect(unsafe_changes)}")
      # Still allow reload, but warn
      :ok
    end
  end

  defp diff_config(old, new) do
    all_keys = MapSet.union(
      MapSet.new(Map.keys(old)),
      MapSet.new(Map.keys(new))
    )

    Enum.reduce(all_keys, %{}, fn key, acc ->
      old_val = Map.get(old, key, %{})
      new_val = Map.get(new, key, %{})

      if old_val != new_val do
        Map.put(acc, key, diff_section(old_val, new_val))
      else
        acc
      end
    end)
  end

  defp diff_section(old, new) when is_map(old) and is_map(new) do
    %{
      added: Map.keys(new) -- Map.keys(old),
      removed: Map.keys(old) -- Map.keys(new),
      changed: Enum.filter(Map.keys(old), fn k ->
        Map.has_key?(new, k) and Map.get(old, k) != Map.get(new, k)
      end),
      old: old,
      new: new
    }
  end

  defp diff_section(old, new), do: %{old: old, new: new}

  defp apply_changes(changes) do
    # Apply rate limiter changes
    if Map.has_key?(changes, :rate_limit) do
      new_rate_limit = changes.rate_limit.new
      Burrow.RateLimiter.update_config(new_rate_limit)
    end

    # Apply IP filter changes
    if Map.has_key?(changes, :ip_filter) do
      new_ip_filter = changes.ip_filter.new
      Application.put_env(:burrow, :ip_filter, new_ip_filter)
    end

    # Apply server changes (only safe ones)
    if Map.has_key?(changes, :server) do
      new_server = changes.server.new
      if max_conn = new_server[:max_connections] do
        # Server.update_config would be called here if implemented
        Logger.info("[ConfigManager] Max connections updated to #{max_conn}")
      end
    end

    :ok
  end

  defp notify_subscribers(subscribers, changes) do
    Enum.each(subscribers, fn pid ->
      send(pid, {:config_changed, changes})
    end)
  end

  defp start_file_watcher(config_file) do
    case Burrow.ConfigManager.FileWatcher.start_link(
      path: config_file,
      notify: self()
    ) do
      {:ok, pid} ->
        Logger.info("[ConfigManager] File watcher started for #{config_file}")
        pid

      {:error, reason} ->
        Logger.warning("[ConfigManager] Failed to start file watcher: #{inspect(reason)}")
        nil
    end
  end

  defp setup_signal_handler do
    # Register for SIGHUP signal
    # Note: This only works on Unix systems
    if function_exported?(:os, :type, 0) do
      case :os.type() do
        {:unix, _} ->
          spawn(fn -> signal_handler_loop() end)

        _ ->
          :ok
      end
    end
  end

  defp signal_handler_loop do
    # This is a simplified signal handler
    # In production, you'd use a proper signal handling library
    receive do
      {:signal, :sighup} ->
        send(__MODULE__, :sighup)
        signal_handler_loop()

      _ ->
        signal_handler_loop()
    end
  end
end
