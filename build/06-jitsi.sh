#!/bin/bash
# Stage 06 - Jitsi Meet install (prosody + jicofo + jitsi-videobridge2 + jitsi-meet)
# Uses Debian 12 Bookworm - Java 17 required for JVB/jicofo
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "==> Installing Java 17 (required for Jitsi components)..."
apt-get -y install openjdk-17-jre-headless
update-alternatives --set java /usr/lib/jvm/java-17-openjdk-amd64/bin/java
echo "JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64" >> /etc/environment

echo "==> Pre-seeding Jitsi Meet debconf values (unattended install)..."
echo "jitsi-meet jitsi-meet/jvb-serve boolean false"                                  | debconf-set-selections
echo "jitsi-meet jitsi-meet/cert-choice select Generate a new self-signed certificate" | debconf-set-selections
echo "jitsi-videobridge2 jitsi-videobridge/jvbjvm string /usr/lib/jvm/java-17-openjdk-amd64" | debconf-set-selections
echo "jitsi-meet-web-config/jvb-hostname string ${JITSI_DOMAIN}"                       | debconf-set-selections

# Set the hostname that Jitsi uses during install
hostnamectl set-hostname "${JITSI_DOMAIN}" 2>/dev/null || echo "${JITSI_DOMAIN}" > /etc/hostname
echo "127.0.0.1 ${JITSI_DOMAIN}" >> /etc/hosts

echo "==> Installing Jitsi Meet stack..."
apt-get -y install \
  prosody \
  jicofo \
  jitsi-videobridge2 \
  jitsi-meet \
  jitsi-meet-web-config \
  jitsi-meet-prosody

echo "==> Writing prosody configuration for Jitsi..."
PROSODY_CONF_DIR="/etc/prosody/conf.avail"
mkdir -p "${PROSODY_CONF_DIR}"

cat > "${PROSODY_CONF_DIR}/${JITSI_DOMAIN}.cfg.lua" <<EOF
-- Prosody configuration for Jitsi Meet
-- Domain: ${JITSI_DOMAIN}

plugin_paths = { "/usr/share/jitsi-meet/prosody-plugins/" }

-- Main virtual host
VirtualHost "${JITSI_DOMAIN}"
    authentication = "jitsi-anonymous"
    ssl = {
        key = "/etc/ssl/private/${JITSI_DOMAIN}.key";
        certificate = "/etc/ssl/certs/${JITSI_DOMAIN}.crt";
    }
    modules_enabled = {
        "bosh";
        "pubsub";
        "ping";
        "speakerstats";
        "conference_duration";
        "end_conference";
        "muc_lobby_rooms";
        "muc_breakout_rooms";
        "av_moderation";
        "room_metadata";
        "polls";
    }
    c2s_require_encryption = false
    speakerstats_component = "speakerstats.${JITSI_DOMAIN}"
    conference_duration_component = "conferenceduration.${JITSI_DOMAIN}"
    lobby_muc = "lobby.${JITSI_DOMAIN}"
    breakout_rooms_muc = "breakout.${JITSI_DOMAIN}"
    room_metadata_component = "metadata.${JITSI_DOMAIN}"
    main_muc = "conference.${JITSI_DOMAIN}"

-- MUC for conferences
Component "conference.${JITSI_DOMAIN}" "muc"
    storage = "memory"
    modules_enabled = {
        "muc_meeting_id";
        "muc_domain_mapper";
        "polls";
        "token_verification";
        "muc_rate_limit";
        "muc_lobby_rooms";
        "muc_breakout_rooms";
        "av_moderation";
        "room_metadata";
    }
    admins = { "focus@auth.${JITSI_DOMAIN}" }
    muc_room_locking = false
    muc_room_default_public_jids = true

-- Focus component (jicofo)
Component "focus.${JITSI_DOMAIN}"
    component_secret = "${JITSI_PASS}"

-- Videobridge
Component "jvb.${JITSI_DOMAIN}"
    component_secret = "${JITSI_APP_SECRET}"

-- Internal auth domain for services
VirtualHost "auth.${JITSI_DOMAIN}"
    ssl = {
        key = "/etc/ssl/private/${JITSI_DOMAIN}.key";
        certificate = "/etc/ssl/certs/${JITSI_DOMAIN}.crt";
    }
    authentication = "internal_plain"

-- Lobby
Component "lobby.${JITSI_DOMAIN}" "muc"
    storage = "memory"
    restrict_room_creation = true
    muc_room_locking = false
    muc_room_default_public_jids = true

-- Breakout rooms
Component "breakout.${JITSI_DOMAIN}" "muc"
    storage = "memory"
    restrict_room_creation = true
    muc_room_locking = false
    muc_room_default_public_jids = true

-- Speaker stats
Component "speakerstats.${JITSI_DOMAIN}" "speakerstats_component"
    muc_component = "conference.${JITSI_DOMAIN}"

-- Conference duration
Component "conferenceduration.${JITSI_DOMAIN}" "conference_duration_component"
    muc_component = "conference.${JITSI_DOMAIN}"

-- AV moderation
Component "avmoderation.${JITSI_DOMAIN}" "av_moderation_component"
    muc_component = "conference.${JITSI_DOMAIN}"

-- Metadata
Component "metadata.${JITSI_DOMAIN}" "room_metadata_component"
    muc_component = "conference.${JITSI_DOMAIN}"
EOF

# Enable the prosody vhost
ln -sf "${PROSODY_CONF_DIR}/${JITSI_DOMAIN}.cfg.lua" \
       "/etc/prosody/conf.d/${JITSI_DOMAIN}.cfg.lua"

echo "==> Creating Prosody users for Jitsi services..."
prosodyctl --config /etc/prosody/prosody.cfg.lua register \
  focus "auth.${JITSI_DOMAIN}" "${JITSI_PASS}" 2>/dev/null || true
