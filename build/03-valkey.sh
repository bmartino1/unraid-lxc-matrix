#!/bin/bash
###############################################################################
# BUILD PHASE - Stage 03
# Install Valkey binary
#
# This stage installs Valkey but does NOT configure it.
# Configuration (password, bind, persistence) happens in setup phase.
###############################################################################

set -euo pipefail

VALKEY_VERSION="8.0.2"
VALKEY_TARBALL="valkey-${VALKEY_VERSION}-linux-x86_64.tar.gz"
VALKEY_URL="https://github.com/valkey-io/valkey/releases/download/${VALKEY_VERSION}/${VALKEY_TARBALL}"
INSTALL_DIR="/opt/valkey"

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
apt-get install -y wget tar

###############################################################################
# Download Valkey
###############################################################################

echo "==> Downloading Valkey ${VALKEY_VERSION}..."

mkdir -p /tmp/valkey-build

wget -q --show-progress \
  -O "/tmp/valkey-build/${VALKEY_TARBALL}" \
  "${VALKEY_URL}"

###############################################################################
# Install binaries
###############################################################################

echo "==> Installing Valkey to ${INSTALL_DIR}..."

mkdir -p "${INSTALL_DIR}"

tar -xzf "/tmp/valkey-build/${VALKEY_TARBALL}" \
  -C "${INSTALL_DIR}" \
  --strip-components=1

###############################################################################
# Create valkey user
###############################################################################

echo "==> Creating valkey system user..."

id valkey &>/dev/null || \
  useradd --system --no-create-home --shell /usr/sbin/nologin valkey

###############################################################################
# Create directories
###############################################################################

echo "==> Creating directories..."

mkdir -p \
  /var/lib/valkey \
  /var/log/valkey \
  /etc/valkey

chown -R valkey:valkey /var/lib/valkey
chown -R valkey:valkey /var/log/valkey

###############################################################################
# Create binary symlinks
###############################################################################

echo "==> Creating symlinks..."

ln -sf "${INSTALL_DIR}/bin/valkey-server" /usr/local/bin/valkey-server
ln -sf "${INSTALL_DIR}/bin/valkey-cli"    /usr/local/bin/valkey-cli

###############################################################################
# Install systemd service
###############################################################################

echo "==> Installing systemd service..."

cat > /etc/systemd/system/valkey.service <<'EOF'
[Unit]
Description=Valkey In-Memory Data Store
Documentation=https://valkey.io
After=network.target

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

###############################################################################
# Cleanup
###############################################################################

rm -rf /tmp/valkey-build

echo
echo "==> Valkey ${VALKEY_VERSION} installed successfully"
echo "==> Service not started yet (configured in setup phase)"
echo
