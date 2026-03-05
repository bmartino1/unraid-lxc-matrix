#!/bin/bash
###############################################################################
# SETUP PHASE 02
# Install + Configure Valkey for Matrix Synapse
###############################################################################

set -euo pipefail

echo
echo "══════════════════════════════════════════════════"
echo "  valkey-config"
echo "══════════════════════════════════════════════════"
echo

BACKPORTS_FILE="/etc/apt/sources.list.d/bookworm-backports.list"

###############################################################################
# Ensure Debian backports repository exists
###############################################################################

if ! grep -Rqs "bookworm-backports" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
    echo "  Adding Debian bookworm-backports repository..."

    cat > "${BACKPORTS_FILE}" <<'EOF'
deb http://deb.debian.org/debian bookworm-backports main
EOF

    apt-get update
fi

###############################################################################
# Install Valkey if missing
###############################################################################

if ! command -v valkey-server >/dev/null 2>&1; then
    echo "  Installing Valkey from bookworm-backports..."

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y -t bookworm-backports valkey-server valkey-tools
else
    echo "  Valkey already installed."
fi

###############################################################################
# Ensure directories exist
###############################################################################

echo "  Preparing directories..."

mkdir -p /etc/valkey
mkdir -p /var/lib/valkey
mkdir -p /var/log/valkey

chown -R valkey:valkey /var/lib/valkey 2>/dev/null || true
chown -R valkey:valkey /var/log/valkey 2>/dev/null || true

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
# Enable + start service
###############################################################################

echo "  Starting Valkey..."

systemctl daemon-reload
systemctl enable valkey-server
systemctl restart valkey-server

sleep 2

###############################################################################
# Verify Valkey
###############################################################################

echo "  Testing Valkey connection..."

if valkey-cli -a "${VALKEY_PASS}" ping 2>/dev/null | grep -q PONG; then
    echo "  Valkey is running and responding."
else
    echo
    echo "  WARNING: Valkey did not respond."
    echo "  Check logs with:"
    echo "  journalctl -u valkey-server --no-pager -n 200"
fi

echo
echo "[✓] 02-valkey-config.sh complete"
echo
