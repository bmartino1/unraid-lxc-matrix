#!/bin/bash
# =============================================================================
# patch.sh — Matrix Synapse + Element Web + Jitsi + coturn Configurator
# =============================================================================
# Architecture:
#   https://DOMAIN         → Element Web + Synapse
#   https://meet.DOMAIN    → Jitsi Meet
#   turn.DOMAIN:443/5349   → coturn TURNS
#   turn.DOMAIN:3478       → coturn TURN
#
# DNS required:
#   DOMAIN, meet.DOMAIN, turn.DOMAIN
# Update script puling data from lxc matrix.env to secure nginx RP of subdomain meet to secure public jitsu access
# =============================================================================

set -euo pipefail

#!/bin/bash
set -euo pipefail

echo "[*] Starting nginx patch..."

ENV_FILE="/root/matrix.env"
[[ -f "$ENV_FILE" ]] || { echo "[ERROR] Missing $ENV_FILE"; exit 1; }

set -a
. "$ENV_FILE"
set +a

: "${DOMAIN:?Missing DOMAIN in /root/matrix.env}"
: "${MEET:?Missing MEET in /root/matrix.env}"
: "${TURN:?Missing TURN in /root/matrix.env}"

NGINX_DIR="/etc/nginx"
BACKUP_ROOT="/root/nginx-patch-attempt"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${TS}"

MATRIX_FILE="${NGINX_DIR}/sites-enabled/matrix"
MEET_FILE="${NGINX_DIR}/sites-enabled/meet"
NGINX_CONF="${NGINX_DIR}/nginx.conf"
STREAM_CONF="${NGINX_DIR}/stream.conf"

SSL_DIR="/etc/ssl/nginx"
LE_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
LE_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
SELF_CERT="${SSL_DIR}/${DOMAIN}.crt"
SELF_KEY="${SSL_DIR}/${DOMAIN}.key"

ELEMENT_ROOT="/usr/share/element-web"
JITSI_ROOT="/usr/share/jitsi-meet"
JITSI_CONFIG="/etc/jitsi/meet/${MEET}-config.js"

DOMAIN_ESCAPED="$(printf '%s' "$DOMAIN" | sed 's/[.[\*^$()+?{|]/\\&/g')"

mkdir -p "$BACKUP_DIR"
mkdir -p "${NGINX_DIR}/sites-enabled"
mkdir -p "${NGINX_DIR}/modules-enabled"
mkdir -p "${NGINX_DIR}/conf.d"
mkdir -p /var/log/nginx
mkdir -p "$SSL_DIR"

echo "[*] Backup directory: $BACKUP_DIR"

backup_file() {
    local src="$1"
    local name="$2"
    if [[ -e "$src" || -L "$src" ]]; then
        cp -a "$src" "${BACKUP_DIR}/${name}"
        echo "    backed up: $src"
    else
        echo "    missing, skipped backup: $src"
    fi
}

backup_file "$NGINX_CONF" "nginx.conf"
backup_file "$STREAM_CONF" "stream.conf"
backup_file "$MATRIX_FILE" "matrix"
backup_file "$MEET_FILE" "meet"

echo "[*] Saving patch metadata..."
cat > "${BACKUP_DIR}/PATCH-INFO.txt" <<EOF
Timestamp: ${TS}
Domain: ${DOMAIN}
Meet: ${MEET}
Turn: ${TURN}
Env file: ${ENV_FILE}
Host: $(hostname)
EOF

touch /var/log/nginx/access.log /var/log/nginx/error.log /var/log/nginx/stream.log
chown www-data:adm /var/log/nginx/access.log /var/log/nginx/error.log /var/log/nginx/stream.log 2>/dev/null || true

CERT="$SELF_CERT"
KEY="$SELF_KEY"

if [[ -f "$LE_CERT" && -f "$LE_KEY" ]]; then
    CERT="$LE_CERT"
    KEY="$LE_KEY"
    echo "[*] Using Let's Encrypt certificate for ${DOMAIN}"
else
    echo "[*] Let's Encrypt cert not found, checking self-signed fallback..."
    if [[ ! -f "$SELF_CERT" || ! -f "$SELF_KEY" ]]; then
        echo "[*] Generating self-signed certificate for ${DOMAIN}"
        openssl req -x509 -nodes -newkey rsa:4096 -days 3650 \
            -keyout "$SELF_KEY" \
            -out "$SELF_CERT" \
            -subj "/CN=${DOMAIN}" \
            >/dev/null 2>&1
        chmod 600 "$SELF_KEY"
    fi
