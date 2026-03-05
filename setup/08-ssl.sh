#!/bin/bash
# =============================================================================
# SETUP PHASE 08
# SSL / TLS certificate provisioning
#
# Behaviour:
#   --skip-ssl → keep self-signed certs from phase 07
#   default    → attempt Let's Encrypt
#
# Safe behaviour:
#   - if certbot fails → self-signed certs remain active
#   - nginx reload still occurs
# =============================================================================

set -euo pipefail

SSL_DIR="/etc/ssl/nginx"
CERT_BASE="/etc/letsencrypt/live"

STAGING_FLAG=""
[[ "${STAGING}" == "true" ]] && STAGING_FLAG="--staging"

mkdir -p "${SSL_DIR}"

link_le_cert() {
  local fqdn="$1"

  if [[ -f "${CERT_BASE}/${fqdn}/fullchain.pem" ]]; then

    ln -sf "${CERT_BASE}/${fqdn}/fullchain.pem" "${SSL_DIR}/${fqdn}.crt"
    ln -sf "${CERT_BASE}/${fqdn}/privkey.pem"   "${SSL_DIR}/${fqdn}.key"

    echo "  Linked Let's Encrypt cert for ${fqdn}"

  else
    echo "  WARNING: cert files missing for ${fqdn}"
  fi
}

# ─────────────────────────────────────────────────────────
# Skip SSL mode
# ─────────────────────────────────────────────────────────

if [[ "${SKIP_SSL}" == "true" ]]; then
  echo "  --skip-ssl enabled."
  echo "  Self-signed certificates from phase 07 remain active."
  echo "  When DNS is ready run: ./scripts/renew-ssl.sh"
  exit 0
fi


# ─────────────────────────────────────────────────────────
# Ensure certbot installed
# ─────────────────────────────────────────────────────────

if ! command -v certbot >/dev/null 2>&1; then

  echo "  Installing certbot..."

  apt-get update
  apt-get install -y certbot

fi


echo "  Requesting Let's Encrypt certificates..."
echo "  DNS must resolve to: ${LXC_IP}"
echo ""


# ─────────────────────────────────────────────────────────
# Issue certificates
# ─────────────────────────────────────────────────────────

for fqdn in "${DOMAIN}" "${MATRIX_DOMAIN}" "${JITSI_DOMAIN}"; do

  echo "  Requesting cert for: ${fqdn}"

  if certbot certonly \
      --webroot \
      --webroot-path /var/www/html \
      --non-interactive \
      --agree-tos \
      --email "admin@${DOMAIN}" \
      --domain "${fqdn}" \
      ${STAGING_FLAG}; then

      link_le_cert "${fqdn}"

  else

      echo "  WARNING: certbot failed for ${fqdn}"
      echo "  Self-signed certificate remains active."

  fi

done


# ─────────────────────────────────────────────────────────
# Enable TLS for coturn if cert exists
# ─────────────────────────────────────────────────────────

if [[ -f "${CERT_BASE}/${DOMAIN}/fullchain.pem" ]]; then

  echo "  Enabling TLS on coturn..."

  sed -i "s|^# cert=.*|cert=${CERT_BASE}/${DOMAIN}/fullchain.pem|" /etc/turnserver.conf
  sed -i "s|^# pkey=.*|pkey=${CERT_BASE}/${DOMAIN}/privkey.pem|"   /etc/turnserver.conf

  systemctl restart coturn

fi


# ─────────────────────────────────────────────────────────
# Reload nginx
# ─────────────────────────────────────────────────────────

echo "  Reloading Nginx with certificates..."

nginx -t
systemctl reload nginx


# ─────────────────────────────────────────────────────────
# Renewal hook
# ─────────────────────────────────────────────────────────

mkdir -p /etc/letsencrypt/renewal-hooks/deploy

cat > /etc/letsencrypt/renewal-hooks/deploy/matrix-stack-reload.sh <<EOF
#!/bin/bash

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


# ─────────────────────────────────────────────────────────
# Renewal cron
# ─────────────────────────────────────────────────────────

if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then

  (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet") | crontab -

fi


echo "  SSL setup complete."
