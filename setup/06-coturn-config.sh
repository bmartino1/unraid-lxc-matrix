#!/bin/bash
###############################################################################
# Configure coturn — matches PVE working turnserver.conf
###############################################################################
set -euo pipefail
echo "  Configuring coturn..."

LE_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
LE_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
SS_CERT="/etc/ssl/nginx/${DOMAIN}.crt"
SS_KEY="/etc/ssl/nginx/${DOMAIN}.key"

# Generate self-signed cert for coturn if nothing exists yet
if [[ ! -f "$LE_CERT" && ! -f "$SS_CERT" ]]; then
  echo "  Generating self-signed cert for coturn TLS..."
  mkdir -p /etc/ssl/nginx
  openssl req -x509 -nodes -newkey rsa:4096 -days 3650 \
    -keyout "$SS_KEY" -out "$SS_CERT" \
    -subj "/CN=${DOMAIN}" 2>/dev/null
  chmod 600 "$SS_KEY"
fi

# Use LE if available, otherwise self-signed (coturn MUST have a cert for TURNS)
if [[ -f "$LE_CERT" && -f "$LE_KEY" ]]; then
  CERT_LINE="cert=${LE_CERT}"
  KEY_LINE="pkey=${LE_KEY}"
else
  CERT_LINE="cert=${SS_CERT}"
  KEY_LINE="pkey=${SS_KEY}"
fi

# Determine external-ip mapping
EXT_MAP=""
if [[ -n "${EXTERNAL_IP:-}" && "$EXTERNAL_IP" != "$LXC_IP" ]]; then
  EXT_MAP="external-ip=${EXTERNAL_IP}/${LXC_IP}"
fi

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

# Allow loopback and LXC relay
allowed-peer-ip=127.0.0.1
allowed-peer-ip=${LXC_IP}

log-file=stdout
verbose
TEOF

echo "TURNSERVER_ENABLED=1" > /etc/default/coturn

# Ensure coturn can read LE certs
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

# Set coturn cert perms now if LE exists
[[ -f "$LE_CERT" ]] && bash /etc/letsencrypt/renewal-hooks/post/coturn-perms.sh 2>/dev/null || true

# If using self-signed, copy to coturn-owned location so turnserver user can read
if [[ ! -f "$LE_CERT" && -f "$SS_CERT" ]]; then
  mkdir -p /etc/coturn/certs
  cp "$SS_CERT" /etc/coturn/certs/fullchain.pem
  cp "$SS_KEY"  /etc/coturn/certs/privkey.pem
  chown -R turnserver:turnserver /etc/coturn/certs/ 2>/dev/null || true
  chmod 640 /etc/coturn/certs/*.pem
  # Update turnserver.conf to use coturn-owned copies
  sed -i "s|cert=${SS_CERT}|cert=/etc/coturn/certs/fullchain.pem|" /etc/turnserver.conf
  sed -i "s|pkey=${SS_KEY}|pkey=/etc/coturn/certs/privkey.pem|" /etc/turnserver.conf
fi

systemctl enable coturn
systemctl restart coturn
echo "  coturn configured."
