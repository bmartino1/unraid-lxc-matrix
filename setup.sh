#!/bin/bash
# =============================================================================
# setup.sh — Matrix Synapse + Element Web + Jitsi + coturn Configurator
# =============================================================================
# Architecture:
#   https://DOMAIN         → Element Web + Synapse
#   https://meet.DOMAIN    → Jitsi Meet
#   turn.DOMAIN:443/5349   → coturn TURNS
#   turn.DOMAIN:3478       → coturn TURN
#
# DNS required:
#   DOMAIN, meet.DOMAIN, turn.DOMAIN
# =============================================================================

set -euo pipefail

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─────────────────────────────────────────────────────────────
# Colours
# ─────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
error()  { echo -e "${RED}[✗]${NC} $*" >&2; }
info()   { echo -e "${BLUE}[→]${NC} $*"; }

header() {
  echo
  echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}${BOLD}  $*${NC}"
  echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════${NC}"
}

# ─────────────────────────────────────────────────────────────
# Generators
# ─────────────────────────────────────────────────────────────

gen_pass() { openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 40; }
gen_hex()  { openssl rand -hex 32; }
gen_b64()  { openssl rand -base64 48; }

# ─────────────────────────────────────────────────────────────
# Defaults / CLI values
# ─────────────────────────────────────────────────────────────

DOMAIN=""
ADMIN_USER=""
ADMIN_PASS=""
POSTGRES_PASSWORD=""
VALKEY_PASS=""
TURN_SECRET=""
JICOFO_PASS=""
JVB_PASS=""
EXTERNAL_IP=""

SKIP_SSL=""
STAGING=""
RECONFIGURE=false

ENV_FILE="/root/matrix.env"

# Back-compat alias
if [[ "${1:-}" == "--reset" ]]; then
  set -- --reconfigure "${@:2}"
fi

# ─────────────────────────────────────────────────────────────
# CLI Argument Parsing
# ─────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)         DOMAIN="${2:-}"; shift 2 ;;
    --admin-user)     ADMIN_USER="${2:-}"; shift 2 ;;
    --admin-pass)     ADMIN_PASS="${2:-}"; shift 2 ;;
    --postgres-pass)  POSTGRES_PASSWORD="${2:-}"; shift 2 ;;
    --valkey-pass)    VALKEY_PASS="${2:-}"; shift 2 ;;
    --turn-secret)    TURN_SECRET="${2:-}"; shift 2 ;;
    --jicofo-pass)    JICOFO_PASS="${2:-}"; shift 2 ;;
    --jvb-pass)       JVB_PASS="${2:-}"; shift 2 ;;
    --external-ip)    EXTERNAL_IP="${2:-}"; shift 2 ;;
    --skip-ssl|--no-ssl) SKIP_SSL="true"; shift ;;
    --staging)        STAGING="true"; shift ;;
    --reconfigure)    RECONFIGURE=true; shift ;;
    --help|-h)
      cat <<'EOF'
Usage:
  ./setup.sh --domain example.com [options]

Options:
  --domain <domain>          Required on first run
  --admin-user <user>        Matrix admin username
  --admin-pass <pass>        Matrix admin password
  --postgres-pass <pass>     PostgreSQL password
  --valkey-pass <pass>       Valkey password
  --turn-secret <secret>     coturn shared secret
  --jicofo-pass <pass>       Jicofo XMPP password
  --jvb-pass <pass>          JVB XMPP password
  --external-ip <ip>         Public IP override
  --skip-ssl                 Skip LE flow / use self-signed where applicable
  --no-ssl                   Alias for --skip-ssl
  --staging                  Use staging mode where supported
  --reconfigure              Rewrite env file and regenerate secrets not explicitly passed
  --reset                    Alias for --reconfigure
EOF
      exit 0
      ;;
    *)
      error "Unknown option: $1"
      exit 1
      ;;
  esac
done

[[ $EUID -ne 0 ]] && { error "Must run as root"; exit 1; }

# ─────────────────────────────────────────────────────────────
# Load existing env if present and not forcing reconfigure
# ─────────────────────────────────────────────────────────────

if [[ -f "$ENV_FILE" && "$RECONFIGURE" != true ]]; then
  info "Existing environment found at ${ENV_FILE} — preserving current values"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# ─────────────────────────────────────────────────────────────
# Effective defaults after loading existing env
# ─────────────────────────────────────────────────────────────

DOMAIN="${DOMAIN:-${DOMAIN:-}}"
ADMIN_USER="${ADMIN_USER:-${ADMIN_USER:-admin}}"
SKIP_SSL="${SKIP_SSL:-${SKIP_SSL:-false}}"
STAGING="${STAGING:-${STAGING:-false}}"

