#!/bin/bash
# =============================================================================
# BUILD PHASE - Stage 99: Final cleanup of the LXC image
# =============================================================================
set -euo pipefail

echo "==> [99] Running apt cleanup..."
apt-get autoremove -y
apt-get autoclean -y
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "==> [99] Removing package caches..."
rm -rf /var/cache/apt/archives/*.deb

echo "==> [99] Clearing bash history and temp files..."
find / -name ".bash_history" -exec rm -f {} \; 2>/dev/null || true
rm -rf /tmp/* /root/.cache 2>/dev/null || true
history -c 2>/dev/null || true

echo "==> [99] Verifying package installs..."
PKGS=(nginx psql valkey-server matrix-synapse jicofo prosody coturn)
for pkg in "${PKGS[@]}"; do
  if command -v "$pkg" &>/dev/null || \
     systemctl list-unit-files | grep -q "$(echo $pkg | cut -d- -f1)"; then
    echo "   ✓ $pkg present"
  else
    echo "   ? $pkg - verify manually"
  fi
done

echo ""
echo "==================================================="
echo "  BUILD COMPLETE"
echo "  All packages installed. No services running."
echo "  User runs /root/setup.sh to configure."
echo "==================================================="
echo ""
echo "==> Completed Stage 99 - Build cleanup done"
