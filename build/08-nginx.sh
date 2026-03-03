#!/bin/bash
# Stage 08 - Nginx configuration
# Architecture:
#   Port 80  -> HTTP redirect to HTTPS + ACME challenge
#   Port 443 -> SNI-based stream routing:
#               matrix.<domain>  -> reverse proxy -> Synapse :8008
#               meet.<domain>    -> reverse proxy -> Jitsi (prosody BOSH + JVB)
#               <domain>         -> reverse proxy -> Element Web (static files)
#   Nginx stream module routes raw TLS SNI for coturn passthrough on :5349
set -euo pipefail

NGINX_DIR="/etc/nginx"
CONF_DIR="${NGINX_DIR}/conf.d"
SITES_DIR="${NGINX_DIR}/sites-available"
SITES_EN="${NGINX_DIR}/sites-enabled"

mkdir -p "${CONF_DIR}" "${SITES_DIR}" "${SITES_EN}"

# Disable the default site
rm -f "${SITES_EN}/default"

echo "==> Writing Nginx main nginx.conf..."
cat > "${NGINX_DIR}/nginx.conf" <<'NGINXEOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log warn;

# Load stream module for SNI passthrough
load_module modules/ngx_stream_module.so;

events {
    worker_connections 2048;
    use epoll;
    multi_accept on;
}

