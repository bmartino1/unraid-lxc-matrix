#!/bin/bash
# =============================================================================
# scripts/create-user.sh
# Create a new Matrix user on this homeserver.
# Uses the Synapse shared secret (no admin token needed).
#
# Usage:
#   ./scripts/create-user.sh
#   ./scripts/create-user.sh --username alice --password s3cr3t
#   ./scripts/create-user.sh --username alice --password s3cr3t --admin
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_env
require_synapse

# ── Defaults ──────────────────────────────────────────────────────────────────
USERNAME=""
PASSWORD=""
IS_ADMIN=false

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --username|-u) USERNAME="$2"; shift 2 ;;
    --password|-p) PASSWORD="$2"; shift 2 ;;
    --admin|-a)    IS_ADMIN=true; shift   ;;
    --help|-h)
      echo "Usage: $0 [--username <user>] [--password <pass>] [--admin]"
      exit 0 ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
done

header "Create Matrix User"
echo ""

# ── Interactive prompts if not provided ──────────────────────────────────────
if [[ -z "$USERNAME" ]]; then
  read -rp "  Username (without @domain): " USERNAME
fi
if [[ -z "$USERNAME" ]]; then
  error "Username cannot be empty."; exit 1
fi

# Sanitise - lowercase, strip @domain if user pasted full MXID
USERNAME="${USERNAME,,}"
USERNAME="${USERNAME/@*/}"
USERNAME="${USERNAME//:*/}"

if [[ -z "$PASSWORD" ]]; then
  read -rsp "  Password: " PASSWORD; echo ""
  read -rsp "  Confirm password: " PASSWORD2; echo ""
  if [[ "$PASSWORD" != "$PASSWORD2" ]]; then
    error "Passwords do not match."; exit 1
  fi
fi
if [[ -z "$PASSWORD" ]]; then
  # Auto-generate if blank
  PASSWORD="$(openssl rand -base64 20 | tr -dc 'a-zA-Z0-9' | head -c 20)"
  warn "No password provided — generated: ${PASSWORD}"
fi

if [[ "$IS_ADMIN" == false ]]; then
  read -rp "  Make this user an admin? [y/N]: " ADMIN_ANS
  [[ "${ADMIN_ANS,,}" == "y" ]] && IS_ADMIN=true
fi

echo ""
info "Creating user @${USERNAME}:${DOMAIN}..."

ADMIN_FLAG=""
[[ "$IS_ADMIN" == true ]] && ADMIN_FLAG="-a"

# Find register_new_matrix_user — may be in venv or system PATH
REGISTER_CMD="register_new_matrix_user"
if [[ -x "/opt/venvs/matrix-synapse/bin/register_new_matrix_user" ]]; then
  REGISTER_CMD="/opt/venvs/matrix-synapse/bin/register_new_matrix_user"
elif ! command -v register_new_matrix_user >/dev/null 2>&1; then
  error "register_new_matrix_user not found in PATH or /opt/venvs/matrix-synapse/bin/"
  error "Try: /opt/venvs/matrix-synapse/bin/register_new_matrix_user"
  exit 1
fi

$REGISTER_CMD \
  -c /etc/matrix-synapse/homeserver.yaml \
  -u "${USERNAME}" \
  -p "${PASSWORD}" \
  ${ADMIN_FLAG} \
  "http://127.0.0.1:8008" 2>&1

EXIT_CODE=$?

echo ""
if [[ $EXIT_CODE -eq 0 ]]; then
  log "User created: @${USERNAME}:${DOMAIN}"
  [[ "$IS_ADMIN" == true ]] && log "User has admin privileges."
  echo ""
  echo -e "  ${BOLD}Full MXID:${NC}  @${USERNAME}:${DOMAIN}"
  echo -e "  ${BOLD}Password:${NC}   ${PASSWORD}"
  echo -e "  ${BOLD}Login at:${NC}   https://${DOMAIN}"
else
  error "User creation failed (exit ${EXIT_CODE})"
  error "The user may already exist. Try: scripts/list-users.sh"
fi
echo ""
