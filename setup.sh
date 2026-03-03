#!/bin/bash
# =============================================================================
# Unraid LXC - Matrix Synapse + Element Web + Jitsi + Nginx Full Stack
# =============================================================================
# Usage:
#   ./setup.sh --domain example.com [OPTIONS]
#
# Options:
#   --domain <domain>         Required. Your public domain (e.g. example.com)
#   --admin-user <username>   Matrix admin username (default: admin)
#   --admin-pass <password>   Matrix admin password (auto-generated if omitted)
#   --jitsi-pass <password>   Jitsi XMPP component password (auto-generated)
#   --turn-secret <secret>    TURN server secret (auto-generated if omitted)
#   --postgres-pass <pass>    PostgreSQL password (auto-generated if omitted)
#   --valkey-pass <pass>      Valkey/Redis password (auto-generated if omitted)
#   --skip-ssl                Skip Let's Encrypt / use self-signed certs
#   --staging                 Use Let's Encrypt staging (for testing)
#   --help                    Show this help
#
# What this does:
#   1. Installs PostgreSQL, Valkey, Matrix Synapse, Element Web, Jitsi Meet,
#      coturn (TURN server), and Nginx inside a Debian 12 (Bookworm) LXC.
#   2. Configures all services to work together on the LXC IP.
#   3. Nginx listens on 80/443 with SNI stream routing:
#        - 443 TLS passthrough -> coturn (TURN/STUN for Jitsi)
#        - 443 SNI -> Jitsi Meet (HTTPS)
#        - 443 SNI -> Matrix Synapse / Element Web (HTTPS)
#   4. Writes all config files, systemd units, and secrets.
#
# Architecture:
#   [Client] -> Nginx :80/:443
#                 |-- SNI: matrix.<domain> / <domain>  -> Element Web + Synapse
#                 |-- SNI: jitsi.<domain>               -> Jitsi Meet
#                 |-- TURN/STUN passthrough             -> coturn :3478/5349
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────────
DOMAIN=""
ADMIN_USER="admin"
ADMIN_PASS=""
JITSI_PASS=""
TURN_SECRET=""
POSTGRES_PASS=""
VALKEY_PASS=""
SKIP_SSL=false
STAGING=false

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header() { echo -e "\n${BLUE}══════════════════════════════════════════${NC}"; \
           echo -e "${CYAN}  $*${NC}"; \
           echo -e "${BLUE}══════════════════════════════════════════${NC}"; }

gen_pass() { openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32; }

usage() {
  grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,2\}//' | head -40
  exit 0
}

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)      DOMAIN="$2";        shift 2 ;;
    --admin-user)  ADMIN_USER="$2";    shift 2 ;;
    --admin-pass)  ADMIN_PASS="$2";    shift 2 ;;
    --jitsi-pass)  JITSI_PASS="$2";    shift 2 ;;
    --turn-secret) TURN_SECRET="$2";   shift 2 ;;
    --postgres-pass) POSTGRES_PASS="$2"; shift 2 ;;
    --valkey-pass) VALKEY_PASS="$2";   shift 2 ;;
    --skip-ssl)    SKIP_SSL=true;      shift   ;;
    --staging)     STAGING=true;       shift   ;;
    --help|-h)     usage ;;
    *) error "Unknown option: $1"; usage ;;
  esac
done

# ── Validate ──────────────────────────────────────────────────────────────────
if [[ -z "$DOMAIN" ]]; then
  error "A --domain is required."
  echo "  Example: ./setup.sh --domain example.com"
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root inside the LXC container."
  exit 1
fi

# ── Auto-generate secrets if not provided ─────────────────────────────────────
[[ -z "$ADMIN_PASS"    ]] && ADMIN_PASS="$(gen_pass)"
[[ -z "$JITSI_PASS"    ]] && JITSI_PASS="$(gen_pass)"
[[ -z "$TURN_SECRET"   ]] && TURN_SECRET="$(gen_pass)"
[[ -z "$POSTGRES_PASS" ]] && POSTGRES_PASS="$(gen_pass)"
[[ -z "$VALKEY_PASS"   ]] && VALKEY_PASS="$(gen_pass)"

MATRIX_SHARED_SECRET="$(gen_pass)"
JITSI_APP_SECRET="$(gen_pass)"

