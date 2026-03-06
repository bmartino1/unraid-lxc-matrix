# unraid-lxc-matrix

Its ALive! :) see https://github.com/bmartino1/unraid-lxc-matrix/blob/main/WIP-Notes-Updates.txt    

> **Self-hosted secure communications stack in a single Unraid LXC**
>
> Matrix Synapse · Element Web · Jitsi Meet · coturn · Nginx · PostgreSQL · Valkey

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Install on Unraid](#install-on-unraid)
- [Initial Setup](#initial-setup)
- [Setup Options](#setup-options)
- [After Setup](#after-setup)
- [Admin Scripts](#admin-scripts)
- [Security Architecture](#security-architecture)
- [Ports Reference](#ports-reference)
- [Troubleshooting](#troubleshooting)
- [Credits & License](#credits--license)

---

## Overview

This project provides a prebuilt **Debian 12 Unraid LXC** containing a full self-hosted communications stack:

| Service | Role |
|---|---|
| **Matrix Synapse** | Federated, end-to-end encrypted homeserver |
| **Element Web** | Web-based Matrix client |
| **Jitsi Meet** | Voice/video calls (Element widget only) |
| **coturn** | TURN/STUN relay for WebRTC NAT traversal |
| **Nginx** | Reverse proxy, TLS termination, SNI stream routing |
| **PostgreSQL 16** | Synapse database backend |
| **Valkey** | Redis-compatible cache for Synapse performance |

The goal is a **turnkey setup**: import the template, assign a static IP, run one script, and have a working stack.

---

## Prerequisites

Before you begin, make sure you have the following ready:

- **Unraid 6.10+** with the [LXC plugin by ich777](https://forums.unraid.net/topic/123935-plugin-lxc-plugin/) installed
- A **public domain name** with the ability to create DNS A records
- **Ports forwarded** on your router to the LXC container IP (see [Ports Reference](#ports-reference))
- *(Optional)* An email address for Let's Encrypt certificate registration

---

## Install on Unraid

### Step 1 — Download the LXC template

Open an Unraid terminal (SSH or the web console) and run:

```bash
wget -O /tmp/lxc_container_template.xml \
  https://raw.githubusercontent.com/bmartino1/unraid-lxc-matrix/main/lxc_container_template.xml
```

### Step 2 — Import the template

Navigate to the LXC template import page in your browser:

```
/LXCAddTemplate
```

```
http://<Your-Unraid-IP>/LXCAddTemplate
```

The LXC plugin will detect the downloaded template. Review settings if needed, then click **Create / Apply** and wait for the **Done** button.

Set your options... In Template Create the container example
| Container Name | `matrix` |

then open the LXC console.

### Step 3 — Run the intail setup scritps and configurations!
**See Below**

---

## Initial Setup

Follow these steps in order after the container is created.

### Step 1 — Assign a static IP

A static IP is required so DNS records point consistently to this container. Run the helper script inside the LXC console:

```bash
/root/scripts/set-static-ip.sh
```

This prompts for your network values and writes the config to `/etc/systemd/network/eth0.network`. Example output:

```ini
[Match]
Name=eth0

[Network]
Address=192.168.1.50/24
Gateway=192.168.1.1
DNS=192.168.1.1
DNS=8.8.8.8
Domains=local

[Link]
MTUBytes=1500
```

> ⚠️ After setting the static IP, **fully stop and start** the LXC (do not just restart). The new IP will not take effect until a full stop/start cycle.

### Step 2 — Forward ports on your router

Before running setup, forward the following ports on your router to the LXC container's static IP:

| Port | Protocol | Purpose |
|---|---|---|
| 80 | TCP | Nginx — HTTP redirect + Let's Encrypt ACME challenge |
| 443 | TCP | Nginx — HTTPS (Element Web, Matrix API, Jitsi widget) |
| 3478 | UDP + TCP | coturn — TURN/STUN |
| 5349 | TCP | coturn — TURNS (TLS) |
| 10000 | UDP | Jitsi Video Bridge — media relay |

*Full lets encrypt setup can work with only port 443 and port 80 setup...

### Step 3 — Create DNS records

Point the following DNS A records to your **public IP** (the one your router forwards to the LXC):

```
A    chat.yourdomain.com          →  <your public IP>
A    matrix.chat.yourdomain.com   →  <your public IP>
A    meet.chat.yourdomain.com     →  <your public IP>
A    turn.chat.yourdomain.com     →  <your public IP>

SRV  _matrix._tcp.chat.yourdomain.com  10 0 443  matrix.chat.yourdomain.com
```

The SRV record enables Matrix federation so other homeservers can discover yours.

### Step 4 — Run setup

Open the LXC console and run:

```bash
/root/setup.sh --domain chat.yourdomain.com --admin-pass ChangeMe
```

Setup runs nine phases: PostgreSQL → Valkey → Synapse → Element Web → Jitsi → coturn → Nginx → SSL → health check. All credentials are saved to `/root/.matrix-stack.env` (chmod 600).

> If DNS has not propagated yet, add `--skip-ssl` to use self-signed certificates first. You can request real certificates later with `/root/scripts/renew-ssl.sh`.

### Step 5 — Get the admin API token

After setup completes, run:

```bash
/root/scripts/get-admin-token.sh --save
```

This logs in as the admin user, retrieves an API access token, and saves it to the `.env` file. The token is used by several admin scripts for authenticated API calls.

### Step 6 — Log in

Open `https://chat.yourdomain.com` in a browser. Sign in with the admin credentials shown during setup or stored in:

```bash
cat /root/.matrix-stack.env
```

---

## Setup Options

`setup.sh` accepts the following flags:

| Flag | Description | Default |
|---|---|---|
| `--domain <domain>` | **Required.** Your public domain. Element Web is served at the root, Matrix API at `matrix.<domain>`, Jitsi at `meet.<domain>`. | — |
| `--admin-user <user>` | Matrix admin account username. | `admin` |
| `--admin-pass <pass>` | Matrix admin account password. | Auto-generated (40 chars) |
| `--postgres-pass <pass>` | PostgreSQL password for the `synapse` user. | Auto-generated |
| `--valkey-pass <pass>` | Valkey authentication password. | Auto-generated |
| `--jitsi-pass <pass>` | Jitsi internal component password. | Auto-generated |
| `--turn-secret <secret>` | Shared secret for coturn HMAC authentication. | Auto-generated (64 hex chars) |
| `--external-ip <ip>` | Override the public IP reported to coturn. Useful if auto-detection fails. | Auto-detected |
| `--skip-ssl` / `--no-ssl` | Use self-signed certificates instead of Let's Encrypt. | `false` |
| `--staging` | Use Let's Encrypt staging environment (for testing — not trusted by browsers). | `false` |
| `--reconfigure` / `--reset` | Re-run full configuration with new domain or secrets. | `false` |

---

## After Setup

### Check stack health

```bash
/root/scripts/stack-status.sh
```

Displays a full dashboard: service states, port bindings, SSL certificate expiry, database size, user count, DNS check, and endpoint URLs.

### View stored credentials

```bash
cat /root/.matrix-stack.env
```

### Renew SSL certificates

Certbot auto-renewal runs daily at 3 AM via cron. To manually renew or request certificates after DNS propagation:

```bash
/root/scripts/renew-ssl.sh
```

### NAT / external IP note

If your Unraid server is behind NAT (typical for home networks), coturn needs your public IP to relay TURN traffic correctly. After setup, edit `/etc/turnserver.conf` and set:

```
external-ip=YOUR_PUBLIC_IP/LXC_INTERNAL_IP
```

Then restart coturn:

```bash
/root/scripts/service-control.sh restart coturn
```

---

## Admin Scripts

All scripts live in `/root/scripts/` and must be run as root. Each supports `--help` for full usage details.

An interactive menu wrapping all scripts is available at:

```bash
/root/scripts/admin.sh
```

### Stack operations

| Script | Description |
|---|---|
| `stack-status.sh` | Health dashboard: services, ports, SSL expiry, DB size, DNS, endpoints. Supports `--logs` and `--json`. |
| `service-control.sh <action> <target>` | Start, stop, restart, or reload services. Targets: `all`, `synapse`, `nginx`, `postgresql`, `valkey`, `prosody`, `jicofo`, `jvb`, `coturn`. |
| `logs.sh [service]` | View or tail logs. Services: `synapse`, `nginx`, `valkey`, `coturn`, `prosody`, `all`, `errors`. Supports `--follow` and `--lines N`. |
| `update-stack.sh [target]` | Update components. Targets: `all`, `element`, `packages`, `valkey`. |
| `backup.sh` | Full backup of config, database, media, SSL certs, and secrets. Supports `--dest <dir>` and `--no-media`. |
| `renew-ssl.sh` | Re-run SSL certificate provisioning. |

### User management

| Script | Description |
|---|---|
| `create-user.sh` | Create a Matrix user. Supports `--username`, `--password`, `--admin`, or runs interactively. |
| `list-users.sh` | List all homeserver users. Supports `--guests`, `--deactivated`, `--csv`. |
| `user-manage.sh` | Manage users: `info`, `deactivate`, `reactivate`, `promote`, `demote`, `reset-password`, `shadow-ban`, `logout-all`. |
| `get-admin-token.sh` | Retrieve admin API token. Use `--save` to store it in the `.env` file. |

### Registration control

| Script | Description |
|---|---|
| `registration-toggle.sh <action>` | Enable or disable open registration. Actions: `enable`, `disable`, `status`. |
| `registration-tokens.sh <command>` | Manage invite tokens. Commands: `list`, `create` (with `--uses N` and `--expiry DAYS`), `delete`, `info`. |

To invite a user when open registration is disabled:

```bash
/root/scripts/registration-tokens.sh create --uses 1 --expiry 7
```

This prints a registration URL like `https://chat.yourdomain.com/#/register?token=TOKEN` to share with the invited user.

### Room administration

| Script | Description |
|---|---|
| `room-manage.sh <command>` | Room operations: `list` (with `--search`), `info`, `members`, `delete`, `purge` (with `--before DAYS`). |

---

## Security Architecture

```
[Internet]
  │
  ├─ :80/tcp    ──▶ Nginx ──▶ HTTPS redirect + ACME challenge
  │
  ├─ :443/tcp   ──▶ Nginx SNI stream router
  │                    ├─ chat.yourdomain.com        ──▶ Element Web
  │                    ├─ matrix.chat.yourdomain.com ──▶ Matrix Synapse :8008
  │                    └─ meet.chat.yourdomain.com   ──▶ Jitsi (widget only — 403 direct)
  │
  ├─ :3478/udp+tcp ──▶ coturn TURN/STUN
  ├─ :5349/tcp     ──▶ coturn TURNS (TLS)
  └─ :10000/udp    ──▶ Jitsi Video Bridge media
```

All TLS is terminated at Nginx. Internal services communicate over loopback (`127.0.0.1`) only.

**Jitsi is widget-only by design.** Direct browser navigation to `meet.<domain>` returns HTTP 403. Jitsi is only accessible as an embedded iframe widget inside Element Web. Nginx enforces this via `Origin`/`Referer` header checks and `Content-Security-Policy: frame-ancestors`.

---

## Ports Reference

**External** — forward these from your router to the LXC IP:

| Port | Protocol | Service |
|---|---|---|
| 80 | TCP | Nginx — HTTP redirect + ACME |
| 443 | TCP | Nginx — HTTPS SNI router |
| 3478 | UDP + TCP | coturn — TURN/STUN |
| 5349 | TCP | coturn — TURNS (TLS) |
| 10000 | UDP | Jitsi Video Bridge — media |

**Internal** — loopback only, no forwarding needed:

| Port | Service |
|---|---|
| 8008 | Matrix Synapse HTTP |
| 5432 | PostgreSQL |
| 6379 | Valkey |
| 5280 | Prosody BOSH + WebSocket |
| 5347 | Prosody component |
| 9090 | JVB Colibri HTTP |
| 4443 | JVB TCP relay |

---

## Troubleshooting

**Services not starting**

```bash
/root/scripts/stack-status.sh
/root/scripts/logs.sh errors
/root/scripts/logs.sh --follow synapse
```

**SSL issues after running with `--skip-ssl`**

Once DNS has propagated, run:

```bash
/root/scripts/renew-ssl.sh
```

**Federation not working**

Verify your SRV record is correct, port 443 is reachable from the internet, and test with the [Matrix Federation Tester](https://federationtester.matrix.org/).

**Jitsi calls not connecting**

Confirm ports 3478/udp, 5349/tcp, and 10000/udp are forwarded. If behind NAT, set `external-ip` in `/etc/turnserver.conf` as described in the [After Setup](#after-setup) section.

**Can't access `meet.<domain>` directly**

This is intentional. Jitsi returns 403 for direct access. Video calls work through the Element Web interface only.

**Re-running setup with a new domain or new secrets**

```bash
/root/setup.sh --reconfigure --domain new.example.com
```

---

## Credits & License

Special thanks to:

- **[ich777](https://github.com/ich777)** — for the [Unraid LXC plugin](https://forums.unraid.net/topic/123935-plugin-lxc-plugin/), pre-built container template patterns, and ongoing support
- Structure modeled after [bmartino1/unraid-lxc-unifi](https://github.com/bmartino1/unraid-lxc-unifi)
- **Adam from (https://www.hax0rbana.org/)** for initial assistance and information that helped shape the working direction

This project is licensed under the terms of the [LICENSE](./LICENSE) file in this repository.

