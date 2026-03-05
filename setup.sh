#!/bin/bash
# =============================================================================
# setup.sh — Matrix Synapse + Element Web + Jitsi + Nginx Stack Configurator
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
# Password Generators
# ─────────────────────────────────────────────────────────────

gen_pass() { openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 40; }
gen_hex()  { openssl rand -hex 32; }

# ─────────────────────────────────────────────────────────────
# Defaults
# ─────────────────────────────────────────────────────────────

DOMAIN=""
ADMIN_USER="admin"
ADMIN_PASS=""
POSTGRES_PASS=""
VALKEY_PASS=""
JITSI_PASS=""
TURN_SECRET=""

SKIP_SSL=false
STAGING=false
RECONFIGURE=false

# ─────────────────────────────────────────────────────────────
# CLI Argument Parsing
# ─────────────────────────────────────────────────────────────

if [[ "${1:-}" == "--reset" ]]; then
    set -- --reconfigure
fi

while [[ $# -gt 0 ]]; do
case "$1" in
    --domain)        DOMAIN="$2"; shift 2 ;;
    --admin-user)    ADMIN_USER="$2"; shift 2 ;;
    --admin-pass)    ADMIN_PASS="$2"; shift 2 ;;
    --postgres-pass) POSTGRES_PASS="$2"; shift 2 ;;
    --valkey-pass)   VALKEY_PASS="$2"; shift 2 ;;
    --jitsi-pass)    JITSI_PASS="$2"; shift 2 ;;
    --turn-secret)   TURN_SECRET="$2"; shift 2 ;;
    --skip-ssl|--no-ssl) SKIP_SSL=true; shift ;;
    --staging)       STAGING=true; shift ;;
    --reconfigure)   RECONFIGURE=true; shift ;;
    --help|-h)
        sed -n '1,80p' "$0" | grep '^#' | sed 's/^# \{0,2\}//'
        exit 0
    ;;
    *)
        error "Unknown option: $1"
        exit 1
    ;;
esac
done

# ─────────────────────────────────────────────────────────────
# Validation
# ─────────────────────────────────────────────────────────────

[[ -z "$DOMAIN" ]] && { error "Required: --domain example.com"; exit 1; }
[[ $EUID -ne 0 ]] && { error "Must run as root"; exit 1; }

# ─────────────────────────────────────────────────────────────
# Generate Secrets
# ─────────────────────────────────────────────────────────────

[[ -z "$ADMIN_PASS" ]]    && ADMIN_PASS=$(gen_pass)
[[ -z "$POSTGRES_PASS" ]] && POSTGRES_PASS=$(gen_pass)
[[ -z "$VALKEY_PASS" ]]   && VALKEY_PASS=$(gen_pass)
[[ -z "$JITSI_PASS" ]]    && JITSI_PASS=$(gen_pass)
[[ -z "$TURN_SECRET" ]]   && TURN_SECRET=$(gen_hex)

MATRIX_SHARED_SECRET=$(gen_hex)
JITSI_APP_SECRET=$(gen_pass)

LXC_IP=$(hostname -I | awk '{print $1}')

MATRIX_DOMAIN="matrix.${DOMAIN}"
JITSI_DOMAIN="meet.${DOMAIN}"
ELEMENT_DOMAIN="${DOMAIN}"

# ─────────────────────────────────────────────────────────────
# Save Environment
# ─────────────────────────────────────────────────────────────

ENV_FILE="/root/.matrix-stack.env"

cat > "$ENV_FILE" <<EOF
DOMAIN=${DOMAIN}
MATRIX_DOMAIN=${MATRIX_DOMAIN}
JITSI_DOMAIN=${JITSI_DOMAIN}
ELEMENT_DOMAIN=${ELEMENT_DOMAIN}
LXC_IP=${LXC_IP}
ADMIN_USER=${ADMIN_USER}
ADMIN_PASS=${ADMIN_PASS}
POSTGRES_PASS=${POSTGRES_PASS}
VALKEY_PASS=${VALKEY_PASS}
JITSI_PASS=${JITSI_PASS}
TURN_SECRET=${TURN_SECRET}
MATRIX_SHARED_SECRET=${MATRIX_SHARED_SECRET}
JITSI_APP_SECRET=${JITSI_APP_SECRET}
SKIP_SSL=${SKIP_SSL}
STAGING=${STAGING}
SETUP_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

