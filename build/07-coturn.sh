#!/bin/bash
# =============================================================================
# BUILD PHASE - Stage 07: coturn installation only
# turnserver.conf written at setup time with real domain/secrets
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "==> [07] Installing coturn TURN/STUN server..."
apt-get install -y coturn

echo "==> [07] Enabling coturn init flag (config written at setup time)..."
sed -i 's/^#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' /etc/default/coturn 2>/dev/null || \
  echo "TURNSERVER_ENABLED=1" >> /etc/default/coturn

echo "==> [07] Stopping coturn (will start after setup)..."
systemctl stop coturn    2>/dev/null || true
systemctl disable coturn 2>/dev/null || true

echo "==> [07] Creating log directory..."
mkdir -p /var/log/coturn
chown turnserver:turnserver /var/log/coturn 2>/dev/null || true

echo "==> [07] Removing default turnserver.conf..."
rm -f /etc/turnserver.conf

echo "==> Completed Stage 07 - coturn installed (not yet configured)"
