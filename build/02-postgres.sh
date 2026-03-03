#!/bin/bash
# =============================================================================
# BUILD PHASE - Stage 02: PostgreSQL 16 installation only
# Database and user creation happens in setup phase (setup/02-postgres-config.sh)
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "==> [02] Installing PostgreSQL 16..."
apt-get install -y postgresql-16 postgresql-client-16

echo "==> [02] Enabling PostgreSQL service (will start on boot after setup)..."
systemctl enable postgresql
# Do NOT start it here - setup phase creates the DB with real credentials

echo "==> [02] Pre-creating directory structure for later configuration..."
mkdir -p /etc/matrix-postgres
chmod 700 /etc/matrix-postgres

echo "==> Completed Stage 02 - PostgreSQL installed (not yet configured)"
