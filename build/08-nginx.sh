#!/bin/bash
# =============================================================================
# BUILD PHASE - Stage 08: Nginx installation and static config
# Domain-specific vhosts and SNI map written at setup time
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "==> [08] Ensuring Nginx and stream module are present..."
apt-get install -y nginx libnginx-mod-stream

echo "==> [08] Stopping Nginx (started at setup time)..."
systemctl stop nginx    2>/dev/null || true
systemctl disable nginx 2>/dev/null || true

echo "==> [08] Removing default site configs..."
rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-available/default

echo "==> [08] Pre-staging Nginx directory structure..."
mkdir -p /etc/nginx/conf.d
mkdir -p /etc/nginx/sites-available
mkdir -p /etc/nginx/sites-enabled
mkdir -p /etc/nginx/stream-conf.d
mkdir -p /etc/ssl/nginx
mkdir -p /var/www/html
mkdir -p /var/www/element

echo "==> [08] Writing base nginx.conf (static - no domain references)..."
cat > /etc/nginx/nginx.conf <<'NGINXEOF'
# nginx.conf - Matrix Stack
# Domain-specific config is in sites-enabled/ (written by setup.sh)
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log warn;

# Stream module: SNI-based TLS routing on port 443
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 2048;
    use epoll;
    multi_accept on;
}

# ── stream{} block: SNI pre-read, route raw TLS by hostname ──────────────
stream {
    log_format stream_log '$remote_addr [$time_local] $protocol '
                          '$status $bytes_sent $bytes_received '
                          '$session_time sni="$ssl_preread_server_name"';
    access_log /var/log/nginx/stream.log stream_log;

    # SNI -> upstream name mapping (written by setup.sh)
    map $ssl_preread_server_name $tls_upstream {
        default            https_terminator;
        include /etc/nginx/stream-sni.map;
    }

    # Internal HTTPS terminator (http{} block listens here)
    upstream https_terminator {
        server 127.0.0.1:8443;
    }

    server {
        listen 443;
        proxy_pass $tls_upstream;
        ssl_preread on;
        proxy_connect_timeout 10s;
        proxy_timeout 600s;
        proxy_buffer_size 16k;
    }
}

# ── http{} block: TLS-terminated reverse proxy ───────────────────────────
http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;
    client_max_body_size 100m;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # TLS - strong defaults
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;

    # Security headers (per-vhost can override)
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Gzip
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json
               application/javascript application/xml+rss
               application/atom+xml image/svg+xml;

    access_log /var/log/nginx/access.log combined;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
NGINXEOF

echo "==> [08] Writing placeholder SNI map (populated by setup.sh)..."
cat > /etc/nginx/stream-sni.map <<'EOF'
# SNI map - managed by setup.sh
# Format: hostname   upstream_name;
# Populated automatically - do not edit by hand
EOF

echo "==> Completed Stage 08 - Nginx pre-staged (vhosts written at setup time)"
