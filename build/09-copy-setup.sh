#!/bin/bash
# =============================================================================
# BUILD PHASE - Stage 09: Stage the setup and admin scripts into /root/
# After build, user sees:
#   /root/setup.sh          <- main setup entry point
#   /root/setup/            <- setup phase sub-scripts
#   /root/scripts/          <- admin/maintenance scripts
#   /root/README.txt        <- first-login instructions
# =============================================================================
set -euo pipefail

echo "==> [09] Staging scripts into /root/..."

if [[ -d /tmp/setup ]]; then
  cp    /tmp/setup/setup.sh        /root/setup.sh
  cp -r /tmp/setup/setup/          /root/setup/
  cp -r /tmp/setup/scripts/        /root/scripts/
  chmod +x /root/setup.sh
  chmod +x /root/setup/*.sh
  chmod +x /root/scripts/*.sh
  chmod +x /root/scripts/lib/*.sh 2>/dev/null || true
  echo "   Scripts staged from /tmp/setup/"
else
  echo "   WARNING: /tmp/setup not found - scripts must be placed manually"
fi

echo "==> [09] Writing /etc/motd..."
cat > /etc/motd <<'MOTD'

  ╔══════════════════════════════════════════════════════════════╗
  ║       Matrix Synapse + Element Web + Jitsi LXC Stack        ║
  ╚══════════════════════════════════════════════════════════════╝

  All packages pre-installed. Configuration required.

  Quick start:
      cd /root
      ./setup.sh --domain chat.example.com

  After setup, use the admin console:
      ./scripts/admin.sh

  Or run scripts directly:
      ./scripts/stack-status.sh
      ./scripts/create-user.sh
      ./scripts/registration-tokens.sh create

  DNS records needed (→ this LXC's IP):
      A  chat.example.com
      A  matrix.chat.example.com
      A  meet.chat.example.com

══════════════════════════════════════════════════════════════════

MOTD

echo "==> [09] Writing /root/README.txt..."
cat > /root/README.txt <<'README'
Matrix Stack LXC - Setup Instructions
======================================

STEP 1: Create DNS records pointing to this LXC IP
  A  yourdomain.com           -> <LXC IP>
  A  yourdomain.com    -> <LXC IP>
  A  meet.yourdomain.com      -> <LXC IP>
  SRV _matrix._tcp.yourdomain.com  10 0 443  yourdomain.com

STEP 2: Run setup in the LXC console
  cd /root
  ./setup.sh --domain yourdomain.com

  For testing without public DNS:
  ./setup.sh --domain yourdomain.com --skip-ssl

STEP 3: After setup completes, access your stack
  Element Web:  https://yourdomain.com
  Matrix API:   https://yourdomain.com
  Jitsi:        Only via Element widget (by design - not public)

STEP 4: Ongoing admin
  ./scripts/admin.sh              <- interactive menu
  ./scripts/stack-status.sh       <- health check
  ./scripts/create-user.sh        <- add users
  ./scripts/registration-tokens.sh create  <- invite tokens
  ./scripts/backup.sh             <- backup all data

All credentials saved to: /root/matrix.env (chmod 600)

Admin scripts available in /root/scripts/:
  admin.sh                Interactive admin menu
  stack-status.sh         Full health dashboard
  logs.sh                 Log viewer (all services)
  get-admin-token.sh      Get Matrix API access token
  create-user.sh          Create a new Matrix user
  list-users.sh           List all users
  user-manage.sh          Deactivate/promote/reset-password
  registration-tokens.sh  Manage invite tokens
  registration-toggle.sh  Enable/disable open registration
  room-manage.sh          List/delete/purge rooms
  service-control.sh      Start/stop/restart services
  backup.sh               Backup config, DB, certs, media
  update-stack.sh         Update Element Web, packages, Valkey
  renew-ssl.sh            Re-run Let's Encrypt cert provisioning

README

echo "==> Completed Stage 09 - Scripts staged"
