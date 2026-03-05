#!/bin/bash
###############################################################################
# Configure Jitsi Meet — matches PVE working prosody/jicofo/jvb configs
###############################################################################
set -euo pipefail
echo "  Configuring Jitsi Meet..."

# Ensure hostname resolution
grep -q "${MEET}" /etc/hosts || echo "127.0.0.1 ${MEET}" >> /etc/hosts

# ── Prosody — full config matching PVE ─────────────────────────────────────
PROSODY_CFG="/etc/prosody/conf.avail/${MEET}.cfg.lua"
cat > "${PROSODY_CFG}" <<PCFG
-- Prosody config for ${MEET} — matches PVE production
component_admins_as_room_owners = true
plugin_paths = { "/usr/share/jitsi-meet/prosody-plugins/" }

muc_mapper_domain_base = "${MEET}";

-- TURN service announcement (clients told to use this)
external_service_secret = "${TURN_SECRET}";
external_services = {
  { type = "turns", host = "${TURN}", port = 443, transport = "tcp", secret = true, ttl = 86400, algorithm = "turn" }
};

cross_domain_bosh = false;
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
        "token_verification";
        "muc_rate_limit";
        "muc_password_whitelist";
    }
    admins = { "focus@auth.${MEET}" }
    muc_password_whitelist = { "focus@auth.${MEET}" }
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
    modules_enabled = { "muc_hide_all"; "ping"; }
    admins = { "focus@auth.${MEET}", "jvb@auth.${MEET}" }
    muc_room_locking = false
    muc_room_default_public_jids = true

VirtualHost "auth.${MEET}"
    ssl = {
        key = "/etc/prosody/certs/auth.${MEET}.key";
        certificate = "/etc/prosody/certs/auth.${MEET}.crt";
    }
    modules_enabled = { "limits_exception"; "smacks"; }
    authentication = "internal_hashed"
    smacks_hibernation_time = 15;

VirtualHost "recorder.${MEET}"
    modules_enabled = { "smacks"; }
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
    modules_enabled = { "muc_hide_all"; "muc_rate_limit"; }

Component "filesharing.${MEET}" "filesharing_component"
    muc_component = "conference.${MEET}"

Component "metadata.${MEET}" "room_metadata_component"
    muc_component = "conference.${MEET}"
    breakout_rooms_component = "breakout.${MEET}"

Component "polls.${MEET}" "polls_component"
PCFG

ln -sf "${PROSODY_CFG}" "/etc/prosody/conf.d/${MEET}.cfg.lua"

# Generate prosody self-signed certs if missing
for vhost in "${MEET}" "auth.${MEET}"; do
  if [[ ! -f "/etc/prosody/certs/${vhost}.crt" ]]; then
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -keyout "/etc/prosody/certs/${vhost}.key" \
      -out "/etc/prosody/certs/${vhost}.crt" \
      -subj "/CN=${vhost}" 2>/dev/null
    chown prosody:prosody "/etc/prosody/certs/${vhost}."* 2>/dev/null || true
  fi
done

systemctl enable prosody
systemctl restart prosody
sleep 3

# Register XMPP users
prosodyctl register focus "auth.${MEET}" "${JICOFO_PASS}" 2>/dev/null || true
prosodyctl register jvb   "auth.${MEET}" "${JVB_PASS}"    2>/dev/null || true

# ── jicofo — matches PVE config ───────────────────────────────────────────
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

# ── jicofo sysvinit config (REQUIRED — tells Java where to find jicofo.conf) ──
cat > /etc/jitsi/jicofo/config <<'JCSEOF'
# Jicofo sysvinit environment — matches PVE
JAVA_SYS_PROPS="-Dnet.java.sip.communicator.SC_HOME_DIR_LOCATION=/etc/jitsi -Dnet.java.sip.communicator.SC_HOME_DIR_NAME=jicofo -Dnet.java.sip.communicator.SC_LOG_DIR_LOCATION=/var/log/jitsi -Djava.util.logging.config.file=/etc/jitsi/jicofo/logging.properties"
JCSEOF

# ── JVB — matches PVE config with ice4j static mappings ───────────────────
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
    apis.xmpp-client.configs {
        shard {
            HOSTNAME=localhost
            DOMAIN="auth.${MEET}"
            USERNAME=jvb
            PASSWORD="${JVB_PASS}"
            MUC_JIDS="jvbbrewery@internal.auth.${MEET}"
            MUC_NICKNAME="$(uuidgen 2>/dev/null || openssl rand -hex 8)"
        }
    }
}
ice4j {
    harvest {
        mapping {
            aws { enabled = false }
            stun { enabled = false; addresses = [] }
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

# ── JVB sysvinit config (REQUIRED — tells Java where to find jvb.conf) ──
cat > /etc/jitsi/videobridge/config <<JVSEOF
# JVB sysvinit environment — matches PVE
JAVA_SYS_PROPS="-Dconfig.file=/etc/jitsi/videobridge/jvb.conf -Dnet.java.sip.communicator.SC_HOME_DIR_LOCATION=/etc/jitsi -Dnet.java.sip.communicator.SC_HOME_DIR_NAME=videobridge -Dnet.java.sip.communicator.SC_LOG_DIR_LOCATION=/var/log/jitsi -Djava.util.logging.config.file=/etc/jitsi/videobridge/logging.properties"
JVSEOF

mkdir -p /var/log/jitsi
chown jvb:jitsi /var/log/jitsi 2>/dev/null || true

# ── Jitsi Meet config.js — matches PVE ────────────────────────────────────
JITSI_CONFIG="/etc/jitsi/meet/${MEET}-config.js"
[[ ! -d "/etc/jitsi/meet" ]] && mkdir -p /etc/jitsi/meet
cat > "${JITSI_CONFIG}" <<JMEOF
var config = {
    hosts: {
        domain: '${MEET}',
        muc: 'conference.${MEET}',
    },
    bosh: 'https://${MEET}/http-bind',
    websocket: 'wss://${MEET}/xmpp-websocket',
    enableWelcomePage: false,
    enableClosePage: false,
    enableNoisyMicDetection: true,
    enableNoAudioDetection: true,
    channelLastN: -1,
    p2p: {
        enabled: true,
        stunServers: [
            { urls: 'stun:meet-jit-si-turnrelay.jitsi.net:443' },
        ],
    },
    analytics: {},
};
JMEOF

systemctl enable jicofo jitsi-videobridge2
# Note: JVB may fail here because nginx stream (step 07) isn't up yet.
# Services will be restarted after nginx config in step 07.
systemctl restart jicofo 2>/dev/null || echo "  jicofo start deferred (nginx not yet configured)"
systemctl restart jitsi-videobridge2 2>/dev/null || echo "  JVB start deferred (nginx not yet configured)"
echo "  Jitsi Meet configured."
