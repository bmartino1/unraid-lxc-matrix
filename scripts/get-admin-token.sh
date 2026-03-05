#!/bin/bash
# =============================================================================
# scripts/get-admin-token.sh
# Log in as the Matrix admin and retrieve an access token.
# Token is saved to /root/matrix.env by default.
#
# Usage:
#   ./scripts/get-admin-token.sh            # login + save token
#   ./scripts/get-admin-token.sh --no-save  # login + print only (don't save)
#   ./scripts/get-admin-token.sh --save     # (same as default, explicit)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Parse flags before any require_ calls
SAVE=true
for arg in "$@"; do
  case "$arg" in
    --no-save)  SAVE=false ;;
    --save)     SAVE=true  ;;
    --help|-h)
      echo "Usage: $0 [--save|--no-save]"
      echo "  --save      Save token to .env file (default)"
      echo "  --no-save   Print token only, don't save"
      exit 0 ;;
  esac
done

require_root
load_env
require_synapse

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
  if grep -q "^ADMIN_TOKEN=" /root/matrix.env; then
    sed -i "s|^ADMIN_TOKEN=.*|ADMIN_TOKEN=${ACCESS_TOKEN}|" /root/matrix.env
  else
    echo "ADMIN_TOKEN=${ACCESS_TOKEN}" >> /root/matrix.env
  fi
  log "Token saved to /root/matrix.env"
else
  info "Token NOT saved (--no-save). To save, run without --no-save."
fi

echo ""
info "Other scripts will auto-login using your admin credentials."
info "You can also pass a token manually:"
echo "  ADMIN_TOKEN=${ACCESS_TOKEN} ./scripts/list-users.sh"
echo ""
