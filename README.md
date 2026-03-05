# unraid-lxc-matrix

> **Self-hosted secure communications stack in a single Unraid LXC**
>
> Matrix Synapse · Element Web · Jitsi Meet (widget-only) · coturn · Nginx · PostgreSQL · Valkey

---

## Table of contents

- [Prerequisites](#prerequisites)
- [Install on Unraid](#install-on-unraid)
- [Setup options](#setup-options)
- [After setup](#after-setup)
- [Admin console](#admin-console)
- [Management scripts](#management-scripts)
- [Security architecture](#security-architecture)
- [Configuration reference](#configuration-reference)
- [Troubleshooting](#troubleshooting)
- [Upstream documentation](#upstream-documentation)
- [File structure](#file-structure)
- [Component versions](#component-versions)
- [Credits](#credits)

---

## Prerequisites

Before installing the LXC template, make sure you have the following in place:

- **Unraid 6.10+** with the [LXC plugin by ich777](https://forums.unraid.net/topic/123935-plugin-lxc-plugin/) installed and configured
- Basic understanding of command-line usage
- A **public domain** with the ability to create A and SRV DNS records
- **Ports forwarded** on your router to the LXC container's IP: **80/tcp, 443/tcp, 3478/udp, 3478/tcp, 5349/tcp, 10000/udp**
- (Optional) A valid email address for Let's Encrypt certificate registration

The container image is based on **Debian 12 (Bookworm), amd64** and ships pre-installed with all required packages. No additional downloads are needed inside the container.

---

## Install on Unraid

### Step 1 — Download the LXC template

Open an Unraid terminal (SSH or the web terminal) and download the template XML to `/tmp`:

```bash
wget -O /tmp/lxc_container_template.xml \
  https://raw.githubusercontent.com/bmartino1/unraid-lxc-matrix/main/lxc_container_template.xml
```

### Step 2 — Deploy the container

Navigate to `http://<your-unraid-ip>/LXCAddTemplate` in your browser. The LXC plugin will display the template you just downloaded. Review the settings and make any changes if necessary (network interface, memory limits, etc.), then click **Apply** and wait for the **Done** button to appear.

The plugin downloads the pre-built container archive from GitHub releases and creates the LXC. This may take a few minutes depending on your internet connection.

### Step 3 — Set the root password

Start the container from the Unraid LXC page and open the console. Set a root password if one is not already configured:

```bash
passwd root
```

### Step 4 — (Recommended) Assign a static IP

A static IP is strongly recommended since DNS records need to point to this container. You can either assign a static lease on your router/DHCP server, or configure it directly inside the container:

```bash
nano /etc/systemd/network/eth0.network
```

After changing the IP, fully **stop** and **start** the container (do not just restart — a full stop/start is required for the new IP to take effect).

### Step 5 — Point DNS to the LXC IP

Before running setup, create these DNS records pointing to your LXC container's static IP:

```
A    chat.yourdomain.com          →  <LXC IP>
A    matrix.chat.yourdomain.com   →  <LXC IP>
A    meet.chat.yourdomain.com     →  <LXC IP>

SRV  _matrix._tcp.chat.yourdomain.com  10 0 443  matrix.chat.yourdomain.com
```

The A records route web traffic to the container. The SRV record allows other Matrix homeservers to discover yours for federation.

### Step 6 — Run setup inside the LXC

Open the LXC console and run:

```bash
cd /root
./setup.sh --domain chat.yourdomain.com
```

Setup will configure all services with your domain, generate secure passwords for every component, optionally obtain Let's Encrypt TLS certificates, create your Matrix admin account, and start the full stack. All credentials are saved to `/root/.matrix-stack.env` (permissions `600`).

If DNS hasn't fully propagated yet, run with `--skip-ssl` to use self-signed certificates first, then request real certificates later with:

```bash
/root/scripts/renew-ssl.sh
```

---

## Setup options

The `setup.sh` script accepts the following flags:

| Flag | Description | Default |
|---|---|---|
| `--domain <domain>` | **Required.** Your public domain (e.g. `chat.example.com`). Element Web is served at the domain root, Matrix API at `matrix.<domain>`, and Jitsi at `meet.<domain>`. | — |
| `--admin-user <user>` | Username for the Matrix admin account. | `admin` |
| `--admin-pass <pass>` | Password for the Matrix admin account. | Auto-generated (40 chars) |
| `--postgres-pass <pass>` | PostgreSQL password for the `synapse` database user. | Auto-generated |
| `--valkey-pass <pass>` | Valkey (Redis-compatible cache) authentication password. | Auto-generated |
| `--jitsi-pass <pass>` | Jitsi internal component password. | Auto-generated |
| `--turn-secret <secret>` | Shared secret for coturn HMAC authentication. | Auto-generated (64 hex chars) |
| `--skip-ssl` / `--no-ssl` | Use self-signed certificates instead of Let's Encrypt. Useful when DNS isn't ready yet. | `false` |
| `--staging` | Use the Let's Encrypt staging environment. For testing only — browsers will not trust staging certificates. | `false` |
| `--reconfigure` | Re-run the full configuration with a new domain or new secrets. Also accessible as `--reset`. | `false` |

All auto-generated passwords and secrets are saved to `/root/.matrix-stack.env` after setup completes. View them at any time:

```bash
cat /root/.matrix-stack.env
```

### What setup configures

Setup runs nine phases in order:

1. **PostgreSQL** — creates the `synapse` database and user with C locale (required by Synapse)
2. **Valkey** — writes `valkey.conf` with password authentication
3. **Matrix Synapse** — writes `homeserver.yaml` with database, cache, TURN, and federation settings; generates the signing key; starts the service
4. **Element Web** — writes `config.json` pointing at your homeserver with Jitsi widget integration
5. **Jitsi Meet** — configures prosody, jicofo, and JVB2 for widget-only video calls through Element
6. **coturn** — writes `turnserver.conf` for TURN/STUN relay (WebRTC NAT traversal for both Matrix and Jitsi)
7. **Nginx** — writes virtual host configs and the SNI stream router; enables all sites
8. **SSL** — obtains Let's Encrypt certificates (or generates self-signed if `--skip-ssl`)
9. **Verify** — runs health checks against all services and endpoints

---

## After setup

### Check status

```bash
/root/scripts/stack-status.sh
```

This shows a full dashboard: service health, port bindings, SSL certificate expiry, database size, user count, DNS resolution check, and endpoint URLs. Add `--logs` to include recent log tails, or `--json` for machine-readable output.

### Get Let's Encrypt certificates (after DNS propagation)

```bash
/root/scripts/renew-ssl.sh
```

Safe to run multiple times. Certbot auto-renewal is configured via cron (runs daily at 3 AM).

### View credentials

```bash
cat /root/.matrix-stack.env
```

### Log in

Open `https://chat.yourdomain.com` in a browser to access Element Web. Sign in with the admin username and password shown during setup (or stored in the `.env` file).

---

## Admin console

The stack includes an interactive admin menu that wraps all management scripts into a single interface:

```bash
/root/scripts/admin.sh
```

The menu provides access to stack status, log viewing, service control, updates, backups, user management, registration tokens, room administration, and SSL renewal — all from one place.

---

## Management scripts

All scripts are located in `/root/scripts/` and must be run as root. Each script supports `--help` for full usage details.

### Stack operations

| Script | Description |
|---|---|
| `stack-status.sh` | Health dashboard showing services, ports, SSL, DB size, DNS, and endpoints. Supports `--logs` and `--json`. |
| `service-control.sh <action> <target>` | Start, stop, restart, reload, or check individual services or the full stack. Targets: `all`, `synapse`, `nginx`, `postgresql`, `valkey`, `prosody`, `jicofo`, `jvb`, `coturn`. |
| `logs.sh [service]` | View, tail, or search logs. Services: `synapse`, `nginx`, `nginx-stream`, `valkey`, `coturn`, `prosody`, `all`, `errors`. Supports `--follow` and `--lines N`. |
| `update-stack.sh [target]` | Update components to latest versions. Targets: `all`, `element` (new GitHub release), `packages` (apt upgrade for Synapse, Jitsi, Nginx, etc.), `valkey` (new binary from GitHub). |
| `backup.sh` | Backup all config, database, media, SSL certs, and secrets. Supports `--dest <dir>` and `--no-media`. |
| `renew-ssl.sh` | Re-run SSL certificate provisioning after DNS has propagated. |

### User management

| Script | Description |
|---|---|
| `create-user.sh` | Create a new Matrix user. Supports `--username`, `--password`, and `--admin` flags, or runs interactively. |
| `list-users.sh` | List all users on the homeserver. Supports `--guests`, `--deactivated`, and `--csv`. |
| `user-manage.sh` | Manage existing users. Actions: `info`, `deactivate`, `reactivate`, `promote`, `demote`, `reset-password`, `shadow-ban`, `logout-all`. |
| `get-admin-token.sh` | Log in as admin and retrieve an API access token. Use `--save` to store it in the `.env` file. |

### Registration control

| Script | Description |
|---|---|
| `registration-toggle.sh <action>` | Enable or disable open registration. Actions: `enable`, `disable`, `status`. When disabled, new users need an invite token. |
| `registration-tokens.sh <command>` | Manage invite tokens. Commands: `list`, `create` (with `--uses N` and `--expiry DAYS`), `delete --token TOKEN`, `info --token TOKEN`. |

To invite a user when open registration is disabled, create a token and share the link:

```bash
/root/scripts/registration-tokens.sh create --uses 1 --expiry 7
```

This prints a registration URL like `https://chat.yourdomain.com/#/register?token=TOKEN` that the invited user can open to create their account.

### Room administration

| Script | Description |
|---|---|
| `room-manage.sh <command>` | Room admin operations. Commands: `list` (with `--search`), `info --room ROOM_ID`, `members --room ROOM_ID`, `delete --room ROOM_ID`, `purge --room ROOM_ID --before DAYS`. |

---

## Security architecture

```
[Internet]
  │
  ├─ :80/tcp    ──▶ Nginx HTTP ──▶ HTTPS redirect + ACME challenge
  │
  ├─ :443/tcp   ──▶ Nginx stream (ssl_preread SNI)
  │                    │
  │                    ├─ chat.yourdomain.com        ──▶ Element Web (static files)
  │                    ├─ matrix.chat.yourdomain.com ──▶ Matrix Synapse :8008
  │                    └─ meet.chat.yourdomain.com   ──▶ Jitsi (widget only — 403 for direct access)
  │
  ├─ :3478/udp+tcp ──▶ coturn TURN/STUN
  ├─ :5349/tcp     ──▶ coturn TURNS (TLS)
  └─ :10000/udp    ──▶ Jitsi Video Bridge media
```

All TLS is terminated at Nginx. Internal services communicate over loopback (`127.0.0.1`) only.

**Jitsi is widget-only by design.** Direct browser navigation to `meet.<domain>` returns HTTP 403. Jitsi is only reachable as an iframe widget from within Element Web. Nginx enforces this by checking `Origin` and `Referer` headers and sets `Content-Security-Policy: frame-ancestors` to restrict embedding to the Element domain only.

### Ports summary

**External** (forward these from your router to the LXC IP):

| Port | Protocol | Service |
|---|---|---|
| 80 | TCP | Nginx — HTTP redirect + ACME challenge |
| 443 | TCP | Nginx — HTTPS SNI stream router |
| 3478 | UDP + TCP | coturn — TURN/STUN |
| 5349 | TCP | coturn — TURNS (TLS) |
| 10000 | UDP | Jitsi Video Bridge — media relay |

**Internal** (loopback only, no forwarding needed):

| Port | Service |
|---|---|
| 8008 | Matrix Synapse HTTP |
| 8443 | Nginx internal HTTPS |
| 9000 | Synapse metrics/health |
| 5280 | prosody BOSH + WebSocket |
| 5347 | prosody component port |
| 5222 | prosody c2s |
| 5269 | prosody s2s |
| 9090 | JVB Colibri HTTP |
| 5432 | PostgreSQL |
| 6379 | Valkey |
| 4443 | JVB TCP media relay |

### NAT / external IP note

If your Unraid server is behind NAT (which is typical for home networks), coturn needs to know your public IP for TURN relay to work correctly. After setup, edit `/etc/turnserver.conf` and uncomment and set the `external-ip` line:

```
external-ip=YOUR_PUBLIC_IP/LXC_INTERNAL_IP
```

Then restart coturn:

```bash
/root/scripts/service-control.sh restart coturn
```

---

## Configuration reference

### What's inside

| Service | Role | Config location |
|---|---|---|
| **Matrix Synapse** | Homeserver — federated, end-to-end encrypted messaging | `/etc/matrix-synapse/homeserver.yaml` |
| **Element Web** | Web client served at your domain root | `/var/www/element/config.json` |
| **Jitsi Meet** | Video/voice calls — accessible only as an Element widget | `/etc/jitsi/`, `/etc/prosody/`, `/usr/share/jitsi-meet/config.js` |
| **coturn** | TURN/STUN server for WebRTC NAT traversal (Matrix + Jitsi) | `/etc/turnserver.conf` |
| **Nginx** | SNI stream router — TLS on port 443, HTTP redirect on port 80 | `/etc/nginx/sites-available/` |
| **PostgreSQL 16** | Synapse database (`synapse` DB, `synapse` user, C locale) | `/etc/postgresql/16/main/` |
| **Valkey** | Redis-compatible cache for Synapse worker performance | `/etc/valkey/valkey.conf` |

### Key files

| File | Purpose |
|---|---|
| `/root/.matrix-stack.env` | All credentials, secrets, and domain config (chmod 600) |
| `/etc/matrix-synapse/homeserver.yaml` | Synapse homeserver configuration |
| `/var/lib/matrix-synapse/<domain>.signing.key` | **Critical** — Synapse signing key. Back this up. If lost, federation identity is broken. |
| `/var/www/element/config.json` | Element Web client configuration |
| `/etc/turnserver.conf` | coturn TURN/STUN settings |
| `/etc/ssl/nginx/` | TLS certificates (self-signed or Let's Encrypt) |
| `/var/lib/matrix-synapse/media_store/` | Uploaded media files |

### Backups

Run the backup script to create a timestamped archive of all config, the database, media, and certificates:

```bash
/root/scripts/backup.sh
/root/scripts/backup.sh --dest /mnt/user/backups
/root/scripts/backup.sh --no-media          # skip media store for faster backup
```

The backup includes the signing key, `.env` secrets, Synapse config, a full PostgreSQL dump, Nginx configs, SSL certs, and all service configs (Valkey, coturn, Jitsi, prosody, Element). To restore the database from a backup:

```bash
PGPASSWORD=<postgres-pass> pg_restore -h 127.0.0.1 -U synapse -d synapse /path/to/synapse-db.pgdump
```

### Updating

```bash
/root/scripts/update-stack.sh              # update everything
/root/scripts/update-stack.sh element      # update Element Web only (fetches latest GitHub release)
/root/scripts/update-stack.sh packages     # apt upgrade Synapse, Jitsi, Nginx, PostgreSQL, coturn
/root/scripts/update-stack.sh valkey       # update Valkey binary from GitHub
```

The Element Web updater preserves your `config.json` across updates automatically.

---

## Troubleshooting

**Services not starting:** Run `stack-status.sh` to see which service is down, then check its logs:

```bash
/root/scripts/logs.sh errors              # scan all logs for errors
/root/scripts/logs.sh --follow synapse    # live-tail the Synapse log
```

**SSL certificate issues:** If you ran setup with `--skip-ssl` and DNS is now ready:

```bash
/root/scripts/renew-ssl.sh
```

**Federation not working:** Verify DNS records are correct (especially the SRV record), check that port 443 is reachable from the internet, and test with the Matrix federation tester: https://federationtester.matrix.org/

**Jitsi video calls not connecting:** Make sure ports 3478/udp, 5349/tcp, and 10000/udp are forwarded to the LXC IP. If behind NAT, configure the `external-ip` in `/etc/turnserver.conf` as described in the NAT section above.

**Can't access `meet.<domain>` directly:** This is intentional. Jitsi is configured as widget-only and returns 403 for direct browser access. Video calls work through Element Web.

**Re-running setup:** If you need to change the domain or regenerate all secrets:

```bash
./setup.sh --reconfigure --domain new.domain.com
```

---

## Upstream documentation

These are the official documentation resources for each component in the stack:

- **Matrix Synapse** (homeserver configuration, federation, workers, admin API): https://element-hq.github.io/synapse/latest/
- **Element Web** (client configuration options, theming, labs features): https://github.com/element-hq/element-web/blob/develop/docs/config.md
- **Jitsi Meet** (self-hosting guide, oonfiguration, oroduction deployment): https://jitsi.github.io/handbook/docs/devops-guide/devops-guide-docker
- **coturn** (TURN/STUN server configuration, NAT traversal, TLS setup): https://github.com/coturn/coturn/wiki/turnserver
- **Matrix Federation Tester** (verify your homeserver is reachable for federation): https://federationtester.matrix.org/
- **Unraid LXC Plugin** (plugin support and discussion): https://forums.unraid.net/topic/123935-plugin-lxc-plugin/

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
│   ├── 03-synapse-config.sh    # Write homeserver.yaml + signing key + start
│   ├── 04-element-config.sh    # Write config.json with homeserver + Jitsi widget
│   ├── 05-jitsi-config.sh      # Write all Jitsi configs (prosody, jicofo, JVB2) + start
│   ├── 06-coturn-config.sh     # Write turnserver.conf + start
│   ├── 07-nginx-config.sh      # Write vhosts + SNI map + start
│   ├── 08-ssl.sh               # Let's Encrypt or self-signed
│   └── 09-verify.sh            # Final health check
│
├── scripts/                    # Management and admin tools
│   ├── admin.sh                # Interactive admin menu
│   ├── stack-status.sh         # Health dashboard
│   ├── service-control.sh      # Start/stop/restart services
│   ├── logs.sh                 # View and search logs
│   ├── update-stack.sh         # Update components
│   ├── backup.sh               # Full backup (config, DB, media, certs)
│   ├── create-user.sh          # Create Matrix users
│   ├── list-users.sh           # List all users
│   ├── user-manage.sh          # Manage users (deactivate, promote, reset-pw, etc.)
│   ├── get-admin-token.sh      # Retrieve admin API access token
│   ├── registration-toggle.sh  # Enable/disable open registration
│   ├── registration-tokens.sh  # Manage invite tokens
│   ├── room-manage.sh          # Room admin (list, delete, purge)
│   ├── renew-ssl.sh            # Re-run SSL provisioning
│   └── lib/
│       └── common.sh           # Shared functions (colors, API calls, env loading)
│
└── LICENSE
```

---

## Component versions

All components are installed from their official repositories and are current as of March 2026:

| Component | Source | Notes |
|---|---|---|
| **Debian** | 12 (Bookworm) | OS base — EOL June 2028 |
| **Matrix Synapse** | packages.matrix.org | Latest stable release |
| **Element Web** | GitHub releases | Latest release tarball |
| **Jitsi Meet** | download.jitsi.org stable | prosody + jicofo + JVB2 |
| **Java** | OpenJDK 17 | Required by JVB2/jicofo — LTS EOL September 2029 |
| **PostgreSQL** | 16 (postgresql.org) | EOL November 2028 |
| **Valkey** | 8.x (GitHub releases) | Redis-compatible, open-source replacement |
| **coturn** | Debian packages (4.6.x) | TURN/STUN relay |
| **Nginx** | Debian packages (1.22.x) | Requires `libnginx-mod-stream` for SNI routing |
| **Certbot** | Debian packages | Auto-renewal via daily cron |

---

## Credits

Structure modeled after [bmartino1/unraid-lxc-unifi](https://github.com/bmartino1/unraid-lxc-unifi).
Thanks to [ich777](https://github.com/ich777) for the [Unraid LXC plugin](https://forums.unraid.net/topic/123935-plugin-lxc-plugin/) and the pre-built container template patterns.
