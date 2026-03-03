# unraid-lxc-matrix

> **Self-hosted secure communications stack in a single Unraid LXC**
>
> Matrix Synapse · Element Web · Jitsi Meet (widget-only) · coturn · Nginx · PostgreSQL · Valkey

---

## Install on Unraid

### Step 1 — Add the LXC template

Open an Unraid terminal and run:

```bash
wget -O /tmp/lxc_container_template.xml \
  https://raw.githubusercontent.com/bmartino1/unraid-lxc-matrix/main/lxc_container_template.xml
```

Then navigate to `http://<your-unraid-ip>/LXCAddTemplate`, click Apply, wait for Done.

The LXC plugin downloads the pre-built container archive and creates the LXC.

### Step 2 — Point DNS to the LXC IP

Before running setup, create these DNS records pointing to your LXC container's IP:

```
A  chat.yourdomain.com          ->  <LXC IP>
A  matrix.chat.yourdomain.com   ->  <LXC IP>
A  meet.chat.yourdomain.com     ->  <LXC IP>

SRV  _matrix._tcp.chat.yourdomain.com  10 0 443  matrix.chat.yourdomain.com
```

### Step 3 — Run setup inside the LXC

Open the LXC console in Unraid and run:

```bash
cd /root
./setup.sh --domain chat.yourdomain.com
```

Setup will configure all services, optionally obtain Let's Encrypt certificates, create your Matrix admin account, and start everything. Credentials are saved to `/root/.matrix-stack.env` (chmod 600).

**Options:**

```
--domain <domain>       Required. Your public domain.
--admin-user <user>     Matrix admin username  (default: admin)
--admin-pass <pass>     Matrix admin password  (auto-generated if omitted)
--skip-ssl              Self-signed certs, skip Let's Encrypt
--staging               Use Let's Encrypt staging (testing only)
```

If DNS isn't ready yet, run with `--skip-ssl` first, then later:

```bash
/root/scripts/renew-ssl.sh
```

---

## What's inside

| Service | Role |
|---|---|
| **Matrix Synapse** | Homeserver (federated, encrypted messaging) |
| **Element Web** | Web client served at your domain root |
| **Jitsi Meet** | Video/voice — accessible only as Element widget |
| **coturn** | TURN/STUN server for WebRTC (Matrix + Jitsi) |
| **Nginx** | SNI stream router — port 443 TLS, port 80 redirect |
| **PostgreSQL 16** | Synapse database |
| **Valkey** | Redis-compatible cache for Synapse |

---

## Security architecture

```
[Internet]
  │
  ├─ :80  ──▶ Nginx HTTP ──▶ HTTPS redirect + ACME challenge
  │
  ├─ :443 ──▶ Nginx stream (ssl_preread SNI)
  │              │
  │              ├─ chat.yourdomain.com        ──▶ Element Web
  │              ├─ matrix.chat.yourdomain.com ──▶ Matrix Synapse :8008
  │              └─ meet.chat.yourdomain.com   ──▶ Jitsi (widget only)
  │
  ├─ :3478/UDP  ──▶ coturn TURN/STUN
  └─ :10000/UDP ──▶ Jitsi Video Bridge media
```

**Jitsi is widget-only:** Direct browser navigation to `meet.<domain>` returns HTTP 403.
Jitsi is only reachable as an iframe widget from within Element Web, enforced by Nginx
checking `Origin` and `Referer` headers.

All TLS is terminated at Nginx. Internal services communicate over loopback only.

---

## File structure

```
unraid-lxc-matrix/
├── setup.sh                    # Run inside LXC to configure your domain
├── createLXCarchive.sh         # Run on Unraid host to build release archive
├── lxc_container_template.xml  # Unraid LXC plugin template
├── notes.txt                   # Component versions and EOL info
│
├── build/                      # Phase 1: install packages (runs during archive build)
│   ├── 01-dependencies.sh      # APT repos + base packages
│   ├── 02-postgres.sh          # PostgreSQL 16
│   ├── 03-valkey.sh            # Valkey binary
│   ├── 04-synapse.sh           # Matrix Synapse
│   ├── 05-element.sh           # Element Web (latest release)
│   ├── 06-jitsi.sh             # Jitsi stack (Java 17 + prosody + JVB2)
│   ├── 07-coturn.sh            # coturn TURN server
│   ├── 08-nginx.sh             # Nginx + stream module
│   ├── 09-copy-setup.sh        # Stage setup scripts into /root/
│   ├── 98-crontab.sh           # Pre-stage cron/logrotate
│   └── 99-cleanup.sh           # Image cleanup
│
├── setup/                      # Phase 2: configure with real domain/secrets
│   ├── 01-postgres-config.sh   # Create synapse DB and user
│   ├── 02-valkey-config.sh     # Write valkey.conf with password
│   ├── 03-synapse-config.sh    # Write homeserver.yaml + start
│   ├── 04-element-config.sh    # Write config.json
│   ├── 05-jitsi-config.sh      # Write all Jitsi configs + start
│   ├── 06-coturn-config.sh     # Write turnserver.conf + start
│   ├── 07-nginx-config.sh      # Write vhosts + SNI map + start
│   ├── 08-ssl.sh               # Let's Encrypt or self-signed
│   └── 09-verify.sh            # Final health check
│
└── scripts/
    ├── renew-ssl.sh            # Re-run SSL after DNS propagation
    └── stack-status.sh         # Show service + endpoint status
```

---

## After setup

```bash
# Check everything is running
/root/scripts/stack-status.sh

# Get Let's Encrypt certs (after DNS propagates)
/root/scripts/renew-ssl.sh

# View credentials
cat /root/.matrix-stack.env
```

---

## Requirements

- Unraid with [LXC plugin by ich777](https://forums.unraid.net/topic/135752-plugin-lxc/)
- Debian 12 (Bookworm) — shipped in the archive
- Public domain with A records pointing to the LXC IP
- Ports open to the LXC: **80, 443, 3478/udp, 5349/tcp, 10000/udp**

---

## Credits

Structure modeled after [bmartino1/unraid-lxc-unifi](https://github.com/bmartino1/unraid-lxc-unifi).
Thanks to [ich777](https://github.com/ich777) for the Unraid LXC plugin and patterns.
