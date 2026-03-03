#!/bin/bash
# SETUP PHASE - 02: Configure Valkey with real password and start
set -euo pipefail

echo "  Writing Valkey configuration..."
cat > /etc/valkey/valkey.conf <<EOF
# Valkey configuration - written by setup.sh
# Cache for Matrix Synapse
bind 127.0.0.1
port 6379
daemonize no
supervised systemd
loglevel notice
logfile /var/log/valkey/valkey.log
dir /var/lib/valkey

# Persistence
save 900 1
save 300 10
save 60 10000

# Security
requirepass ${VALKEY_PASS}
protected-mode yes

# Memory
maxmemory 256mb
maxmemory-policy allkeys-lru

# Performance
tcp-backlog 511
timeout 0
tcp-keepalive 300
EOF
chmod 640 /etc/valkey/valkey.conf
chown valkey:valkey /etc/valkey/valkey.conf

echo "  Starting Valkey..."
systemctl daemon-reload
systemctl enable valkey
systemctl restart valkey

sleep 2
if /usr/local/bin/valkey-cli -a "${VALKEY_PASS}" ping 2>/dev/null | grep -q PONG; then
  echo "  Valkey is running and responding."
else
  echo "  WARNING: Valkey did not respond to PING - check: journalctl -u valkey"
fi