# ── Stream block: SNI-based TCP/TLS routing on port 443 ────────────────────
stream {
    log_format basic '$remote_addr [$time_local] '
                     '$protocol $status $bytes_sent $bytes_received '
                     '$session_time "$ssl_preread_server_name"';

    access_log /var/log/nginx/stream.log basic;

    # Map SNI hostname -> upstream
    map $ssl_preread_server_name $backend_name {
        default            https_default;
        include /etc/nginx/stream-sni.map;
    }

    # Upstream pools (nginx http proxies internally on high ports)
    upstream https_default {
        server 127.0.0.1:8443;
    }

    # The actual SNI pre-read listener
    server {
        listen 443;
        proxy_pass $backend_name;
        ssl_preread on;
        proxy_connect_timeout 10s;
        proxy_timeout 600s;
    }
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    # HSTS
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript application/xml+rss application/atom+xml image/svg+xml;

    access_log /var/log/nginx/access.log combined;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
NGINXEOF

echo "==> Writing SNI map file (to be updated after cert provisioning)..."
# Placeholder — will be rewritten by 09-ssl.sh when certs are known
cat > "${NGINX_DIR}/stream-sni.map" <<EOF
# SNI map - managed by setup.sh
# Format:  hostname    upstream_pool;
# These are the internal https upstreams (port 8443 terminates TLS in http{})
${DOMAIN}          https_default;
${MATRIX_DOMAIN}   https_default;
${JITSI_DOMAIN}    https_default;
EOF

echo "==> Writing HTTP redirect vhost..."
cat > "${SITES_DIR}/00-redirect.conf" <<EOF
# HTTP -> HTTPS redirect + ACME challenge passthrough
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    # Let's Encrypt ACME challenge
    location /.well-known/acme-challenge/ {
        root /var/www/html;
        try_files \$uri =404;
    }

    # Redirect everything else to HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

echo "==> Writing Element Web vhost (${DOMAIN})..."
cat > "${SITES_DIR}/10-element.conf" <<EOF
# Element Web - ${DOMAIN}
# Served over HTTPS on internal port 8443, exposed via stream SNI on :443
server {
    listen 8443 ssl;
    listen [::]:8443 ssl;
    server_name ${DOMAIN};

    ssl_certificate     /etc/ssl/nginx/${DOMAIN}.crt;
    ssl_certificate_key /etc/ssl/nginx/${DOMAIN}.key;

    root /var/www/element;
    index index.html;

    # Security headers
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Content-Security-Policy "frame-src 'self'; frame-ancestors 'self'; object-src 'none'" always;

    location / {
        try_files \$uri \$uri/ /index.html;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    # Matrix well-known delegation
    location /.well-known/matrix/server {
        default_type application/json;
        add_header Access-Control-Allow-Origin *;
        return 200 '{"m.server": "${MATRIX_DOMAIN}:443"}';
    }

    location /.well-known/matrix/client {
        default_type application/json;
        add_header Access-Control-Allow-Origin *;
        return 200 '{"m.homeserver":{"base_url":"https://${MATRIX_DOMAIN}"},"m.identity_server":{"base_url":"https://vector.im"}}';
    }
}
EOF

echo "==> Writing Matrix Synapse vhost (${MATRIX_DOMAIN})..."
cat > "${SITES_DIR}/20-synapse.conf" <<EOF
# Matrix Synapse - ${MATRIX_DOMAIN}
server {
    listen 8443 ssl;
    listen [::]:8443 ssl;
    server_name ${MATRIX_DOMAIN};

    ssl_certificate     /etc/ssl/nginx/${MATRIX_DOMAIN}.crt;
    ssl_certificate_key /etc/ssl/nginx/${MATRIX_DOMAIN}.key;

    # Matrix federation / client API
    location / {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header X-Forwarded-For   \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host              \$host;
        proxy_http_version 1.1;

        # Large file uploads
        client_max_body_size 100m;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }

    # Health check
    location /health {
        proxy_pass http://127.0.0.1:9000/health;
        access_log off;
    }

    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header Access-Control-Allow-Origin "*" always;
    add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS" always;
    add_header Access-Control-Allow-Headers "X-Requested-With, Content-Type, Authorization" always;
}
EOF

echo "==> Writing Jitsi Meet vhost (${JITSI_DOMAIN})..."
cat > "${SITES_DIR}/30-jitsi.conf" <<EOF
# Jitsi Meet - ${JITSI_DOMAIN}
server {
    listen 8443 ssl;
    listen [::]:8443 ssl;
    server_name ${JITSI_DOMAIN};

    ssl_certificate     /etc/ssl/nginx/${JITSI_DOMAIN}.crt;
    ssl_certificate_key /etc/ssl/nginx/${JITSI_DOMAIN}.key;

    root /usr/share/jitsi-meet;
    index index.html;

    # Security headers
    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Frame-Options SAMEORIGIN always;

    # Jitsi Meet SPA
    location / {
        try_files \$uri \$uri/ @root_path;
    }

    location @root_path {
        rewrite ^/(.*)$ / break;
    }

    # BOSH (HTTP long-polling for XMPP)
    location = /http-bind {
        proxy_pass http://127.0.0.1:5280/http-bind;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header Host \$http_host;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
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

    # Config files served dynamically
    location ~ /config.js {
        alias /usr/share/jitsi-meet/config.js;
    }

    location ~ /external_api.js {
        alias /usr/share/jitsi-meet/libs/external_api.min.js;
    }

    # Static assets
    location ~ ^/(libs|css|static|images|fonts|lang|sounds|connection_optimization|.well-known)/ {
        add_header Cache-Control "max-age=3600";
    }
}
EOF

echo "==> Creating self-signed cert directories (pre-SSL stage)..."
mkdir -p /etc/ssl/nginx
for fqdn in "${DOMAIN}" "${MATRIX_DOMAIN}" "${JITSI_DOMAIN}"; do
  if [[ ! -f "/etc/ssl/nginx/${fqdn}.crt" ]]; then
    openssl req -x509 -nodes -newkey rsa:4096 -days 365 \
      -keyout "/etc/ssl/nginx/${fqdn}.key" \
      -out    "/etc/ssl/nginx/${fqdn}.crt" \
      -subj "/CN=${fqdn}/O=matrix-stack/C=US" \
      -addext "subjectAltName=DNS:${fqdn}" 2>/dev/null
    echo "   Created self-signed cert for ${fqdn}"
  fi
done

echo "==> Enabling sites..."
for f in 00-redirect 10-element 20-synapse 30-jitsi; do
  ln -sf "${SITES_DIR}/${f}.conf" "${SITES_EN}/${f}.conf"
done

echo "==> Testing Nginx configuration..."
nginx -t

echo "==> Reloading Nginx..."
systemctl enable nginx
systemctl reload nginx || systemctl start nginx

echo "Completed Stage 08 - Nginx"