# If sourced env did not provide these, set sane defaults
: "${ADMIN_USER:=admin}"
: "${SKIP_SSL:=false}"
: "${STAGING:=false}"

# Required domain must now exist either from CLI or preserved env
[[ -z "${DOMAIN:-}" ]] && { error "Required: --domain example.com"; exit 1; }

MEET="meet.${DOMAIN}"
TURN="turn.${DOMAIN}"
LXC_IP="$(hostname -I | awk '{print $1}')"

# External IP: CLI overrides env; else try existing; else detect
if [[ -z "${EXTERNAL_IP:-}" ]]; then
  EXTERNAL_IP="${EXTERNAL_IP:-}"
fi
if [[ -z "${EXTERNAL_IP:-}" ]]; then
  EXTERNAL_IP="$(curl -4 -sf --connect-timeout 5 https://ifconfig.me 2>/dev/null || true)"
fi

# ─────────────────────────────────────────────────────────────
# Preserve existing secrets unless missing or reconfigure/override
# ─────────────────────────────────────────────────────────────

: "${ADMIN_PASS:=${ADMIN_PASS:-}}"
: "${POSTGRES_PASSWORD:=${POSTGRES_PASSWORD:-}}"
: "${VALKEY_PASS:=${VALKEY_PASS:-}}"
: "${TURN_SECRET:=${TURN_SECRET:-}}"
: "${JICOFO_PASS:=${JICOFO_PASS:-}}"
: "${JVB_PASS:=${JVB_PASS:-}}"
: "${REG_SECRET:=${REG_SECRET:-}}"
: "${MACAROON_SECRET:=${MACAROON_SECRET:-}}"
: "${FORM_SECRET:=${FORM_SECRET:-}}"
: "${SYNAPSE:=${SYNAPSE:-http://127.0.0.1:8008}}"
: "${SETUP_DATE:=${SETUP_DATE:-}}"

[[ -z "${ADMIN_PASS:-}" ]]         && ADMIN_PASS="$(gen_pass)"
[[ -z "${POSTGRES_PASSWORD:-}" ]]  && POSTGRES_PASSWORD="$(gen_b64 | tr -dc 'a-zA-Z0-9/' | head -c 32)"
[[ -z "${VALKEY_PASS:-}" ]]        && VALKEY_PASS="$(gen_pass)"
[[ -z "${TURN_SECRET:-}" ]]        && TURN_SECRET="$(gen_b64)"
[[ -z "${JICOFO_PASS:-}" ]]        && JICOFO_PASS="$(gen_pass)"
[[ -z "${JVB_PASS:-}" ]]           && JVB_PASS="$(gen_pass)"
[[ -z "${REG_SECRET:-}" ]]         && REG_SECRET="$(gen_hex)"
[[ -z "${MACAROON_SECRET:-}" ]]    && MACAROON_SECRET="$(gen_hex)"
[[ -z "${FORM_SECRET:-}" ]]        && FORM_SECRET="$(gen_hex)"
[[ -z "${SETUP_DATE:-}" || "$RECONFIGURE" == true ]] && SETUP_DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# ─────────────────────────────────────────────────────────────
# Save environment
# ─────────────────────────────────────────────────────────────

cat > "$ENV_FILE" <<EOF
DOMAIN=${DOMAIN}
MEET=${MEET}
TURN=${TURN}
LXC_IP=${LXC_IP}
EXTERNAL_IP=${EXTERNAL_IP}
ADMIN_USER=${ADMIN_USER}
ADMIN_PASS=${ADMIN_PASS}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
REG_SECRET=${REG_SECRET}
MACAROON_SECRET=${MACAROON_SECRET}
FORM_SECRET=${FORM_SECRET}
TURN_SECRET=${TURN_SECRET}
JICOFO_PASS=${JICOFO_PASS}
JVB_PASS=${JVB_PASS}
VALKEY_PASS=${VALKEY_PASS}
SYNAPSE=${SYNAPSE}
SKIP_SSL=${SKIP_SSL}
STAGING=${STAGING}
SETUP_DATE=${SETUP_DATE}
EOF

chmod 600 "$ENV_FILE"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

export LE_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
export LE_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

# ─────────────────────────────────────────────────────────────
# Banner
# ─────────────────────────────────────────────────────────────

clear
echo -e "\n${CYAN}${BOLD}  Matrix Stack Setup${NC}"
echo -e "  Domain:     ${DOMAIN}"
echo -e "  Element:    https://${DOMAIN}"
echo -e "  Jitsi:      https://${MEET}"
echo -e "  TURN:       ${TURN}"
echo -e "  LXC IP:     ${LXC_IP}"
[[ -n "${EXTERNAL_IP:-}" ]] && echo -e "  Public IP:  ${EXTERNAL_IP}"
[[ -f "$ENV_FILE" && "$RECONFIGURE" != true ]] && echo -e "  Env file:   ${ENV_FILE}"
echo

