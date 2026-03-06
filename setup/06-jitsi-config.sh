#!/bin/bash
###############################################################################
# 05-jitsi-config.sh
# Configure Jitsi Meet from matrix.env as the single source of truth.
# Anonymous web join + authenticated focus/jvb on auth.<meet>.
###############################################################################
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "  Configuring Jitsi Meet..."

ENV_FILE="/root/matrix.env"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE"; exit 1; }

set -a
. "$ENV_FILE"
set +a

: "${MEET:?Missing MEET in matrix.env}"
: "${TURN:?Missing TURN in matrix.env}"
: "${TURN_SECRET:?Missing TURN_SECRET in matrix.env}"
: "${JICOFO_PASS:?Missing JICOFO_PASS in matrix.env}"
: "${JVB_PASS:?Missing JVB_PASS in matrix.env}"
: "${LXC_IP:?Missing LXC_IP in matrix.env}"

EXTERNAL_IP="${EXTERNAL_IP:-$LXC_IP}"

###############################################################################
# Packages / helpers
###############################################################################

apt-get update
apt-get install -y \
  prosody \
  lua-inspect \
  lua-basexx \
  lua-cjson \
  lua-sec \
  lua-socket \
  openssl \
  nginx

ln -sf /usr/share/lua/5.3/inspect.lua /usr/lib/prosody/inspect.lua 2>/dev/null || true

grep -qE "[[:space:]]${MEET}([[:space:]]|\$)" /etc/hosts || \
  echo "127.0.0.1 ${MEET}" >> /etc/hosts

mkdir -p /etc/prosody/conf.avail
mkdir -p /etc/prosody/conf.d
mkdir -p /etc/prosody/certs
mkdir -p /etc/jitsi/jicofo
mkdir -p /etc/jitsi/videobridge
mkdir -p /etc/jitsi/meet
mkdir -p /var/log/jitsi

###############################################################################
# Helper: make a self-signed cert with SAN
###############################################################################

make_cert() {
  local vhost="$1"
  local crt="/etc/prosody/certs/${vhost}.crt"
  local key="/etc/prosody/certs/${vhost}.key"

  openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 825 \
    -keyout "$key" \
    -out "$crt" \
    -subj "/CN=${vhost}" \
    -addext "subjectAltName=DNS:${vhost}" \
    >/dev/null 2>&1

  chown prosody:prosody "$crt" "$key" 2>/dev/null || true
  chmod 644 "$crt" 2>/dev/null || true
  chmod 640 "$key" 2>/dev/null || true
}

###############################################################################
# Internal Prosody certs
#
# We explicitly support a self-signed auth.<MEET> because public LE/SAN certs
# may not cover it. We also generate a local cert for ${MEET} for Prosody c2s.
###############################################################################

make_cert "${MEET}"
make_cert "auth.${MEET}"

# Reuse the main MEET cert for component hosts that only need a cert loaded.
for vhost in \
  "conference.${MEET}" \
  "breakout.${MEET}" \
  "focus.${MEET}" \
  "speakerstats.${MEET}" \
  "endconference.${MEET}" \
  "avmoderation.${MEET}" \
  "lobby.${MEET}" \
  "filesharing.${MEET}" \
  "metadata.${MEET}" \
  "polls.${MEET}" \
  "recorder.${MEET}"
do
  ln -sf "/etc/prosody/certs/${MEET}.crt" "/etc/prosody/certs/${vhost}.crt"
  ln -sf "/etc/prosody/certs/${MEET}.key" "/etc/prosody/certs/${vhost}.key"
done

ln -sf "/etc/prosody/certs/auth.${MEET}.crt" "/etc/prosody/certs/internal.auth.${MEET}.crt"
ln -sf "/etc/prosody/certs/auth.${MEET}.key" "/etc/prosody/certs/internal.auth.${MEET}.key"

###############################################################################
# Trust auth.<MEET> cert system-wide and for Java
###############################################################################

#cp -f "/etc/prosody/certs/auth.${MEET}.crt" "/usr/local/share/ca-certificates/auth.${MEET}.crt"
#Was delted...

AUTH_CRT="/etc/prosody/certs/auth.${MEET}.crt"
CA_CRT="/usr/local/share/ca-certificates/auth.${MEET}.crt"

