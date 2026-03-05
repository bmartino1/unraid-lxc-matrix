#!/bin/bash
# =============================================================================
# lib/common.sh — Shared functions for all matrix-stack admin scripts
# Source this file: source "$(dirname "$0")/lib/common.sh"
# =============================================================================

# ── Colour output ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
error()  { echo -e "${RED}[✗]${NC} $*" >&2; }
info()   { echo -e "${BLUE}[→]${NC} $*"; }
header() { echo -e "\n${CYAN}${BOLD}══ $* ══${NC}"; }

# ── Load environment ──────────────────────────────────────────────────────────
load_env() {
  local ENV_FILE="${1:-/root/matrix.env}"
  if [[ ! -f "$ENV_FILE" ]]; then
    error "Environment file not found: $ENV_FILE"
    error "Run setup.sh --domain yourdomain.com first."
    exit 1
  fi
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

# ── Require root ──────────────────────────────────────────────────────────────
require_root() {
  if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root."
    exit 1
  fi
}

# ── Synapse Admin API base ────────────────────────────────────────────────────
SYNAPSE_URL="http://127.0.0.1:8008"
SYNAPSE_ADMIN_API="${SYNAPSE_URL}/_synapse/admin/v1"
SYNAPSE_ADMIN_API_V2="${SYNAPSE_URL}/_synapse/admin/v2"

# ── Check Synapse is running ──────────────────────────────────────────────────
require_synapse() {
  local HTTP_CODE
  # Try /health first (if metrics listener enabled), then the main client API
  HTTP_CODE=$(curl -so /dev/null -w "%{http_code}" \
    "${SYNAPSE_URL}/health" 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" != "200" ]]; then
    HTTP_CODE=$(curl -so /dev/null -w "%{http_code}" \
      "${SYNAPSE_URL}/_matrix/client/versions" 2>/dev/null || echo "000")
  fi
  if [[ "$HTTP_CODE" != "200" ]]; then
    error "Matrix Synapse is not responding (HTTP ${HTTP_CODE})."
    error "Check: systemctl status matrix-synapse"
    exit 1
  fi
}

# ── Get or create admin token ─────────────────────────────────────────────────
# Checks: ADMIN_TOKEN in env → saved in .env file → auto-login with credentials
get_admin_token() {
  # 1. Already set in current environment
  if [[ -n "${ADMIN_TOKEN:-}" ]]; then
    export ADMIN_TOKEN
    return 0
  fi

  # 2. Try auto-login using ADMIN_USER + ADMIN_PASS from .env
  if [[ -n "${ADMIN_USER:-}" && -n "${ADMIN_PASS:-}" ]]; then
    local LOGIN_RESP
    LOGIN_RESP=$(curl -sf -X POST \
      -H "Content-Type: application/json" \
      -d "{
        \"type\": \"m.login.password\",
        \"user\": \"${ADMIN_USER}\",
        \"password\": \"${ADMIN_PASS}\",
        \"initial_device_display_name\": \"admin-script-$(date +%s)\"
      }" \
      "${SYNAPSE_URL}/_matrix/client/v3/login" 2>/dev/null) || true

    if [[ -n "$LOGIN_RESP" ]]; then
      ADMIN_TOKEN=$(echo "$LOGIN_RESP" | python3 -c \
        "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
    fi

    if [[ -n "${ADMIN_TOKEN:-}" ]]; then
      export ADMIN_TOKEN
      # Save token to .env for reuse within this session
      if [[ -f /root/matrix.env ]]; then
        if grep -q "^ADMIN_TOKEN=" /root/matrix.env; then
          sed -i "s|^ADMIN_TOKEN=.*|ADMIN_TOKEN=${ADMIN_TOKEN}|" /root/matrix.env
        else
          echo "ADMIN_TOKEN=${ADMIN_TOKEN}" >> /root/matrix.env
        fi
      fi
      return 0
    fi
  fi

  # 3. Fallback: prompt user to paste a token
  echo ""
  warn "Could not auto-login. No ADMIN_TOKEN available."
  echo "  Get your token: Element Web → Settings → Help & About → Access Token"
  echo "  Or run: ./scripts/get-admin-token.sh --save"
  echo ""
  read -rsp "  Paste admin access token: " ADMIN_TOKEN
  echo ""
  export ADMIN_TOKEN
}

# ── Make authenticated API call ───────────────────────────────────────────────
# Usage: api_call GET /path | api_call POST /path '{"json":"body"}'
api_call() {
  local METHOD="$1"
  local ENDPOINT="$2"
  local BODY="${3:-}"
  local URL="${SYNAPSE_URL}${ENDPOINT}"

  if [[ -n "$BODY" ]]; then
    curl -sf -X "$METHOD" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$BODY" \
      "$URL"
  else
    curl -sf -X "$METHOD" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      "$URL"
  fi
}

# ── Pretty-print JSON ─────────────────────────────────────────────────────────
pp_json() {
  python3 -m json.tool 2>/dev/null || cat
}