prosodyctl --config /etc/prosody/prosody.cfg.lua register \
  jvb "auth.${JITSI_DOMAIN}" "${JITSI_APP_SECRET}" 2>/dev/null || true

echo "==> Writing jicofo sip-communicator.properties..."
JICOFO_CONF_DIR="/etc/jitsi/jicofo"
mkdir -p "${JICOFO_CONF_DIR}"
cat > "${JICOFO_CONF_DIR}/sip-communicator.properties" <<EOF
org.jitsi.jicofo.BRIDGE_MUC=JvbBrewery@internal.auth.${JITSI_DOMAIN}
org.jitsi.jicofo.auth.URL=XMPP:${JITSI_DOMAIN}
org.jitsi.impl.protocol.xmpp.XMPP_DOMAIN=${JITSI_DOMAIN}
org.jitsi.impl.protocol.xmpp.FOCUS_USER_DOMAIN=auth.${JITSI_DOMAIN}
org.jitsi.impl.protocol.xmpp.FOCUS_ANONYMOUS_USER_DOMAIN=${JITSI_DOMAIN}
org.jitsi.jicofo.FOCUS_COMPONENT_URL=focus.${JITSI_DOMAIN}
EOF

cat > "${JICOFO_CONF_DIR}/config" <<EOF
JICOFO_HOST=${JITSI_DOMAIN}
JICOFO_HOSTNAME=${JITSI_DOMAIN}
JICOFO_SECRET=${JITSI_PASS}
JICOFO_PORT=5347
JICOFO_AUTH_DOMAIN=auth.${JITSI_DOMAIN}
JICOFO_AUTH_USER=focus
JICOFO_AUTH_PASSWORD=${JITSI_PASS}
JAVA_SYS_PROPS="-Djava.util.logging.config.file=/etc/jitsi/jicofo/logging.properties"
EOF

echo "==> Writing jitsi-videobridge2 configuration..."
JVB_CONF_DIR="/etc/jitsi/videobridge"
mkdir -p "${JVB_CONF_DIR}"
cat > "${JVB_CONF_DIR}/config" <<EOF
JVB_HOSTNAME=${JITSI_DOMAIN}
JVB_HOST=${JITSI_DOMAIN}
JVB_PORT=5347
JVB_SECRET=${JITSI_APP_SECRET}
JAVA_SYS_PROPS="-Dconfig.file=/etc/jitsi/videobridge/jvb.conf -Djava.util.logging.config.file=/etc/jitsi/videobridge/logging.properties -Djavax.net.ssl.trustStore=/etc/jitsi/videobridge/cacerts"
EOF

cat > "${JVB_CONF_DIR}/jvb.conf" <<EOF
videobridge {
  ice {
    udp {
      port = 10000
    }
    tcp {
      enabled = true
      port = 4443
    }
  }
  apis {
    xmpp-client {
      configs {
        xmpp-server-1 {
          hostname = "localhost"
          domain = "auth.${JITSI_DOMAIN}"
          username = "jvb"
          password = "${JITSI_APP_SECRET}"
          muc_jids = "JvbBrewery@internal.auth.${JITSI_DOMAIN}"
          muc_nickname = "jvb-1"
          disable_certificate_verification = true
        }
      }
    }
  }
  stats {
    enabled = true
  }
  websockets {
    enabled = true
    domain = "${JITSI_DOMAIN}"
    tls = true
    server-id = "default-id"
  }
}
EOF

echo "==> Writing meet.jitsi config.js..."
JITSI_WEB_DIR="/usr/share/jitsi-meet"
cat > "${JITSI_WEB_DIR}/config.js" <<EOF
/* Jitsi Meet configuration - generated by unraid-lxc-matrix */
var config = {
    hosts: {
        domain: '${JITSI_DOMAIN}',
        muc: 'conference.${JITSI_DOMAIN}',
        focus: 'focus.${JITSI_DOMAIN}',
    },
    bosh: 'https://${JITSI_DOMAIN}/http-bind',
    websocket: 'wss://${JITSI_DOMAIN}/xmpp-websocket',
    clientNode: 'https://jitsi.org/jitsimeet',
    enableWelcomePage: true,
    enableClosePage: false,
    prejoinPageEnabled: true,
    disableDeepLinking: false,
    startWithAudioMuted: false,
    startWithVideoMuted: false,
    enableNoisyMicDetection: true,
    p2p: {
        enabled: true,
        stunServers: [
            { urls: 'turn:${DOMAIN}:3478?transport=udp', username: 'jitsi', credential: '${TURN_SECRET}' },
            { urls: 'turns:${DOMAIN}:5349?transport=tcp', username: 'jitsi', credential: '${TURN_SECRET}' },
        ],
    },
    analytics: {},
    deploymentInfo: {},
    disableAudioLevels: false,
    enableLayerSuspension: true,
    channelLastN: -1,
    toolbarButtons: [
        'microphone', 'camera', 'closedcaptions', 'desktop', 'fullscreen',
        'fodeviceselection', 'hangup', 'chat', 'recording',
        'livestreaming', 'etherpad', 'sharedvideo', 'shareaudio',
        'settings', 'raisehand', 'videoquality', 'filmstrip', 'invite',
        'feedback', 'stats', 'shortcuts', 'tileview', 'select-background',
        'help', 'mute-everyone', 'mute-video-everyone', 'security'
    ],
};
EOF

echo "==> Starting Jitsi services..."
systemctl daemon-reload
for svc in prosody jicofo jitsi-videobridge2; do
  systemctl enable "$svc" || true
  systemctl restart "$svc" || true
done

echo "Completed Stage 06 - Jitsi Meet"
