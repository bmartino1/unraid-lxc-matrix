#!/bin/bash
###############################################################################
# Configure Nginx — mirrors known-working baseline stream mux + vhosts
#
# External:
#   80/tcp    -> nginx
#   443/tcp   -> nginx stream mux
#   10000/udp -> nginx stream proxy to JVB (matches baseline)
###############################################################################
set -euo pipefail

echo "  Configuring Nginx..."

mkdir -p /etc/nginx/sites-available
mkdir -p /etc/nginx/sites-enabled
mkdir -p /etc/nginx/modules-enabled
mkdir -p /etc/nginx/conf.d
mkdir -p /etc/ssl/nginx
mkdir -p /var/log/nginx

rm -f /etc/nginx/sites-enabled/*

touch /var/log/nginx/access.log
touch /var/log/nginx/error.log
touch /var/log/nginx/stream.log
chown www-data:adm /var/log/nginx/access.log /var/log/nginx/error.log /var/log/nginx/stream.log 2>/dev/null || true

SSL_DIR="/etc/ssl/nginx"

for fqdn in "${DOMAIN}" "${MEET}"; do
  if [[ ! -f "${SSL_DIR}/${fqdn}.crt" || ! -f "${SSL_DIR}/${fqdn}.key" ]]; then
    openssl req -x509 -nodes -newkey rsa:4096 -days 3650 \
      -keyout "${SSL_DIR}/${fqdn}.key" \
      -out "${SSL_DIR}/${fqdn}.crt" \
      -subj "/CN=${fqdn}" \
      >/dev/null 2>&1
    chmod 600 "${SSL_DIR}/${fqdn}.key"
  fi
done

CERT="${SSL_DIR}/${DOMAIN}.crt"
KEY="${SSL_DIR}/${DOMAIN}.key"

LE_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
LE_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

if [[ -f "$LE_CERT" && -f "$LE_KEY" ]]; then
  CERT="$LE_CERT"
  KEY="$LE_KEY"
fi

if [[ -f /usr/share/nginx/modules-available/mod-stream.conf ]]; then
  ln -sf /usr/share/nginx/modules-available/mod-stream.conf \
    /etc/nginx/modules-enabled/50-mod-stream.conf 2>/dev/null || true
elif [[ -f /usr/lib/nginx/modules/ngx_stream_module.so ]]; then
  cat > /etc/nginx/modules-enabled/50-mod-stream.conf <<'EOF'
load_module /usr/lib/nginx/modules/ngx_stream_module.so;
EOF
fi

cat > /etc/nginx/nginx.conf <<NGEOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;
include /etc/nginx/modules-enabled/*.conf;

events { worker_connections 1024; }

http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;
    server_tokens off;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    access_log /var/log/nginx/access.log;
    gzip on;
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}

include /etc/nginx/stream.conf;
NGEOF

cat > /etc/nginx/stream.conf <<STEOF
stream {

    log_format stream_basic '\$remote_addr [\$time_local] '
                            '\$protocol \$status \$bytes_sent \$bytes_received '
                            '\$session_time "\$ssl_preread_server_name"';

    access_log /var/log/nginx/stream.log stream_basic;

    map \$ssl_preread_server_name \$stream_backend {
        ${TURN}  turn_backend;
        default  https_backend;
    }

    upstream https_backend {
        server 127.0.0.1:60443;
    }

    upstream turn_backend {
        server 127.0.0.1:5349;
    }

    server {
        listen 443;
        proxy_pass \$stream_backend;
        ssl_preread on;
    }

    # JVB media over UDP — mirrored from known-working baseline
#    server {
#        listen 10000 udp;
#        proxy_pass ${LXC_IP}:10000;
#    }
}
STEOF

cat > /etc/nginx/sites-available/matrix <<MEOF
# /etc/nginx/sites-enabled/matrix
server {
    listen 127.0.0.1:60443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     ${CERT};
    ssl_certificate_key ${KEY};

    location /_matrix {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location /_synapse/client {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location / {
        root /var/www/element;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }
}

server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}
MEOF

if [[ -d "/usr/share/element-web" ]]; then
  sed -i "s|root /var/www/element|root /usr/share/element-web|" /etc/nginx/sites-available/matrix
fi

JITSI_ROOT="/usr/share/jitsi-meet"
JITSI_CONFIG="/etc/jitsi/meet/${MEET}-config.js"

cat > /etc/nginx/sites-available/meet <<JTEOF
# /etc/nginx/sites-enabled/meet
upstream prosody {
    zone upstreams 64K;
    server 127.0.0.1:5280;
    keepalive 2;
}
upstream jvb1 {
    zone upstreams 64K;
    server 127.0.0.1:9090;
    keepalive 2;
}
map \$arg_vnode \$prosody_node {
    default prosody;
}
map \$http_referer \$allowed_referer {
    default                     0;
    "~*${DOMAIN//./\\.}"        1;
}
server {
    listen 127.0.0.1:60443 ssl http2;
    server_name ${MEET};
    ssl_certificate     ${CERT};
    ssl_certificate_key ${KEY};
    set \$prefix "";
    set \$custom_index "";
    set \$config_js_location ${JITSI_CONFIG};
    root ${JITSI_ROOT};
    ssi on;
    ssi_types application/x-javascript application/javascript;
    index index.html index.htm;
    error_page 404 /static/404.html;
    gzip on;
    gzip_types text/plain text/css application/javascript application/json image/x-icon application/octet-stream application/wasm;
    gzip_vary on;
    gzip_proxied no-cache no-store private expired auth;
    gzip_min_length 512;

    location = / {
        if (\$allowed_referer = 0) { return 403; }
        try_files \$uri @root_path;
    }

    location ~ ^/[A-Za-z0-9]+\$ {
        if (\$allowed_referer = 0) { return 403; }
        try_files \$uri @root_path;
    }

    location = /config.js {
        alias \$config_js_location;
    }

    location = /external_api.js {
        alias ${JITSI_ROOT}/libs/external_api.min.js;
    }

    location = /_api/room-info {
        proxy_pass http://prosody/room-info?prefix=\$prefix&\$args;
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header Host \$http_host;
    }

    location ~ ^/(libs|css|static|images|fonts|lang|sounds|.well-known)/(.*)\$ {
        add_header 'Access-Control-Allow-Origin' '*';
        alias ${JITSI_ROOT}/\$1/\$2;
        if (\$arg_v) {
            expires 1y;
        }
    }

    location = /http-bind {
        proxy_pass http://\$prosody_node/http-bind?prefix=\$prefix&\$args;
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header Host \$http_host;
        proxy_set_header Connection "";
    }

    location = /xmpp-websocket {
        proxy_pass http://\$prosody_node/xmpp-websocket?prefix=\$prefix&\$args;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
        tcp_nodelay on;
    }

    location ~ ^/colibri-ws/default-id/(.*) {
        proxy_pass http://jvb1/colibri-ws/default-id/\$1\$is_args\$args;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        tcp_nodelay on;
    }

    location ~ ^/conference-request/v1(\/.*)?\$ {
        proxy_pass http://127.0.0.1:8888/conference-request/v1\$1;
        add_header "Cache-Control" "no-cache, no-store";
        add_header 'Access-Control-Allow-Origin' '*';
    }

    location = /_unlock {
        add_header 'Access-Control-Allow-Origin' '*';
        add_header "Cache-Control" "no-cache, no-store";
    }

    location @root_path {
        rewrite ^/(.*)\$ /\$custom_index break;
    }

    location ~ ^/([^/?&:'"]+)/xmpp-websocket {
        set \$subdomain "\$1.";
        set \$subdir "\$1/";
        set \$prefix "\$1";
        rewrite ^/(.*)\$ /xmpp-websocket;
    }

    location ~ ^/([^/?&:'"]+)/http-bind {
        set \$subdomain "\$1.";
        set \$subdir "\$1/";
        set \$prefix "\$1";
        rewrite ^/(.*)\$ /http-bind;
    }

    location ~ ^/([^/?&:'"]+)/(.*)\$ {
        set \$subdomain "\$1.";
        set \$subdir "\$1/";
        rewrite ^/([^/?&:'"]+)/(.*)\$ /\$2;
    }
}
server {
    listen 80;
    server_name ${MEET};
    return 301 https://\$host\$request_uri;
}
JTEOF

ln -sf /etc/nginx/sites-available/matrix /etc/nginx/sites-enabled/matrix
ln -sf /etc/nginx/sites-available/meet   /etc/nginx/sites-enabled/meet

nginx -t || { echo "ERROR: nginx config test failed"; nginx -t; exit 1; }

systemctl enable nginx
systemctl restart nginx

echo "  Restarting Jitsi services (need nginx for websockets)..."
systemctl restart jicofo 2>/dev/null || true
systemctl restart jitsi-videobridge2 2>/dev/null || true

echo "  Nginx configured with stream mux."
