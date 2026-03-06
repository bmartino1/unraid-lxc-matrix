#!/bin/bash
# =============================================================================
# BUILD PHASE - Stage 06: Jitsi Meet package installation (NO real config)
# We install packages only; setup.sh will write real configs later.
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

JITSI_PLACEHOLDER="meet.placeholder.invalid"

echo "==> [06] Installing Java 17 (required for JVB2 and jicofo)..."
apt-get update
apt-get install -y openjdk-17-jre-headless
update-alternatives --set java /usr/lib/jvm/java-17-openjdk-amd64/bin/java 2>/dev/null || true
echo "JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64" >> /etc/environment

echo "==> [06] Setting temporary hostname for package postinst scripts..."
hostnamectl set-hostname "${JITSI_PLACEHOLDER}" 2>/dev/null || echo "${JITSI_PLACEHOLDER}" > /etc/hostname
grep -q "${JITSI_PLACEHOLDER}" /etc/hosts || echo "127.0.0.1 ${JITSI_PLACEHOLDER}" >> /etc/hosts

echo "==> [06] Pre-seeding Jitsi debconf with placeholder hostname..."
# These keys are what automated installs commonly preseed successfully
debconf-set-selections <<EOF
jitsi-meet-web-config   jitsi-meet/cert-choice                    select Generate a new self-signed certificate (You will later get a chance to obtain a Let's encrypt certificate)
jitsi-meet-prosody      jitsi-videobridge/jvb-hostname             string ${JITSI_PLACEHOLDER}
jitsi-meet-turnserver   jitsi-videobridge/jvb-hostname             string ${JITSI_PLACEHOLDER}
jitsi-meet-web-config   jitsi-videobridge/jvb-hostname             string ${JITSI_PLACEHOLDER}
jitsi-videobridge2      jitsi-videobridge/jvb-hostname             string ${JITSI_PLACEHOLDER}
jitsi-meet-turnserver   jitsi-meet-turnserver/jvb-hostname         string ${JITSI_PLACEHOLDER}
jitsi-meet-prosody      jitsi-meet-prosody/jvb-hostname            string ${JITSI_PLACEHOLDER}
EOF

echo "==> [06] Installing Jitsi Meet stack..."
# Installing jitsi-meet pulls the rest; keeps ordering sane
apt-get install -y jitsi-meet

echo "==> [06] Stopping all Jitsi services (configured at setup time)..."
for svc in prosody jicofo jitsi-videobridge2 coturn; do
  systemctl stop    "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
done

echo "==> [06] Removing placeholder configs written by packages (setup.sh regenerates)..."
rm -f /etc/prosody/conf.d/*.cfg.lua || true
rm -f /etc/jitsi/jicofo/config /etc/jitsi/jicofo/sip-communicator.properties || true
rm -f /etc/jitsi/videobridge/config /etc/jitsi/videobridge/jvb.conf || true
rm -f /usr/share/jitsi-meet/config.js || true

echo "==> [06] Creating skeleton directories for setup phase..."
mkdir -p /etc/prosody/conf.avail /etc/prosody/conf.d
mkdir -p /etc/jitsi/jicofo
mkdir -p /etc/jitsi/videobridge

echo "==> Completed Stage 06 - Jitsi packages installed (not configured)"
