#!/bin/bash
###############################################################################
# Configure coturn — Matrix/Jitsi TURN server
###############################################################################
set -euo pipefail
echo "  Configuring coturn..."

###############################################################################
# Ensure Prosody certs exist (prevents interactive prompts)
###############################################################################

for vhost in "${MEET}" "auth.${MEET}"; do
  CRT="/etc/prosody/certs/${vhost}.crt"
  KEY="/etc/prosody/certs/${vhost}.key"

  if [[ ! -f "$CRT" || ! -f "$KEY" ]]; then
    echo "  Generating internal Prosody cert for ${vhost}"
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -keyout "$KEY" \
      -out "$CRT" \
      -subj "/CN=${vhost}" \
      >/dev/null 2>&1

    chown prosody:prosody "$CRT" "$KEY" 2>/dev/null || true
    chmod 640 "$CRT" "$KEY" 2>/dev/null || true
  fi
done

###############################################################################
# TLS certificate sources
###############################################################################

LE_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
LE_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

SS_CERT="/etc/ssl/nginx/${DOMAIN}.crt"
SS_KEY="/etc/ssl/nginx/${DOMAIN}.key"

###############################################################################
# Generate fallback self-signed cert for TURN
###############################################################################

if [[ ! -f "$LE_CERT" && ! -f "$SS_CERT" ]]; then
  echo "  Generating self-signed TURN certificate..."

  mkdir -p /etc/ssl/nginx

  openssl req -x509 -nodes -newkey rsa:4096 -days 3650 \
    -keyout "$SS_KEY" \
    -out "$SS_CERT" \
    -subj "/CN=${DOMAIN}" \
    >/dev/null 2>&1

  chmod 600 "$SS_KEY"
fi

###############################################################################
# Choose certificate source
###############################################################################

if [[ -f "$LE_CERT" && -f "$LE_KEY" ]]; then
  CERT_LINE="cert=${LE_CERT}"
  KEY_LINE="pkey=${LE_KEY}"
else
  CERT_LINE="cert=${SS_CERT}"
  KEY_LINE="pkey=${SS_KEY}"
fi

###############################################################################
# External IP mapping
###############################################################################

EXT_MAP=""

if [[ -n "${EXTERNAL_IP:-}" && "$EXTERNAL_IP" != "$LXC_IP" ]]; then
  EXT_MAP="external-ip=${EXTERNAL_IP}/${LXC_IP}"
fi

###############################################################################
# Ensure coturn log directory exists
###############################################################################

mkdir -p /var/log/coturn
touch /var/log/coturn/turn.log
chown turnserver:turnserver /var/log/coturn/turn.log

###############################################################################
# Write turnserver configuration
###############################################################################

cat > /etc/turnserver.conf <<TEOF
realm=${TURN}

use-auth-secret
static-auth-secret=${TURN_SECRET}

fingerprint

listening-ip=0.0.0.0
relay-ip=${LXC_IP}
${EXT_MAP}

no-udp
listening-port=3478
tls-listening-port=5349

min-port=49160
max-port=49250

${CERT_LINE}
${KEY_LINE}

no-tlsv1
no-tlsv1_1

no-cli
no-multicast-peers
no-loopback-peers

stale-nonce=600
total-quota=300

# Block all private/reserved ranges (SSRF protection)
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
TEOF

###############################################################################
# Enable coturn service
###############################################################################

echo "TURNSERVER_ENABLED=1" > /etc/default/coturn

###############################################################################
# LetsEncrypt permissions hook
###############################################################################

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

###############################################################################
# Restart coturn
###############################################################################

systemctl enable coturn
systemctl restart coturn

echo "  coturn configured."
