#!/bin/bash
# Stage 03 - Valkey (Redis-compatible cache) install and configure
# Valkey is the open-source Redis fork used for Matrix Synapse worker caching
set -euo pipefail

VALKEY_VERSION="8.0.2"
VALKEY_TARBALL="valkey-${VALKEY_VERSION}-linux-x86_64.tar.gz"
VALKEY_URL="https://github.com/valkey-io/valkey/releases/download/${VALKEY_VERSION}/${VALKEY_TARBALL}"
INSTALL_DIR="/opt/valkey"

echo "==> Downloading Valkey ${VALKEY_VERSION} from GitHub releases..."
mkdir -p /tmp/valkey-build
wget -O "/tmp/valkey-build/${VALKEY_TARBALL}" "${VALKEY_URL}"

echo "==> Extracting Valkey..."
mkdir -p "${INSTALL_DIR}"
tar -xzf "/tmp/valkey-build/${VALKEY_TARBALL}" -C "${INSTALL_DIR}" --strip-components=1

echo "==> Creating valkey user and directories..."
useradd --system --no-create-home --shell /bin/false valkey 2>/dev/null || true
mkdir -p /var/lib/valkey /var/log/valkey /etc/valkey
chown valkey:valkey /var/lib/valkey /var/log/valkey

echo "==> Writing Valkey configuration..."
cat > /etc/valkey/valkey.conf <<EOF
# Valkey configuration for Matrix Synapse cache
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
maxmemory 256mb
maxmemory-policy allkeys-lru
EOF
chmod 640 /etc/valkey/valkey.conf

echo "==> Creating symlinks for valkey-server and valkey-cli..."
ln -sf "${INSTALL_DIR}/bin/valkey-server" /usr/local/bin/valkey-server
ln -sf "${INSTALL_DIR}/bin/valkey-cli"    /usr/local/bin/valkey-cli

echo "==> Creating Valkey systemd service..."
cat > /etc/systemd/system/valkey.service <<EOF
[Unit]
Description=Valkey In-Memory Data Store
After=network.target
Documentation=https://valkey.io

[Service]
Type=notify
User=valkey
Group=valkey
ExecStart=/usr/local/bin/valkey-server /etc/valkey/valkey.conf
ExecStop=/usr/local/bin/valkey-cli -a ${VALKEY_PASS} shutdown
TimeoutStopSec=0
Restart=always
RestartSec=5

LimitNOFILE=65536
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/valkey /var/log/valkey

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable valkey
systemctl start valkey

echo "==> Verifying Valkey is running..."
sleep 2
if /usr/local/bin/valkey-cli -a "${VALKEY_PASS}" ping | grep -q PONG; then
  echo "   Valkey is responding to PING: OK"
else
  echo "   WARNING: Valkey did not respond to PING - check logs at /var/log/valkey/valkey.log"
fi

rm -rf /tmp/valkey-build

echo "Completed Stage 03 - Valkey"
