#!/bin/bash
###############################################################################
# 04-jitsi-install.sh
# Install Jitsi packages using REAL env values, then wipe package-generated
# config so 05 can rebuild everything from a single source of truth.
###############################################################################
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "  Installing Jitsi packages..."

ENV_FILE="/root/matrix.env"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE"; exit 1; }

set -a
. "$ENV_FILE"
set +a

: "${MEET:?Missing MEET in matrix.env}"

JITSI_DOMAIN="${MEET}"

###############################################################################
# Java
###############################################################################

apt-get update
apt-get install -y openjdk-17-jre-headless ca-certificates ca-certificates-java

update-alternatives --set java /usr/lib/jvm/java-17-openjdk-amd64/bin/java 2>/dev/null || true

if grep -q '^JAVA_HOME=' /etc/environment 2>/dev/null; then
  sed -i 's|^JAVA_HOME=.*|JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64|' /etc/environment
else
  echo 'JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64' >> /etc/environment
fi

###############################################################################
# Preseed Jitsi packages with the REAL meet hostname
###############################################################################

debconf-set-selections <<EOF
jitsi-meet-web-config   jitsi-meet/cert-choice                    select Generate a new self-signed certificate
jitsi-meet-web-config   jitsi-videobridge/jvb-hostname            string ${JITSI_DOMAIN}
jitsi-videobridge2      jitsi-videobridge/jvb-hostname            string ${JITSI_DOMAIN}
jitsi-meet-prosody      jitsi-meet-prosody/jvb-hostname           string ${JITSI_DOMAIN}
jitsi-meet-turnserver   jitsi-meet-turnserver/jvb-hostname        string ${JITSI_DOMAIN}
EOF

###############################################################################
# Make sure the real meet hostname resolves locally for package postinst
###############################################################################

grep -qE "[[:space:]]${JITSI_DOMAIN}([[:space:]]|\$)" /etc/hosts || \
  echo "127.0.0.1 ${JITSI_DOMAIN}" >> /etc/hosts

###############################################################################
# Install Jitsi stack
###############################################################################

apt-get install -y jitsi-meet

###############################################################################
# Stop/disable services - 05 will fully regenerate config and re-enable
###############################################################################

for svc in prosody jicofo jitsi-videobridge2 coturn; do
  systemctl stop "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
done

pkill -9 -f '/usr/share/jicofo/' || true
pkill -9 -f '/usr/share/jitsi-videobridge/' || true
pkill -9 -f 'org.jitsi.jicofo' || true
pkill -9 -f 'org.jitsi.videobridge' || true
pkill -9 -f '/usr/bin/prosody' || true

sleep 2

###############################################################################
# Purge package-generated Jitsi state/config so 05 owns /etc
###############################################################################

rm -f /etc/prosody/conf.d/*.cfg.lua || true
rm -f /etc/prosody/conf.avail/*.cfg.lua || true

rm -f /etc/jitsi/jicofo/config \
      /etc/jitsi/jicofo/jicofo.conf \
      /etc/jitsi/jicofo/sip-communicator.properties || true

rm -f /etc/jitsi/videobridge/config \
      /etc/jitsi/videobridge/jvb.conf \
      /etc/jitsi/videobridge/sip-communicator.properties || true

rm -f /etc/nginx/sites-enabled/meet \
      /etc/nginx/sites-available/meet || true

rm -f /usr/share/jitsi-meet/config.js || true
rm -f /etc/jitsi/meet/*-config.js || true

rm -f /etc/prosody/conf.d/meet.placeholder.invalid.cfg.lua \
      /etc/prosody/conf.avail/meet.placeholder.invalid.cfg.lua || true

find /etc/jitsi/meet -maxdepth 1 -type f -name '*placeholder.invalid*' -delete 2>/dev/null || true

###############################################################################
# Recreate clean directories expected by 05
###############################################################################

mkdir -p /etc/prosody/conf.avail
mkdir -p /etc/prosody/conf.d
mkdir -p /etc/prosody/certs
mkdir -p /etc/jitsi/jicofo
mkdir -p /etc/jitsi/videobridge
mkdir -p /etc/jitsi/meet
mkdir -p /var/log/jitsi

touch /var/log/jitsi/jicofo.log /var/log/jitsi/jvb.log
chown jicofo:jitsi /var/log/jitsi/jicofo.log 2>/dev/null || true
chown jvb:jitsi    /var/log/jitsi/jvb.log    2>/dev/null || true

echo "  Jitsi packages installed and package-generated config removed."
