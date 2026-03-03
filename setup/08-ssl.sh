#!/bin/bash
# SETUP PHASE - 08: SSL/TLS certificate provisioning
set -euo pipefail

SSL_DIR="/etc/ssl/nginx"
CERT_BASE="/etc/letsencrypt/live"
STAGING_FLAG=""
[[ "${STAGING}" == "true" ]] && STAGING_FLAG="--staging"

link_le_cert() {
  local fqdn="$1"
  ln -sf "${CERT_BASE}/${fqdn}/fullchain.pem" "${SSL_DIR}/${fqdn}.crt"
  ln -sf "${CERT_BASE}/${fqdn}/privkey.pem"   "${SSL_DIR}/${fqdn}.key"
  echo "  Linked Let's Encrypt cert for ${fqdn}"
}

if [[ "${SKIP_SSL}" == "true" ]]; then
  echo "  --skip-ssl: self-signed certificates are active."
  echo "  When DNS is ready, run: ./scripts/renew-ssl.sh"
  exit 0
fi

echo "  Requesting Let's Encrypt certificates..."
echo "  (DNS for ${DOMAIN}, ${MATRIX_DOMAIN}, ${JITSI_DOMAIN} must point to ${LXC_IP})"

for fqdn in "${DOMAIN}" "${MATRIX_DOMAIN}" "${JITSI_DOMAIN}"; do
  echo "  Requesting cert for: ${fqdn}"
  certbot certonly \
    --webroot \
    --webroot-path /var/www/html \
    --non-interactive \
    --agree-tos \
    --email "admin@${DOMAIN}" \
    --domain "${fqdn}" \
    ${STAGING_FLAG} \
    2>&1 | tail -8 || {
      echo "  WARNING: certbot failed for ${fqdn} (DNS may not be ready yet)"
      echo "  Self-signed cert will remain active. Run ./scripts/renew-ssl.sh later."
      continue
    }
  link_le_cert "${fqdn}"
done

# ── Update coturn to use real TLS cert ────────────────────────────────────────
if [[ -f "${CERT_BASE}/${DOMAIN}/fullchain.pem" ]]; then
  echo "  Enabling TLS on coturn..."
  sed -i "s|^# cert=.*|cert=${CERT_BASE}/${DOMAIN}/fullchain.pem|" /etc/turnserver.conf
  sed -i "s|^# pkey=.*|pkey=${CERT_BASE}/${DOMAIN}/privkey.pem|"   /etc/turnserver.conf
  systemctl restart coturn
fi

echo "  Reloading Nginx with new certificates..."
nginx -t && systemctl reload nginx

# ── Auto-renewal hook ────────────────────────────────────────────────────────
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/matrix-stack-reload.sh <<EOF
#!/bin/bash
# Renewal hook - relinks certs and reloads services
SSL_DIR=/etc/ssl/nginx
for fqdn in \$(ls /etc/letsencrypt/live/); do
  [[ -f /etc/letsencrypt/live/\${fqdn}/fullchain.pem ]] || continue
  ln -sf /etc/letsencrypt/live/\${fqdn}/fullchain.pem \${SSL_DIR}/\${fqdn}.crt
  ln -sf /etc/letsencrypt/live/\${fqdn}/privkey.pem   \${SSL_DIR}/\${fqdn}.key
done
systemctl reload nginx  2>/dev/null || true
systemctl restart coturn 2>/dev/null || true
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/matrix-stack-reload.sh

# Add renewal cron if not already there
if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
  (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet") | crontab -
fi

echo "  SSL setup complete."
