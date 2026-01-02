defmodule Burrow.CLI do
  @moduledoc """
  Command-line interface for Burrow.

  ## Usage

      # Start server
      ./burrow server --port 4000 --token secret

      # Start client
      ./burrow client --server host:4000 --token secret --tunnel web:8080:80

  """

  def main(args) do
    args
    |> parse_args()
    |> run()
  end

  defp parse_args(args) do
    {opts, commands, _} = OptionParser.parse(args,
      strict: [
        port: :integer,
        server: :string,
        token: :string,
        tunnel: [:string, :keep],
        config: :string,
        verbose: :boolean,
        quiet: :boolean,
        daemon: :boolean,
        help: :boolean
      ],
      aliases: [
        p: :port,
        s: :server,
        t: :token,
        c: :config,
        v: :verbose,
        q: :quiet,
        d: :daemon,
        h: :help
      ]
    )

    {commands, opts}
  end

  defp run({["help" | _], _opts}) do
    print_help()
  end

  defp run({_, opts}) when opts[:help] do
    print_help()
  end

  defp run({["server" | _], opts}) do
    run_server(opts)
  end

  defp run({["client" | _], opts}) do
    run_client(opts)
  end

  defp run({["version" | _], _opts}) do
    IO.puts("Burrow v#{Burrow.version()}")
  end

  defp run({[], _opts}) do
    print_help()
  end

  defp run({[cmd | _], _opts}) do
    IO.puts("Unknown command: #{cmd}")
    IO.puts("Run 'burrow --help' for usage.")
    System.halt(1)
  end

  defp run_server(opts) do
    port = Keyword.get(opts, :port, 4000)
    token = Keyword.get(opts, :token)

    unless token do
      IO.puts("Error: --token is required")
      System.halt(1)
    end

    IO.puts("Starting Burrow server on port #{port}...")

    # Set token in application env for handlers
    Application.put_env(:burrow, :server_token, token)

    # Start the application
    {:ok, _} = Application.ensure_all_started(:burrow)

    # Start the server
    case Burrow.Server.start_link(port: port, token: token) do
      {:ok, _pid} ->
        IO.puts("Server listening on port #{port}")
        IO.puts("Press Ctrl+C to stop.")

        # Keep running
        :timer.sleep(:infinity)

      {:error, reason} ->
        IO.puts("Failed to start server: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp run_client(opts) do
    server = Keyword.get(opts, :server)
    token = Keyword.get(opts, :token)
    tunnel_strs = Keyword.get_values(opts, :tunnel)

    unless server do
      IO.puts("Error: --server is required")
      System.halt(1)
    end

    unless token do
      IO.puts("Error: --token is required")
      System.halt(1)
    end

    if tunnel_strs == [] do
      IO.puts("Error: at least one --tunnel is required")
      System.halt(1)
    end

    tunnels = Enum.map(tunnel_strs, &parse_tunnel/1)

    IO.puts("Connecting to #{server}...")

    # Start the application
    {:ok, _} = Application.ensure_all_started(:burrow)

    # Connect
    case Burrow.connect(server, token: token, tunnels: tunnels) do
      {:ok, _pid} ->
        IO.puts("Connected!")
        Enum.each(tunnels, fn t ->
          IO.puts("  Tunnel '#{t[:name]}': localhost:#{t[:local]} -> remote:#{t[:remote]}")
        end)
        IO.puts("Press Ctrl+C to stop.")

        # Keep running
        :timer.sleep(:infinity)

      {:error, reason} ->
        IO.puts("Failed to connect: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp parse_tunnel(str) do
    case String.split(str, ":") do
      [name, local, remote] ->
        [name: name, local: String.to_integer(local), remote: String.to_integer(remote)]

      [local, remote] ->
        [local: String.to_integer(local), remote: String.to_integer(remote)]

      _ ->
        IO.puts("Invalid tunnel format: #{str}")
        IO.puts("Expected: name:local:remote or local:remote")
        System.halt(1)
    end
  end

  defp print_help do
    IO.puts("""
    Burrow - Fast, secure TCP/UDP tunneling in Elixir

    USAGE:
        burrow <COMMAND> [OPTIONS]

    COMMANDS:
        server      Start a Burrow server
        client      Connect to a Burrow server
        version     Print version information
        help        Print this help message

    SERVER OPTIONS:
        -p, --port <PORT>       Listen port (default: 4000)
        -t, --token <TOKEN>     Authentication token (required)
        -c, --config <FILE>     Load config from file

    CLIENT OPTIONS:
        -s, --server <HOST:PORT>  Server address (required)
        -t, --token <TOKEN>       Authentication token (required)
        --tunnel <NAME:LOCAL:REMOTE>  Add tunnel (can be repeated)
        -c, --config <FILE>       Load config from file

    COMMON OPTIONS:
        -v, --verbose     Verbose output
        -q, --quiet       Suppress output
        -d, --daemon      Run in background
        -h, --help        Print help

    EXAMPLES:
        # Start server
        burrow server --port 4000 --token mysecret

        # Connect with tunnels
        burrow client --server example.com:4000 --token mysecret \\
            --tunnel web:8080:80 \\
            --tunnel ssh:22:2222

    For more information, visit: https://github.com/EntropyParadigm/burrow
    """)
  end
end
