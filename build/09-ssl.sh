#!/bin/bash
# Stage 09 - SSL/TLS certificate provisioning via Let's Encrypt or self-signed
set -euo pipefail

CERT_DIR="/etc/letsencrypt/live"
NGINX_SSL_DIR="/etc/ssl/nginx"
STAGING_FLAG=""
[[ "$STAGING" == "true" ]] && STAGING_FLAG="--staging"

# Function to replace self-signed with real certs for a domain
link_cert() {
  local fqdn="$1"
  ln -sf "${CERT_DIR}/${fqdn}/fullchain.pem" "${NGINX_SSL_DIR}/${fqdn}.crt"
  ln -sf "${CERT_DIR}/${fqdn}/privkey.pem"   "${NGINX_SSL_DIR}/${fqdn}.key"
  echo "   Linked Let's Encrypt cert for ${fqdn}"
}

if [[ "$SKIP_SSL" == "true" ]]; then
  echo "==> --skip-ssl set: keeping self-signed certificates."
  echo "    To get real certs later, run:  scripts/renew-ssl.sh"
  exit 0
fi

echo "==> Requesting Let's Encrypt certificates via certbot..."
LXC_IP=$(hostname -I | awk '{print $1}')

# Certbot needs port 80 accessible from the internet
# Make sure Nginx is running for the ACME webroot challenge
systemctl start nginx 2>/dev/null || true

for fqdn in "${DOMAIN}" "${MATRIX_DOMAIN}" "${JITSI_DOMAIN}"; do
  echo "==> Obtaining cert for: ${fqdn}"
  certbot certonly \
    --webroot \
    --webroot-path /var/www/html \
    --non-interactive \
    --agree-tos \
    --email "admin@${DOMAIN}" \
    --domain "${fqdn}" \
    ${STAGING_FLAG} \
    2>&1 | tail -5 || {
      echo "   WARNING: certbot failed for ${fqdn}"
      echo "   The self-signed certificate will remain active."
      echo "   DNS records must point to this LXC's IP (${LXC_IP}) for ACME to work."
      continue
    }

  link_cert "${fqdn}"
done

echo "==> Updating coturn TLS cert paths..."
COTURN_CONF="/etc/turnserver.conf"
if [[ -f "${CERT_DIR}/${DOMAIN}/fullchain.pem" ]]; then
  sed -i "s|^# cert=.*|cert=${CERT_DIR}/${DOMAIN}/fullchain.pem|" "${COTURN_CONF}"
  sed -i "s|^# pkey=.*|pkey=${CERT_DIR}/${DOMAIN}/privkey.pem|"   "${COTURN_CONF}"
  systemctl reload coturn 2>/dev/null || systemctl restart coturn
fi

echo "==> Reloading Nginx with new certs..."
nginx -t && systemctl reload nginx

echo "==> Setting up certbot auto-renewal hook..."
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-services.sh <<'EOF'
#!/bin/bash
# Reload services after cert renewal
for fqdn in $(ls /etc/letsencrypt/live/); do
  ln -sf /etc/letsencrypt/live/${fqdn}/fullchain.pem /etc/ssl/nginx/${fqdn}.crt 2>/dev/null || true
  ln -sf /etc/letsencrypt/live/${fqdn}/privkey.pem   /etc/ssl/nginx/${fqdn}.key 2>/dev/null || true
done
systemctl reload nginx  2>/dev/null || true
systemctl reload coturn 2>/dev/null || true
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-services.sh

echo "==> Adding certbot renewal cron..."
(crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --no-self-upgrade") | crontab -

echo "Completed Stage 09 - SSL"
