#!/bin/bash
###############################################################################
# SSL/TLS provisioning — non-fatal (never breaks setup)
###############################################################################
set -euo pipefail
echo "  SSL/TLS setup..."

SSL_DIR="/etc/ssl/nginx"
LE_BASE="/etc/letsencrypt/live"
STAGING_FLAG=""
[[ "${STAGING:-false}" == "true" ]] && STAGING_FLAG="--staging"

if [[ "${SKIP_SSL:-false}" == "true" ]]; then
  echo "  --skip-ssl: self-signed certs remain. Run scripts/renew-ssl.sh later."
  exit 0
fi

echo "  Requesting Let's Encrypt certificates (DNS must resolve to ${LXC_IP})..."

# Use single cert for all domains (SAN cert)
if certbot certonly --nginx --non-interactive --agree-tos \
    --email "admin@${DOMAIN}" \
    -d "${DOMAIN}" -d "${MEET}" -d "${TURN}" \
    ${STAGING_FLAG} 2>&1; then

  echo "  Certificates obtained. Linking..."

  # Update nginx to use LE certs
  for conf in /etc/nginx/sites-available/matrix /etc/nginx/sites-available/meet; do
    [[ -f "$conf" ]] && \
      sed -i "s|ssl_certificate .*|ssl_certificate     ${LE_BASE}/${DOMAIN}/fullchain.pem;|" "$conf" && \
      sed -i "s|ssl_certificate_key .*|ssl_certificate_key ${LE_BASE}/${DOMAIN}/privkey.pem;|" "$conf"
  done

  # Update coturn
  sed -i "s|^# cert=.*|cert=${LE_BASE}/${DOMAIN}/fullchain.pem|" /etc/turnserver.conf 2>/dev/null || true
  sed -i "s|^cert=.*|cert=${LE_BASE}/${DOMAIN}/fullchain.pem|" /etc/turnserver.conf 2>/dev/null || true
  sed -i "s|^# pkey=.*|pkey=${LE_BASE}/${DOMAIN}/privkey.pem|" /etc/turnserver.conf 2>/dev/null || true
  sed -i "s|^pkey=.*|pkey=${LE_BASE}/${DOMAIN}/privkey.pem|" /etc/turnserver.conf 2>/dev/null || true

  # Fix coturn cert permissions
  bash /etc/letsencrypt/renewal-hooks/post/coturn-perms.sh 2>/dev/null || true

  # Copy certs for Jitsi/Prosody
  cp "${LE_BASE}/${DOMAIN}/fullchain.pem" "/etc/prosody/certs/${MEET}.crt" 2>/dev/null || true
  cp "${LE_BASE}/${DOMAIN}/privkey.pem"   "/etc/prosody/certs/${MEET}.key" 2>/dev/null || true
  chown prosody:prosody /etc/prosody/certs/${MEET}.* 2>/dev/null || true

  cp "${LE_BASE}/${DOMAIN}/fullchain.pem" "/etc/jitsi/meet/${MEET}.crt" 2>/dev/null || true
  cp "${LE_BASE}/${DOMAIN}/privkey.pem"   "/etc/jitsi/meet/${MEET}.key" 2>/dev/null || true

  # Restart services
  nginx -t && systemctl reload nginx
  systemctl restart coturn 2>/dev/null || true
  systemctl restart prosody 2>/dev/null || true

  echo "  SSL certificates installed."
else
  echo "  WARNING: certbot failed. Self-signed certs remain active."
  echo "  Run scripts/renew-ssl.sh when DNS is ready."
fi
