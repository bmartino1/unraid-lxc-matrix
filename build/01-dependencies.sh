#!/bin/bash
# Stage 01 - System dependencies and APT sources
# Debian 12 (Bookworm) base
set -euo pipefail

echo "==> Updating system and installing base dependencies..."
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get -y upgrade
apt-get -y install \
  wget curl nano gnupg cron ca-certificates \
  apt-transport-https lsb-release software-properties-common \
  sudo openssl net-tools dnsutils unzip \
  python3 python3-pip python3-venv \
  build-essential git certbot python3-certbot-nginx \
  jq

echo "==> Installing Nginx..."
apt-get -y install nginx

echo "==> Adding PostgreSQL APT repository..."
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg
echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] \
  https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  > /etc/apt/sources.list.d/postgresql.list

echo "==> Adding Matrix Synapse APT repository..."
curl -fsSL https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg \
  | gpg --dearmor -o /usr/share/keyrings/matrix-org-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] \
  https://packages.matrix.org/debian/ $(lsb_release -cs) main" \
  > /etc/apt/sources.list.d/matrix-org.list

echo "==> Adding Jitsi Meet APT repository..."
curl -fsSL https://download.jitsi.org/jitsi-key.gpg.key \
  | gpg --dearmor -o /usr/share/keyrings/jitsi.gpg
echo "deb [signed-by=/usr/share/keyrings/jitsi.gpg] \
  https://download.jitsi.org stable/" \
  > /etc/apt/sources.list.d/jitsi-stable.list

echo "==> Refreshing package lists with new repos..."
apt-get update

echo "Completed Stage 01 - Dependencies and APT sources"
