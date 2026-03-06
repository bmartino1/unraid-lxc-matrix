#!/bin/bash
#WIP issues with intal build breaking jitsu
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

ENV_FILE="/root/matrix.env"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE"; exit 1; }

set -a
. "$ENV_FILE"
set +a

: "${MEET:?Missing MEET in matrix.env}"

apt-get update
apt-get install -y openjdk-17-jre-headless
update-alternatives --set java /usr/lib/jvm/java-17-openjdk-amd64/bin/java 2>/dev/null || true

grep -q '^JAVA_HOME=' /etc/environment 2>/dev/null \
  && sed -i 's|^JAVA_HOME=.*|JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64|' /etc/environment \
  || echo 'JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64' >> /etc/environment

debconf-set-selections <<EOF
jitsi-meet-web-config   jitsi-meet/cert-choice             select Generate a new self-signed certificate
jitsi-meet-web-config   jitsi-videobridge/jvb-hostname     string ${MEET}
jitsi-videobridge2      jitsi-videobridge/jvb-hostname     string ${MEET}
jitsi-meet-prosody      jitsi-meet-prosody/jvb-hostname    string ${MEET}
jitsi-meet-turnserver   jitsi-meet-turnserver/jvb-hostname string ${MEET}
EOF

apt-get install -y jitsi-meet

for svc in prosody jicofo jitsi-videobridge2; do
  systemctl stop "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
done

rm -f /etc/prosody/conf.d/*.cfg.lua
rm -f /etc/prosody/conf.avail/*.cfg.lua
rm -f /etc/jitsi/jicofo/config /etc/jitsi/jicofo/sip-communicator.properties /etc/jitsi/jicofo/jicofo.conf
rm -f /etc/jitsi/videobridge/config /etc/jitsi/videobridge/sip-communicator.properties /etc/jitsi/videobridge/jvb.conf
rm -f /etc/nginx/sites-enabled/meet /etc/nginx/sites-available/meet
rm -f /usr/share/jitsi-meet/config.js
rm -f /etc/jitsi/meet/*-config.js

mkdir -p /etc/prosody/conf.avail /etc/prosody/conf.d
mkdir -p /etc/jitsi/jicofo
mkdir -p /etc/jitsi/videobridge
mkdir -p /etc/jitsi/meet