if [[ "$(readlink -f "$AUTH_CRT")" != "$(readlink -f "$CA_CRT" 2>/dev/null || echo "__missing__")" ]]; then
  install -m 0644 "$AUTH_CRT" "$CA_CRT"
fi

update-ca-certificates >/dev/null 2>&1 || true

keytool -delete \
  -alias "auth-${MEET//./-}" \
  -keystore /etc/ssl/certs/java/cacerts \
  -storepass changeit >/dev/null 2>&1 || true

keytool -importcert -noprompt \
  -alias "auth-${MEET//./-}" \
  -file "$AUTH_CRT" \
  -keystore /etc/ssl/certs/java/cacerts \
  -storepass changeit >/dev/null 2>&1 || true

###############################################################################
# Prosody config
###############################################################################

PROSODY_CFG="/etc/prosody/conf.avail/${MEET}.cfg.lua"

cat > "${PROSODY_CFG}" <<PCFG
component_admins_as_room_owners = true

plugin_paths = { "/usr/share/jitsi-meet/prosody-plugins/" }

muc_mapper_domain_base = "${MEET}";

external_service_secret = "${TURN_SECRET}";
external_services = {
  { type = "turns", host = "${TURN}", port = 443, transport = "tcp", secret = true, ttl = 86400, algorithm = "turn" }
};

consider_bosh_secure = true;
consider_websocket_secure = true;

ssl = {
    protocol = "tlsv1_2+";
    ciphers = "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
}

unlimited_jids = {
    "focus@auth.${MEET}",
    "jvb@auth.${MEET}"
}

smacks_max_unacked_stanzas = 5;
smacks_hibernation_time = 60;
smacks_max_old_sessions = 1;

VirtualHost "${MEET}"
    authentication = "jitsi-anonymous"

    ssl = {
        key = "/etc/prosody/certs/${MEET}.key";
        certificate = "/etc/prosody/certs/${MEET}.crt";
    }

    modules_enabled = {
        "bosh";
        "websocket";
        "smacks";
        "ping";
        "external_services";
        "features_identity";
        "conference_duration";
        "muc_lobby_rooms";
        "muc_breakout_rooms";
    }

    c2s_require_encryption = false
    lobby_muc = "lobby.${MEET}"
    breakout_rooms_muc = "breakout.${MEET}"
    main_muc = "conference.${MEET}"

Component "conference.${MEET}" "muc"
    restrict_room_creation = true
    storage = "memory"
    modules_enabled = {
        "muc_hide_all";
        "muc_meeting_id";
        "muc_domain_mapper";
        "muc_rate_limit";
        "muc_password_whitelist";
    }
    admins = { "focus@auth.${MEET}" }
    muc_password_whitelist = {
        "focus@auth.${MEET}";
    }
    muc_room_locking = false
    muc_room_default_public_jids = true

Component "breakout.${MEET}" "muc"
    restrict_room_creation = true
    storage = "memory"
    modules_enabled = {
        "muc_hide_all";
        "muc_meeting_id";
        "muc_domain_mapper";
        "muc_rate_limit";
    }
    admins = { "focus@auth.${MEET}" }
    muc_room_locking = false
    muc_room_default_public_jids = true

Component "internal.auth.${MEET}" "muc"
    storage = "memory"
    modules_enabled = {
        "muc_hide_all";
        "ping";
    }
    admins = { "focus@auth.${MEET}", "jvb@auth.${MEET}" }
    muc_room_locking = false
    muc_room_default_public_jids = true

VirtualHost "auth.${MEET}"
    ssl = {
        key = "/etc/prosody/certs/auth.${MEET}.key";
        certificate = "/etc/prosody/certs/auth.${MEET}.crt";
    }
    modules_enabled = {
        "limits_exception";
        "smacks";
    }
    authentication = "internal_hashed"
    smacks_hibernation_time = 15;

VirtualHost "recorder.${MEET}"
    modules_enabled = {
        "smacks";
    }
    authentication = "internal_hashed"
    smacks_max_old_sessions = 2000;

Component "focus.${MEET}" "client_proxy"
    target_address = "focus@auth.${MEET}"

Component "speakerstats.${MEET}" "speakerstats_component"
    muc_component = "conference.${MEET}"

