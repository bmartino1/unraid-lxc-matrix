#!/bin/bash
# =============================================================================
# scripts/room-manage.sh
# Room administration: list rooms, view details, delete rooms, purge history.
#
# Usage:
#   ./scripts/room-manage.sh list
#   ./scripts/room-manage.sh list --search "general"
#   ./scripts/room-manage.sh info  --room '!roomid:domain'
#   ./scripts/room-manage.sh delete --room '!roomid:domain'
#   ./scripts/room-manage.sh purge  --room '!roomid:domain' --before 30d
#   ADMIN_TOKEN=<tok> ./scripts/room-manage.sh list
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_env
require_synapse
get_admin_token

SUBCOMMAND="${1:-list}"
shift || true

ROOM_ID=""
SEARCH=""
BEFORE_DAYS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --room|-r)   ROOM_ID="$2";    shift 2 ;;
    --search|-s) SEARCH="$2";     shift 2 ;;
    --before|-b) BEFORE_DAYS="$2"; shift 2 ;;
    --help|-h)
      cat <<EOF
Usage: $0 <command> [options]

Commands:
  list [--search TEXT]           List all rooms (optional name filter)
  info --room ROOM_ID            Show room details and members
  delete --room ROOM_ID          Shutdown and delete a room
  purge  --room ROOM_ID          Purge old messages from a room
         [--before DAYS]         Purge messages older than N days (default: 30)
  members --room ROOM_ID         List room members

ROOM_ID format: !roomid:domain (copy from room settings in Element)
EOF
      exit 0 ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
done

header "Room Management — ${DOMAIN}"
echo ""

case "$SUBCOMMAND" in

  # ── list ─────────────────────────────────────────────────────────────────
  list)
    QUERY="order_by=joined_members&dir=b&limit=50"
    [[ -n "$SEARCH" ]] && QUERY="${QUERY}&search_term=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${SEARCH}'))")"

    RESP=$(api_call GET "/_synapse/admin/v1/rooms?${QUERY}") || {
      error "API call failed."; exit 1
    }

    echo "$RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
rooms = d.get('rooms', [])
total = d.get('total_rooms', len(rooms))
hdr_rid = 'ROOM ID'
hdr_name = 'NAME'
hdr_mem = 'MEMBERS'
hdr_loc = 'LOCAL'
print(f'  {hdr_rid:<35} {hdr_name:<35} {hdr_mem:>7} {hdr_loc:>6}')
print('  ' + '-'*85)
for r in rooms:
    rid     = r.get('room_id','')
    name    = (r.get('name') or r.get('canonical_alias') or '(unnamed)')[:34]
    members = r.get('joined_members', 0)
    local   = r.get('joined_local_members', 0)
    print(f'  {rid:<35} {name:<35} {members:>7} {local:>6}')
print()
print(f'  Total rooms: {total}')
"
    ;;

  # ── info ─────────────────────────────────────────────────────────────────
  info)
    [[ -z "$ROOM_ID" ]] && { read -rp "Room ID (!room:domain): " ROOM_ID; }
    ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${ROOM_ID}'))")

    RESP=$(api_call GET "/_synapse/admin/v1/rooms/${ENCODED}") || {
      error "Room not found or API error."; exit 1
    }

    echo "$RESP" | python3 -c "
