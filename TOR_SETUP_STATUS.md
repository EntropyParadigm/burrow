# Tor Setup Status for Burrow/GopherLab

## Status: COMPLETE

All services are running and accessible via Tor hidden service.

## Completed Steps

1. **Tor installed on relay server** ✅
   - `sudo apt-get install tor` on relay.westus3.cloudapp.azure.com

2. **Hidden services configured** ✅
   - Added to `/etc/tor/torrc`:
     ```
     HiddenServiceDir /var/lib/tor/gopherlab/
     HiddenServicePort 70 127.0.0.1:70
     HiddenServicePort 1965 127.0.0.1:1965
     ```

3. **Onion address obtained** ✅
   - **Address: `4la36s6x44qfs5bktepwmbvrg2spz5etdons5a3cg2k7gfmwjkb7wqad.onion`**

4. **Config updated in main repo** ✅
   - `/Users/anthonyramirez/pure_gopher_ai/config/config.exs` has onion_address set

5. **Burrow systemd service updated with Noise** ✅
   - `/etc/systemd/system/burrow.service` now includes `--encryption noise --noise-keyfile`

6. **Setup script ran** ✅
   - Files copied to gopher user

7. **EXLA recompiled for arm64** ✅
   - Fixed architecture mismatch (x86 vs arm64)
   - Disabled torchx, using EXLA backend

8. **All services verified working** ✅
   - Gopher server responding on port 70
   - Gemini server responding on port 1965 (TLS)
   - Burrow tunnel connected with Noise encryption
   - Tor hidden service accessible

## Live Endpoints

| Protocol | Clearnet | Tor |
|----------|----------|-----|
| Gopher | `gopher://gopherlab.org` | `gopher://4la36s6x44qfs5bktepwmbvrg2spz5etdons5a3cg2k7gfmwjkb7wqad.onion` |
| Gopher (Tor-aware) | - | `gopher://4la36s6x44qfs5bktepwmbvrg2spz5etdons5a3cg2k7gfmwjkb7wqad.onion:7071` |
| Gemini | `gemini://gopherlab.org` | `gemini://4la36s6x44qfs5bktepwmbvrg2spz5etdons5a3cg2k7gfmwjkb7wqad.onion` |

**Port 7071**: Tor-specific port that displays "Network: Tor Hidden Service" instead of "Clearnet"

## Key Information

- **Relay server**: owlwix@relay.westus3.cloudapp.azure.com
- **SSH key**: ~/relay.pem
- **Onion address**: 4la36s6x44qfs5bktepwmbvrg2spz5etdons5a3cg2k7gfmwjkb7wqad.onion
- **Noise public key**: jLP+tx3QcjtOyky0p/PfvH09dbqNuGCOrKf/z7QvXWQ=
- **Burrow token**: CrYyQgTr0S6D5jrkswY7B43yvXWOKj9zPIL6cHxpFw0

## Services Status

| Service | Port | Status |
|---------|------|--------|
| Gopher | 70 | ✅ Running |
| Gemini | 1965 | ✅ Running |
| Burrow control | 4000 | ✅ Running on relay with Noise |
| Tor | - | ✅ Running on relay |

## Testing Commands

```bash
# Test local gopher
echo "" | nc localhost 70

# Check server logs
tail -f /Users/gopher/.gopher/server.log

# Check Burrow tunnel on relay
ssh -i ~/relay.pem owlwix@relay.westus3.cloudapp.azure.com "journalctl -u burrow --since '5 minutes ago' | tail -20"

# Test Tor access (from machine with Tor)
torsocks nc 4la36s6x44qfs5bktepwmbvrg2spz5etdons5a3cg2k7gfmwjkb7wqad.onion 70
```

## Service Management

```bash
# Restart gopher service
sudo launchctl stop com.puregopherai.server
sudo launchctl start com.puregopherai.server

# Check service status
sudo launchctl list | grep puregopher
```
