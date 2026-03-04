#!/bin/bash
# =============================================================================
# scripts/user-manage.sh
# User account management: deactivate, reactivate, promote to admin,
# demote from admin, reset password, view account details.
#
# Usage:
#   ./scripts/user-manage.sh --user alice --action deactivate
#   ./scripts/user-manage.sh --user alice --action reactivate
#   ./scripts/user-manage.sh --user alice --action promote
#   ./scripts/user-manage.sh --user alice --action demote
#   ./scripts/user-manage.sh --user alice --action reset-password
#   ./scripts/user-manage.sh --user alice --action info
#   ./scripts/user-manage.sh --user alice --action shadow-ban
#   ADMIN_TOKEN=<tok> ./scripts/user-manage.sh ...
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

require_root
load_env
require_synapse

USERNAME=""
ACTION=""
NEW_PASS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user|-u)     USERNAME="$2";  shift 2 ;;
    --action|-a)   ACTION="$2";    shift 2 ;;
    --password|-p) NEW_PASS="$2";  shift 2 ;;
    --help|-h)
      cat <<EOF
Usage: $0 --user <username> --action <action>

Actions:
  info            Show account details
  deactivate      Disable account (user cannot log in)
  reactivate      Re-enable a deactivated account
  promote         Grant admin privileges
  demote          Remove admin privileges
  reset-password  Set a new password
  shadow-ban      Shadow-ban user (they can send, but others don't receive)
  logout-all      Invalidate all access tokens (force re-login everywhere)

Options:
  --user <username>    Username without @domain (or full MXID)
  --password <pass>    New password (for reset-password, prompted if omitted)
  ADMIN_TOKEN=<tok>    Set admin token via environment
EOF
      exit 0 ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
done

get_admin_token

# ── Normalise username ────────────────────────────────────────────────────────
if [[ -z "$USERNAME" ]]; then
  read -rp "Username (without @domain, or full MXID): " USERNAME
fi
USERNAME="${USERNAME,,}"
USERNAME="${USERNAME/@*/}"
USERNAME="${USERNAME//:*/}"
MXID="@${USERNAME}:${DOMAIN}"
ENCODED_MXID=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${MXID}'))")

if [[ -z "$ACTION" ]]; then
  echo ""
  echo "Available actions: info, deactivate, reactivate, promote, demote, reset-password, shadow-ban, logout-all"
  read -rp "Action: " ACTION
fi

header "User Management — ${MXID}"
echo ""

case "$ACTION" in

  # ── info ──────────────────────────────────────────────────────────────────
  info)
    info "Fetching account details..."
    RESP=$(api_call GET "/_synapse/admin/v2/users/${ENCODED_MXID}") || {
      error "Failed to fetch user info. User may not exist."; exit 1
    }
    echo "$RESP" | python3 -c "
