#!/bin/bash
###############################################################################
# SETUP PHASE 03
# Configure Matrix Synapse homeserver (LXC-safe, idempotent)
#
# Fixes:
# - Uses the SAME python Synapse service uses (venv vs system python)
# - Generates required secrets (macaroon_secret_key etc.)
# - Ensures signing key exists (without relying on generate_signing_key binary)
# - Bootstraps DB/schema safely
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

HOMESERVER_YAML="${SYNAPSE_CONF_DIR}/homeserver.yaml"
LOG_YAML="${SYNAPSE_CONF_DIR}/log.yaml"

SIGNING_KEY="${SYNAPSE_DATA_DIR}/${DOMAIN}.signing.key"

# Secrets that Synapse actually needs to start
MACAROON_SECRET_FILE="${SYNAPSE_CONF_DIR}/.macaroon_secret_key"
FORM_SECRET_FILE="${SYNAPSE_CONF_DIR}/.form_secret"
REG_SHARED_SECRET_FILE="${SYNAPSE_CONF_DIR}/.registration_shared_secret"

###############################################################################
# Helpers
###############################################################################

gen_hex() { openssl rand -hex 32; }

# Use the SAME python that the matrix-synapse service uses (venv on Matrix packages).
detect_synapse_python() {
  local p="/opt/venvs/matrix-synapse/bin/python"
  if [[ -x "$p" ]]; then
    echo "$p"
    return 0
  fi
  echo "/usr/bin/python3"
}

SYNAPSE_PY="$(detect_synapse_python)"

echo "  Using Synapse python: ${SYNAPSE_PY}"

###############################################################################
# Ensure packages exist
###############################################################################

echo "  Ensuring Synapse packages are installed..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  matrix-synapse-py3 \
  python3-psycopg2 \
  python3-signedjson \
  curl

###############################################################################
# Prepare directories (important for LXC)
###############################################################################

echo "  Preparing directories..."
mkdir -p "${SYNAPSE_CONF_DIR}" "${SYNAPSE_DATA_DIR}" "${SYNAPSE_LOG_DIR}" "${SYNAPSE_RUN_DIR}"
mkdir -p "${SYNAPSE_DATA_DIR}/media_store"

chown -R matrix-synapse:matrix-synapse "${SYNAPSE_DATA_DIR}" "${SYNAPSE_LOG_DIR}" "${SYNAPSE_RUN_DIR}"
chmod 750 "${SYNAPSE_DATA_DIR}" "${SYNAPSE_LOG_DIR}" "${SYNAPSE_RUN_DIR}"

###############################################################################
# Ensure required secrets exist (Synapse will refuse to start without these)
###############################################################################

echo "  Ensuring Synapse secrets exist..."

if [[ ! -f "${MACAROON_SECRET_FILE}" ]]; then
  gen_hex > "${MACAROON_SECRET_FILE}"
fi
if [[ ! -f "${FORM_SECRET_FILE}" ]]; then
  gen_hex > "${FORM_SECRET_FILE}"
fi
if [[ ! -f "${REG_SHARED_SECRET_FILE}" ]]; then
  # If setup.sh already exports MATRIX_SHARED_SECRET use it; else generate.
  if [[ -n "${MATRIX_SHARED_SECRET:-}" ]]; then
    echo "${MATRIX_SHARED_SECRET}" > "${REG_SHARED_SECRET_FILE}"
  else
    gen_hex > "${REG_SHARED_SECRET_FILE}"
  fi
fi

chmod 600 "${MACAROON_SECRET_FILE}" "${FORM_SECRET_FILE}" "${REG_SHARED_SECRET_FILE}"
chown matrix-synapse:matrix-synapse "${MACAROON_SECRET_FILE}" "${FORM_SECRET_FILE}" "${REG_SHARED_SECRET_FILE}"

MACAROON_SECRET_KEY="$(cat "${MACAROON_SECRET_FILE}")"
FORM_SECRET="$(cat "${FORM_SECRET_FILE}")"
REG_SHARED_SECRET="$(cat "${REG_SHARED_SECRET_FILE}")"

