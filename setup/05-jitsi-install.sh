#!/bin/bash
###############################################################################
# 04-jitsi-install.sh
# Install Jitsi packages using values from /root/matrix.env, then remove
# package-generated Jitsi/Prosody state so 05 can rebuild from one source
# of truth.
#
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
JAVA_BIN="/usr/lib/jvm/java-17-openjdk-amd64/bin/java"
JAVA_HOME_DIR="/usr/lib/jvm/java-17-openjdk-amd64"

###############################################################################
# Java + cert tooling
###############################################################################

apt-get update
apt-get install -y \
  openjdk-17-jre-headless \
  ca-certificates \
  ca-certificates-java \
  debconf-utils \
  apt-transport-https \
  gnupg

update-alternatives --set java "$JAVA_BIN" 2>/dev/null || true

if grep -q '^JAVA_HOME=' /etc/environment 2>/dev/null; then
  sed -i "s|^JAVA_HOME=.*|JAVA_HOME=${JAVA_HOME_DIR}|" /etc/environment
else
  echo "JAVA_HOME=${JAVA_HOME_DIR}" >> /etc/environment
fi

###############################################################################
# Ensure local hostname resolution for package postinst
###############################################################################

grep -qE "[[:space:]]${JITSI_DOMAIN}([[:space:]]|$)" /etc/hosts || \
  echo "127.0.0.1 ${JITSI_DOMAIN}" >> /etc/hosts

###############################################################################
# Preseed Jitsi package install with REAL meet hostname
###############################################################################

debconf-set-selections <<EOF
jitsi-meet-web-config   jitsi-meet/cert-choice                    select Generate a new self-signed certificate
jitsi-meet-web-config   jitsi-videobridge/jvb-hostname            string ${JITSI_DOMAIN}
jitsi-videobridge2      jitsi-videobridge/jvb-hostname            string ${JITSI_DOMAIN}
jitsi-meet-prosody      jitsi-meet-prosody/jvb-hostname           string ${JITSI_DOMAIN}
jitsi-meet-turnserver   jitsi-meet-turnserver/jvb-hostname        string ${JITSI_DOMAIN}
EOF

###############################################################################
# Install Jitsi stack
###############################################################################

apt-get install -y jitsi-meet

###############################################################################
# Stop all related services; later stages will re-enable in correct order
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
# Purge package-generated Jitsi/Prosody config only
# DO NOT touch nginx here; 07 owns nginx.
###############################################################################

rm -f /etc/prosody/conf.d/*.cfg.lua || true
rm -f /etc/prosody/conf.avail/*.cfg.lua || true

rm -f /etc/jitsi/jicofo/config \
      /etc/jitsi/jicofo/jicofo.conf \
      /etc/jitsi/jicofo/sip-communicator.properties || true

rm -f /etc/jitsi/videobridge/config \
      /etc/jitsi/videobridge/jvb.conf \
      /etc/jitsi/videobridge/sip-communicator.properties || true

rm -f /usr/share/jitsi-meet/config.js || true
rm -f /etc/jitsi/meet/*-config.js || true

rm -f /etc/prosody/conf.d/meet.placeholder.invalid.cfg.lua \
      /etc/prosody/conf.avail/meet.placeholder.invalid.cfg.lua || true

find /etc/jitsi/meet -maxdepth 1 -type f -name '*placeholder.invalid*' -delete 2>/dev/null || true
find /etc/prosody/certs -maxdepth 1 \( -name '*placeholder.invalid*' -o -name '*.cnf' \) -delete 2>/dev/null || true

###############################################################################
# Recreate directories expected by 05
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
