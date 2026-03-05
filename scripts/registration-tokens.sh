#!/bin/bash
# =============================================================================
# scripts/registration-tokens.sh
# Manage Matrix registration tokens (invite-only registration control).
# Users need a token to register when open registration is disabled.
#
# Usage:
#   ./scripts/registration-tokens.sh list
#   ./scripts/registration-tokens.sh create [--uses 1] [--expiry 7d]
#   ./scripts/registration-tokens.sh create --token MYTOKEN --uses 5
#   ./scripts/registration-tokens.sh delete --token TOKEN
#   ./scripts/registration-tokens.sh info   --token TOKEN
#   ADMIN_TOKEN=<tok> ./scripts/registration-tokens.sh list
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_env
require_synapse
get_admin_token

SUBCOMMAND="${1:-list}"
shift || true

CUSTOM_TOKEN=""
MAX_USES=1
EXPIRY_DAYS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token|-t)  CUSTOM_TOKEN="$2"; shift 2 ;;
    --uses|-n)   MAX_USES="$2";     shift 2 ;;
    --expiry|-e) EXPIRY_DAYS="$2";  shift 2 ;;  # e.g. 7 = 7 days, 0 = no expiry
    --help|-h)
      cat <<EOF
Usage: $0 <command> [options]

Commands:
  list                    List all active registration tokens
  create                  Create a new registration token
  delete --token TOKEN    Delete (invalidate) a token
  info   --token TOKEN    Show details of a specific token

Options for create:
  --token  TOKEN   Custom token string (auto-generated if omitted)
  --uses   N       Max number of uses (default: 1, 0 = unlimited)
  --expiry DAYS    Token valid for N days (default: 0 = never expires)

Share registration link:
  https://${ELEMENT_DOMAIN:-yourdomain.com}/#/register?token=TOKEN
EOF
      exit 0 ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
done

header "Registration Tokens — ${DOMAIN}"
echo ""

case "$SUBCOMMAND" in

  # ── list ─────────────────────────────────────────────────────────────────
  list)
    RESP=$(api_call GET "/_synapse/admin/v1/registration_tokens") || {
      error "API call failed."; exit 1
    }
    COUNT=$(echo "$RESP" | python3 -c \
      "import sys,json; print(len(json.load(sys.stdin).get('registration_tokens',[])))")

    if [[ "$COUNT" == "0" ]]; then
      info "No registration tokens exist."
      echo "  Create one with: $0 create"
    else
      echo "$RESP" | python3 -c "
import sys, json, datetime
d = json.load(sys.stdin)
tokens = d.get('registration_tokens', [])
hdr_token = 'TOKEN'
hdr_uses = 'USES'
hdr_expiry = 'EXPIRY'
print(f'  {hdr_token:<30} {hdr_uses:<15} {hdr_expiry:<22} STATUS')
print('  ' + '-'*80)
for t in tokens:
    tok      = t.get('token', '')
    used     = t.get('uses_allowed', 0)
    pending  = t.get('pending', 0)
    completed= t.get('completed', 0)
    exp_ts   = t.get('expiry_time')
    if used is None:
        uses_str = f'{completed} used / unlimited'
    else:
        remaining = used - completed - pending
        uses_str = f'{completed}/{used} used ({remaining} left)'
    if exp_ts:
        try:
            exp_str = datetime.datetime.fromtimestamp(exp_ts/1000).strftime('%Y-%m-%d %H:%M')
        except:
            exp_str = str(exp_ts)
    else:
        exp_str = 'never'
    expired = exp_ts and exp_ts < int(__import__('time').time() * 1000)
    status  = 'EXPIRED' if expired else 'active'
    print(f'  {tok:<30} {uses_str:<15} {exp_str:<22} {status}')
"
    fi
    echo ""
    log "Total: ${COUNT} token(s)"
    echo ""
    info "Share registration link:"
    echo "  https://${ELEMENT_DOMAIN}/#/register?token=<TOKEN>"
    ;;

  # ── create ───────────────────────────────────────────────────────────────
  create)
    BODY_PARTS=""

    if [[ -n "$CUSTOM_TOKEN" ]]; then
      BODY_PARTS="\"token\": \"${CUSTOM_TOKEN}\""
    fi

    if [[ "$MAX_USES" -gt 0 ]]; then
      [[ -n "$BODY_PARTS" ]] && BODY_PARTS="${BODY_PARTS}, "
      BODY_PARTS="${BODY_PARTS}\"uses_allowed\": ${MAX_USES}"
    fi

    if [[ "$EXPIRY_DAYS" -gt 0 ]]; then
      EXPIRY_MS=$(( $(date +%s%3N) + EXPIRY_DAYS * 86400000 ))
      [[ -n "$BODY_PARTS" ]] && BODY_PARTS="${BODY_PARTS}, "
      BODY_PARTS="${BODY_PARTS}\"expiry_time\": ${EXPIRY_MS}"
    fi

    BODY="{${BODY_PARTS}}"
    info "Creating token... (body: ${BODY})"

    RESP=$(api_call POST "/_synapse/admin/v1/registration_tokens/new" "$BODY") || {
      error "Failed to create token."; exit 1
    }

    TOKEN=$(echo "$RESP" | python3 -c \
      "import sys,json; print(json.load(sys.stdin).get('token',''))")

    echo ""
    log "Registration token created: ${TOKEN}"
    echo ""
    echo -e "  ${BOLD}Token:${NC}        ${TOKEN}"
    echo -e "  ${BOLD}Max uses:${NC}     $([[ $MAX_USES -eq 0 ]] && echo 'unlimited' || echo $MAX_USES)"
    echo -e "  ${BOLD}Expires:${NC}      $([[ $EXPIRY_DAYS -eq 0 ]] && echo 'never' || echo "in ${EXPIRY_DAYS} days")"
    echo ""
    echo -e "  ${BOLD}Registration URL:${NC}"
    echo "  https://${ELEMENT_DOMAIN}/#/register?token=${TOKEN}"
    echo ""
    info "Share the URL above with users you want to invite."
    ;;

  # ── delete ───────────────────────────────────────────────────────────────
  delete)
    if [[ -z "$CUSTOM_TOKEN" ]]; then
      read -rp "  Token to delete: " CUSTOM_TOKEN
    fi
    [[ -z "$CUSTOM_TOKEN" ]] && { error "Token required."; exit 1; }

    read -rp "  Delete token '${CUSTOM_TOKEN}'? [y/N]: " CONFIRM
    [[ "${CONFIRM,,}" != "y" ]] && { echo "Aborted."; exit 0; }

    api_call DELETE "/_synapse/admin/v1/registration_tokens/${CUSTOM_TOKEN}" | pp_json
    log "Token '${CUSTOM_TOKEN}' deleted."
    ;;

  # ── info ─────────────────────────────────────────────────────────────────
  info)
    if [[ -z "$CUSTOM_TOKEN" ]]; then
      read -rp "  Token to look up: " CUSTOM_TOKEN
    fi
    [[ -z "$CUSTOM_TOKEN" ]] && { error "Token required."; exit 1; }

    RESP=$(api_call GET "/_synapse/admin/v1/registration_tokens/${CUSTOM_TOKEN}") || {
      error "Token not found or API error."; exit 1
    }
    echo "$RESP" | pp_json
    ;;

  *)
    error "Unknown subcommand: ${SUBCOMMAND}"
    echo "Valid: list, create, delete, info"
    exit 1
    ;;
esac
