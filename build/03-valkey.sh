#!/bin/bash
###############################################################################
# BUILD PHASE - Stage 03
# Install Valkey from Debian bookworm-backports
#
# This stage installs Valkey only.
# Configuration happens in the setup phase.
###############################################################################

set -euo pipefail

echo
echo "══════════════════════════════════════════════════"
echo "  build-valkey"
echo "══════════════════════════════════════════════════"
echo

BACKPORTS_LIST="/etc/apt/sources.list.d/bookworm-backports.list"

###############################################################################
# Skip if already installed
###############################################################################

if command -v valkey-server >/dev/null 2>&1; then
  echo "Valkey already installed — skipping."
  exit 0
fi

###############################################################################
# Ensure backports repository exists
###############################################################################

echo "==> Ensuring Debian bookworm-backports repository..."

if ! grep -RqsE '^[[:space:]]*deb[[:space:]].*bookworm-backports' \
    /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then

  cat > "${BACKPORTS_LIST}" <<'EOF'
deb http://deb.debian.org/debian bookworm-backports main
EOF

fi

###############################################################################
# Install Valkey
###############################################################################

echo "==> Installing Valkey from bookworm-backports..."

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y -t bookworm-backports valkey-server valkey-tools

###############################################################################
# Ensure directories exist (configuration happens later)
###############################################################################

echo "==> Preparing directories..."

mkdir -p /etc/valkey
mkdir -p /var/lib/valkey
mkdir -p /var/log/valkey

chown -R valkey:valkey /var/lib/valkey /var/log/valkey 2>/dev/null || true

###############################################################################
# Reload systemd but do NOT start service
###############################################################################

systemctl daemon-reload

###############################################################################
# Done
###############################################################################

echo
echo "==> Valkey installed successfully (Debian backports)"
echo "==> Service will be configured and started during setup phase"
echo