chmod 600 "$ENV_FILE"

set -a
source "$ENV_FILE"
set +a

# ─────────────────────────────────────────────────────────────
# Banner
# ─────────────────────────────────────────────────────────────

clear

echo
echo -e "${CYAN}${BOLD}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║   Matrix Synapse + Element Web + Jitsi Stack Setup  ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "  ${BOLD}Domain:${NC}       ${DOMAIN}"
echo -e "  ${BOLD}Element Web:${NC}  https://${ELEMENT_DOMAIN}"
echo -e "  ${BOLD}Matrix API:${NC}   https://${MATRIX_DOMAIN}"
echo -e "  ${BOLD}Jitsi Meet:${NC}   https://${JITSI_DOMAIN}"
echo -e "  ${BOLD}LXC IP:${NC}       ${LXC_IP}"
echo

# ─────────────────────────────────────────────────────────────
# Run Setup Scripts
# ─────────────────────────────────────────────────────────────

SETUP_SCRIPTS_DIR="${SETUP_DIR}/setup"

if [[ ! -d "$SETUP_SCRIPTS_DIR" ]]; then
error "Missing setup directory: $SETUP_SCRIPTS_DIR"
exit 1
fi

for script in $(ls "$SETUP_SCRIPTS_DIR"/[0-9][0-9]-*.sh | sort); do

    name=$(basename "$script")

    header "$name"

    chmod +x "$script"

    if ! bash "$script"; then
        error "Setup step failed: $name"
        exit 1
    fi

    log "$name complete"

done

# ─────────────────────────────────────────────────────────────
# Wait for Synapse
# ─────────────────────────────────────────────────────────────

header "Waiting for Synapse"

for i in {1..30}; do

    if curl -fs http://127.0.0.1:8008/_matrix/client/versions >/dev/null 2>&1; then
        log "Synapse is responding"
        break
    fi

    sleep 2

done

# ─────────────────────────────────────────────────────────────
# Ensure Admin User Exists
# ─────────────────────────────────────────────────────────────

header "Matrix Admin Setup"

ADMIN_EXISTS=$(sudo -u postgres psql -d synapse -tAc \
"SELECT 1 FROM users WHERE name='${ADMIN_USER}'")

if [[ "$ADMIN_EXISTS" == "1" ]]; then

    warn "Admin user exists — resetting password"

else

    info "Creating Matrix admin account"

fi

register_new_matrix_user \
-u "${ADMIN_USER}" \
-p "${ADMIN_PASS}" \
-a \
-c /etc/matrix-synapse/homeserver.yaml \
http://127.0.0.1:8008 || true

log "Admin account verified"

# ─────────────────────────────────────────────────────────────
# Final Output
# ─────────────────────────────────────────────────────────────

header "Setup Complete 🎉"

echo
echo -e "${GREEN}Matrix stack running at:${NC}"
echo
echo "Element Web:"
echo "https://${ELEMENT_DOMAIN}"
echo
echo "Matrix API:"
echo "https://${MATRIX_DOMAIN}"
echo
echo "Jitsi:"
echo "https://${JITSI_DOMAIN}"
echo

echo -e "${YELLOW}Matrix Admin:${NC}"
echo "User: ${ADMIN_USER}"
echo "Pass: ${ADMIN_PASS}"
echo

echo -e "${YELLOW}DNS Records Required:${NC}"
echo "A  ${ELEMENT_DOMAIN}  → ${LXC_IP}"
echo "A  ${MATRIX_DOMAIN}   → ${LXC_IP}"
echo "A  ${JITSI_DOMAIN}    → ${LXC_IP}"
echo "SRV _matrix._tcp.${DOMAIN} 10 0 443 ${MATRIX_DOMAIN}"
echo

echo "Credentials stored at:"
echo "$ENV_FILE"
echo
