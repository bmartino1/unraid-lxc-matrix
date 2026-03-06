#!/bin/bash
###############################################################################
# Configure Jitsi Meet — matches PVE working prosody/jicofo/jvb configs
###############################################################################
set -euo pipefail

echo "  Configuring Jitsi Meet..."

###############################################################################
# Install required packages
###############################################################################

apt install -y \
  prosody \
  lua-inspect \
  lua-basexx \
  lua-cjson \
  lua-sec \
  lua-socket

# Prosody module path fix required by Jitsi
ln -sf /usr/share/lua/5.3/inspect.lua /usr/lib/prosody/inspect.lua

###############################################################################
# Ensure hostname resolution
###############################################################################

grep -q "${MEET}" /etc/hosts || echo "127.0.0.1 ${MEET}" >> /etc/hosts

###############################################################################
# Ensure required dirs exist
###############################################################################

mkdir -p /etc/prosody/conf.avail
mkdir -p /etc/prosody/conf.d
mkdir -p /etc/prosody/certs
mkdir -p /etc/jitsi/jicofo
mkdir -p /etc/jitsi/videobridge
mkdir -p /var/log/jitsi

###############################################################################
# Prosody configuration
###############################################################################

PROSODY_CFG="/etc/prosody/conf.avail/${MEET}.cfg.lua"

cat > "${PROSODY_CFG}" <<PCFG
-- Prosody config for ${MEET}

component_admins_as_room_owners = true
plugin_paths = { "/usr/share/jitsi-meet/prosody-plugins/" }

muc_mapper_domain_base = "${MEET}"

external_service_secret = "${TURN_SECRET}"
external_services = {
  { type = "turns", host = "${TURN}", port = 443, transport = "tcp", secret = true, ttl = 86400, algorithm = "turn" }
}

cross_domain_bosh = false
consider_bosh_secure = true
consider_websocket_secure = true

ssl = {
    protocol = "tlsv1_2+"
}

unlimited_jids = {
    "focus@auth.${MEET}",
    "jvb@auth.${MEET}"
}

VirtualHost "${MEET}"
    authentication = "jitsi-anonymous"

    ssl = {
        key = "/etc/prosody/certs/${MEET}.key"
        certificate = "/etc/prosody/certs/${MEET}.crt"
    }

    modules_enabled = {
        "bosh";
        "websocket";
        "smacks";
        "ping";
        "external_services";
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
    }
    admins = { "focus@auth.${MEET}" }

Component "breakout.${MEET}" "muc"
    storage = "memory"
    restrict_room_creation = true

Component "internal.auth.${MEET}" "muc"
    storage = "memory"
    modules_enabled = { "muc_hide_all"; "ping"; }
    admins = { "focus@auth.${MEET}", "jvb@auth.${MEET}" }

VirtualHost "auth.${MEET}"
    authentication = "internal_hashed"

    ssl = {
        key = "/etc/prosody/certs/auth.${MEET}.key"
        certificate = "/etc/prosody/certs/auth.${MEET}.crt"
    }

VirtualHost "recorder.${MEET}"
    authentication = "internal_hashed"

Component "focus.${MEET}" "client_proxy"
    target_address = "focus@auth.${MEET}"
PCFG

ln -sf "${PROSODY_CFG}" "/etc/prosody/conf.d/${MEET}.cfg.lua"

###############################################################################
# Hybrid Prosody Certificate Generation
###############################################################################

for vhost in "${MEET}" "auth.${MEET}"; do
  # Try official Prosody generation first
  prosodyctl cert generate "${vhost}" 2>/dev/null || true

  # Move generated certs if Prosody created them
  mv "/var/lib/prosody/${vhost}.crt" "/etc/prosody/certs/" 2>/dev/null || true
  mv "/var/lib/prosody/${vhost}.key" "/etc/prosody/certs/" 2>/dev/null || true
  mv "/var/lib/prosody/${vhost}.cnf" "/etc/prosody/certs/" 2>/dev/null || true

  # Fallback to OpenSSL if still missing
  if [[ ! -f "/etc/prosody/certs/${vhost}.crt" ]] || [[ ! -f "/etc/prosody/certs/${vhost}.key" ]]; then
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -keyout "/etc/prosody/certs/${vhost}.key" \
      -out "/etc/prosody/certs/${vhost}.crt" \
      -subj "/CN=${vhost}" 2>/dev/null
  fi

  chown prosody:prosody "/etc/prosody/certs/${vhost}.crt" "/etc/prosody/certs/${vhost}.key" 2>/dev/null || true
  chmod 640 "/etc/prosody/certs/${vhost}.crt" "/etc/prosody/certs/${vhost}.key" 2>/dev/null || true
done

# Validate config before restart
prosodyctl check config 2>/dev/null || true

###############################################################################
# Restart Prosody
###############################################################################

systemctl enable prosody
systemctl restart prosody
sleep 3

###############################################################################
# Register XMPP users
###############################################################################

prosodyctl register focus "auth.${MEET}" "${JICOFO_PASS}" 2>/dev/null || true
prosodyctl register jvb   "auth.${MEET}" "${JVB_PASS}"    2>/dev/null || true

###############################################################################
# Jicofo configuration
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
  }

  bridge: {
    brewery-jid: "jvbbrewery@internal.auth.${MEET}"
  }
}
JCEOF

###############################################################################
# Jicofo environment config
###############################################################################

cat > /etc/jitsi/jicofo/config <<'JCSEOF'
JAVA_SYS_PROPS="-Dnet.java.sip.communicator.SC_HOME_DIR_LOCATION=/etc/jitsi -Dnet.java.sip.communicator.SC_HOME_DIR_NAME=jicofo -Dnet.java.sip.communicator.SC_LOG_DIR_LOCATION=/var/log/jitsi -Djava.util.logging.config.file=/etc/jitsi/jicofo/logging.properties"
JCSEOF

###############################################################################
# Jitsi Videobridge configuration
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
            aws { enabled = false }

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

###############################################################################
# JVB environment config
###############################################################################

cat > /etc/jitsi/videobridge/config <<JVSEOF
JAVA_SYS_PROPS="-Dconfig.file=/etc/jitsi/videobridge/jvb.conf -Dnet.java.sip.communicator.SC_HOME_DIR_LOCATION=/etc/jitsi -Dnet.java.sip.communicator.SC_HOME_DIR_NAME=videobridge -Dnet.java.sip.communicator.SC_LOG_DIR_LOCATION=/var/log/jitsi -Djava.util.logging.config.file=/etc/jitsi/videobridge/logging.properties"
JVSEOF

chown jvb:jitsi /var/log/jitsi 2>/dev/null || true

###############################################################################
# Restart Jitsi stack
###############################################################################

systemctl daemon-reload

systemctl enable jicofo jitsi-videobridge2

systemctl restart prosody
sleep 2

systemctl restart jicofo
sleep 2

systemctl stop jitsi-videobridge2 2>/dev/null || true
systemctl reset-failed jitsi-videobridge2 2>/dev/null || true
systemctl start jitsi-videobridge2

echo "  Jitsi Meet configured."
