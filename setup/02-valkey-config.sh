#!/bin/bash
###############################################################################
# SETUP PHASE 02
# Install + configure Valkey for Matrix Synapse
###############################################################################

set -euo pipefail

echo
echo "══════════════════════════════════════════════════"
echo "  valkey-config"
echo "══════════════════════════════════════════════════"
echo

###############################################################################
# Install Valkey repository if missing
###############################################################################

if ! command -v valkey-server >/dev/null 2>&1; then
  echo "  Adding Valkey repository..."

  apt-get update
  apt-get install -y curl gpg

  install -d /etc/apt/keyrings

  curl -fsSL https://packages.valkey.io/debian/valkey.gpg \
    | gpg --dearmor -o /etc/apt/keyrings/valkey.gpg

  echo \
  "deb [signed-by=/etc/apt/keyrings/valkey.gpg] https://packages.valkey.io/debian bookworm main" \
    > /etc/apt/sources.list.d/valkey.list

  echo "  Installing Valkey..."
  apt-get update
  apt-get install -y valkey
fi

###############################################################################
# Ensure directories exist
###############################################################################

echo "  Preparing directories..."

mkdir -p /etc/valkey
mkdir -p /var/lib/valkey
mkdir -p /var/log/valkey

chown -R valkey:valkey /var/lib/valkey
chown -R valkey:valkey /var/log/valkey

###############################################################################
# Write configuration
###############################################################################

echo "  Writing Valkey configuration..."

cat > /etc/valkey/valkey.conf <<EOF
bind 127.0.0.1
port 6379
daemonize no
supervised systemd

loglevel notice
logfile /var/log/valkey/valkey.log
dir /var/lib/valkey

save 900 1
save 300 10
save 60 10000

requirepass ${VALKEY_PASS}
protected-mode yes

maxmemory 256mb
maxmemory-policy allkeys-lru

tcp-backlog 511
timeout 0
tcp-keepalive 300
EOF

chmod 640 /etc/valkey/valkey.conf
chown valkey:valkey /etc/valkey/valkey.conf

###############################################################################
# Start Valkey
###############################################################################

echo "  Starting Valkey..."

systemctl enable valkey
systemctl restart valkey

sleep 2

###############################################################################
# Verify service
###############################################################################

echo "  Testing Valkey connection..."

if valkey-cli -a "${VALKEY_PASS}" ping | grep -q PONG; then
  echo "  Valkey is running and responding."
else
  echo
  echo "  WARNING: Valkey did not respond to PING"
  echo "  Check logs:"
  echo "  journalctl -u valkey"
fi

echo
echo "[✓] 02-valkey-config.sh complete"
echo