# ─────────────────────────────────────────────────────────────
# Run setup scripts
# ─────────────────────────────────────────────────────────────

SETUP_SCRIPTS_DIR="${SETUP_DIR}/setup"
[[ ! -d "$SETUP_SCRIPTS_DIR" ]] && { error "Missing setup directory: $SETUP_SCRIPTS_DIR"; exit 1; }

shopt -s nullglob
SETUP_SCRIPTS=( "$SETUP_SCRIPTS_DIR"/[0-9][0-9]-*.sh )
shopt -u nullglob

[[ ${#SETUP_SCRIPTS[@]} -eq 0 ]] && { error "No setup scripts found in $SETUP_SCRIPTS_DIR"; exit 1; }

for script in "${SETUP_SCRIPTS[@]}"; do
  name="$(basename "$script")"
  header "$name"
  chmod +x "$script"
  if ! bash "$script"; then
    error "Failed: $name"
    exit 1
  fi
  log "$name complete"
done

# ─────────────────────────────────────────────────────────────
# Wait for Synapse
# ─────────────────────────────────────────────────────────────

header "Waiting for Synapse"

SYNAPSE_OK=false
for i in {1..30}; do
  if curl -fs http://127.0.0.1:8008/_matrix/client/versions >/dev/null 2>&1; then
    SYNAPSE_OK=true
    log "Synapse responding"
    break
  fi
  sleep 2
done

if [[ "$SYNAPSE_OK" != true ]]; then
  error "Synapse did not respond after waiting"
  exit 1
fi

# ─────────────────────────────────────────────────────────────
# Ensure admin user exists
# ─────────────────────────────────────────────────────────────

header "Matrix Admin Setup"

register_new_matrix_user \
  -u "${ADMIN_USER}" \
  -p "${ADMIN_PASS}" \
  -a \
  -c /etc/matrix-synapse/homeserver.yaml \
  http://127.0.0.1:8008 2>/dev/null || true

ADMIN_EXISTS="$(sudo -u postgres psql -d synapse -tAc "SELECT 1 FROM users WHERE name='@${ADMIN_USER}:${DOMAIN}' OR name='${ADMIN_USER}' LIMIT 1;" 2>/dev/null || true)"
if [[ "$ADMIN_EXISTS" == "1" ]]; then
  log "Admin account ready"
else
  warn "Admin account could not be confirmed in database; verify login manually"
fi

cat > /root/matrix.creds <<EOF
Matrix-Credentials
Admin username: ${ADMIN_USER}
Admin password: ${ADMIN_PASS}
EOF
chmod 600 /root/matrix.creds

# ─────────────────────────────────────────────────────────────
# Validation
# ─────────────────────────────────────────────────────────────

header "Validation"

if prosodyctl check config >/dev/null 2>&1; then
  log "Prosody config valid"
else
  error "Prosody config invalid"
  exit 1
fi

if nginx -t >/dev/null 2>&1; then
  log "Nginx config valid"
else
  error "Nginx config invalid"
  exit 1
fi

SERVICES=(
  postgresql
  valkey-server
  matrix-synapse
  prosody
  jicofo
  jitsi-videobridge2
  coturn
  nginx
)

for svc in "${SERVICES[@]}"; do
  if systemctl list-unit-files | grep -q "^${svc}"; then
    if systemctl is-active --quiet "$svc"; then
      log "${svc} active"
    else
      warn "${svc} not active"
    fi
  fi
done

# ─────────────────────────────────────────────────────────────
# Final output
# ─────────────────────────────────────────────────────────────

header "Setup Complete"

echo
echo -e "${GREEN}Stack running at:${NC}"
echo
echo "Element Web:"
echo "https://${DOMAIN}"
echo
echo "Matrix API:"
echo "https://${DOMAIN}/_matrix/client/versions"
echo
echo "Jitsi:"
echo "https://${MEET}"
echo

echo -e "${YELLOW}Matrix Admin:${NC}"
echo "User: ${ADMIN_USER}"
echo "Pass: ${ADMIN_PASS}"
echo

echo -e "${YELLOW}DNS Records Required:${NC}"
if [[ -n "${EXTERNAL_IP:-}" ]]; then
  echo "A  ${DOMAIN}  → ${EXTERNAL_IP}"
  echo "A  ${MEET}    → ${EXTERNAL_IP}"
  echo "A  ${TURN}    → ${EXTERNAL_IP}"
else
  echo "A  ${DOMAIN}  → ${LXC_IP}"
  echo "A  ${MEET}    → ${LXC_IP}"
  echo "A  ${TURN}    → ${LXC_IP}"
fi
echo

echo "Credentials stored at:"
echo "${ENV_FILE}"
echo "/root/matrix.creds"
echo
