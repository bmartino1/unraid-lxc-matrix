#!/bin/bash
###############################################################################
# SETUP PHASE - 08: SSL/TLS certificate provisioning (non-fatal)
# - If --skip-ssl: do nothing (self-signed stays)
# - If certbot fails: warn and continue (NEVER breaks setup)
###############################################################################

set -euo pipefail

echo
echo "══════════════════════════════════════════════════"
echo "  ssl"
echo "══════════════════════════════════════════════════"
echo

SSL_DIR="/etc/ssl/nginx"
CERT_BASE="/etc/letsencrypt/live"

STAGING_FLAG=""
[[ "${STAGING:-false}" == "true" ]] && STAGING_FLAG="--staging"

mkdir -p "${SSL_DIR}"

link_le_cert() {
  local fqdn="$1"
  if [[ -f "${CERT_BASE}/${fqdn}/fullchain.pem" && -f "${CERT_BASE}/${fqdn}/privkey.pem" ]]; then
    ln -sf "${CERT_BASE}/${fqdn}/fullchain.pem" "${SSL_DIR}/${fqdn}.crt"
    ln -sf "${CERT_BASE}/${fqdn}/privkey.pem"   "${SSL_DIR}/${fqdn}.key"
    echo "  Linked Let's Encrypt cert for ${fqdn}"
    return 0
  fi
  return 1
}

# Always non-fatal exit path
finish_ok() {
  echo
  echo "  SSL step finished (non-fatal)."
  exit 0
}

if [[ "${SKIP_SSL:-false}" == "true" ]]; then
  echo "  --skip-ssl enabled: self-signed certificates remain active."
  echo "  When you want Let's Encrypt later, run: ./scripts/renew-ssl.sh"
  finish_ok
fi

echo "  Requesting Let's Encrypt certificates..."
echo "  DNS must resolve to: ${LXC_IP}"
echo

# certbot is best-effort; never let it kill setup
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
    link_le_cert "${fqdn}" || true
  else
    echo "  WARNING: certbot failed for ${fqdn}"
    echo "  Self-signed certificate remains active."
  fi

  echo
done

# Update coturn TLS if DOMAIN cert exists (best-effort)
if [[ -f "${CERT_BASE}/${DOMAIN}/fullchain.pem" && -f "${CERT_BASE}/${DOMAIN}/privkey.pem" ]]; then
  echo "  Enabling TLS on coturn (best-effort)..."
  sed -i "s|^#\s*cert=.*|cert=${CERT_BASE}/${DOMAIN}/fullchain.pem|" /etc/turnserver.conf 2>/dev/null || true
  sed -i "s|^#\s*pkey=.*|pkey=${CERT_BASE}/${DOMAIN}/privkey.pem|"   /etc/turnserver.conf 2>/dev/null || true
  systemctl restart coturn 2>/dev/null || true
fi

echo "  Reloading Nginx with certificates (best-effort)..."
nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true

# Renewal hook (only useful if certbot succeeds later)
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/matrix-stack-reload.sh <<'EOF'
#!/bin/bash
SSL_DIR=/etc/ssl/nginx
for fqdn in $(ls /etc/letsencrypt/live/ 2>/dev/null); do
  [[ -f /etc/letsencrypt/live/${fqdn}/fullchain.pem ]] || continue
  ln -sf /etc/letsencrypt/live/${fqdn}/fullchain.pem ${SSL_DIR}/${fqdn}.crt
  ln -sf /etc/letsencrypt/live/${fqdn}/privkey.pem   ${SSL_DIR}/${fqdn}.key
done
systemctl reload nginx 2>/dev/null || true
systemctl restart coturn 2>/dev/null || true
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/matrix-stack-reload.sh 2>/dev/null || true

finish_ok
