#!/bin/bash
###############################################################################
# scripts/set-static-ip.sh
# Prompt user for static network settings and write /etc/systemd/network/eth0.network
###############################################################################
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root."
  exit 1
fi

NET_FILE="/etc/systemd/network/eth0.network"
BACKUP_FILE="${NET_FILE}.bak.$(date +%Y%m%d-%H%M%S)"

echo ""
echo "Static IP Configuration"
echo "Interface: eth0"
echo ""

read -rp "IPv4 address with CIDR (example 192.168.1.50/24): " IP_CIDR
read -rp "Gateway (example 192.168.1.1): " GATEWAY
read -rp "Primary DNS (example 192.168.1.1): " DNS1
read -rp "Secondary DNS (optional, press Enter to skip): " DNS2
read -rp "Search domain (optional, example local): " SEARCH_DOMAIN
read -rp "MTU (default 1500): " MTU

MTU="${MTU:-1500}"

if [[ -f "$NET_FILE" ]]; then
  cp -a "$NET_FILE" "$BACKUP_FILE"
  echo "Backed up existing config to: $BACKUP_FILE"
fi

{
  echo "[Match]"
  echo "Name=eth0"
  echo
  echo "[Network]"
  echo "Address=${IP_CIDR}"
  echo "Gateway=${GATEWAY}"
  echo "DNS=${DNS1}"
  [[ -n "${DNS2}" ]] && echo "DNS=${DNS2}"
  [[ -n "${SEARCH_DOMAIN}" ]] && echo "Domains=${SEARCH_DOMAIN}"
  echo
  echo "[Link]"
  echo "MTUBytes=${MTU}"
} > "$NET_FILE"

echo ""
echo "Wrote:"
echo "----------------------------------------"
cat "$NET_FILE"
echo "----------------------------------------"
echo ""

read -rp "Apply now by restarting systemd-networkd? [y/N]: " APPLY_NOW
if [[ "${APPLY_NOW,,}" == "y" ]]; then
  systemctl restart systemd-networkd
  echo "systemd-networkd restarted."
  echo "Check connectivity before disconnecting your session."
else
  echo "Not applied yet."
  echo "To apply later:"
  echo "  systemctl restart systemd-networkd"
fi
