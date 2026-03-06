#!/bin/bash
###############################################################################
# Configure Jitsi Meet — mirrors known-working baseline /etc layout
###############################################################################
set -euo pipefail

echo "  Configuring Jitsi Meet..."

apt update
apt install -y \
  prosody \
  lua-inspect \
  lua-basexx \
  lua-cjson \
  lua-sec \
  lua-socket

ln -sf /usr/share/lua/5.3/inspect.lua /usr/lib/prosody/inspect.lua

grep -q "${MEET}" /etc/hosts || echo "127.0.0.1 ${MEET}" >> /etc/hosts

mkdir -p /etc/prosody/conf.avail
mkdir -p /etc/prosody/conf.d
mkdir -p /etc/prosody/certs
mkdir -p /etc/jitsi/jicofo
mkdir -p /etc/jitsi/videobridge
mkdir -p /var/log/jitsi

###############################################################################
# Internal Prosody certs — NON-INTERACTIVE
###############################################################################

for vhost in "${MEET}" "auth.${MEET}"; do
  CRT="/etc/prosody/certs/${vhost}.crt"
  KEY="/etc/prosody/certs/${vhost}.key"

  if [[ ! -f "$CRT" || ! -f "$KEY" ]]; then
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -keyout "$KEY" \
      -out "$CRT" \
      -subj "/CN=${vhost}" \
      >/dev/null 2>&1
  fi

  chown prosody:prosody "$CRT" "$KEY" 2>/dev/null || true
  chmod 640 "$CRT" "$KEY" 2>/dev/null || true
done

###############################################################################
# Prosody config — baseline layout, token_verification disabled for current flow
###############################################################################

PROSODY_CFG="/etc/prosody/conf.avail/${MEET}.cfg.lua"

cat > "${PROSODY_CFG}" <<PCFG
-- We need this for prosody 13.0
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
    ciphers = "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384"
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
        -- "token_verification";
        "muc_rate_limit";
        "muc_password_whitelist";
    }
    admins = { "focus@auth.${MEET}" }
    muc_password_whitelist = {
        "focus@auth.${MEET}"
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
# Validate Prosody config
###############################################################################

PROSODY_CHECK_OUTPUT="$(prosodyctl check config 2>&1 || true)"
echo "$PROSODY_CHECK_OUTPUT"

if echo "$PROSODY_CHECK_OUTPUT" | grep -qiE 'Error:|not found:|unexpected symbol|expected|failed'; then
  echo "  Prosody config invalid — aborting."
  exit 1
fi

systemctl enable prosody
systemctl restart prosody
sleep 3

prosodyctl register focus "auth.${MEET}" "${JICOFO_PASS}" 2>/dev/null || true
prosodyctl register jvb   "auth.${MEET}" "${JVB_PASS}"    2>/dev/null || true

###############################################################################
# Jicofo — baseline structure
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
    }
    trusted-domains: [ "recorder.${MEET}" ]
  }
  bridge: {
    brewery-jid: "JvbBrewery@internal.auth.${MEET}"
  }
}
JCEOF

cat > /etc/jitsi/jicofo/config <<'JCSEOF'
JAVA_SYS_PROPS="-Dnet.java.sip.communicator.SC_HOME_DIR_LOCATION=/etc/jitsi -Dnet.java.sip.communicator.SC_HOME_DIR_NAME=jicofo -Dnet.java.sip.communicator.SC_LOG_DIR_LOCATION=/var/log/jitsi -Djava.util.logging.config.file=/etc/jitsi/jicofo/logging.properties"
JCSEOF

###############################################################################
# JVB — working HOCON syntax for current package
###############################################################################

cat > /etc/jitsi/videobridge/jvb.conf <<JVEOF
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
                    domain = "auth.${MEET}"
                    username = "jvb"
                    password = "${JVB_PASS}"
                    muc_jids = "jvbbrewery@internal.auth.${MEET}"
                    muc_nickname = "jvb-1"
                }
            }
        }
    }
}
ice4j {
    harvest {
        mapping {
            aws {
                enabled = false
            }
            stun {
                enabled = false
                addresses = []
            }
            static-mappings = [
                {
                    local-address = "${LXC_IP}"
                    public-address = "${EXTERNAL_IP:-${LXC_IP}}"
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
chown jvb:jitsi /var/log/jitsi 2>/dev/null || true

###############################################################################
# Service starts
###############################################################################

systemctl daemon-reload
systemctl enable jicofo jitsi-videobridge2

systemctl restart prosody
sleep 2

systemctl restart jicofo 2>/dev/null || echo "  jicofo deferred (nginx not yet up)"
systemctl restart jitsi-videobridge2 2>/dev/null || echo "  JVB deferred (nginx not yet up)"

sleep 2
systemctl stop jitsi-videobridge2 2>/dev/null || true
systemctl reset-failed jitsi-videobridge2 2>/dev/null || true
systemctl start jitsi-videobridge2 2>/dev/null || echo "  JVB deferred (nginx not yet up)"

echo "  Jitsi Meet configured."