import sys, json
r = json.load(sys.stdin)
print(f\"  Room ID:          {r.get('room_id')}\")
print(f\"  Name:             {r.get('name') or '(not set)'}\")
print(f\"  Alias:            {r.get('canonical_alias') or '(not set)'}\")
print(f\"  Topic:            {r.get('topic') or '(not set)'}\")
print(f\"  Creator:          {r.get('creator')}\")
print(f\"  Encryption:       {r.get('encryption') or 'none'}\")
print(f\"  Public:           {r.get('public', False)}\")
print(f\"  Federated:        {not r.get('is_federatable', True) and 'no' or 'yes'}\")
print(f\"  Members total:    {r.get('joined_members', 0)}\")
print(f\"  Members local:    {r.get('joined_local_members', 0)}\")
print(f\"  State events:     {r.get('state_events', 0)}\")
print(f\"  Version:          {r.get('version', '?')}\")
"
    ;;

  # ── members ──────────────────────────────────────────────────────────────
  members)
    [[ -z "$ROOM_ID" ]] && { read -rp "Room ID (!room:domain): " ROOM_ID; }
    ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${ROOM_ID}'))")

    RESP=$(api_call GET "/_synapse/admin/v1/rooms/${ENCODED}/members") || {
      error "API error."; exit 1
    }

    echo "$RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
members = d.get('members', [])
total   = d.get('total', len(members))
print(f'  Members in room ({total} total):')
for m in members:
    print(f'    {m}')
"
    ;;

  # ── delete ───────────────────────────────────────────────────────────────
  delete)
    [[ -z "$ROOM_ID" ]] && { read -rp "Room ID to delete (!room:domain): " ROOM_ID; }
    warn "This will shut down and delete room: ${ROOM_ID}"
    warn "All local members will be removed. This cannot be undone."
    read -rp "  Confirm deletion [y/N]: " CONFIRM
    [[ "${CONFIRM,,}" != "y" ]] && { echo "Aborted."; exit 0; }
    read -rp "  New room for members to be redirected to (leave blank for none): " NEW_ROOM

    BODY="{\"block\": true, \"purge\": true"
    [[ -n "$NEW_ROOM" ]] && BODY="${BODY}, \"new_room_user_id\": \"@${ADMIN_USER}:${DOMAIN}\", \"message\": \"This room has been shut down.\""
    BODY="${BODY}}"

    RESP=$(api_call DELETE "/_synapse/admin/v1/rooms/${ROOM_ID}" "$BODY") || {
      error "Delete failed. Check the room ID."; exit 1
    }

    DELETE_ID=$(echo "$RESP" | python3 -c \
      "import sys,json; print(json.load(sys.stdin).get('delete_id',''))" 2>/dev/null)
    log "Room deletion initiated. Delete ID: ${DELETE_ID}"
    info "Check progress: api_call GET /_synapse/admin/v2/rooms/delete_status/${DELETE_ID}"
    ;;

  # ── purge ─────────────────────────────────────────────────────────────────
  purge)
    [[ -z "$ROOM_ID" ]] && { read -rp "Room ID (!room:domain): " ROOM_ID; }
    [[ "$BEFORE_DAYS" -eq 0 ]] && BEFORE_DAYS=30

    # Calculate timestamp for N days ago
    PURGE_TS=$(( ($(date +%s) - BEFORE_DAYS * 86400) * 1000 ))
    PURGE_DATE=$(date -d "@$(( PURGE_TS / 1000 ))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || \
                 date -r  "$(( PURGE_TS / 1000 ))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)

    warn "Purging messages in ${ROOM_ID} older than ${BEFORE_DAYS} days (before ${PURGE_DATE})."
    warn "This removes messages from the database permanently."
    read -rp "  Confirm [y/N]: " CONFIRM
    [[ "${CONFIRM,,}" != "y" ]] && { echo "Aborted."; exit 0; }

    RESP=$(api_call POST "/_synapse/admin/v1/purge_history/${ROOM_ID}" \
      "{\"purge_up_to_ts\": ${PURGE_TS}}") || {
      error "Purge request failed."; exit 1
    }

    PURGE_ID=$(echo "$RESP" | python3 -c \
      "import sys,json; print(json.load(sys.stdin).get('purge_id',''))" 2>/dev/null)
    log "Purge started. Purge ID: ${PURGE_ID}"
    info "Check status: GET /_synapse/admin/v1/purge_history_status/${PURGE_ID}"
    ;;

  *)
    error "Unknown subcommand: ${SUBCOMMAND}"
    echo "Valid: list, info, members, delete, purge"
    exit 1
    ;;
esac
echo ""
