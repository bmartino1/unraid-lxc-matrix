#!/bin/bash
# =============================================================================
# scripts/logs.sh
# View, tail, and search logs across all stack services.
#
# Usage:
#   ./scripts/logs.sh                    # interactive service selector
#   ./scripts/logs.sh synapse            # tail synapse log
#   ./scripts/logs.sh nginx              # tail nginx access + error
#   ./scripts/logs.sh nginx-stream       # tail nginx stream (SNI) log
#   ./scripts/logs.sh valkey
#   ./scripts/logs.sh coturn
#   ./scripts/logs.sh prosody
#   ./scripts/logs.sh all                # last 30 lines from every log
#   ./scripts/logs.sh errors             # grep ERROR/WARNING across all logs
#   ./scripts/logs.sh --lines 50 synapse # last 50 lines
#   ./scripts/logs.sh --follow synapse   # follow (like tail -f)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root

LINES=30
FOLLOW=false
SERVICE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lines|-n)  LINES="$2"; shift 2 ;;
    --follow|-f) FOLLOW=true; shift  ;;
    --help|-h)
      cat <<EOF
Usage: $0 [--lines N] [--follow] <service>

Services:
  synapse        Matrix Synapse homeserver log
  nginx          Nginx access + error logs
  nginx-stream   Nginx SNI stream log
  valkey         Valkey cache log
  coturn         coturn TURN server log
  prosody        prosody XMPP log
  all            Last \$N lines from every log file
  errors         Grep ERROR/WARN/CRITICAL across all logs

Options:
  --lines N      Show N lines (default: 30)
  --follow       Follow log in real-time (Ctrl+C to stop)
EOF
      exit 0 ;;
    -*) error "Unknown option: $1"; exit 1 ;;
    *)  SERVICE="$1"; shift ;;
  esac
done

declare -A LOG_FILES=(
  [synapse]="/var/log/matrix-synapse/homeserver.log"
  [nginx-access]="/var/log/nginx/access.log"
  [nginx-error]="/var/log/nginx/error.log"
  [nginx-stream]="/var/log/nginx/stream.log"
  [valkey]="/var/log/valkey/valkey.log"
  [coturn]="/var/log/coturn/turn.log"
  [prosody]="/var/log/prosody/prosody.log"
)

show_log() {
  local NAME="$1"
  local FILE="$2"

  if [[ ! -f "$FILE" ]]; then
    warn "${NAME}: log not found at ${FILE}"
    return
  fi

  header "${NAME} — ${FILE}"

  if [[ "$FOLLOW" == true ]]; then
    tail -f -n "$LINES" "$FILE"
  else
    tail -n "$LINES" "$FILE"
  fi
}

# ── Interactive menu if no service given ─────────────────────────────────────
if [[ -z "$SERVICE" ]]; then
  echo ""
  header "Log Viewer"
  echo ""
  echo "  1) synapse       — Matrix Synapse"
  echo "  2) nginx         — Nginx access + error"
  echo "  3) nginx-stream  — Nginx SNI stream"
  echo "  4) valkey        — Valkey cache"
  echo "  5) coturn        — TURN server"
  echo "  6) prosody       — Jitsi XMPP"
  echo "  7) all           — All logs"
  echo "  8) errors        — Errors across all logs"
  echo ""
  read -rp "  Choice [1-8]: " CHOICE
  case "$CHOICE" in
    1) SERVICE="synapse" ;;
    2) SERVICE="nginx" ;;
    3) SERVICE="nginx-stream" ;;
    4) SERVICE="valkey" ;;
    5) SERVICE="coturn" ;;
    6) SERVICE="prosody" ;;
    7) SERVICE="all" ;;
    8) SERVICE="errors" ;;
    *) error "Invalid choice"; exit 1 ;;
  esac
fi

case "$SERVICE" in
  synapse)
    show_log "Matrix Synapse" "${LOG_FILES[synapse]}"
    ;;
  nginx)
    show_log "Nginx Access" "${LOG_FILES[nginx-access]}"
    echo ""
    show_log "Nginx Error"  "${LOG_FILES[nginx-error]}"
    ;;
  nginx-stream)
    show_log "Nginx Stream (SNI)" "${LOG_FILES[nginx-stream]}"
    ;;
  valkey)
    show_log "Valkey" "${LOG_FILES[valkey]}"
    ;;
  coturn)
    show_log "coturn TURN" "${LOG_FILES[coturn]}"
    ;;
  prosody)
    show_log "prosody XMPP" "${LOG_FILES[prosody]}"
    ;;
  all)
    for key in synapse nginx-access nginx-error nginx-stream valkey coturn prosody; do
      show_log "$key" "${LOG_FILES[$key]}"
      echo ""
    done
    ;;
  errors)
    header "Errors and Warnings (last 24h)"
    echo ""
    for key in synapse nginx-error coturn prosody; do
      FILE="${LOG_FILES[$key]}"
      [[ ! -f "$FILE" ]] && continue
      MATCHES=$(grep -iE "ERROR|WARNING|CRITICAL|FATAL|exception|traceback" \
        "$FILE" 2>/dev/null | tail -20)
      if [[ -n "$MATCHES" ]]; then
        echo -e "  ${BOLD}${key} (${FILE}):${NC}"
        echo "$MATCHES" | sed 's/^/    /'
        echo ""
      fi
    done

    # Also check systemd journal for service failures
    echo -e "  ${BOLD}Systemd failures (last 24h):${NC}"
    journalctl --since "24h ago" -p err \
      -u nginx -u matrix-synapse -u postgresql -u valkey \
      -u prosody -u jicofo -u jitsi-videobridge2 -u coturn \
      --no-pager 2>/dev/null | tail -30 | sed 's/^/    /' || true
    ;;
  *)
    error "Unknown service: ${SERVICE}"
    exit 1
    ;;
esac
echo ""
