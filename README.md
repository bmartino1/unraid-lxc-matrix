# unraid-lxc-matrix

> **Self-hosted secure communications stack in a single Unraid LXC**
>
> Matrix Synapse · Element Web · Jitsi Meet · coturn · Nginx · PostgreSQL · Valkey

---

## What's inside

| Service | Role |
|---|---|
| **Matrix Synapse** | Homeserver (federated messaging) |
| **Element Web** | Web client for Matrix |
| **Jitsi Meet** | Video/voice conferencing (prosody + jicofo + JVB2) |
| **coturn** | TURN/STUN server for WebRTC NAT traversal |
| **Nginx** | Reverse proxy + SNI stream router (ports 80/443) |
| **PostgreSQL 16** | Database for Synapse |
| **Valkey** | Redis-compatible cache for Synapse workers |

All services run inside a single **Debian 12 (Bookworm)** LXC container.  
The LXC's IP becomes the **entire stack endpoint** — no Docker, no compose.

---

## Architecture

```
[Internet] ──80──▶  Nginx ──▶ HTTPS redirect
           ──443──▶ Nginx stream (ssl_preread SNI)
                      │
                      ├── <domain>        ──▶ Element Web  (static)
                      ├── matrix.<domain> ──▶ Matrix Synapse :8008
                      └── meet.<domain>   ──▶ Jitsi Meet (prosody/JVB)

           ──3478──▶ coturn TURN/STUN (UDP+TCP)
           ──5349──▶ coturn TURNS (TLS)
           ──10000/UDP──▶ Jitsi Video Bridge media
```

---

## Quick Start (inside the LXC)

```bash
# 1. Clone this repo
git clone https://github.com/bmartino1/unraid-lxc-matrix
cd unraid-lxc-matrix

# 2. Make setup script executable
chmod +x setup.sh

# 3. Run with your domain
./setup.sh --domain example.com

# Optional flags:
./setup.sh --domain example.com \
  --admin-user myuser \
  --admin-pass "mypassword" \
  --skip-ssl        # use self-signed certs (useful for testing)
  --staging         # use Let's Encrypt staging
```

The script will:
1. Install and configure all services
2. Write all config files
3. Request Let's Encrypt certificates (if DNS is pointed to the LXC)
4. Create the Matrix admin user
5. Print access URLs and credentials

---

## DNS Requirements

Point all three records to your **LXC container's IP**:

```
A  example.com          -> <LXC IP>
A  matrix.example.com   -> <LXC IP>
A  meet.example.com     -> <LXC IP>

# Matrix federation SRV record:
SRV _matrix._tcp.example.com  10 0 443 matrix.example.com
```

---

## Re-run SSL after DNS propagates

```bash
./scripts/renew-ssl.sh
```

---

## Check stack health

```bash
./scripts/stack-status.sh
```

---

## Building the Unraid LXC archive

Run this **on the Unraid host** (requires LXC plugin):

```bash
chmod +x createLXCarchive.sh
./createLXCarchive.sh
```

Output files will be in `<lxc_path>/cache/build_cache_matrix/`:
- `matrix.tar.xz`
- `matrix.tar.xz.md5`
- `build.log`

---

## File structure

```
unraid-lxc-matrix/
├── setup.sh                    # Main entry point — run inside LXC
├── createLXCarchive.sh         # Unraid build script — run on host
├── lxc_container_template.xml  # Unraid LXC template
├── notes.txt                   # Component versions and EOL info
├── build/
│   ├── 01-dependencies.sh      # APT sources, base packages
│   ├── 02-postgres.sh          # PostgreSQL 16
│   ├── 03-valkey.sh            # Valkey (Redis-compatible cache)
│   ├── 04-synapse.sh           # Matrix Synapse homeserver
│   ├── 05-element.sh           # Element Web client
│   ├── 06-jitsi.sh             # Jitsi Meet stack
│   ├── 07-coturn.sh            # coturn TURN/STUN server
│   ├── 08-nginx.sh             # Nginx with SNI stream routing
│   ├── 09-ssl.sh               # Let's Encrypt / self-signed certs
│   ├── 98-crontab.sh           # Cron jobs and health-check
│   └── 99-cleanup.sh           # Final cleanup and verification
└── scripts/
    ├── renew-ssl.sh            # Re-run SSL provisioning
    └── stack-status.sh         # Service and endpoint status
```

---

## Requirements

- Unraid with [LXC plugin](https://forums.unraid.net/topic/135752-plugin-lxc/)
- Debian 12 (Bookworm) LXC template
- Public domain with DNS control
- Ports 80, 443, 3478, 5349, 10000/UDP open to the LXC

---

## Credits

Project structure inspired by [bmartino1/unraid-lxc-unifi](https://github.com/bmartino1/unraid-lxc-unifi).
