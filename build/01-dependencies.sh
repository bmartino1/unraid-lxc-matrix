#!/bin/bash
# =============================================================================
# BUILD PHASE - Stage 01: APT sources and base package installation
# Runs during LXC archive creation (createLXCarchive.sh) on the Unraid host.
# NO domain/secrets used here. Pure package pre-staging.
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "==> [01] Updating base system..."
apt-get update -y
apt-get upgrade -y
apt-get install -y --no-install-recommends \
  wget curl nano gnupg cron ca-certificates \
  apt-transport-https lsb-release software-properties-common \
  sudo openssl net-tools dnsutils unzip zip \
  python3 python3-pip python3-venv python3-dev \
  build-essential git jq \
  certbot python3-certbot-nginx \
  iproute2 procps mc lua-inspect

echo "==> [01] Installing Nginx with stream module..."
apt-get install -y nginx libnginx-mod-stream

echo "==> [01] Adding PostgreSQL 16 APT repository..."
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg
echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] \
https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  > /etc/apt/sources.list.d/postgresql.list

echo "==> [01] Adding Matrix Synapse APT repository..."
curl -fsSL https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg \
  | gpg --dearmor -o /usr/share/keyrings/matrix-org-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] \
https://packages.matrix.org/debian/ $(lsb_release -cs) main" \
  > /etc/apt/sources.list.d/matrix-org.list

echo "==> [01] Adding Jitsi Meet APT repository..."
curl -fsSL https://download.jitsi.org/jitsi-key.gpg.key \
  | gpg --dearmor -o /usr/share/keyrings/jitsi.gpg
echo "deb [signed-by=/usr/share/keyrings/jitsi.gpg] \
https://download.jitsi.org stable/" \
  > /etc/apt/sources.list.d/jitsi-stable.list

echo "==> [01] Refreshing package lists with all repos..."
apt-get update -y

echo "==> Completed Stage 01 - APT sources and base packages"
