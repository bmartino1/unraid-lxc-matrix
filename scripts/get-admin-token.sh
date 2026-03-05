#!/bin/bash
# =============================================================================
# scripts/get-admin-token.sh
# Log in as the Matrix admin and retrieve an access token.
# Token is printed to stdout and optionally saved to /root/.matrix-stack.env
#
# Usage:
#   ./scripts/get-admin-token.sh
#   ./scripts/get-admin-token.sh --save   # save token to .env file
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_env
require_synapse

SAVE=false
[[ "${1:-}" == "--save" ]] && SAVE=true

header "Matrix Admin Token"
echo ""
info  "Logging in as @${ADMIN_USER}:${DOMAIN}..."
echo ""

RESPONSE=$(curl -sf -X POST \
  -H "Content-Type: application/json" \
  -d "{
    \"type\": \"m.login.password\",
    \"user\": \"${ADMIN_USER}\",
    \"password\": \"${ADMIN_PASS}\",
    \"initial_device_display_name\": \"admin-script-$(date +%s)\"
  }" \
  "${SYNAPSE_URL}/_matrix/client/v3/login" 2>/dev/null) || {
  error "Login request failed. Check Synapse is running and credentials are correct."
  exit 1
}

ACCESS_TOKEN=$(echo "$RESPONSE" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)

if [[ -z "$ACCESS_TOKEN" ]]; then
  error "Failed to extract access token from response:"
  echo "$RESPONSE" | pp_json
  exit 1
fi

echo -e "  ${GREEN}Access token retrieved successfully.${NC}"
echo ""
echo -e "  ${BOLD}Token:${NC}"
echo "  ${ACCESS_TOKEN}"
echo ""

if [[ "$SAVE" == "true" ]]; then
  # Update or append ADMIN_TOKEN in the env file
  if grep -q "^ADMIN_TOKEN=" /root/.matrix-stack.env; then
    sed -i "s|^ADMIN_TOKEN=.*|ADMIN_TOKEN=${ACCESS_TOKEN}|" /root/.matrix-stack.env
  else
    echo "ADMIN_TOKEN=${ACCESS_TOKEN}" >> /root/.matrix-stack.env
  fi
  log "Token saved to /root/.matrix-stack.env as ADMIN_TOKEN"
  warn "Token expires when you log out or the session is invalidated."
fi

echo ""
info "To use this token in other scripts, either:"
echo "  1. Run with --save and re-source the env file"
echo "  2. Export manually: export ADMIN_TOKEN=${ACCESS_TOKEN}"
echo "  3. Pass inline:    ADMIN_TOKEN=${ACCESS_TOKEN} ./scripts/list-users.sh"
echo ""
