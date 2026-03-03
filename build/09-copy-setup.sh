#!/bin/bash
# =============================================================================
# BUILD PHASE - Stage 09: Stage the setup scripts into the LXC rootfs
# Places setup.sh at /root/setup.sh so user can run it after first boot
# Also installs the health-check helper and status script
# =============================================================================
set -euo pipefail

echo "==> [09] Staging setup scripts into the LXC at /root/..."

# The build process (createLXCarchive.sh) copies the repo's setup/ directory
# into /tmp/setup inside the container, then this script moves them to /root/
if [[ -d /tmp/setup ]]; then
  cp -r /tmp/setup/* /root/
  chmod +x /root/setup.sh 2>/dev/null || true
  chmod +x /root/setup/*.sh 2>/dev/null || true
  echo "   Setup scripts installed from /tmp/setup/"
else
  echo "   WARNING: /tmp/setup not found - setup scripts must be placed manually at /root/setup.sh"
fi

echo "==> [09] Writing /etc/motd to guide user on first login..."
cat > /etc/motd <<'MOTD'

  ╔══════════════════════════════════════════════════════════════╗
  ║       Matrix Synapse + Element Web + Jitsi LXC Stack        ║
  ╚══════════════════════════════════════════════════════════════╝

  This LXC has all packages pre-installed but NOT yet configured.

  To complete setup, run:

      cd /root
      ./setup.sh --domain chat.example.com

  Options:
      --domain <domain>       Required. Your public domain.
      --admin-user <user>     Matrix admin username (default: admin)
      --admin-pass <pass>     Matrix admin password (auto-generated if omitted)
      --skip-ssl              Use self-signed certs (for internal/testing)
      --staging               Use Let's Encrypt staging environment

  DNS records needed (point to this LXC's IP):
      A  chat.example.com          ->  <LXC IP>
      A  matrix.chat.example.com   ->  <LXC IP>
      A  meet.chat.example.com     ->  <LXC IP>

  Check status after setup:
      /root/scripts/stack-status.sh

══════════════════════════════════════════════════════════════════

MOTD

echo "==> [09] Writing first-boot README at /root/README.txt..."
cat > /root/README.txt <<'README'
Matrix Stack LXC - Setup Instructions
======================================

STEP 1: Point DNS to this LXC's IP address
  A  yourdomain.com           -> <this LXC IP>
  A  matrix.yourdomain.com    -> <this LXC IP>
  A  meet.yourdomain.com      -> <this LXC IP>

STEP 2: Open an Unraid terminal, attach to this LXC, and run:
  cd /root
  ./setup.sh --domain yourdomain.com

  For internal testing (no public DNS/cert):
  ./setup.sh --domain yourdomain.com --skip-ssl

STEP 3: Follow the output. Setup will:
  - Configure PostgreSQL with a generated password
  - Configure Valkey cache
  - Configure Matrix Synapse homeserver
  - Write Element Web config pointing to your homeserver
  - Configure Jitsi Meet (integrated into Element)
  - Configure coturn TURN server
  - Configure Nginx with SNI/TLS routing
  - Optionally obtain Let's Encrypt certificates
  - Create your Matrix admin user
  - Start all services

STEP 4: Access your stack
  Element Web:  https://yourdomain.com
  Matrix API:   https://matrix.yourdomain.com
  Jitsi Meet:   Only accessible via Element widget (by design)

All credentials are saved to /root/.matrix-stack.env (chmod 600)

README

echo "==> Completed Stage 09 - Setup scripts staged"
