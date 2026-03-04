#!/bin/bash
# =============================================================================
# scripts/list-users.sh
# List all users on this Matrix homeserver via the Admin API.
#
# Usage:
#   ./scripts/list-users.sh
#   ./scripts/list-users.sh --guests     # include guest accounts
#   ./scripts/list-users.sh --deactivated # include deactivated accounts
#   ./scripts/list-users.sh --csv        # output CSV
#   ADMIN_TOKEN=<tok> ./scripts/list-users.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

require_root
load_env
require_synapse
get_admin_token

SHOW_GUESTS=false
SHOW_DEACTIVATED=false
CSV_OUTPUT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --guests)      SHOW_GUESTS=true;      shift ;;
    --deactivated) SHOW_DEACTIVATED=true; shift ;;
    --csv)         CSV_OUTPUT=true;       shift ;;
    --help|-h)
      echo "Usage: $0 [--guests] [--deactivated] [--csv]"
      exit 0 ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
done

header "Matrix User List — ${DOMAIN}"
echo ""

FROM=0
LIMIT=100
TOTAL_PRINTED=0

if [[ "$CSV_OUTPUT" == true ]]; then
  echo "mxid,display_name,admin,deactivated,shadow_banned,creation_ts"
fi

while true; do
  QUERY="from=${FROM}&limit=${LIMIT}"
  [[ "$SHOW_GUESTS" == true ]]      && QUERY="${QUERY}&guests=true"
  [[ "$SHOW_DEACTIVATED" == true ]] && QUERY="${QUERY}&deactivated=true"

  RESPONSE=$(api_call GET "/_synapse/admin/v2/users?${QUERY}" 2>/dev/null) || {
    error "API call failed. Check your admin token."
    exit 1
  }

  # Extract user count in this page
  PAGE_COUNT=$(echo "$RESPONSE" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(len(d.get('users',[])))" 2>/dev/null)
  TOTAL=$(echo "$RESPONSE" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('total',0))" 2>/dev/null)

  if [[ "$CSV_OUTPUT" == true ]]; then
    echo "$RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for u in d.get('users', []):
    name        = u.get('name','')
    display     = u.get('displayname','').replace(',','_')
    admin       = str(u.get('admin', False)).lower()
    deactivated = str(u.get('deactivated', False)).lower()
    shadow      = str(u.get('shadow_banned', False)).lower()
    ts          = u.get('creation_ts', '')
    print(f'{name},{display},{admin},{deactivated},{shadow},{ts}')
"
  else
    echo "$RESPONSE" | python3 -c "
import sys, json, datetime
d = json.load(sys.stdin)
users = d.get('users', [])
for u in users:
    name     = u.get('name','')
    display  = u.get('displayname') or '(no display name)'
    admin    = ' [ADMIN]'    if u.get('admin') else ''
    deact    = ' [DEACTIVATED]' if u.get('deactivated') else ''
    shadow   = ' [SHADOW-BANNED]' if u.get('shadow_banned') else ''
    ts       = u.get('creation_ts', 0)
    try:
        created = datetime.datetime.fromtimestamp(ts/1000).strftime('%Y-%m-%d')
    except:
        created = '?'
    print(f'  {name:<40} {display:<25} created:{created}{admin}{deact}{shadow}')
"
  fi

  TOTAL_PRINTED=$((TOTAL_PRINTED + PAGE_COUNT))
  FROM=$((FROM + LIMIT))

  [[ $PAGE_COUNT -lt $LIMIT ]] && break
done

echo ""
if [[ "$CSV_OUTPUT" != true ]]; then
  log "Total users: ${TOTAL_PRINTED}"
  if [[ "$SHOW_GUESTS" == false ]]; then
    info "Tip: use --guests to include guest accounts, --deactivated for deactivated"
  fi
fi
echo ""
