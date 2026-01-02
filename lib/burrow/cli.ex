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
        help: :boolean,
        # TLS options
        tls: :boolean,
        tls_cert: :string,
        tls_key: :string,
        tls_ca: :string,
        tls_verify: :boolean,
        insecure: :boolean,
        # Token hashing
        token_hash: :string
      ],
      aliases: [
        p: :port,
        s: :server,
        t: :token,
        c: :config,
        v: :verbose,
        q: :quiet,
        d: :daemon,
        h: :help,
        k: :insecure
      ]
    )

    {commands, opts}
  end

  defp run({commands, opts}) do
    # Check for help flag first
    if Keyword.get(opts, :help, false) do
      print_help()
    else
      run_command(commands, opts)
    end
  end

  defp run_command(["help" | _], _opts) do
    print_help()
  end

  defp run_command(["server" | _], opts) do
    run_server(opts)
  end

  defp run_command(["client" | _], opts) do
    run_client(opts)
  end

  defp run_command(["hash-token" | rest], _opts) do
    run_hash_token(rest)
  end

  defp run_command(["generate-token" | _], _opts) do
    run_generate_token()
  end

  defp run_command(["version" | _], _opts) do
    IO.puts("Burrow v#{Burrow.version()}")
  end

  defp run_command([], _opts) do
    print_help()
  end

  defp run_command([cmd | _], _opts) do
    IO.puts("Unknown command: #{cmd}")
    IO.puts("Run 'burrow --help' for usage.")
    System.halt(1)
  end

  defp run_server(opts) do
    # Load config from file if specified
    {config, file_opts} = load_config_file(opts)

    # Merge file config with CLI options (CLI takes precedence)
    server_opts = if config do
      Burrow.Config.apply_to_env(config)
      Burrow.Config.server_opts(config)
    else
      []
    end

    # CLI options override file config
    port = Keyword.get(opts, :port) || Keyword.get(server_opts, :port, 4000)
    token = Keyword.get(opts, :token) || Keyword.get(server_opts, :token)
    token_hash = Keyword.get(opts, :token_hash) || Keyword.get(server_opts, :token_hash)

    unless token || token_hash do
      IO.puts("Error: --token or --token-hash is required (via CLI or config file)")
      System.halt(1)
    end

    # Build TLS options if provided (CLI overrides config)
    tls_opts = build_server_tls_opts(opts) || Keyword.get(server_opts, :tls)
    tls_info = if tls_opts, do: " (TLS)", else: ""
    hash_info = if token_hash, do: " (hashed token)", else: ""
    config_info = if file_opts[:config], do: " [config: #{file_opts[:config]}]", else: ""

    IO.puts("Starting Burrow server on port #{port}#{tls_info}#{hash_info}#{config_info}...")

    # Start the application
    {:ok, _} = Application.ensure_all_started(:burrow)

    # Build server options
    server_opts = [port: port]
    server_opts = if token_hash, do: Keyword.put(server_opts, :token_hash, token_hash), else: Keyword.put(server_opts, :token, token)
    server_opts = if tls_opts, do: Keyword.put(server_opts, :tls, tls_opts), else: server_opts

    # Start the server
    case Burrow.Server.start_link(server_opts) do
      {:ok, _pid} ->
        IO.puts("Server listening on port #{port}#{tls_info}#{hash_info}")
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

    # TLS options
    tls_enabled = Keyword.get(opts, :tls, false)
    insecure = Keyword.get(opts, :insecure, false)
    tls_info = if tls_enabled, do: " (TLS)", else: ""

    IO.puts("Connecting to #{server}#{tls_info}...")

    # Start the application
    {:ok, _} = Application.ensure_all_started(:burrow)

    # Build connection options
    connect_opts = [token: token, tunnels: tunnels]
    connect_opts = if tls_enabled, do: Keyword.put(connect_opts, :tls, true), else: connect_opts
    connect_opts = if insecure, do: Keyword.put(connect_opts, :tls_verify, :verify_none), else: connect_opts

    # Connect
    case Burrow.connect(server, connect_opts) do
      {:ok, _pid} ->
        IO.puts("Connected#{tls_info}!")
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

  defp run_hash_token([]) do
    IO.puts("Error: token argument required")
    IO.puts("Usage: burrow hash-token <token>")
    System.halt(1)
  end

  defp run_hash_token([token | _]) do
    {:ok, _} = Application.ensure_all_started(:argon2_elixir)
    hash = Burrow.Token.hash(token)
    IO.puts(hash)
  end

  defp run_generate_token do
    token = Burrow.Token.generate()
    IO.puts("Token: #{token}")
    {:ok, _} = Application.ensure_all_started(:argon2_elixir)
    hash = Burrow.Token.hash(token)
    IO.puts("Hash:  #{hash}")
    IO.puts("")
    IO.puts("Save the token securely - you'll need it to connect clients.")
    IO.puts("Use the hash in server config for secure token storage.")
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

  defp build_server_tls_opts(opts) do
    cert = Keyword.get(opts, :tls_cert)
    key = Keyword.get(opts, :tls_key)

    cond do
      cert && key ->
        tls_opts = [certfile: cert, keyfile: key]

        tls_opts =
          case Keyword.get(opts, :tls_ca) do
            nil -> tls_opts
            ca -> Keyword.put(tls_opts, :cacertfile, ca)
          end

        tls_opts =
          if Keyword.get(opts, :tls_verify, false) do
            Keyword.put(tls_opts, :verify, :verify_peer)
          else
            tls_opts
          end

        tls_opts

      Keyword.get(opts, :tls, false) ->
        IO.puts("Error: --tls-cert and --tls-key are required when using --tls")
        System.halt(1)

      true ->
        nil
    end
  end

  defp print_help do
    IO.puts("""
    Burrow - Fast, secure TCP/UDP tunneling in Elixir

    USAGE:
        burrow <COMMAND> [OPTIONS]

    COMMANDS:
        server          Start a Burrow server
        client          Connect to a Burrow server
        hash-token      Hash a token for secure storage
        generate-token  Generate a new token and hash
        version         Print version information
        help            Print this help message

    SERVER OPTIONS:
        -p, --port <PORT>       Listen port (default: 4000)
        -t, --token <TOKEN>     Authentication token
        --token-hash <HASH>     Argon2 hash of token (more secure)
        -c, --config <FILE>     Load config from file
        --tls-cert <FILE>       TLS certificate file (enables TLS)
        --tls-key <FILE>        TLS private key file
        --tls-ca <FILE>         CA certificate for client verification
        --tls-verify            Require client certificate verification

    CLIENT OPTIONS:
        -s, --server <HOST:PORT>  Server address (required)
        -t, --token <TOKEN>       Authentication token (required)
        --tunnel <NAME:LOCAL:REMOTE>  Add tunnel (can be repeated)
        -c, --config <FILE>       Load config from file
        --tls                     Use TLS encryption
        -k, --insecure            Skip TLS certificate verification

    COMMON OPTIONS:
        -v, --verbose     Verbose output
        -q, --quiet       Suppress output
        -d, --daemon      Run in background
        -h, --help        Print help

    EXAMPLES:
        # Generate a secure token
        burrow generate-token

        # Hash an existing token
        burrow hash-token mysecret

        # Start server with plain token
        burrow server --port 4000 --token mysecret

        # Start server with hashed token (more secure)
        burrow server --port 4000 --token-hash '$argon2id$v=19$...'

        # Start server with TLS
        burrow server --port 4000 --token mysecret \\
            --tls-cert /path/to/cert.pem \\
            --tls-key /path/to/key.pem

        # Connect with tunnels
        burrow client --server example.com:4000 --token mysecret \\
            --tunnel web:8080:80 \\
            --tunnel ssh:22:2222

        # Connect with TLS
        burrow client --server example.com:4000 --token mysecret --tls \\
            --tunnel web:8080:80

        # Start server from config file
        burrow server --config /etc/burrow/server.toml

        # Start client from config file
        burrow client --config ~/.burrow/client.toml

    For more information, visit: https://github.com/EntropyParadigm/burrow
    """)
  end

  defp load_config_file(opts) do
    case Keyword.get(opts, :config) do
      nil ->
        {nil, opts}

      path ->
        case Burrow.Config.load(path) do
          {:ok, config} ->
            {config, opts}

          {:error, reason} ->
            IO.puts("Error: Failed to load config from #{path}: #{inspect(reason)}")
            System.halt(1)
        end
    end
  end
end