# Sub-domains
MATRIX_DOMAIN="matrix.${DOMAIN}"
JITSI_DOMAIN="meet.${DOMAIN}"
ELEMENT_DOMAIN="${DOMAIN}"

# ── Save config for re-runs ───────────────────────────────────────────────────
ENV_FILE="/root/.matrix-stack.env"
cat > "$ENV_FILE" <<EOF
DOMAIN=${DOMAIN}
MATRIX_DOMAIN=${MATRIX_DOMAIN}
JITSI_DOMAIN=${JITSI_DOMAIN}
ELEMENT_DOMAIN=${ELEMENT_DOMAIN}
ADMIN_USER=${ADMIN_USER}
ADMIN_PASS=${ADMIN_PASS}
JITSI_PASS=${JITSI_PASS}
TURN_SECRET=${TURN_SECRET}
POSTGRES_PASS=${POSTGRES_PASS}
VALKEY_PASS=${VALKEY_PASS}
MATRIX_SHARED_SECRET=${MATRIX_SHARED_SECRET}
JITSI_APP_SECRET=${JITSI_APP_SECRET}
SKIP_SSL=${SKIP_SSL}
STAGING=${STAGING}
EOF
chmod 600 "$ENV_FILE"
log "Configuration saved to $ENV_FILE"

# ── Run staged build scripts ──────────────────────────────────────────────────
header "Matrix Synapse / Element / Jitsi Stack Installer"
log "Domain:         $DOMAIN"
log "Matrix:         https://${MATRIX_DOMAIN}"
log "Element Web:    https://${ELEMENT_DOMAIN}"
log "Jitsi Meet:     https://${JITSI_DOMAIN}"
echo ""

BUILD_DIR="${SCRIPT_DIR}/build"
BUILD_SCRIPTS=$(ls -1 "${BUILD_DIR}/" | grep '^[0-9][0-9]-' | sort)

for script in $BUILD_SCRIPTS; do
  header "Stage: $script"
  chmod +x "${BUILD_DIR}/${script}"
  # Export all vars so child scripts can use them
  export DOMAIN MATRIX_DOMAIN JITSI_DOMAIN ELEMENT_DOMAIN \
         ADMIN_USER ADMIN_PASS JITSI_PASS TURN_SECRET \
         POSTGRES_PASS VALKEY_PASS MATRIX_SHARED_SECRET \
         JITSI_APP_SECRET SKIP_SSL STAGING SCRIPT_DIR
  bash "${BUILD_DIR}/${script}"
  EXIT_STATUS=$?
  if [[ $EXIT_STATUS -ne 0 ]]; then
    error "Build script ${script} failed with exit code ${EXIT_STATUS}. Aborting."
    exit 1
  fi
  log "✓ ${script} completed successfully"
done

# ── Final summary ─────────────────────────────────────────────────────────────
header "✅ Installation Complete!"
LXC_IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${GREEN}Stack is running on LXC IP: ${CYAN}${LXC_IP}${NC}"
echo ""
echo -e "  Element Web:   ${CYAN}https://${ELEMENT_DOMAIN}${NC}"
echo -e "  Matrix API:    ${CYAN}https://${MATRIX_DOMAIN}${NC}"
echo -e "  Jitsi Meet:    ${CYAN}https://${JITSI_DOMAIN}${NC}"
echo ""
echo -e "${YELLOW}Matrix Admin Credentials:${NC}"
echo -e "  Username:  ${ADMIN_USER}"
echo -e "  Password:  ${ADMIN_PASS}"
echo ""
echo -e "${YELLOW}DNS Records required (point to LXC IP: ${LXC_IP}):${NC}"
echo -e "  A  ${ELEMENT_DOMAIN}       -> ${LXC_IP}"
echo -e "  A  ${MATRIX_DOMAIN}  -> ${LXC_IP}"
echo -e "  A  ${JITSI_DOMAIN}    -> ${LXC_IP}"
echo ""
echo -e "  _matrix._tcp.${DOMAIN}  SRV  10 0 443 ${MATRIX_DOMAIN}"
echo ""
echo -e "${YELLOW}Credentials saved to:${NC} ${ENV_FILE}"
echo ""
