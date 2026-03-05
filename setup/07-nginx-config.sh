#!/bin/bash
# =============================================================================
# SETUP PHASE 07
# Configure Nginx virtual hosts and TLS SNI routing
#
# Security model:
#   - meet.<domain> cannot be opened directly in browser
#   - Jitsi only loads via Element iframe
#   - referer/origin checks enforce widget-only usage
#   - only ports 80 and 443 exposed externally
#
# This step:
#   - ensures nginx directories exist
#   - generates temporary self-signed certificates
#   - writes vhost configs
#   - enables nginx sites
# =============================================================================

set -euo pipefail

SITES_AVAIL="/etc/nginx/sites-available"
SITES_EN="/etc/nginx/sites-enabled"
SSL_DIR="/etc/ssl/nginx"

mkdir -p "${SITES_AVAIL}" "${SITES_EN}" "${SSL_DIR}"
rm -f "${SITES_EN}"/*

echo "  Ensuring nginx installed..."
if ! command -v nginx >/dev/null 2>&1; then
    apt-get update
    apt-get install -y nginx openssl
fi

# ─────────────────────────────────────────────────────────
# Generate placeholder TLS certificates
# These are replaced by step 08 when LE is requested
# ─────────────────────────────────────────────────────────

echo "  Generating self-signed placeholder certificates..."

for fqdn in "${DOMAIN}" "${MATRIX_DOMAIN}" "${JITSI_DOMAIN}"; do

    crt="${SSL_DIR}/${fqdn}.crt"
    key="${SSL_DIR}/${fqdn}.key"

    if [[ ! -f "${crt}" || ! -f "${key}" ]]; then

        openssl req -x509 -nodes -newkey rsa:4096 \
            -days 3650 \
            -keyout "${key}" \
            -out "${crt}" \
            -subj "/CN=${fqdn}/O=matrix-stack/C=US" \
            -addext "subjectAltName=DNS:${fqdn}" \
            2>/dev/null

        chmod 600 "${key}"

        echo "    Self-signed cert created for ${fqdn}"

    else
        echo "    Existing cert found for ${fqdn}"
    fi
done


# ─────────────────────────────────────────────────────────
# Stream SNI map used by nginx stream proxy
# ─────────────────────────────────────────────────────────

echo "  Writing Nginx SNI stream map..."

cat > /etc/nginx/stream-sni.map <<EOF
# SNI routing map
${DOMAIN}         https_terminator;
${MATRIX_DOMAIN}  https_terminator;
${JITSI_DOMAIN}   https_terminator;
EOF


# ─────────────────────────────────────────────────────────
# HTTP redirect + ACME support
# ─────────────────────────────────────────────────────────

cat > "${SITES_AVAIL}/00-redirect.conf" <<EOF
server {

    listen 80 default_server;
    listen [::]:80 default_server;

    server_name _;

    root /var/www/html;

    location /.well-known/acme-challenge/ {
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF


# ─────────────────────────────────────────────────────────
# Element Web
# ─────────────────────────────────────────────────────────

cat > "${SITES_AVAIL}/10-element.conf" <<EOF
server {

    listen 8443 ssl http2;
    listen [::]:8443 ssl http2;

    server_name ${ELEMENT_DOMAIN};

    ssl_certificate     ${SSL_DIR}/${DOMAIN}.crt;
    ssl_certificate_key ${SSL_DIR}/${DOMAIN}.key;

    root /var/www/element;
    index index.html;

    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    add_header Content-Security-Policy "frame-src 'self' https://${JITSI_DOMAIN}; frame-ancestors 'self'; object-src 'none'" always;

    location / {
        try_files \$uri \$uri/ /index.html;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)\$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    location /.well-known/matrix/server {
        default_type application/json;
        add_header Access-Control-Allow-Origin *;
        return 200 '{"m.server":"${MATRIX_DOMAIN}:443"}';
    }

    location /.well-known/matrix/client {
        default_type application/json;
        add_header Access-Control-Allow-Origin *;
        return 200 '{"m.homeserver":{"base_url":"https://${MATRIX_DOMAIN}"},"m.identity_server":{"base_url":"https://vector.im"}}';
    }

}
EOF


# ─────────────────────────────────────────────────────────
# Matrix Synapse reverse proxy
# ─────────────────────────────────────────────────────────

cat > "${SITES_AVAIL}/20-synapse.conf" <<EOF
server {

    listen 8443 ssl http2;
    listen [::]:8443 ssl http2;

    server_name ${MATRIX_DOMAIN};

    ssl_certificate     ${SSL_DIR}/${MATRIX_DOMAIN}.crt;
    ssl_certificate_key ${SSL_DIR}/${MATRIX_DOMAIN}.key;

    client_max_body_size 100m;

    proxy_read_timeout 600s;
    proxy_send_timeout 600s;

    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header Access-Control-Allow-Origin "*" always;

    location / {

        proxy_pass http://127.0.0.1:8008;

        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Host \$host;

        proxy_http_version 1.1;
    }

}
EOF


# ─────────────────────────────────────────────────────────
# Jitsi Meet (restricted access)
# ─────────────────────────────────────────────────────────

cat > "${SITES_AVAIL}/30-jitsi.conf" <<EOF
server {

    listen 8443 ssl http2;
    listen [::]:8443 ssl http2;

    server_name ${JITSI_DOMAIN};

    ssl_certificate     ${SSL_DIR}/${JITSI_DOMAIN}.crt;
    ssl_certificate_key ${SSL_DIR}/${JITSI_DOMAIN}.key;

    root /usr/share/jitsi-meet;
    index index.html;

    add_header Content-Security-Policy "frame-ancestors 'self' https://${ELEMENT_DOMAIN}" always;

    set \$allow_jitsi 0;

    if (\$request_uri ~* "^/(http-bind|xmpp-websocket|colibri-ws|libs/|css/|static/|images/|fonts/|sounds/|config\.js|external_api\.js)") {
        set \$allow_jitsi 1;
    }

    if (\$http_origin = "https://${ELEMENT_DOMAIN}") {
        set \$allow_jitsi 1;
    }

    if (\$http_referer ~* "^https://${ELEMENT_DOMAIN}/") {
        set \$allow_jitsi 1;
    }

    if (\$allow_jitsi = 0) {
        return 403;
    }

    location / {
        try_files \$uri \$uri/ @root_path;
    }

    location @root_path {
        rewrite ^/(.*)$ / break;
    }

    location = /http-bind {
        proxy_pass http://127.0.0.1:5280/http-bind;
    }

    location = /xmpp-websocket {
        proxy_pass http://127.0.0.1:5280/xmpp-websocket;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

}
EOF


# ─────────────────────────────────────────────────────────
# Enable sites
# ─────────────────────────────────────────────────────────

echo "  Enabling Nginx sites..."

for site in 00-redirect 10-element 20-synapse 30-jitsi; do
    ln -sf "${SITES_AVAIL}/${site}.conf" "${SITES_EN}/${site}.conf"
done


# ─────────────────────────────────────────────────────────
# Start nginx
# ─────────────────────────────────────────────────────────

echo "  Testing Nginx configuration..."
nginx -t

echo "  Starting Nginx..."
systemctl enable nginx
systemctl restart nginx

echo "  Nginx configured. Jitsi should be restricted to Element widget access only."
