#!/bin/bash
###############################################################################
# BUILD PHASE - Stage 03
# Install Valkey using the official APT repository
#
# This stage installs the Valkey software only.
# Configuration (password, bind, persistence) occurs during setup phase.
###############################################################################

set -euo pipefail

echo
echo "══════════════════════════════════════════════════"
echo "  build-valkey"
echo "══════════════════════════════════════════════════"
echo

###############################################################################
# Skip if already installed
###############################################################################

if command -v valkey-server >/dev/null 2>&1; then
  echo "Valkey already installed — skipping."
  exit 0
fi

###############################################################################
# Install prerequisites
###############################################################################

echo "==> Installing prerequisites..."

apt-get update
apt-get install -y curl gpg

###############################################################################
# Add Valkey APT repository
###############################################################################

echo "==> Adding Valkey APT repository..."

install -d /etc/apt/keyrings

curl -fsSL https://apt.valkey.io/gpg.key \
  | gpg --dearmor -o /etc/apt/keyrings/valkey.gpg

cat > /etc/apt/sources.list.d/valkey.list <<EOF
deb [signed-by=/etc/apt/keyrings/valkey.gpg] https://apt.valkey.io/debian bookworm main
EOF

###############################################################################
# Install Valkey
###############################################################################

echo "==> Installing Valkey..."

apt-get update
apt-get install -y valkey

###############################################################################
# Ensure required directories exist
###############################################################################

echo "==> Ensuring Valkey directories exist..."

mkdir -p /etc/valkey
mkdir -p /var/lib/valkey
mkdir -p /var/log/valkey

chown -R valkey:valkey /var/lib/valkey
chown -R valkey:valkey /var/log/valkey

###############################################################################
# Ensure service exists but do not start it
###############################################################################

echo "==> Preparing systemd service..."

systemctl daemon-reload

###############################################################################
# Final message
###############################################################################

echo
echo "==> Valkey installed successfully via APT"
echo "==> Service will be configured and started during setup phase"
echo
