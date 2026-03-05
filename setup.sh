#!/bin/bash
# =============================================================================
# setup.sh — Matrix Synapse + Element Web + Jitsi + coturn Configurator
# =============================================================================
# Architecture (matches proven PVE deployment):
#   https://DOMAIN         → Element Web + Synapse (path routing)
#   https://meet.DOMAIN    → Jitsi Meet (iframe widget only)
#   turn.DOMAIN:443/5349   → coturn TURNS (stream-muxed on 443)
#   turn.DOMAIN:3478       → coturn TURN
#
# DNS required (all A records → LXC IP):
#   DOMAIN, meet.DOMAIN, turn.DOMAIN
# =============================================================================
set -euo pipefail
SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
error()  { echo -e "${RED}[✗]${NC} $*" >&2; }
info()   { echo -e "${BLUE}[→]${NC} $*"; }
header() {
  echo; echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}${BOLD}  $*${NC}"
  echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════${NC}"
}

gen_pass()  { openssl rand -base64 18 | cut -c1-24; }
gen_hex()   { openssl rand -hex 32; }
gen_b64()   { openssl rand -base64 48; }

DOMAIN="" ADMIN_USER="admin" ADMIN_PASS="" EXTERNAL_IP=""
SKIP_SSL=false STAGING=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)       DOMAIN="$2"; shift 2 ;;
    --admin-user)   ADMIN_USER="$2"; shift 2 ;;
    --admin-pass)   ADMIN_PASS="$2"; shift 2 ;;
    --external-ip)  EXTERNAL_IP="$2"; shift 2 ;;
    --skip-ssl)     SKIP_SSL=true; shift ;;
    --staging)      STAGING=true; shift ;;
    --help|-h) echo "Usage: $0 --domain <domain> [--admin-user <u>] [--admin-pass <p>] [--external-ip <ip>] [--skip-ssl] [--staging]"; exit 0 ;;
    *) error "Unknown: $1"; exit 1 ;;
  esac
done

[[ -z "$DOMAIN" ]] && { error "Required: --domain example.com"; exit 1; }
[[ $EUID -ne 0 ]]  && { error "Must run as root"; exit 1; }

MEET="meet.${DOMAIN}"
TURN="turn.${DOMAIN}"
LXC_IP=$(hostname -I | awk '{print $1}')
[[ -z "$EXTERNAL_IP" ]] && EXTERNAL_IP=$(curl -4 -sf --connect-timeout 5 https://ifconfig.me 2>/dev/null || echo "")
[[ -z "$ADMIN_PASS" ]]  && ADMIN_PASS=$(gen_pass)

POSTGRES_PASSWORD=$(gen_b64 | tr -dc 'a-zA-Z0-9/' | head -c 32)
REG_SECRET=$(gen_hex)
MACAROON_SECRET=$(gen_hex)
FORM_SECRET=$(gen_hex)
TURN_SECRET=$(gen_b64)
JICOFO_PASS=$(gen_pass)
JVB_PASS=$(gen_pass)

ENV_FILE="/root/matrix.env"
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
SYNAPSE=http://127.0.0.1:8008
SKIP_SSL=${SKIP_SSL}
STAGING=${STAGING}
SETUP_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
chmod 600 "$ENV_FILE"
set -a; source "$ENV_FILE"; set +a

export LE_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
export LE_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

clear
echo -e "\n${CYAN}${BOLD}  Matrix Stack Setup${NC}"
echo -e "  Domain:     ${DOMAIN}"
echo -e "  Element:    https://${DOMAIN}"
echo -e "  Jitsi:      https://${MEET}"
echo -e "  TURN:       ${TURN}"
echo -e "  LXC IP:     ${LXC_IP}"
[[ -n "$EXTERNAL_IP" ]] && echo -e "  Public IP:  ${EXTERNAL_IP}"
echo

SETUP_SCRIPTS_DIR="${SETUP_DIR}/setup"
[[ ! -d "$SETUP_SCRIPTS_DIR" ]] && { error "Missing: $SETUP_SCRIPTS_DIR"; exit 1; }

for script in $(ls "$SETUP_SCRIPTS_DIR"/[0-9][0-9]-*.sh 2>/dev/null | sort); do
  name=$(basename "$script")
  header "$name"
  chmod +x "$script"
  if ! bash "$script"; then error "Failed: $name"; exit 1; fi
  log "$name complete"
done

header "Waiting for Synapse"
for i in {1..30}; do
  curl -fs http://127.0.0.1:8008/_matrix/client/versions >/dev/null 2>&1 && { log "Synapse responding"; break; }
  sleep 2
done

header "Matrix Admin Setup"
register_new_matrix_user -u "${ADMIN_USER}" -p "${ADMIN_PASS}" -a \
  -c /etc/matrix-synapse/homeserver.yaml http://127.0.0.1:8008 2>/dev/null || true
log "Admin account ready"

cat > /root/matrix.creds <<EOF
Matrix-Credentials
Admin username: ${ADMIN_USER}
Admin password: ${ADMIN_PASS}
EOF
chmod 600 /root/matrix.creds

header "Setup Complete"
echo -e "\n${GREEN}Stack running:${NC}"
echo "  Element:  https://${DOMAIN}"
echo "  Jitsi:    https://${MEET}"
echo "  API:      https://${DOMAIN}/_matrix/client/versions"
echo -e "\n${YELLOW}Admin:${NC} ${ADMIN_USER} / ${ADMIN_PASS}"
echo -e "\n${YELLOW}DNS Required (all → ${LXC_IP}):${NC}"
echo "  A  ${DOMAIN}    → ${LXC_IP}"
echo "  A  ${MEET} → ${LXC_IP}"
echo "  A  ${TURN} → ${LXC_IP}"
echo -e "\nSecrets: /root/matrix.env\n"
