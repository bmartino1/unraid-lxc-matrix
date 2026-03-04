#!/bin/bash
# =============================================================================
# lib/common.sh — Shared functions for all matrix-stack admin scripts
# Source this file: source "$(dirname "$0")/../lib/common.sh"
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
  local ENV_FILE="${1:-/root/.matrix-stack.env}"
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
  HTTP_CODE=$(curl -so /dev/null -w "%{http_code}" \
    "${SYNAPSE_URL}/health" 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" != "200" ]]; then
    error "Matrix Synapse is not responding (HTTP ${HTTP_CODE})."
    error "Check: systemctl status matrix-synapse"
    exit 1
  fi
}

# ── Prompt for admin token if not set ────────────────────────────────────────
get_admin_token() {
  if [[ -z "${ADMIN_TOKEN:-}" ]]; then
    echo ""
    warn "No ADMIN_TOKEN found in environment."
    echo "  Get your token: Element Web → Username → Settings → Help & About → Access Token"
    echo "  Or run: scripts/get-admin-token.sh"
    echo ""
    read -rsp "  Paste admin access token: " ADMIN_TOKEN
    echo ""
    export ADMIN_TOKEN
  fi
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
