#!/bin/bash
# SETUP PHASE - 07: Write Nginx vhosts and SNI map
#
# Security model:
#   - meet.<domain> is NOT accessible via direct browser navigation
#   - Jitsi is only reachable as an Element widget (iframe from element domain)
#   - Nginx checks the Referer/Origin for direct Jitsi browser access
#   - Only 443 (stream SNI) and 80 (ACME + redirect) are exposed externally
set -euo pipefail

SITES_AVAIL="/etc/nginx/sites-available"
SITES_EN="/etc/nginx/sites-enabled"
SSL_DIR="/etc/ssl/nginx"

mkdir -p "${SITES_AVAIL}" "${SITES_EN}" "${SSL_DIR}"
rm -f "${SITES_EN}"/*

# ── Self-signed placeholder certs (replaced by 08-ssl.sh) ────────────────────
echo "  Generating self-signed certificates (placeholder until Let's Encrypt)..."
for fqdn in "${DOMAIN}" "${MATRIX_DOMAIN}" "${JITSI_DOMAIN}"; do
  if [[ ! -f "${SSL_DIR}/${fqdn}.crt" ]]; then
    openssl req -x509 -nodes -newkey rsa:4096 -days 365 \
      -keyout "${SSL_DIR}/${fqdn}.key" \
      -out    "${SSL_DIR}/${fqdn}.crt" \
      -subj   "/CN=${fqdn}/O=matrix-stack/C=US" \
      -addext "subjectAltName=DNS:${fqdn}" 2>/dev/null
    echo "    Self-signed cert created for ${fqdn}"
  fi
done

# ── Update SNI stream map ─────────────────────────────────────────────────────
echo "  Writing Nginx SNI stream map..."
cat > /etc/nginx/stream-sni.map <<EOF
# SNI map - written by setup.sh
# All SNI names route to the internal HTTPS terminator
${DOMAIN}         https_terminator;
${MATRIX_DOMAIN}  https_terminator;
${JITSI_DOMAIN}   https_terminator;
EOF

# ── HTTP redirect + ACME ─────────────────────────────────────────────────────
cat > "${SITES_AVAIL}/00-redirect.conf" <<EOF
# HTTP -> HTTPS redirect and ACME challenge
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

# ── Element Web (chat.example.com) ───────────────────────────────────────────
cat > "${SITES_AVAIL}/10-element.conf" <<EOF
# Element Web - ${ELEMENT_DOMAIN}
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
    # Allow embedding Jitsi in iframes from this domain
    add_header Content-Security-Policy "frame-src 'self' https://${JITSI_DOMAIN}; frame-ancestors 'self'; object-src 'none'" always;

    location / {
        try_files \$uri \$uri/ /index.html;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)\$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    # Matrix well-known delegation
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

# ── Matrix Synapse (matrix.domain) ───────────────────────────────────────────
cat > "${SITES_AVAIL}/20-synapse.conf" <<EOF
# Matrix Synapse - ${MATRIX_DOMAIN}
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
    add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS" always;
    add_header Access-Control-Allow-Headers "X-Requested-With, Content-Type, Authorization" always;

    location / {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header X-Forwarded-For   \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Host              \$host;
        proxy_http_version 1.1;
    }

    location /health {
        proxy_pass http://127.0.0.1:9000/health;
        access_log off;
    }
}
EOF

# ── Jitsi Meet (meet.domain) — WIDGET ONLY ──────────────────────────────────
# Direct browser navigation returns 403. Only accessible from Element iframe.
cat > "${SITES_AVAIL}/30-jitsi.conf" <<EOF
# Jitsi Meet - ${JITSI_DOMAIN}
# Access restriction: only allowed when loaded as an Element widget (iframe)
# Direct browser navigation is blocked with 403.
server {
    listen 8443 ssl http2;
    listen [::]:8443 ssl http2;
    server_name ${JITSI_DOMAIN};

    ssl_certificate     ${SSL_DIR}/${JITSI_DOMAIN}.crt;
    ssl_certificate_key ${SSL_DIR}/${JITSI_DOMAIN}.key;

    root /usr/share/jitsi-meet;
    index index.html;

    # Allow embedding in iframes from the Element domain
    add_header Content-Security-Policy "frame-ancestors 'self' https://${ELEMENT_DOMAIN}" always;
    add_header Strict-Transport-Security "max-age=63072000" always;

    # CORS for BOSH/WS requests from Element
    add_header Access-Control-Allow-Origin "https://${ELEMENT_DOMAIN}" always;
    add_header Access-Control-Allow-Credentials "true" always;

    # ── Restrict direct browser navigation ──────────────────────────────────
    # Allow: requests that come from Element (have correct Origin/Referer)
    # Allow: internal service requests (BOSH, WS, assets with no Referer)
    # Block: direct navigation (browser sets Sec-Fetch-Mode: navigate, no Referer)
    set \$allow_jitsi 0;

    # Always allow: BOSH, WebSocket, asset requests (no Sec-Fetch-Mode: navigate)
    if (\$request_uri ~* "^/(http-bind|xmpp-websocket|colibri-ws|libs/|css/|static/|images/|fonts/|sounds/|config\.js|external_api\.js|\\.well-known/)") {
        set \$allow_jitsi 1;
    }

    # Allow if Origin matches Element domain
    if (\$http_origin = "https://${ELEMENT_DOMAIN}") {
        set \$allow_jitsi 1;
    }

    # Allow if Referer starts with Element domain (widget frame navigation)
    if (\$http_referer ~* "^https://${ELEMENT_DOMAIN}/") {
        set \$allow_jitsi 1;
    }

    # Block everything else (direct browser navigation)
    if (\$allow_jitsi = 0) {
        return 403;
    }

    # SPA routing
    location / {
        try_files \$uri \$uri/ @root_path;
    }
    location @root_path {
        rewrite ^/(.*)$ / break;
    }

    # BOSH
    location = /http-bind {
        proxy_pass http://127.0.0.1:5280/http-bind;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header Host \$http_host;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_read_timeout 90s;
    }

    # XMPP WebSocket
    location = /xmpp-websocket {
        proxy_pass http://127.0.0.1:5280/xmpp-websocket;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_read_timeout 900s;
    }

    # Colibri / JVB WebSocket
    location ~ ^/colibri-ws/(.*) {
        proxy_pass http://127.0.0.1:9090/colibri-ws/\$1\$is_args\$args;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
        proxy_read_timeout 900s;
    }

    # Static assets
    location ~ /config\.js {
        alias /usr/share/jitsi-meet/config.js;
    }
    location ~ /external_api\.js {
        alias /usr/share/jitsi-meet/libs/external_api.min.js;
    }
    location ~* ^/(libs|css|static|images|fonts|lang|sounds)/ {
        add_header Cache-Control "max-age=3600";
    }
}
EOF

echo "  Enabling Nginx sites..."
for site in 00-redirect 10-element 20-synapse 30-jitsi; do
  ln -sf "${SITES_AVAIL}/${site}.conf" "${SITES_EN}/${site}.conf"
done

echo "  Testing Nginx configuration..."
nginx -t

echo "  Starting Nginx..."
systemctl enable nginx
systemctl restart nginx

echo "  Nginx configured. Jitsi restricted to Element widget access only."
