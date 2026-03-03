#!/bin/bash
# =============================================================================
# BUILD PHASE - Stage 03: Valkey binary install
# Configuration (password, bind) happens in setup phase
# =============================================================================
set -euo pipefail

VALKEY_VERSION="8.0.2"
VALKEY_TARBALL="valkey-${VALKEY_VERSION}-linux-x86_64.tar.gz"
VALKEY_URL="https://github.com/valkey-io/valkey/releases/download/${VALKEY_VERSION}/${VALKEY_TARBALL}"
INSTALL_DIR="/opt/valkey"

echo "==> [03] Downloading Valkey ${VALKEY_VERSION}..."
mkdir -p /tmp/valkey-build
wget -q --show-progress -O "/tmp/valkey-build/${VALKEY_TARBALL}" "${VALKEY_URL}"

echo "==> [03] Installing Valkey to ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"
tar -xzf "/tmp/valkey-build/${VALKEY_TARBALL}" -C "${INSTALL_DIR}" --strip-components=1

echo "==> [03] Creating valkey system user..."
useradd --system --no-create-home --shell /bin/false valkey 2>/dev/null || true

echo "==> [03] Creating directories..."
mkdir -p /var/lib/valkey /var/log/valkey /etc/valkey
chown valkey:valkey /var/lib/valkey /var/log/valkey

echo "==> [03] Creating symlinks..."
ln -sf "${INSTALL_DIR}/bin/valkey-server" /usr/local/bin/valkey-server
ln -sf "${INSTALL_DIR}/bin/valkey-cli"    /usr/local/bin/valkey-cli

echo "==> [03] Pre-staging systemd service unit (password injected at setup time)..."
cat > /etc/systemd/system/valkey.service <<'EOF'
[Unit]
Description=Valkey In-Memory Data Store
After=network.target
Documentation=https://valkey.io

[Service]
Type=notify
User=valkey
Group=valkey
ExecStart=/usr/local/bin/valkey-server /etc/valkey/valkey.conf
ExecStop=/bin/sh -c '/usr/local/bin/valkey-cli -a $(grep requirepass /etc/valkey/valkey.conf | awk "{print \$2}") shutdown 2>/dev/null || kill $MAINPID'
TimeoutStopSec=0
Restart=always
RestartSec=5
LimitNOFILE=65536
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/valkey /var/log/valkey /etc/valkey

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
# Do NOT enable or start - setup phase does that after writing valkey.conf

rm -rf /tmp/valkey-build
echo "==> Completed Stage 03 - Valkey installed (not yet configured)"