Component "endconference.${MEET}" "end_conference"
    muc_component = "conference.${MEET}"

Component "avmoderation.${MEET}" "av_moderation_component"
    muc_component = "conference.${MEET}"

Component "lobby.${MEET}" "muc"
    storage = "memory"
    restrict_room_creation = true
    muc_room_locking = false
    muc_room_default_public_jids = true
    modules_enabled = {
        "muc_hide_all";
        "muc_rate_limit";
    }

Component "filesharing.${MEET}" "filesharing_component"
    muc_component = "conference.${MEET}"

Component "metadata.${MEET}" "room_metadata_component"
    muc_component = "conference.${MEET}"
    breakout_rooms_component = "breakout.${MEET}"

Component "polls.${MEET}" "polls_component"
PCFG

ln -sf "${PROSODY_CFG}" "/etc/prosody/conf.d/${MEET}.cfg.lua"

###############################################################################
# Prosody validation
###############################################################################

PROSODY_CHECK_OUTPUT="$(prosodyctl check config 2>&1 || true)"
echo "$PROSODY_CHECK_OUTPUT"

if echo "$PROSODY_CHECK_OUTPUT" | grep -qiE 'Error:|not found:|unexpected symbol|expected|failed'; then
  echo "  Prosody config invalid — should aborting. Continue Anyways..."
#  exit 1
fi

###############################################################################
# Register service users
###############################################################################

systemctl enable prosody
systemctl restart prosody
sleep 3

prosodyctl register focus "auth.${MEET}" "${JICOFO_PASS}" 2>/dev/null || true
prosodyctl register jvb   "auth.${MEET}" "${JVB_PASS}"    2>/dev/null || true

###############################################################################
# Jicofo config
###############################################################################

cat > /etc/jitsi/jicofo/jicofo.conf <<JCEOF
jicofo {
  xmpp: {
    client: {
      client-proxy: "focus.${MEET}"
      xmpp-domain: "${MEET}"
      domain: "auth.${MEET}"
      username: "focus"
      password: "${JICOFO_PASS}"
      hostname: "localhost"
      port: 5222
    }
    trusted-domains: [ "recorder.${MEET}" ]
  }
  bridge: {
    brewery-jid: "jvbbrewery@internal.auth.${MEET}"
  }
}
JCEOF

cat > /etc/jitsi/jicofo/config <<'JCSEOF'
JAVA_SYS_PROPS="-Dnet.java.sip.communicator.SC_HOME_DIR_LOCATION=/etc/jitsi -Dnet.java.sip.communicator.SC_HOME_DIR_NAME=jicofo -Dnet.java.sip.communicator.SC_LOG_DIR_LOCATION=/var/log/jitsi -Djava.util.logging.config.file=/etc/jitsi/jicofo/logging.properties"
JCSEOF

###############################################################################
# JVB config
###############################################################################

cat > /etc/jitsi/videobridge/jvb.conf <<JVEOF
videobridge {
  http-servers {
    public {
      port = 9090
    }
    private {
      port = 127.0.0.1:8080
    }
  }

  websockets {
    enabled = true
    domain = "${MEET}:443"
    tls = true
  }

  apis {
    xmpp-client {
      configs {
        shard {
          hostname = "localhost"
          port = 5222
          domain = "auth.${MEET}"
          username = "jvb"
          password = "${JVB_PASS}"
          muc_jids = "jvbbrewery@internal.auth.${MEET}"
          muc_nickname = "jvb-1"
          disable-certificate-verification = false
        }
      }
    }
  }
}

ice4j {
  harvest {
    mapping {
      stun {
        enabled = false
        addresses = []
      }
      aws {
        enabled = false
      }
      static-mappings = [
        {
          local-address = "${LXC_IP}"
          public-address = "${EXTERNAL_IP}"
          name = "main"
        }
      ]
    }
  }
}
JVEOF

cat > /etc/jitsi/videobridge/config <<JVSEOF
JAVA_SYS_PROPS="-Dconfig.file=/etc/jitsi/videobridge/jvb.conf -Dnet.java.sip.communicator.SC_HOME_DIR_LOCATION=/etc/jitsi -Dnet.java.sip.communicator.SC_HOME_DIR_NAME=videobridge -Dnet.java.sip.communicator.SC_LOG_DIR_LOCATION=/var/log/jitsi -Djava.util.logging.config.file=/etc/jitsi/videobridge/logging.properties"
JVSEOF