fi

echo "[*] Ensuring nginx stream module is available..."
if [[ -f /usr/share/nginx/modules-available/mod-stream.conf ]]; then
    ln -sf /usr/share/nginx/modules-available/mod-stream.conf \
        /etc/nginx/modules-enabled/50-mod-stream.conf || true
elif [[ -f /usr/lib/nginx/modules/ngx_stream_module.so ]]; then
    cat > /etc/nginx/modules-enabled/50-mod-stream.conf <<'EOF'
load_module /usr/lib/nginx/modules/ngx_stream_module.so;
EOF
fi

echo "[*] Writing ${NGINX_CONF} ..."
cat > "$NGINX_CONF" <<'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
}

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
EOF

echo "[*] Writing ${STREAM_CONF} ..."
cat > "$STREAM_CONF" <<EOF
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
}
EOF

echo "[*] Writing ${MATRIX_FILE} ..."
cat > "$MATRIX_FILE" <<EOF
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
        root ${ELEMENT_ROOT};
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }
}

server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}
EOF

echo "[*] Writing ${MEET_FILE} ..."
cat > "$MEET_FILE" <<EOF
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
    default 0;
    "~*^https://${DOMAIN_ESCAPED}(/|$)" 1;
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

    location ~ ^/[A-Za-z0-9]+$ {
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

    location ~ ^/(libs|css|static|images|fonts|lang|sounds|\.well-known)/(.*)$ {
        add_header Access-Control-Allow-Origin *;
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

    location ~ ^/colibri-ws/default-id/(.*)$ {
        proxy_pass http://jvb1/colibri-ws/default-id/\$1\$is_args\$args;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        tcp_nodelay on;
    }

    location ~ ^/conference-request/v1(\/.*)?$ {
        proxy_pass http://127.0.0.1:8888/conference-request/v1\$1;
        add_header Cache-Control "no-cache, no-store";
        add_header Access-Control-Allow-Origin *;
    }

    location = /_unlock {
        add_header Access-Control-Allow-Origin *;
        add_header Cache-Control "no-cache, no-store";
    }

    location @root_path {
        rewrite ^/(.*)$ /\$custom_index break;
    }

    location ~ ^/([^/?&:'"]+)/xmpp-websocket {
        set \$subdomain "\$1.";
        set \$subdir "\$1/";
        set \$prefix "\$1";
        rewrite ^/(.*)$ /xmpp-websocket;
    }

    location ~ ^/([^/?&:'"]+)/http-bind {
        set \$subdomain "\$1.";
        set \$subdir "\$1/";
        set \$prefix "\$1";
        rewrite ^/(.*)$ /http-bind;
    }

    location ~ ^/([^/?&:'"]+)/(.*)$ {
        set \$subdomain "\$1.";
        set \$subdir "\$1/";
        rewrite ^/([^/?&:'"]+)/(.*)$ /\$2 break;
    }
}

server {
    listen 80;
    server_name ${MEET};
    return 301 https://\$host\$request_uri;
}
EOF

echo "[*] Testing nginx config..."
if ! nginx -t; then
    echo
    echo "[ERROR] nginx -t failed."
    echo "[*] Backups are in: ${BACKUP_DIR}"
    echo "[*] Restore example:"
    echo "    cp -a ${BACKUP_DIR}/nginx.conf ${NGINX_CONF}"
    echo "    cp -a ${BACKUP_DIR}/stream.conf ${STREAM_CONF}"
    echo "    cp -a ${BACKUP_DIR}/matrix ${MATRIX_FILE}"
    echo "    cp -a ${BACKUP_DIR}/meet ${MEET_FILE}"
    exit 1
fi

echo "[*] Reloading nginx..."
systemctl reload nginx

#small fix to nginx pthing matters:
sed -i 's|root /usr/share/element-web;|root /var/www/element;|' /etc/nginx/sites-enabled/matrix
nginx -t && systemctl reload nginx

echo
echo "[OK] Patch applied successfully."
echo "[*] Backup saved at: ${BACKUP_DIR}"
echo "[*] Files updated:"
echo "    ${NGINX_CONF}"
echo "    ${STREAM_CONF}"
echo "    ${MATRIX_FILE}"
echo "    ${MEET_FILE}"
echo
echo "[*] This patch does NOT modify port 10000/udp handling."
