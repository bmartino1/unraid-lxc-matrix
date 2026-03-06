#!/bin/bash
###############################################################################
# 06-jitsi-config.sh
# Configure Jitsi Meet from /root/matrix.env as the single source of truth.
#
# Owns:
#   - Prosody config
#   - Prosody certs
#   - Jicofo config
#   - JVB config
#   - /etc/jitsi/meet/${MEET}-config.js
#
# Does NOT own nginx.
###############################################################################
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "  Configuring Jitsi Meet..."

ENV_FILE="/root/matrix.env"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE"; exit 1; }

set -a
. "$ENV_FILE"
set +a

: "${DOMAIN:?Missing DOMAIN in matrix.env}"
: "${MEET:?Missing MEET in matrix.env}"
: "${TURN:?Missing TURN in matrix.env}"
: "${TURN_SECRET:?Missing TURN_SECRET in matrix.env}"
: "${JICOFO_PASS:?Missing JICOFO_PASS in matrix.env}"
: "${JVB_PASS:?Missing JVB_PASS in matrix.env}"
: "${LXC_IP:?Missing LXC_IP in matrix.env}"

EXTERNAL_IP="${EXTERNAL_IP:-$LXC_IP}"
PROSODY_CFG="/etc/prosody/conf.avail/${MEET}.cfg.lua"
MEET_CFG="/etc/jitsi/meet/${MEET}-config.js"

###############################################################################
# Packages / helpers for Prosody + Lua modules
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
  ca-certificates \
  ca-certificates-java

ln -sf /usr/share/lua/5.3/inspect.lua /usr/lib/prosody/inspect.lua 2>/dev/null || true

grep -qE "[[:space:]]${MEET}([[:space:]]|$)" /etc/hosts || \
  echo "127.0.0.1 ${MEET}" >> /etc/hosts

mkdir -p /etc/prosody/conf.avail
mkdir -p /etc/prosody/conf.d
mkdir -p /etc/prosody/certs
mkdir -p /etc/jitsi/jicofo
mkdir -p /etc/jitsi/videobridge
mkdir -p /etc/jitsi/meet
mkdir -p /var/log/jitsi
mkdir -p /usr/local/share/ca-certificates

###############################################################################
# Helper: generate SAN self-signed cert
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
# Local Prosody certs
#
# auth.${MEET} needs its own SAN-valid cert because public certs may not cover it.
# ${MEET} gets its own local cert for Prosody's XMPP side.
###############################################################################

make_cert "${MEET}"
make_cert "auth.${MEET}"

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
# Trust auth.${MEET} system-wide and in Java truststore
###############################################################################

AUTH_CRT="/etc/prosody/certs/auth.${MEET}.crt"
CA_CRT="/usr/local/share/ca-certificates/auth.${MEET}.crt"

if [[ ! -e "$CA_CRT" ]] || [[ "$(readlink -f "$AUTH_CRT")" != "$(readlink -f "$CA_CRT" 2>/dev/null || true)" ]]; then
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

cat > "$PROSODY_CFG" <<EOF
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
    "focus@auth.${MEET}";
    "jvb@auth.${MEET}";
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
EOF

ln -sf "$PROSODY_CFG" "/etc/prosody/conf.d/${MEET}.cfg.lua"

###############################################################################
# Validate Prosody strictly
###############################################################################

PROSODY_CHECK_OUTPUT="$(prosodyctl check config 2>&1 || true)"
echo "$PROSODY_CHECK_OUTPUT"

if echo "$PROSODY_CHECK_OUTPUT" | grep -qiE 'Error:|not found:|unexpected symbol|expected|failed'; then
  echo "  Prosody config invalid — aborting."
  exit 1
fi

###############################################################################
# Start Prosody first, then register users
###############################################################################

systemctl enable prosody
systemctl restart prosody
sleep 3

prosodyctl register focus "auth.${MEET}" "${JICOFO_PASS}" 2>/dev/null || true
prosodyctl register jvb   "auth.${MEET}" "${JVB_PASS}"    2>/dev/null || true

###############################################################################
# Jicofo config
###############################################################################

cat > /etc/jitsi/jicofo/jicofo.conf <<EOF
jicofo {
  xmpp: {
    client: {
      client-proxy: "focus.${MEET}"
      xmpp-domain: "${MEET}"
      domain: "auth.${MEET}"
      username: "focus"
      password: "${JICOFO_PASS}"
      hostname: "localhost"
      port = 5222
    }
    trusted-domains: [ "recorder.${MEET}" ]
  }
  bridge: {
    brewery-jid: "jvbbrewery@internal.auth.${MEET}"
  }
}
EOF

cat > /etc/jitsi/jicofo/config <<'EOF'
JAVA_SYS_PROPS="-Dnet.java.sip.communicator.SC_HOME_DIR_LOCATION=/etc/jitsi -Dnet.java.sip.communicator.SC_HOME_DIR_NAME=jicofo -Dnet.java.sip.communicator.SC_LOG_DIR_LOCATION=/var/log/jitsi -Djava.util.logging.config.file=/etc/jitsi/jicofo/logging.properties"
EOF

###############################################################################
# JVB config
# Valid HOCON only. No bogus "127.0.0.1:8080" value in a port field.
###############################################################################

cat > /etc/jitsi/videobridge/jvb.conf <<EOF
videobridge {
  http-servers {
    public {
      port = 9090
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
EOF

cat > /etc/jitsi/videobridge/config <<'EOF'
JAVA_SYS_PROPS="-Dconfig.file=/etc/jitsi/videobridge/jvb.conf -Dnet.java.sip.communicator.SC_HOME_DIR_LOCATION=/etc/jitsi -Dnet.java.sip.communicator.SC_HOME_DIR_NAME=videobridge -Dnet.java.sip.communicator.SC_LOG_DIR_LOCATION=/var/log/jitsi -Djava.util.logging.config.file=/etc/jitsi/videobridge/logging.properties"
EOF

touch /var/log/jitsi/jicofo.log /var/log/jitsi/jvb.log
chown jicofo:jitsi /var/log/jitsi/jicofo.log 2>/dev/null || true
chown jvb:jitsi    /var/log/jitsi/jvb.log    2>/dev/null || true

###############################################################################
# Jitsi web config only
# nginx will serve /config.js later in 07.
###############################################################################

cat > "$MEET_CFG" <<EOF
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
EOF

chmod 644 "$MEET_CFG"

###############################################################################
# Enable Jitsi services, but do NOT start them here.
# 07 starts nginx first, then starts jicofo/jvb in correct order.
###############################################################################

systemctl enable jicofo jitsi-videobridge2

echo "  Jitsi config written."
echo "  Prosody is running."
echo "  Nginx is intentionally not touched here."