import sys, json, datetime
u = json.load(sys.stdin)
ts = u.get('creation_ts', 0)
try:    created = datetime.datetime.fromtimestamp(ts/1000).strftime('%Y-%m-%d %H:%M:%S')
except: created = '?'
print(f\"  MXID:           {u.get('name')}\")
print(f\"  Display name:   {u.get('displayname') or '(not set)'}\")
print(f\"  Admin:          {u.get('admin', False)}\")
print(f\"  Deactivated:    {u.get('deactivated', False)}\")
print(f\"  Shadow banned:  {u.get('shadow_banned', False)}\")
print(f\"  Created:        {created}\")
print(f\"  Avatar URL:     {u.get('avatar_url') or '(not set)'}\")
# Devices
devs = u.get('devices', {}).get('devices', [])
if devs:
    print(f\"  Devices:        {len(devs)}\")
    for d in devs[:5]:
        print(f\"    - {d.get('device_id')}: {d.get('display_name','?')} (last seen: {d.get('last_seen_ts','?')})\")
    if len(devs) > 5:
        print(f\"    ... and {len(devs)-5} more\")
"
    ;;

  # ── deactivate ───────────────────────────────────────────────────────────
  deactivate)
    warn "This will deactivate @${USERNAME}:${DOMAIN}."
    warn "The user will be unable to log in. Their messages remain."
    read -rp "  Erase user data (rooms, messages)? [y/N]: " ERASE
    ERASE_BOOL="false"
    [[ "${ERASE,,}" == "y" ]] && ERASE_BOOL="true"
    read -rp "  Confirm deactivation [y/N]: " CONFIRM
    [[ "${CONFIRM,,}" != "y" ]] && { echo "Aborted."; exit 0; }

    api_call POST "/_synapse/admin/v1/deactivate/${ENCODED_MXID}" \
      "{\"erase\": ${ERASE_BOOL}}" | pp_json
    log "User @${USERNAME}:${DOMAIN} deactivated."
    ;;

  # ── reactivate ───────────────────────────────────────────────────────────
  reactivate)
    info "Reactivating @${USERNAME}:${DOMAIN}..."
    api_call PUT "/_synapse/admin/v2/users/${ENCODED_MXID}" \
      '{"deactivated": false}' | pp_json
    log "User reactivated. They may need a password reset to log in."
    ;;

  # ── promote ──────────────────────────────────────────────────────────────
  promote)
    info "Granting admin privileges to @${USERNAME}:${DOMAIN}..."
    api_call PUT "/_synapse/admin/v1/users/${ENCODED_MXID}/admin" \
      '{"admin": true}' | pp_json
    log "@${USERNAME}:${DOMAIN} is now an admin."
    ;;

  # ── demote ───────────────────────────────────────────────────────────────
  demote)
    warn "Removing admin privileges from @${USERNAME}:${DOMAIN}..."
    api_call PUT "/_synapse/admin/v1/users/${ENCODED_MXID}/admin" \
      '{"admin": false}' | pp_json
    log "@${USERNAME}:${DOMAIN} is no longer an admin."
    ;;

  # ── reset-password ───────────────────────────────────────────────────────
  reset-password)
    if [[ -z "$NEW_PASS" ]]; then
      read -rsp "  New password: " NEW_PASS; echo ""
      read -rsp "  Confirm:      " NEW_PASS2; echo ""
      [[ "$NEW_PASS" != "$NEW_PASS2" ]] && { error "Passwords do not match."; exit 1; }
    fi
    if [[ -z "$NEW_PASS" ]]; then
      NEW_PASS="$(openssl rand -base64 20 | tr -dc 'a-zA-Z0-9' | head -c 20)"
      warn "Generated password: ${NEW_PASS}"
    fi
    api_call POST "/_synapse/admin/v1/reset_password/${ENCODED_MXID}" \
      "{\"new_password\": \"${NEW_PASS}\", \"logout_devices\": true}" | pp_json
    log "Password reset for @${USERNAME}:${DOMAIN}"
    log "All existing sessions have been logged out."
    echo "  New password: ${NEW_PASS}"
    ;;

  # ── shadow-ban ───────────────────────────────────────────────────────────
  shadow-ban)
    warn "Shadow-banning @${USERNAME}:${DOMAIN}"
    warn "They can still send messages but recipients won't see them."
    read -rp "  Confirm [y/N]: " CONFIRM
    [[ "${CONFIRM,,}" != "y" ]] && { echo "Aborted."; exit 0; }
    api_call POST "/_synapse/admin/v1/users/${ENCODED_MXID}/shadow_ban" "" | pp_json
    log "User shadow-banned."
    ;;

  # ── logout-all ───────────────────────────────────────────────────────────
  logout-all)
    info "Invalidating all access tokens for @${USERNAME}:${DOMAIN}..."
    api_call POST "/_synapse/admin/v1/users/${ENCODED_MXID}/logout" "" | pp_json
    log "All sessions invalidated. User must log in again on all devices."
    ;;

  *)
    error "Unknown action: ${ACTION}"
    error "Valid actions: info, deactivate, reactivate, promote, demote, reset-password, shadow-ban, logout-all"
    exit 1
    ;;
esac

echo ""