###############################################################################
# Generate signing key (NO dependency on generate_signing_key binary)
###############################################################################

echo "  Ensuring Matrix signing key exists..."

if [[ ! -f "${SIGNING_KEY}" ]]; then
  sudo -u matrix-synapse "${SYNAPSE_PY}" <<PY
from signedjson.key import generate_signing_key, write_signing_keys
key = generate_signing_key("a_1")
with open("${SIGNING_KEY}", "w") as f:
    write_signing_keys(f, [key])
print("Signing key generated")
PY
  chown matrix-synapse:matrix-synapse "${SIGNING_KEY}"
  chmod 600 "${SIGNING_KEY}"
else
  echo "  Signing key already exists."
fi

###############################################################################
# Write log.yaml
###############################################################################

echo "  Writing log.yaml..."

cat > "${LOG_YAML}" <<EOF
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

chown matrix-synapse:matrix-synapse "${LOG_YAML}"
chmod 640 "${LOG_YAML}"

###############################################################################
# Write homeserver.yaml
###############################################################################

echo "  Writing homeserver.yaml..."

cat > "${HOMESERVER_YAML}" <<EOF
# Generated by setup.sh on ${SETUP_DATE:-unknown}
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

  - port: 9000
    tls: false
    type: http
    x_forwarded: true
    bind_addresses: ['127.0.0.1']
    resources:
      - names: [health, metrics]

database:
  name: psycopg2
  args:
    user: synapse
    password: "${POSTGRES_PASS}"
    database: synapse
    host: 127.0.0.1
    port: 5432
    # Synapse requires collation C; ensured in setup/01-postgres-config.sh

log_config: "${LOG_YAML}"

media_store_path: "${SYNAPSE_DATA_DIR}/media_store"
max_upload_size: 100M

signing_key_path: "${SIGNING_KEY}"

# Required secrets (without these Synapse exits immediately)
macaroon_secret_key: "${MACAROON_SECRET_KEY}"
form_secret: "${FORM_SECRET}"

trusted_key_servers:
  - server_name: "matrix.org"
suppress_key_server_warning: true

enable_registration: false
registration_shared_secret: "${REG_SHARED_SECRET}"

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

chown matrix-synapse:matrix-synapse "${HOMESERVER_YAML}"
chmod 640 "${HOMESERVER_YAML}"

###############################################################################
# Bootstrap DB/schema (safe, idempotent)
###############################################################################

echo "  Initializing Synapse database (schema bootstrap)..."

# If Synapse python module exists, run a one-shot config read that will create/upgrade schema
# (This uses the venv python if present, avoiding the 'No module named synapse' issue.)
sudo -u matrix-synapse "${SYNAPSE_PY}" -m synapse.app.homeserver \
  --config-path "${HOMESERVER_YAML}" \
  --keys-directory "${SYNAPSE_DATA_DIR}" \
  --generate-keys \
  --report-stats=no \
  >/dev/null 2>&1 || true

###############################################################################
# Start Synapse service
###############################################################################

echo "  Starting Matrix Synapse..."
systemctl daemon-reload
systemctl enable matrix-synapse >/dev/null 2>&1 || true
systemctl restart matrix-synapse

###############################################################################
# Wait for Synapse
###############################################################################

echo "  Waiting for Synapse..."
for i in $(seq 1 30); do
  if curl -fs http://127.0.0.1:8008/_matrix/client/versions >/dev/null 2>&1; then
    echo "  Synapse is responding."
    echo
    echo "[✓] 03-synapse-config.sh complete"
    echo
    exit 0
  fi
  sleep 2
done

echo "  WARNING: Synapse did not respond."
echo "  Showing last 80 lines of service logs:"
journalctl -u matrix-synapse --no-pager -n 80 || true

echo
echo "[✓] 03-synapse-config.sh complete"
echo