mkdir -p /var/log/jitsi
touch /var/log/jitsi/jicofo.log /var/log/jitsi/jvb.log
chown jicofo:jitsi /var/log/jitsi/jicofo.log 2>/dev/null || true
chown jvb:jitsi    /var/log/jitsi/jvb.log    2>/dev/null || true

###############################################################################
# Web config for anonymous join
###############################################################################

MEET_CFG="/etc/jitsi/meet/${MEET}-config.js"

cat > "${MEET_CFG}" <<MCEOF
var subdir = '';
var subdomain = '';
if (location.pathname.indexOf('/') > 1) {
    subdir = location.pathname.substring(1, location.pathname.indexOf('/', 1) + 1);
    subdomain = subdir;
}

var config = {
    hosts: {
        domain: '${MEET}',
        muc: 'conference.' + subdomain + '${MEET}'
    },

    bosh: 'https://${MEET}/' + subdir + 'http-bind',
    websocket: 'wss://${MEET}/' + subdir + 'xmpp-websocket',

    clientNode: 'http://jitsi.org/jitsimeet',
    focusUserJid: undefined,

    testing: {
        p2pTestMode: false
    },

    p2p: {
        enabled: true,
        stunServers: [
            { urls: 'stun:${TURN}:3478' }
        ]
    }
};
MCEOF

chmod 644 "${MEET_CFG}"

###############################################################################
# Nginx meet site (internal-only listener behind stream mux)
###############################################################################

cat > /etc/nginx/sites-available/meet <<NGEOF
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
    "~*${MEET//./\\.}" 1;
}

server {
    listen 127.0.0.1:60443 ssl http2;
    server_name ${MEET};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    set \$prefix "";
    set \$custom_index "";
    set \$config_js_location /etc/jitsi/meet/${MEET}-config.js;

    root /usr/share/jitsi-meet;
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
        alias /usr/share/jitsi-meet/libs/external_api.min.js;
    }

    location = /_api/room-info {
        proxy_pass http://prosody/room-info?prefix=\$prefix&\$args;
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header Host \$http_host;
    }

    location ~ ^/(libs|css|static|images|fonts|lang|sounds|.well-known)/(.*)$ {
        add_header Access-Control-Allow-Origin "*";
        alias /usr/share/jitsi-meet/\$1/\$2;
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

    location ~ ^/conference-request/v1(\/.*)?$ {
        proxy_pass http://127.0.0.1:8888/conference-request/v1\$1;
        add_header Cache-Control "no-cache, no-store";
        add_header Access-Control-Allow-Origin "*";
    }

    location = /_unlock {
        add_header Access-Control-Allow-Origin "*";
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
        rewrite ^/([^/?&:'"]+)/(.*)$ /\$2;
    }
}

server {
    listen 80;
    server_name ${MEET};
    return 301 https://\$host\$request_uri;
}
NGEOF

ln -sf /etc/nginx/sites-available/meet /etc/nginx/sites-enabled/meet

###############################################################################
# Start services cleanly in order
###############################################################################

systemctl daemon-reload
systemctl enable prosody jicofo jitsi-videobridge2

systemctl stop prosody jicofo jitsi-videobridge2 2>/dev/null || true
pkill -9 -f '/usr/share/jicofo/' || true
pkill -9 -f '/usr/share/jitsi-videobridge/' || true
pkill -9 -f 'org.jitsi.jicofo' || true
pkill -9 -f 'org.jitsi.videobridge' || true
sleep 2

#Nginx not set yet...
#nginx -t
#systemctl restart nginx

systemctl restart prosody
sleep 5

systemctl restart jicofo
sleep 5

systemctl restart jitsi-videobridge2
sleep 5

echo "  Jitsi Meet configured."

echo
echo "  Quick checks:"
echo "    systemctl --no-pager --full status prosody jicofo jitsi-videobridge2"
echo "    tail -n 80 /var/log/jitsi/jicofo.log"
echo "    tail -n 80 /var/log/jitsi/jvb.log"
echo "    tail -n 80 /var/log/prosody/prosody.log"
