#!/bin/bash
# =============================================================================
# BUILD PHASE - Stage 06: Jitsi Meet package installation
# All prosody/jicofo/JVB config written at setup time with real domain/secrets
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "==> [06] Installing Java 17 (required for JVB2 and jicofo)..."
apt-get install -y openjdk-17-jre-headless
update-alternatives --set java \
  /usr/lib/jvm/java-17-openjdk-amd64/bin/java 2>/dev/null || true
echo "JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64" >> /etc/environment

echo "==> [06] Pre-seeding Jitsi debconf with placeholder hostname..."
# Use a placeholder - all real config written by setup.sh
echo "jitsi-meet jitsi-meet/jvb-serve boolean false"                                       | debconf-set-selections
echo "jitsi-meet jitsi-meet/cert-choice select Generate a new self-signed certificate"      | debconf-set-selections
echo "jitsi-videobridge2 jitsi-videobridge/jvbjvm string /usr/lib/jvm/java-17-openjdk-amd64" | debconf-set-selections
echo "jitsi-meet-web-config/jvb-hostname string localhost"                                  | debconf-set-selections

echo "==> [06] Installing Jitsi Meet stack..."
apt-get install -y \
  prosody \
  jicofo \
  jitsi-videobridge2 \
  jitsi-meet \
  jitsi-meet-web-config \
  jitsi-meet-prosody

echo "==> [06] Stopping all Jitsi services (configured at setup time)..."
for svc in prosody jicofo jitsi-videobridge2; do
  systemctl stop    "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
done

echo "==> [06] Removing placeholder prosody/jicofo configs written by packages..."
rm -f /etc/prosody/conf.d/*.cfg.lua
rm -f /etc/jitsi/jicofo/config
rm -f /etc/jitsi/jicofo/sip-communicator.properties
rm -f /etc/jitsi/videobridge/config
rm -f /etc/jitsi/videobridge/jvb.conf
rm -f /usr/share/jitsi-meet/config.js

echo "==> [06] Creating skeleton directories for setup phase..."
mkdir -p /etc/prosody/conf.avail /etc/prosody/conf.d
mkdir -p /etc/jitsi/jicofo
mkdir -p /etc/jitsi/videobridge

echo "==> Completed Stage 06 - Jitsi packages installed (not yet configured)"
