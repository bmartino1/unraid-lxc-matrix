#!/bin/bash
###############################################################################
# Configure Nginx — matches PVE stream mux + vhost architecture
#
# Stream block muxes port 443:
#   turn.DOMAIN → coturn :5349 (TLS passthrough)
#   everything else → internal :60443 (nginx http termination)
#
# HTTP block on :60443:
#   DOMAIN → Element Web + Synapse (path routing)
#   meet.DOMAIN → Jitsi Meet (referer-restricted)
###############################################################################
set -euo pipefail
echo "  Configuring Nginx..."

mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/ssl/nginx
rm -f /etc/nginx/sites-enabled/*

# ── Self-signed placeholder certs ──────────────────────────────────────────
SSL_DIR="/etc/ssl/nginx"
for fqdn in "${DOMAIN}" "${MEET}"; do
  if [[ ! -f "${SSL_DIR}/${fqdn}.crt" ]]; then
    openssl req -x509 -nodes -newkey rsa:4096 -days 3650 \
      -keyout "${SSL_DIR}/${fqdn}.key" \
      -out "${SSL_DIR}/${fqdn}.crt" \
      -subj "/CN=${fqdn}" 2>/dev/null
    chmod 600 "${SSL_DIR}/${fqdn}.key"
  fi
done

# Use LE certs if available, else self-signed
CERT="${SSL_DIR}/${DOMAIN}.crt"
KEY="${SSL_DIR}/${DOMAIN}.key"
LE_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
LE_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
[[ -f "$LE_CERT" && -f "$LE_KEY" ]] && CERT="$LE_CERT" && KEY="$LE_KEY"

# ── nginx.conf with stream block ───────────────────────────────────────────
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

# Stream mux: SNI-route port 443
# turn.DOMAIN → coturn TLS :5349 (passthrough)
# everything else → nginx http :60443 (terminate)
include /etc/nginx/stream.conf;
NGEOF

# ── stream.conf ────────────────────────────────────────────────────────────
cat > /etc/nginx/stream.conf <<STEOF
stream {
    access_log /var/log/nginx/stream.log;

    map \$ssl_preread_server_name \$stream_backend {
        ${TURN} turn_backend;
        default https_backend;
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

    # Note: JVB binds directly to 10000/udp for media.
    # If you forward port 10000/udp to this LXC, JVB handles it natively.
    # No nginx stream proxy needed (and it would conflict with JVB).
}
STEOF

# ── Main vhost: DOMAIN → Element Web + Synapse ────────────────────────────
cat > /etc/nginx/sites-available/matrix <<MEOF
server {
    listen 127.0.0.1:60443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     ${CERT};
    ssl_certificate_key ${KEY};

    # Matrix Synapse
    location /_matrix {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Real-IP \$remote_addr;
        client_max_body_size 100m;
    }

    location /_synapse/client {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    # Element Web (catch-all — must be LAST)
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

# Use /usr/share/element-web if Element is installed via apt
if [[ -d "/usr/share/element-web" ]]; then
  sed -i "s|root /var/www/element|root /usr/share/element-web|" /etc/nginx/sites-available/matrix
fi

# ── Jitsi vhost: meet.DOMAIN ──────────────────────────────────────────────
JITSI_ROOT="/usr/share/jitsi-meet"
JITSI_CONFIG="/etc/jitsi/meet/${MEET}-config.js"

cat > /etc/nginx/sites-available/meet <<JTEOF
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
    default              0;
    "~*${DOMAIN//./\\.}" 1;
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
    index index.html;

    gzip on;
    gzip_types text/plain text/css application/javascript application/json image/x-icon application/octet-stream application/wasm;
    gzip_vary on;

    location = / {
        if (\$allowed_referer = 0) { return 403; }
        try_files \$uri @root_path;
    }

    location ~ ^/[A-Za-z0-9]+\$ {
        if (\$allowed_referer = 0) { return 403; }
        try_files \$uri @root_path;
    }

    location = /config.js { alias \$config_js_location; }
    location = /external_api.js { alias ${JITSI_ROOT}/libs/external_api.min.js; }

    location ~ ^/(libs|css|static|images|fonts|lang|sounds|.well-known)/(.*)\$ {
        add_header 'Access-Control-Allow-Origin' '*';
        alias ${JITSI_ROOT}/\$1/\$2;
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

# Enable sites
ln -sf /etc/nginx/sites-available/matrix /etc/nginx/sites-enabled/matrix
ln -sf /etc/nginx/sites-available/meet   /etc/nginx/sites-enabled/meet

# Ensure stream module is loaded
mkdir -p /etc/nginx/modules-enabled
if [[ -f /usr/share/nginx/modules-available/mod-stream.conf ]]; then
  ln -sf /usr/share/nginx/modules-available/mod-stream.conf \
    /etc/nginx/modules-enabled/50-mod-stream.conf 2>/dev/null || true
elif [[ -f /usr/lib/nginx/modules/ngx_stream_module.so ]]; then
  echo "load_module /usr/lib/nginx/modules/ngx_stream_module.so;" \
    > /etc/nginx/modules-enabled/50-mod-stream.conf
fi

nginx -t || { echo "ERROR: nginx config test failed"; nginx -t; exit 1; }

systemctl enable nginx
systemctl restart nginx

# Now that nginx is up, restart Jitsi services that depend on it
echo "  Restarting Jitsi services (need nginx for websockets)..."
systemctl restart jicofo 2>/dev/null || true
systemctl restart jitsi-videobridge2 2>/dev/null || true

echo "  Nginx configured with stream mux."
