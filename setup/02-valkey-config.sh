#!/bin/bash
###############################################################################
# SETUP PHASE 02
# Add Debian bookworm-backports repo + install Valkey + configure + start
###############################################################################
set -euo pipefail

echo
echo "══════════════════════════════════════════════════"
echo "  valkey-config"
echo "══════════════════════════════════════════════════"
echo

BACKPORTS_LIST="/etc/apt/sources.list.d/bookworm-backports.list"

###############################################################################
# Ensure bookworm-backports repo exists
###############################################################################
if ! grep -RqsE '^[[:space:]]*deb[[:space:]].*bookworm-backports' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
  echo "  Adding Debian bookworm-backports repository..."
  cat > "${BACKPORTS_LIST}" <<'EOF'
deb http://deb.debian.org/debian bookworm-backports main
EOF
fi

###############################################################################
# Install Valkey from backports (repo install, no third-party keys)
###############################################################################
echo "  Installing Valkey (bookworm-backports)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y -t bookworm-backports valkey-server valkey-tools

###############################################################################
# Ensure directories exist
###############################################################################
echo "  Preparing directories..."
mkdir -p /etc/valkey /var/lib/valkey /var/log/valkey
chown -R valkey:valkey /var/lib/valkey /var/log/valkey 2>/dev/null || true

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
chown valkey:valkey /etc/valkey/valkey.conf 2>/dev/null || true

###############################################################################
# Start service (Debian package service name is valkey-server)
###############################################################################
echo "  Starting Valkey..."
systemctl daemon-reload
systemctl enable valkey-server
systemctl restart valkey-server

sleep 2

###############################################################################
# Verify service
###############################################################################
echo "  Testing Valkey connection..."
if valkey-cli -a "${VALKEY_PASS}" ping 2>/dev/null | grep -q PONG; then
  echo "  Valkey is running and responding."
else
  echo
  echo "  WARNING: Valkey did not respond to PING"
  echo "  Check logs:"
  echo "  journalctl -u valkey-server --no-pager -n 200"
fi

echo
echo "[✓] 02-valkey-config.sh complete"
echo
