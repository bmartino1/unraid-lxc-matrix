#!/bin/bash
###############################################################################
# SETUP PHASE 03
# Configure Matrix Synapse homeserver
###############################################################################

set -euo pipefail

echo
echo "══════════════════════════════════════════════════"
echo "  synapse-config"
echo "══════════════════════════════════════════════════"
echo

SYNAPSE_CONF_DIR="/etc/matrix-synapse"
SYNAPSE_DATA_DIR="/var/lib/matrix-synapse"
SYNAPSE_LOG_DIR="/var/log/matrix-synapse"
SYNAPSE_RUN_DIR="/var/run/matrix-synapse"

SIGNING_KEY="${SYNAPSE_DATA_DIR}/${DOMAIN}.signing.key"

###############################################################################
# Ensure packages exist
###############################################################################

echo "  Ensuring Synapse packages are installed..."

apt-get update

apt-get install -y \
  matrix-synapse-py3 \
  python3-psycopg2 \
  python3-signedjson \
  curl

###############################################################################
# Prepare directories (important for LXC)
###############################################################################

echo "  Preparing directories..."

mkdir -p "${SYNAPSE_CONF_DIR}"
mkdir -p "${SYNAPSE_DATA_DIR}"
mkdir -p "${SYNAPSE_LOG_DIR}"
mkdir -p "${SYNAPSE_RUN_DIR}"
mkdir -p "${SYNAPSE_DATA_DIR}/media_store"

chown -R matrix-synapse:matrix-synapse "${SYNAPSE_DATA_DIR}"
chown -R matrix-synapse:matrix-synapse "${SYNAPSE_LOG_DIR}"
chown -R matrix-synapse:matrix-synapse "${SYNAPSE_RUN_DIR}"

###############################################################################
# Generate signing key
###############################################################################

echo "  Generating Matrix signing key..."

if [[ ! -f "${SIGNING_KEY}" ]]; then

sudo -u matrix-synapse generate_signing_key -o "${SIGNING_KEY}"

chown matrix-synapse:matrix-synapse "${SIGNING_KEY}"
chmod 600 "${SIGNING_KEY}"

else
  echo "  Signing key already exists."
fi

###############################################################################
# Write logging config
###############################################################################

echo "  Writing log.yaml..."

cat > "${SYNAPSE_CONF_DIR}/log.yaml" <<EOF
version: 1
formatters:
  precise:
    format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(message)s'
handlers:
  file:
    class: logging.handlers.TimedRotatingFileHandler
    formatter: precise
    filename: ${SYNAPSE_LOG_DIR}/homeserver.log
    when: midnight
    backupCount: 7
    encoding: utf8
  console:
    class: logging.StreamHandler
    formatter: precise
loggers:
  synapse.storage.SQL:
    level: WARNING
root:
    level: INFO
    handlers: [file, console]
disable_existing_loggers: false
EOF

chown matrix-synapse:matrix-synapse "${SYNAPSE_CONF_DIR}/log.yaml"

###############################################################################
# Write homeserver config
###############################################################################

echo "  Writing homeserver.yaml..."

cat > "${SYNAPSE_CONF_DIR}/homeserver.yaml" <<EOF
server_name: "${DOMAIN}"
public_baseurl: "https://${MATRIX_DOMAIN}/"

pid_file: ${SYNAPSE_RUN_DIR}/homeserver.pid

listeners:
  - port: 8008
    tls: false
    type: http
    x_forwarded: true
    bind_addresses: ['127.0.0.1']
    resources:
      - names: [client, federation]

database:
  name: psycopg2
  args:
    user: synapse
    password: "${POSTGRES_PASS}"
    database: synapse
    host: 127.0.0.1
    port: 5432

log_config: "${SYNAPSE_CONF_DIR}/log.yaml"

media_store_path: "${SYNAPSE_DATA_DIR}/media_store"

signing_key_path: "${SIGNING_KEY}"

trusted_key_servers:
  - server_name: "matrix.org"

enable_registration: false
registration_shared_secret: "${MATRIX_SHARED_SECRET}"

redis:
  enabled: true
  host: 127.0.0.1
  port: 6379
  password: "${VALKEY_PASS}"

turn_uris:
  - "turn:${DOMAIN}:3478?transport=udp"
  - "turn:${DOMAIN}:3478?transport=tcp"

turn_shared_secret: "${TURN_SECRET}"
turn_user_lifetime: 86400000
turn_allow_guests: true
EOF

chown matrix-synapse:matrix-synapse "${SYNAPSE_CONF_DIR}/homeserver.yaml"
chmod 640 "${SYNAPSE_CONF_DIR}/homeserver.yaml"

###############################################################################
# Start Synapse service
###############################################################################

echo "  Starting Matrix Synapse..."

systemctl daemon-reload
systemctl enable matrix-synapse
systemctl restart matrix-synapse

###############################################################################
# Wait for Synapse
###############################################################################

echo "  Waiting for Synapse..."

for i in $(seq 1 30); do
  if curl -fs http://127.0.0.1:8008/_matrix/client/versions >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if curl -fs http://127.0.0.1:8008/_matrix/client/versions >/dev/null 2>&1; then
  echo "  Synapse is responding."
else
  echo "  WARNING: Synapse did not respond."
  journalctl -u matrix-synapse --no-pager -n 50
fi

echo
echo "[✓] 03-synapse-config.sh complete"
echo
