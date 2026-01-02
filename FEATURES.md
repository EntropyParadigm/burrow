# Burrow Features Roadmap

## Overview

This document tracks planned features and enhancements for Burrow, the Elixir TCP/UDP tunneling library.

## Status Legend

- ✅ Completed
- 🚧 In Progress
- 📋 Planned

---

## Security Features

### TLS/SSL Encryption
**Status:** ✅ Completed

End-to-end encryption using TLS 1.3 for control connections.

```elixir
# Server
Burrow.Server.start_link(
  port: 4000,
  token: "secret",
  tls: [
    certfile: "/path/to/cert.pem",
    keyfile: "/path/to/key.pem"
  ]
)

# Client
Burrow.connect("server:4000",
  token: "secret",
  tls: true,
  tls_verify: :verify_peer
)
```

### Noise Protocol Encryption
**Status:** 📋 Planned

Alternative encryption using Noise_IK pattern (like WireGuard) for lower overhead.

### Token Hashing (Argon2)
**Status:** ✅ Completed

Store authentication tokens as Argon2 hashes on the server instead of plaintext.

```elixir
# Generate hash for config
Burrow.Token.hash("my_secret_token")
# => "$argon2id$v=19$m=65536,t=3,p=4$..."

# Server config
Burrow.Server.start_link(
  port: 4000,
  token_hash: "$argon2id$v=19$m=65536,t=3,p=4$..."
)
```

### Rate Limiting
**Status:** 📋 Planned

Per-client connection and bandwidth limits to prevent relay abuse.

```elixir
Burrow.Server.start_link(
  port: 4000,
  token: "secret",
  rate_limit: [
    max_connections_per_client: 10,
    max_tunnels_per_client: 5,
    max_bandwidth_mbps: 100
  ]
)
```

### IP Allowlisting
**Status:** 📋 Planned

Server-side configuration to restrict which IPs can connect.

```elixir
Burrow.Server.start_link(
  port: 4000,
  token: "secret",
  allowed_ips: [
    "192.168.1.0/24",
    "10.0.0.0/8",
    "203.0.113.50"
  ]
)
```

### Client Certificates (mTLS)
**Status:** 📋 Planned

Mutual TLS authentication for enhanced security.

```elixir
# Server requires client certs
Burrow.Server.start_link(
  port: 4000,
  tls: [
    certfile: "server.pem",
    keyfile: "server-key.pem",
    verify: :verify_peer,
    cacertfile: "ca.pem"
  ]
)

# Client provides cert
Burrow.connect("server:4000",
  tls: [
    certfile: "client.pem",
    keyfile: "client-key.pem"
  ]
)
```

---

## Reliability Features

### Connection Multiplexing
**Status:** 📋 Planned

Multiple logical connections over a single TCP connection using stream IDs.

### Heartbeat Tuning
**Status:** 📋 Planned

Configurable heartbeat intervals and dead peer detection.

```elixir
Burrow.connect("server:4000",
  token: "secret",
  heartbeat_interval: 15_000,    # 15 seconds
  heartbeat_timeout: 45_000,     # 45 seconds before disconnect
  tunnels: [...]
)
```

### Graceful Shutdown
**Status:** 📋 Planned

Drain existing connections before stopping the server.

```elixir
# Graceful shutdown with 30s drain period
Burrow.Server.shutdown(server, drain_timeout: 30_000)
```

### Connection Pooling
**Status:** 📋 Planned

Pool local connections for high-traffic tunnels.

```elixir
Burrow.connect("server:4000",
  token: "secret",
  tunnels: [
    [name: "web", local: 8080, remote: 80, pool_size: 10]
  ]
)
```

### Auto-Reconnect with Backoff
**Status:** ✅ Completed

Automatic reconnection with exponential backoff on disconnect.

---

## Protocol Features

### UDP Tunneling
**Status:** 📋 Planned

Support for UDP protocol tunneling (DNS, gaming, VoIP, etc.).

```elixir
Burrow.connect("server:4000",
  token: "secret",
  tunnels: [
    [name: "dns", local: 53, remote: 53, protocol: :udp],
    [name: "web", local: 8080, remote: 80, protocol: :tcp]
  ]
)
```

### Port Ranges
**Status:** 📋 Planned

Request port ranges instead of single ports.

```elixir
Burrow.connect("server:4000",
  token: "secret",
  tunnels: [
    [name: "game", local: {27015, 27020}, remote: {27015, 27020}]
  ]
)
```

