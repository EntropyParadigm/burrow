defmodule Burrow.Config do
  @moduledoc """
  Configuration loader for Burrow.

  Supports loading configuration from TOML files.

  ## Example TOML Configuration

      # /etc/burrow/server.toml
      [server]
      port = 4000
      max_connections = 100

      [auth]
      token = "secret"
      # OR use token_hash for secure storage
      # token_hash = "$argon2id$v=19$..."

      [tls]
      enabled = true
      cert_file = "/path/to/cert.pem"
      key_file = "/path/to/key.pem"
      # ca_file = "/path/to/ca.pem"  # Optional, for mTLS
      # verify = true                 # Require client certs

      [rate_limit]
      enabled = true
      max_connections_per_minute = 10
      max_tunnels_per_client = 5
      max_bandwidth_mbps = 100

      [ip_filter]
      enabled = true
      mode = "allowlist"  # or "blocklist"
      addresses = [
        "192.168.1.0/24",
        "10.0.0.0/8"
      ]

      [logging]
      level = "info"
      access_log = "/var/log/burrow/access.log"

  ## Usage

      {:ok, config} = Burrow.Config.load("/path/to/config.toml")
      {:ok, server} = Burrow.Server.start_link(config.server)

  """

  require Logger

  @doc """
  Load configuration from a TOML file.

  Returns `{:ok, config}` where config is a map of configuration sections,
  or `{:error, reason}` if the file cannot be read or parsed.
  """
  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  def load(path) do
    path = Path.expand(path)

    with {:ok, content} <- File.read(path),
         {:ok, parsed} <- parse_toml(content) do
      config = transform_config(parsed)
      {:ok, config}
    else
      {:error, reason} ->
        Logger.error("[Burrow.Config] Failed to load config from #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Load configuration from a TOML file, raising on error.
  """
  @spec load!(String.t()) :: map()
  def load!(path) do
    case load(path) do
      {:ok, config} -> config
      {:error, reason} -> raise "Failed to load config: #{inspect(reason)}"
    end
  end

  @doc """
  Build server options from a config map.
  """
  @spec server_opts(map()) :: keyword()
  def server_opts(config) do
    opts = []

    # Server section
    opts = if server = config[:server] do
      opts
      |> put_if_present(:port, server[:port])
      |> put_if_present(:max_connections, server[:max_connections])
    else
      opts
    end

    # Auth section
    opts = if auth = config[:auth] do
      opts
      |> put_if_present(:token, auth[:token])
      |> put_if_present(:token_hash, auth[:token_hash])
    else
      opts
    end

    # TLS section
    opts = if tls = config[:tls] do
      if tls[:enabled] do
        tls_opts = []
        |> put_if_present(:certfile, tls[:cert_file])
        |> put_if_present(:keyfile, tls[:key_file])
        |> put_if_present(:cacertfile, tls[:ca_file])
        |> maybe_add_verify(tls[:verify])

        Keyword.put(opts, :tls, tls_opts)
      else
        opts
      end
    else
      opts
    end

    opts
  end

  @doc """
  Build client options from a config map.
  """
  @spec client_opts(map()) :: keyword()
  def client_opts(config) do
    opts = []

    # Client section
    opts = if client = config[:client] do
      opts
      |> put_if_present(:reconnect, client[:reconnect])
      |> put_if_present(:reconnect_interval, client[:reconnect_interval])
      |> put_if_present(:max_reconnect_interval, client[:max_reconnect_interval])
      |> put_if_present(:heartbeat_interval, client[:heartbeat_interval])
      |> put_if_present(:heartbeat_timeout, client[:heartbeat_timeout])
    else
      opts
    end

    # Server connection
    opts = if server = config[:server] do
      opts
      |> put_if_present(:host, server[:host])
      |> put_if_present(:port, server[:port])
    else
      opts
    end

    # Auth
    opts = if auth = config[:auth] do
      put_if_present(opts, :token, auth[:token])
    else
      opts
    end

    # TLS
    opts = if tls = config[:tls] do
      if tls[:enabled] do
        opts
        |> Keyword.put(:tls, true)
        |> maybe_put_verify_mode(tls[:insecure])
      else
        opts
      end
    else
      opts
    end

    # Tunnels
    opts = if tunnels = config[:tunnels] do
      tunnel_configs = Enum.map(tunnels, fn tunnel ->
        [
          name: tunnel[:name] || "tunnel",
          local: tunnel[:local],
          remote: tunnel[:remote],
          protocol: parse_protocol(tunnel[:protocol])
        ]
      end)

      Keyword.put(opts, :tunnels, tunnel_configs)
    else
      opts
    end

    opts
  end

  @doc """
  Apply configuration to application environment.

  This sets rate_limit and ip_filter configs that are read at runtime.
  """
  @spec apply_to_env(map()) :: :ok
  def apply_to_env(config) do
    # Rate limiting
    if rate_limit = config[:rate_limit] do
      Application.put_env(:burrow, :rate_limit, %{
        enabled: rate_limit[:enabled] || false,
        max_connections_per_minute: rate_limit[:max_connections_per_minute] || 10,
        max_tunnels_per_client: rate_limit[:max_tunnels_per_client] || 5,
        max_bandwidth_bytes_per_second: (rate_limit[:max_bandwidth_mbps] || 100) * 1024 * 1024
      })
    end

    # IP filtering
    if ip_filter = config[:ip_filter] do
      Application.put_env(:burrow, :ip_filter, %{
        enabled: ip_filter[:enabled] || false,
        mode: parse_filter_mode(ip_filter[:mode]),
        addresses: ip_filter[:addresses] || []
      })
    end

    :ok
  end

  # Private functions

  defp parse_toml(content) do
    case Toml.decode(content) do
      {:ok, result} -> {:ok, result}
      {:error, msg} -> {:error, {:parse_error, msg}}
    end
  end

  defp transform_config(parsed) do
    parsed
    |> Enum.map(fn {key, value} ->
      {String.to_atom(key), transform_section(value)}
    end)
    |> Map.new()
  end

  defp transform_section(section) when is_map(section) do
    section
    |> Enum.map(fn {key, value} ->
      {String.to_atom(key), transform_value(value)}
    end)
    |> Map.new()
  end

  defp transform_section(value), do: value

  defp transform_value(list) when is_list(list) do
    Enum.map(list, &transform_value/1)
  end

  defp transform_value(map) when is_map(map) do
    transform_section(map)
  end

  defp transform_value(value), do: value

  defp put_if_present(opts, _key, nil), do: opts
  defp put_if_present(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_add_verify(opts, true), do: Keyword.put(opts, :verify, :verify_peer)
  defp maybe_add_verify(opts, _), do: opts

  defp maybe_put_verify_mode(opts, true), do: Keyword.put(opts, :tls_verify, :verify_none)
  defp maybe_put_verify_mode(opts, _), do: opts

  defp parse_protocol("udp"), do: :udp
  defp parse_protocol("tcp"), do: :tcp
  defp parse_protocol(:udp), do: :udp
  defp parse_protocol(:tcp), do: :tcp
  defp parse_protocol(_), do: :tcp

  defp parse_filter_mode("blocklist"), do: :blocklist
  defp parse_filter_mode("allowlist"), do: :allowlist
  defp parse_filter_mode(:blocklist), do: :blocklist
  defp parse_filter_mode(:allowlist), do: :allowlist
  defp parse_filter_mode(_), do: :allowlist
end
