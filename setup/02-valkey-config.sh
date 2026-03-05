#!/bin/bash
###############################################################################
# SETUP PHASE 02
# Install + configure Valkey for Matrix Synapse caching
###############################################################################

set -euo pipefail

echo
echo "══════════════════════════════════════════════════"
echo "  valkey-config"
echo "══════════════════════════════════════════════════"
echo

###############################################################################
# Install Valkey if missing
###############################################################################

if ! command -v valkey-server >/dev/null 2>&1; then
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
# Valkey configuration - written by setup.sh
bind 127.0.0.1
port 6379
daemonize no
supervised systemd

loglevel notice
logfile /var/log/valkey/valkey.log
dir /var/lib/valkey

################################
# Persistence
################################

save 900 1
save 300 10
save 60 10000

################################
# Security
################################

requirepass ${VALKEY_PASS}
protected-mode yes

################################
# Memory
################################

maxmemory 256mb
maxmemory-policy allkeys-lru

################################
# Performance
################################

tcp-backlog 511
timeout 0
tcp-keepalive 300
EOF

chmod 640 /etc/valkey/valkey.conf
chown valkey:valkey /etc/valkey/valkey.conf

###############################################################################
# Restart service
###############################################################################

echo "  Starting Valkey..."

systemctl enable valkey
systemctl restart valkey

sleep 2

###############################################################################
# Verify Valkey
###############################################################################

echo "  Testing Valkey connection..."

if valkey-cli -a "${VALKEY_PASS}" ping 2>/dev/null | grep -q PONG; then
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