### Domain/SNI Routing
**Status:** 📋 Planned

Route by hostname (SNI) for multiple services on the same port.

```elixir
Burrow.Server.start_link(
  port: 4000,
  token: "secret",
  sni_routing: true
)

# Client requests domain
Burrow.connect("server:4000",
  token: "secret",
  tunnels: [
    [name: "api", local: 3000, remote: 443, hostname: "api.example.com"],
    [name: "web", local: 8080, remote: 443, hostname: "www.example.com"]
  ]
)
```

---

## Observability Features

### Prometheus Metrics
**Status:** 📋 Planned

Export telemetry metrics to Prometheus.

```elixir
# Add to supervision tree
{Burrow.Metrics.Prometheus, port: 9090}

# Metrics exported:
# - burrow_connections_total
# - burrow_connections_current
# - burrow_bytes_transferred_total
# - burrow_tunnel_latency_seconds
```

### Web Dashboard
**Status:** 📋 Planned

Real-time web dashboard showing:
- Connected clients
- Active tunnels
- Bandwidth usage
- Connection history

```elixir
Burrow.Server.start_link(
  port: 4000,
  token: "secret",
  dashboard: [
    enabled: true,
    port: 8080,
    username: "admin",
    password: "secret"
  ]
)
```

### Access Logging
**Status:** 📋 Planned

Detailed logging of connections and data transfer.

```elixir
Burrow.Server.start_link(
  port: 4000,
  token: "secret",
  access_log: [
    enabled: true,
    format: :json,
    file: "/var/log/burrow/access.log"
  ]
)
```

Log format:
```json
{
  "timestamp": "2024-01-15T10:30:00Z",
  "client_id": "abc123",
  "client_ip": "192.168.1.100",
  "tunnel": "web",
  "remote_port": 80,
  "bytes_in": 1024,
  "bytes_out": 4096,
  "duration_ms": 150
}
```

---

## Configuration Features

### TOML Config File
**Status:** 📋 Planned

Load settings from TOML configuration file.

```toml
# /etc/burrow/server.toml
[server]
port = 4000
token = "secret"
max_connections = 100

[tls]
enabled = true
cert_file = "/etc/burrow/cert.pem"
key_file = "/etc/burrow/key.pem"

[rate_limit]
max_connections_per_client = 10
max_bandwidth_mbps = 100

[logging]
level = "info"
access_log = "/var/log/burrow/access.log"
```

```bash
./burrow server --config /etc/burrow/server.toml
```

### Hot Reload
**Status:** 📋 Planned

Reload configuration without restarting.

```bash
./burrow reload
# or
kill -HUP <pid>
```

### Environment Variable Support
**Status:** 📋 Planned

All config options settable via environment variables.

```bash
BURROW_PORT=4000 \
BURROW_TOKEN=secret \
BURROW_TLS_ENABLED=true \
./burrow server
```

---

## Operational Features

### Systemd Service
**Status:** 📋 Planned

Ready-made systemd unit file for Linux deployment.

```ini
# /etc/systemd/system/burrow.service
[Unit]
Description=Burrow Tunnel Server
After=network.target

[Service]
Type=simple
User=burrow
ExecStart=/usr/local/bin/burrow server --config /etc/burrow/server.toml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### Docker Image
**Status:** 📋 Planned

Containerized deployment option.

```dockerfile
FROM elixir:1.16-alpine
COPY burrow /usr/local/bin/
EXPOSE 4000
CMD ["burrow", "server", "--port", "4000"]
```

```bash
docker run -d -p 4000:4000 -e BURROW_TOKEN=secret burrow/server
```

### Cluster Mode
**Status:** 📋 Planned

Multiple relay servers with failover and load balancing.

```elixir
Burrow.connect([
  "relay1.example.com:4000",
  "relay2.example.com:4000",
  "relay3.example.com:4000"
],
  token: "secret",
  strategy: :round_robin,  # or :failover, :random
  tunnels: [...]
)
```

---

## Implementation Priority

### Phase 1: Security (Critical)
1. TLS/SSL Encryption
2. Token Hashing (Argon2)
3. Rate Limiting
4. IP Allowlisting

### Phase 2: Reliability
5. Heartbeat Tuning
6. Graceful Shutdown
7. UDP Tunneling

### Phase 3: Configuration
8. TOML Config File
9. Access Logging

### Phase 4: Observability
10. Prometheus Metrics
11. Web Dashboard

### Phase 5: Operations
12. Systemd Service
13. Docker Image
14. Cluster Mode
