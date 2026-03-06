#!/bin/bash
###############################################################################
# Configure coturn — Matrix/Jitsi TURN server
# Internal-only coturn behind nginx stream SNI mux on :443
###############################################################################
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "  Configuring coturn..."

ENV_FILE="/root/matrix.env"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE"; exit 1; }

set -a
. "$ENV_FILE"
set +a

: "${DOMAIN:?Missing DOMAIN in matrix.env}"
: "${MEET:?Missing MEET in matrix.env}"
: "${TURN:?Missing TURN in matrix.env}"
: "${TURN_SECRET:?Missing TURN_SECRET in matrix.env}"
: "${LXC_IP:?Missing LXC_IP in matrix.env}"
: "${EXTERNAL_IP:?Missing EXTERNAL_IP in matrix.env}"

mkdir -p /etc/prosody/certs
mkdir -p /var/log/coturn
touch /var/log/coturn/turn.log
chown turnserver:turnserver /var/log/coturn /var/log/coturn/turn.log 2>/dev/null || true

LE_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
LE_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

SS_CERT="/etc/ssl/nginx/${DOMAIN}.crt"
SS_KEY="/etc/ssl/nginx/${DOMAIN}.key"

if [[ ! -f "$LE_CERT" || ! -f "$LE_KEY" ]]; then
  echo "  Let's Encrypt cert not found, generating fallback self-signed TURN cert..."
  mkdir -p /etc/ssl/nginx
  openssl req -x509 -nodes -newkey rsa:4096 -days 3650 \
    -keyout "$SS_KEY" \
    -out "$SS_CERT" \
    -subj "/CN=${DOMAIN}" \
    >/dev/null 2>&1
  chmod 600 "$SS_KEY"
fi

if [[ -f "$LE_CERT" && -f "$LE_KEY" ]]; then
  CERT_PATH="$LE_CERT"
  KEY_PATH="$LE_KEY"
else
  CERT_PATH="$SS_CERT"
  KEY_PATH="$SS_KEY"
fi

cp -a /etc/turnserver.conf /root/turnserver.conf.bak.$(date +%F-%H%M%S) 2>/dev/null || true

cat > /etc/turnserver.conf <<EOF
realm=${TURN}

use-auth-secret
static-auth-secret=${TURN_SECRET}

fingerprint

listening-ip=127.0.0.1
relay-ip=${LXC_IP}
external-ip=${EXTERNAL_IP}/${LXC_IP}

listening-port=3478
tls-listening-port=5349

min-port=49160
max-port=49250

cert=${CERT_PATH}
pkey=${KEY_PATH}

no-tlsv1
no-tlsv1_1
no-ipv6

no-cli
no-multicast-peers
no-loopback-peers

stale-nonce=600
total-quota=300

denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=100.64.0.0-100.127.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=198.18.0.0-198.19.255.255
denied-peer-ip=198.51.100.0-198.51.100.255
denied-peer-ip=203.0.113.0-203.0.113.255
denied-peer-ip=224.0.0.0-239.255.255.255
denied-peer-ip=240.0.0.0-255.255.255.255

allowed-peer-ip=127.0.0.1
allowed-peer-ip=${LXC_IP}

log-file=/var/log/coturn/turn.log
verbose
EOF

chmod 640 /etc/turnserver.conf
chown root:turnserver /etc/turnserver.conf 2>/dev/null || true

cat > /etc/default/coturn <<EOF
TURNSERVER_ENABLED=1
EOF

mkdir -p /etc/letsencrypt/renewal-hooks/post
cat > /etc/letsencrypt/renewal-hooks/post/coturn-perms.sh <<'HOOKEOF'
#!/bin/bash
chown -R root:turnserver /etc/letsencrypt/live/ 2>/dev/null || true
chown -R root:turnserver /etc/letsencrypt/archive/ 2>/dev/null || true
chmod 750 /etc/letsencrypt/live/ 2>/dev/null || true
chmod 750 /etc/letsencrypt/archive/ 2>/dev/null || true
find /etc/letsencrypt/archive/ -name "*.pem" -exec chmod 640 {} \; 2>/dev/null || true
systemctl restart coturn 2>/dev/null || true
HOOKEOF
chmod +x /etc/letsencrypt/renewal-hooks/post/coturn-perms.sh

systemctl daemon-reload
systemctl enable coturn
systemctl restart coturn

echo "  coturn configured."
echo "  Expected external TURN path: turns://${TURN}:443?transport=tcp"
