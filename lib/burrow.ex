defmodule Burrow do
  @moduledoc """
  Fast, secure TCP/UDP tunneling in Elixir.

  Burrow exposes your local services to the internet without opening router ports.
  Built with Elixir/OTP for reliability and performance.

  ## Quick Start

  ### Client (at home)

      {:ok, client} = Burrow.connect("your-vps.com:4000",
        token: "secret",
        tunnels: [
          [name: "web", local: 8080, remote: 80],
          [name: "gopher", local: 70, remote: 70]
        ]
      )

  ### Server (on VPS)

      {:ok, server} = Burrow.listen(4000, token: "secret")

  ## Features

  - TCP tunneling for any service
  - Token-based authentication
  - Multiple tunnels over single connection
  - Auto-reconnection
  - Telemetry integration
  - OTP supervised processes
  """

  @doc """
  Connect to a Burrow server and establish tunnels.

  ## Options

  - `:token` - Authentication token (required)
  - `:tunnels` - List of tunnel configs (required)
  - `:encryption` - `:noise`, `:tls`, or `:none` (default: `:none`)
  - `:reconnect` - Auto-reconnect on disconnect (default: `true`)
  - `:reconnect_interval` - Ms between reconnect attempts (default: `5000`)
  - `:heartbeat_interval` - Ms between keepalive pings (default: `30000`)

  ## Tunnel Config

  Each tunnel is a keyword list with:
  - `:name` - Tunnel name (optional, auto-generated if not provided)
  - `:local` - Local port to forward from
  - `:remote` - Remote port to expose on server
  - `:protocol` - `:tcp` or `:udp` (default: `:tcp`)

  ## Examples

      # Simple connection
      {:ok, client} = Burrow.connect("server.com:4000",
        token: "secret",
        tunnels: [[local: 8080, remote: 80]]
      )

      # Multiple tunnels
      {:ok, client} = Burrow.connect("server.com:4000",
        token: "secret",
        tunnels: [
          [name: "web", local: 8080, remote: 80],
          [name: "ssh", local: 22, remote: 2222]
        ]
      )

  """
  @spec connect(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def connect(server, opts) do
    {host, port} = parse_server(server)

    opts =
      opts
      |> Keyword.put(:host, host)
      |> Keyword.put(:port, port)

    Burrow.Client.start_link(opts)
  end

  @doc """
  Start a Burrow server to accept client connections.

  ## Options

  - `:token` - Authentication token (required)
  - `:max_connections` - Max concurrent clients (default: `100`)
  - `:encryption` - `:noise`, `:tls`, or `:none` (default: `:none`)
  - `:on_connect` - Callback `fn(client_info) -> :ok` (optional)
  - `:on_disconnect` - Callback `fn(client_info, reason) -> :ok` (optional)

  ## Examples

      {:ok, server} = Burrow.listen(4000, token: "secret")

      # With callbacks
      {:ok, server} = Burrow.listen(4000,
        token: "secret",
        on_connect: fn info -> IO.puts("Connected: \#{info.id}") end
      )

  """
  @spec listen(pos_integer(), keyword()) :: {:ok, pid()} | {:error, term()}
  def listen(port, opts) do
    opts = Keyword.put(opts, :port, port)
    Burrow.Server.start_link(opts)
  end

  @doc """
  Get the version of Burrow.
  """
  @spec version() :: String.t()
  def version, do: "0.1.0"

  # Parse "host:port" string
  defp parse_server(server) when is_binary(server) do
    case String.split(server, ":") do
      [host, port_str] ->
        {host, String.to_integer(port_str)}

      [host] ->
        {host, 4000}
    end
  end
end
