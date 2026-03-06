#!/bin/bash
set -euo pipefail

echo "  Configuring Valkey..."

if ! command -v valkey-server >/dev/null 2>&1; then
  echo "  Valkey not found, skipping (Synapse will work without cache)."
  exit 0
fi

###############################################################################
# Kernel tuning required by Valkey
###############################################################################

if ! grep -q "vm.overcommit_memory" /etc/sysctl.conf; then
  echo "vm.overcommit_memory = 1" >> /etc/sysctl.conf
else
  sed -i 's/^vm.overcommit_memory.*/vm.overcommit_memory = 1/' /etc/sysctl.conf
fi

sysctl -w vm.overcommit_memory=1 >/dev/null

###############################################################################
# Valkey directories
###############################################################################

mkdir -p /etc/valkey /var/lib/valkey /var/log/valkey
chown -R valkey:valkey /var/lib/valkey /var/log/valkey 2>/dev/null || true

###############################################################################
# Generate password
###############################################################################

VALKEY_PASS=$(openssl rand -hex 16)

###############################################################################
# Write configuration
###############################################################################

cat > /etc/valkey/valkey.conf <<VEOF
bind 127.0.0.1
port 6379
daemonize no
supervised systemd

loglevel notice
logfile /var/log/valkey/valkey.log

dir /var/lib/valkey

save 900 1
save 300 10

requirepass ${VALKEY_PASS}

protected-mode yes

maxmemory 256mb
maxmemory-policy allkeys-lru
VEOF

chmod 640 /etc/valkey/valkey.conf
chown valkey:valkey /etc/valkey/valkey.conf 2>/dev/null || true

###############################################################################
# Start service
###############################################################################

systemctl daemon-reload
systemctl enable valkey-server
systemctl restart valkey-server

###############################################################################
# Export password for Synapse
###############################################################################

echo "VALKEY_PASS=${VALKEY_PASS}" >> /root/matrix.env
export VALKEY_PASS

echo "  Valkey configured."
