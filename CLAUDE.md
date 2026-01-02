# Burrow - Project Context

## Overview
Burrow is a fast, secure TCP/UDP tunneling library and CLI tool written in Elixir. It exposes local services to the internet without opening router ports, using a relay server architecture.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         BURROW                               │
│          Fast, secure TCP/UDP tunneling in Elixir           │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────┐         Internet          ┌──────────┐        │
│  │  Client  │◄══════════════════════════►│  Server  │        │
│  │  (Home)  │    Control Connection      │  (VPS)   │        │
│  └────┬─────┘                            └────┬─────┘        │
│       │                                       │              │
│       ▼                                       ▼              │
│  ┌──────────┐                           ┌──────────┐        │
│  │ Local    │                           │ Public   │        │
│  │ Services │                           │ Listeners│        │
│  └──────────┘                           └──────────┘        │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Data Flow

1. **Client connects** to Server via control connection (single TCP)
2. **Client authenticates** with token
3. **Client requests tunnels** (name, local port, remote port)
4. **Server opens public listeners** on requested ports
5. **Public connection arrives** → Server notifies Client via control
6. **Client connects to local service** and relays data bidirectionally

## Key Files

| File | Purpose |
|------|---------|
| `lib/burrow.ex` | Main API (`connect/2`, `listen/2`) |
| `lib/burrow/application.ex` | OTP Application supervisor |
| `lib/burrow/client.ex` | Client GenServer - manages tunnels |
| `lib/burrow/server.ex` | Server GenServer - manages clients |
| `lib/burrow/protocol.ex` | Binary wire protocol encoding/decoding |
| `lib/burrow/server/control_handler.ex` | Handles client control connections |
| `lib/burrow/server/public_handler.ex` | Handles public tunnel connections |
| `lib/burrow/metrics.ex` | Telemetry metrics collector |
| `lib/burrow/cli.ex` | Command-line interface |

## Protocol

Binary protocol over TCP control connection:

```
┌────────┬────────┬────────────────────────────────────────────┐
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
  0x30 - PING        (keepalive)
  0x31 - PONG        (keepalive response)
  0x40 - CLOSE       (close connection)
  0x41 - SHUTDOWN    (graceful shutdown)
```

## Commands

```bash
# Development
mix deps.get           # Install dependencies
mix compile            # Compile
mix test               # Run tests
iex -S mix             # Interactive shell

# Build CLI
mix escript.build      # Creates ./burrow executable

# Run server
./burrow server --port 4000 --token secret

# Run client
./burrow client --server host:4000 --token secret --tunnel web:8080:80
```

## Usage Examples

### Programmatic (Library)

```elixir
# Client
{:ok, client} = Burrow.connect("server.com:4000",
  token: "secret",
  tunnels: [
    [name: "web", local: 8080, remote: 80],
    [name: "gopher", local: 70, remote: 70]
  ]
)

# Check status
Burrow.Client.status(client)

# Server
{:ok, server} = Burrow.listen(4000, token: "secret")
Burrow.Server.clients(server)
```

### CLI

```bash
# Server
./burrow server --port 4000 --token mysecret

# Client
./burrow client \
  --server relay.example.com:4000 \
  --token mysecret \
  --tunnel web:8080:80 \
  --tunnel ssh:22:2222
```

## Configuration

```elixir
# config/config.exs
config :burrow,
  client: [
    server: "relay.example.com:4000",
    token: {:system, "BURROW_TOKEN"},
    tunnels: [
      [name: "web", local: 8080, remote: 80]
    ],
    reconnect: true,
    heartbeat_interval: 30_000
  ],
  server: [
    port: 4000,
    token: {:system, "BURROW_TOKEN"},
    max_connections: 100
  ]
```

## Dependencies

- `thousand_island` - TCP server framework
- `jason` - JSON encoding
- `toml` - TOML config parsing
- `telemetry` - Metrics
- `optimus` - CLI argument parsing

## Integration with PureGopherAI

Add to `mix.exs`:

```elixir
{:burrow, "~> 0.1.0"}
# or from GitHub:
{:burrow, github: "EntropyParadigm/burrow"}
```

Configure in `config/prod.exs`:

```elixir
config :pure_gopher_ai, :tunnel,
  enabled: true,
  server: System.get_env("BURROW_SERVER"),
  token: System.get_env("BURROW_TOKEN"),
  tunnels: [
    [name: "gopher", local: 70, remote: 70],
    [name: "gemini", local: 1965, remote: 1965],
    [name: "tor", local: 7071, remote: 7071]
  ]
```

## Telemetry Events

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:burrow, :client, :connected]` | `%{}` | `%{server: ...}` |
| `[:burrow, :client, :disconnected]` | `%{uptime_ms: ...}` | `%{reason: ...}` |
| `[:burrow, :tunnel, :bytes_transferred]` | `%{bytes: ...}` | `%{tunnel: ...}` |
| `[:burrow, :server, :client_connected]` | `%{}` | `%{client_id: ...}` |

## Roadmap

- [x] Core TCP tunneling
- [x] Token authentication
- [x] Multi-tunnel support
- [x] Auto-reconnection
- [x] CLI interface
- [x] Telemetry metrics
- [ ] Noise protocol encryption
- [ ] UDP tunneling
- [ ] TLS encryption option
- [ ] Web dashboard
- [ ] Public relay server (burrow.pub)
- [ ] Config file support (TOML)
- [ ] Prometheus metrics exporter

## Notes

- All integers in protocol are big-endian
- Control connection multiplexes all tunnel data
- Each tunnel gets a unique ID (32-bit)
- Each connection within a tunnel gets a unique ID (32-bit)
- Heartbeats every 30s by default to detect dead connections
- Auto-reconnect with exponential backoff on disconnect
