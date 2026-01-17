# Burrow

**Fast, secure TCP/UDP tunneling in Elixir** - A Gopher's tunnel to the world.

[![Hex.pm](https://img.shields.io/hexpm/v/burrow.svg)](https://hex.pm/packages/burrow)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/burrow)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

Burrow exposes your local services to the internet without opening router ports. Built with Elixir/OTP for reliability and performance.

```
┌─────────────────────────────────────────────────────────────┐
│                         BURROW                               │
│          Fast, secure TCP/UDP tunneling in Elixir           │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────┐         Internet          ┌──────────┐        │
│  │  Client  │◄══════════════════════════►│  Server  │        │
│  │  (Home)  │    Encrypted Tunnel        │  (VPS)   │        │
│  └────┬─────┘                            └────┬─────┘        │
│       │                                       │              │
│       ▼                                       ▼              │
│  ┌──────────┐                           ┌──────────┐        │
│  │ Local    │                           │ Public   │        │
│  │ Services │                           │ Ports    │        │
│  │ :70      │                           │ :70      │        │
│  │ :1965    │                           │ :1965    │        │
│  │ :8080    │                           │ :8080    │        │
│  └──────────┘                           └──────────┘        │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Features

| Feature | Description |
|---------|-------------|
| **TCP Tunneling** | Expose any TCP service (HTTP, Gopher, SSH, etc.) |
| **UDP Tunneling** | UDP support via relay mode |
| **Noise Encryption** | Modern cryptography (same as WireGuard) |
| **Token Auth** | Simple shared-secret authentication |
| **Multi-Service** | Multiple tunnels over single connection |
| **Hot Reload** | Change config without restart |
| **Auto-Reconnect** | Resilient connection handling |
| **Telemetry** | Built-in metrics and monitoring |
| **Zero Config** | Works with minimal setup |
| **OTP Native** | Fault-tolerant, supervised processes |

## Installation

Add `burrow` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:burrow, "~> 0.1.0"}
  ]
end
```

For standalone CLI usage:

```bash
# Install from source
git clone https://github.com/YourUsername/burrow.git
cd burrow
mix escript.build
./burrow --help
```

## Quick Start

### 1. Start the Server (on your VPS)

```elixir
# In your application
Burrow.Server.start_link(
  port: 4000,
  token: "your-secret-token"
)
```

Or via CLI:

```bash
./burrow server --port 4000 --token your-secret-token
```

### 2. Start the Client (at home)

```elixir
Burrow.Client.start_link(
  server: "your-vps.com:4000",
  token: "your-secret-token",
  tunnels: [
    [name: "web", local: 8080, remote: 80],
    [name: "gopher", local: 70, remote: 70],
    [name: "gemini", local: 1965, remote: 1965]
  ]
)
```

Or via CLI:

```bash
./burrow client \
  --server your-vps.com:4000 \
  --token your-secret-token \
  --tunnel web:8080:80 \
  --tunnel gopher:70:70 \
  --tunnel gemini:1965:1965
```

### 3. Access Your Services

Your local services are now accessible via your VPS:
- `http://your-vps.com:80` -> `localhost:8080`
- `gopher://your-vps.com:70` -> `localhost:70`
- `gemini://your-vps.com:1965` -> `localhost:1965`

## Configuration

### Application Config

```elixir
# config/config.exs
config :burrow,
  # Client settings
  client: [
    server: "your-vps.com:4000",
    token: {:system, "BURROW_TOKEN"},  # Read from env
    tunnels: [
      [name: "web", local: 8080, remote: 80],
      [name: "gopher", local: 70, remote: 70]
    ],
    encryption: :noise,      # :noise | :tls | :none
    reconnect: true,
    reconnect_interval: 5_000,
    heartbeat_interval: 30_000
  ],

  # Server settings (if running server)
  server: [
    port: 4000,
    token: {:system, "BURROW_TOKEN"},
    max_connections: 100,
    encryption: :noise
  ]
```

### Config File

For standalone usage, create `burrow.toml`:

```toml
# burrow.toml

[client]
server = "your-vps.com:4000"
token = "your-secret-token"
encryption = "noise"
reconnect = true

[[tunnels]]
name = "web"
local = 8080
remote = 80
protocol = "tcp"

[[tunnels]]
name = "gopher"
local = 70
remote = 70
protocol = "tcp"

[[tunnels]]
name = "gemini"
local = 1965
remote = 1965
protocol = "tcp"
```

Run with:

```bash
./burrow client --config burrow.toml
```

## Programmatic API

### Basic Usage

```elixir
# Start client with minimal config
{:ok, client} = Burrow.connect("your-vps.com:4000",
  token: "secret",
  tunnels: [[local: 8080, remote: 80]]
)

# Check status
Burrow.Client.status(client)
# => %{connected: true, tunnels: [...], uptime: 3600}

# Add tunnel dynamically
Burrow.Client.add_tunnel(client, name: "ssh", local: 22, remote: 2222)

# Remove tunnel
Burrow.Client.remove_tunnel(client, "ssh")

# Disconnect
Burrow.Client.disconnect(client)
```

### Supervised Usage

```elixir
# In your application.ex
def start(_type, _args) do
  children = [
    {Burrow.Client, [
      server: "your-vps.com:4000",
      token: System.get_env("BURROW_TOKEN"),
      tunnels: [
        [name: "app", local: 4000, remote: 80]
      ]
    ]}
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

### Server API

```elixir
# Start server
{:ok, server} = Burrow.Server.start_link(
  port: 4000,
  token: "secret",
  on_connect: fn client_info ->
    IO.puts("Client connected: #{client_info.id}")
  end,
  on_disconnect: fn client_info, reason ->
    IO.puts("Client disconnected: #{reason}")
  end
)

# List connected clients
Burrow.Server.clients(server)
# => [%{id: "abc123", tunnels: [...], connected_at: ~U[...]}]

# Kick a client
Burrow.Server.disconnect_client(server, "abc123")

# Get metrics
Burrow.Server.metrics(server)
# => %{bytes_in: 1024000, bytes_out: 512000, connections: 5}
```

## Encryption

Burrow supports multiple encryption modes:

### Noise Protocol (Recommended)

Uses the Noise Protocol Framework (Noise_IK pattern, same as WireGuard) for fast, secure encryption:

```bash
# Generate server keypair
./burrow keygen --output server.key

# Start server with Noise encryption
./burrow server --port 4000 --token secret \
  --encryption noise --noise-keyfile server.key

# The server will print its public key, use it for clients:
# Noise public key: <base64_public_key>

# Connect client with Noise encryption
./burrow client --server your-vps.com:4000 --token secret \
  --encryption noise --noise-pubkey <base64_public_key> \
  --tunnel web:8080:80
```

Or programmatically:

```elixir
# Generate and save keypair
{:ok, keypair} = Burrow.Noise.generate_keypair()
Burrow.Noise.Keys.save(keypair, "server.key")

# Get public key to share with clients
pubkey = Burrow.Noise.Keys.public_key_base64(keypair)

# Server with Noise
Burrow.Server.start_link(
  port: 4000,
  token: "secret",
  encryption: :noise,
  noise_keypair: keypair
)

# Client with Noise
Burrow.Client.start_link(
  server: "your-vps.com:4000",
  token: "secret",
  encryption: :noise,
  noise_server_pubkey: pubkey,
  tunnels: [[local: 8080, remote: 80]]
)
```

Features:
- Forward secrecy with ephemeral keys
- 1-RTT handshake (low latency)
- Modern cryptography (X25519, ChaCha20-Poly1305, SHA256)
- Client knows server identity beforehand (prevents MITM)

### TLS

Standard TLS encryption:

```elixir
config :burrow,
  encryption: :tls,
  tls_cert: "/path/to/cert.pem",
  tls_key: "/path/to/key.pem"
```

### None (Development Only)

For testing on trusted networks:

```elixir
config :burrow, encryption: :none
```

## UDP Tunneling

Burrow supports UDP tunnels alongside TCP. UDP tunnels use session-based multiplexing where each unique source address (IP + port) gets a virtual connection ID.

```bash
# Tunnel UDP traffic (e.g., DNS, game servers, voice)
./burrow client --server your-vps.com:4000 --token secret \
  --tunnel dns:5353:53:udp \
  --tunnel voice:9987:9987:udp
```

Or in config:

```toml
[[tunnels]]
name = "dns"
local = 5353
remote = 53
protocol = "udp"

[[tunnels]]
name = "gameserver"
local = 27015
remote = 27015
protocol = "udp"
```

UDP sessions automatically expire after 60 seconds of inactivity.

## Hot Reload

Burrow supports runtime configuration updates without restarting:

```bash
# Start server with config file
./burrow server --config /etc/burrow/server.toml

# Trigger reload via signal
kill -HUP $(pgrep -f "burrow server")

# Or via CLI
./burrow reload
```

### What Can Be Hot-Reloaded

| Setting | Safe to Reload |
|---------|----------------|
| IP filter rules | Yes |
| Rate limit config | Yes |
| Max connections | Yes |
| Port binding | No (requires restart) |
| Token/auth | No (breaks connections) |
| TLS certificates | No (requires restart) |

### Programmatic Reload

```elixir
# Subscribe to config changes
Burrow.ConfigManager.subscribe()

# Trigger reload
{:ok, changes} = Burrow.ConfigManager.reload()

# Update specific settings
Burrow.ConfigManager.update_config(:rate_limit, %{
  enabled: true,
  max_connections_per_minute: 20
})
```

## CLI Reference

### Server Commands

```bash
# Start server
./burrow server --port 4000 --token secret

# With Noise encryption
./burrow server --port 4000 --token secret \
  --encryption noise --noise-keyfile server.key

# With config file
./burrow server --config server.toml

# Daemonize
./burrow server --port 4000 --token secret --daemon
```

### Client Commands

```bash
# Connect with tunnels
./burrow client \
  --server your-vps.com:4000 \
  --token secret \
  --tunnel web:8080:80 \
  --tunnel ssh:22:2222

# With Noise encryption
./burrow client \
  --server your-vps.com:4000 \
  --token secret \
  --encryption noise \
  --noise-pubkey <base64_key> \
  --tunnel web:8080:80

# With config file
./burrow client --config burrow.toml

# Daemonize
./burrow client --config burrow.toml --daemon
```

### Key Management

```bash
# Generate Noise keypair
./burrow keygen --output server.key

# Generate and hash authentication token
./burrow generate-token

# Hash an existing token
./burrow hash-token mysecrettoken
```

### Hot Reload

```bash
# Trigger config reload on running server
./burrow reload
```

### Common Options

```bash
--verbose, -v       Verbose output
--quiet, -q         Suppress output
--config FILE       Load config from file
--daemon, -d        Run in background
--encryption MODE   Encryption: noise, tls, none
```

## Telemetry & Metrics

Burrow emits telemetry events for monitoring:

```elixir
# Attach to events
:telemetry.attach_many("burrow-metrics", [
  [:burrow, :client, :connected],
  [:burrow, :client, :disconnected],
  [:burrow, :tunnel, :bytes_transferred],
  [:burrow, :tunnel, :connection_opened],
  [:burrow, :tunnel, :connection_closed]
], &handle_event/4, nil)

def handle_event([:burrow, :tunnel, :bytes_transferred], measurements, metadata, _) do
  IO.puts("Transferred #{measurements.bytes} bytes on #{metadata.tunnel_name}")
end
```

### Metrics Available

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:burrow, :client, :connected]` | `%{}` | `%{server: ...}` |
| `[:burrow, :client, :disconnected]` | `%{uptime_ms: ...}` | `%{reason: ...}` |
| `[:burrow, :tunnel, :bytes_transferred]` | `%{bytes: ...}` | `%{tunnel: ..., direction: :in/:out}` |
| `[:burrow, :tunnel, :connection_opened]` | `%{}` | `%{tunnel: ..., remote_ip: ...}` |
| `[:burrow, :tunnel, :connection_closed]` | `%{duration_ms: ...}` | `%{tunnel: ...}` |
| `[:burrow, :server, :client_connected]` | `%{}` | `%{client_id: ...}` |

## Protocol

Burrow uses a simple binary protocol over the control connection:

```
┌─────────────────────────────────────────────────────────────┐
│                    Frame Format                              │
├────────┬────────┬────────────────────────────────────────────┤
│ Length │  Type  │              Payload                       │
│ 4 bytes│ 1 byte │           Variable                         │
└────────┴────────┴────────────────────────────────────────────┘

Frame Types:
  0x01 - AUTH        (token authentication)
  0x02 - AUTH_OK     (authentication successful)
  0x03 - AUTH_FAIL   (authentication failed)
  0x10 - TUNNEL_REQ  (request new tunnel)
  0x11 - TUNNEL_OK   (tunnel established)
  0x12 - TUNNEL_FAIL (tunnel failed)
  0x20 - DATA        (tunnel data)
  0x21 - DATA_ACK    (data acknowledgment)
  0x30 - PING        (keepalive ping)
  0x31 - PONG        (keepalive pong)
  0x40 - CLOSE       (close tunnel)
  0x41 - SHUTDOWN    (graceful shutdown)
```

## Comparison with Alternatives

| Feature | Burrow | rathole | bore | frp |
|---------|--------|---------|------|-----|
| Language | Elixir | Rust | Rust | Go |
| TCP | Yes | Yes | Yes | Yes |
| UDP | Yes | Yes | No | Yes |
| Encryption | Noise/TLS | Noise | TLS | TLS |
| Hot Reload | Yes | Yes | No | No |
| Multi-tunnel | Yes | Yes | No | Yes |
| Public Server | Yes | No | Yes | No |
| OTP Supervised | Yes | No | No | No |
| Hex Package | Yes | No | No | No |
| Elixir API | Yes | No | No | No |

## Use Cases

### Expose Local Development

```bash
# Share your dev server with teammates
./burrow client --tunnel dev:3000:80
# => http://your-vps.com accessible to anyone
```

### Self-Host Services

```elixir
# Expose Gopher + Gemini without port forwarding
Burrow.connect("vps.com:4000",
  token: "secret",
  tunnels: [
    [local: 70, remote: 70],    # Gopher
    [local: 1965, remote: 1965] # Gemini
  ]
)
```

### IoT / Home Automation

```elixir
# Securely access home devices
Burrow.connect("relay.example.com:4000",
  token: System.get_env("HOME_TOKEN"),
  tunnels: [
    [name: "homeassistant", local: 8123, remote: 8123],
    [name: "cameras", local: 8080, remote: 8080]
  ]
)
```

### Gaming / Minecraft

```bash
./burrow client \
  --tunnel minecraft:25565:25565 \
  --tunnel voice:9987:9987:udp
```

## Development

```bash
# Clone
git clone https://github.com/YourUsername/burrow.git
cd burrow

# Install deps
mix deps.get

# Run tests
mix test

# Build escript
mix escript.build

# Generate docs
mix docs
```

## Roadmap

- [x] Core TCP tunneling
- [x] Token authentication
- [x] Multi-tunnel support
- [x] Auto-reconnection
- [x] CLI interface
- [x] Noise protocol encryption
- [x] UDP tunneling
- [x] Hot reload configuration
- [ ] Web dashboard
- [ ] Public relay server (burrow.pub)
- [ ] Prometheus metrics exporter
- [ ] Kubernetes operator

## License

MIT License - see [LICENSE](LICENSE) for details.

## Credits

Inspired by:
- [rathole](https://github.com/rapiz1/rathole) - Rust tunnel
- [bore](https://github.com/ekzhang/bore) - Simple Rust tunnel
- [frp](https://github.com/fatedier/frp) - Go reverse proxy

Built with love in Elixir.
