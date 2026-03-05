#!/bin/bash
# =============================================================================
# scripts/service-control.sh
# Start, stop, restart, or check individual stack services or the full stack.
#
# Usage:
#   ./scripts/service-control.sh start   all
#   ./scripts/service-control.sh stop    all
#   ./scripts/service-control.sh restart all
#   ./scripts/service-control.sh restart synapse
#   ./scripts/service-control.sh restart nginx
#   ./scripts/service-control.sh status  all
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root

ACTION="${1:-status}"
TARGET="${2:-all}"

# Service order matters for start (dependencies first)
SERVICES_START=(postgresql valkey matrix-synapse prosody jicofo jitsi-videobridge2 coturn nginx)
# Reverse order for stop
SERVICES_STOP=(nginx coturn jitsi-videobridge2 jicofo prosody matrix-synapse valkey postgresql)

ALIAS=(
  "synapse=matrix-synapse"
  "postgres=postgresql"
  "jvb=jitsi-videobridge2"
)

# Resolve aliases
resolve_service() {
  local svc="$1"
  for alias in "${ALIAS[@]}"; do
    local key="${alias%%=*}"
    local val="${alias##*=}"
    [[ "$svc" == "$key" ]] && echo "$val" && return
  done
  echo "$svc"
}

header "Service Control — ${ACTION} ${TARGET}"
echo ""

case "$ACTION" in
  start)
    if [[ "$TARGET" == "all" ]]; then
      for svc in "${SERVICES_START[@]}"; do
        info "Starting ${svc}..."
        systemctl start "$svc" 2>/dev/null && log "${svc} started" || warn "${svc} failed to start"
      done
    else
      SVC=$(resolve_service "$TARGET")
      systemctl start "$SVC" && log "${SVC} started" || error "Failed to start ${SVC}"
    fi
    ;;

  stop)
    if [[ "$TARGET" == "all" ]]; then
      warn "Stopping all stack services..."
      read -rp "  Confirm [y/N]: " CONFIRM
      [[ "${CONFIRM,,}" != "y" ]] && { echo "Aborted."; exit 0; }
      for svc in "${SERVICES_STOP[@]}"; do
        info "Stopping ${svc}..."
        systemctl stop "$svc" 2>/dev/null && log "${svc} stopped" || warn "${svc}: ${svc} not running"
      done
    else
      SVC=$(resolve_service "$TARGET")
      systemctl stop "$SVC" && log "${SVC} stopped" || error "Failed to stop ${SVC}"
    fi
    ;;

  restart)
    if [[ "$TARGET" == "all" ]]; then
      warn "Restarting all stack services (brief outage)..."
      read -rp "  Confirm [y/N]: " CONFIRM
      [[ "${CONFIRM,,}" != "y" ]] && { echo "Aborted."; exit 0; }
      for svc in "${SERVICES_STOP[@]}"; do
        systemctl stop "$svc" 2>/dev/null || true
      done
      sleep 2
      for svc in "${SERVICES_START[@]}"; do
        info "Starting ${svc}..."
        systemctl start "$svc" 2>/dev/null && log "${svc} started" || warn "${svc} failed"
      done
    else
      SVC=$(resolve_service "$TARGET")
      systemctl restart "$SVC" && log "${SVC} restarted" || error "Failed to restart ${SVC}"
    fi
    ;;

  reload)
    # Graceful reload where supported
    for svc in nginx matrix-synapse; do
      if [[ "$TARGET" == "all" || "$TARGET" == "$svc" ]]; then
        systemctl reload "$svc" 2>/dev/null && log "${svc} reloaded" || \
          { warn "${svc} does not support reload, restarting..."; systemctl restart "$svc"; }
      fi
    done
    ;;

  status)
    SERVICES=(postgresql valkey matrix-synapse prosody jicofo jitsi-videobridge2 coturn nginx)
    if [[ "$TARGET" != "all" ]]; then
      SVC=$(resolve_service "$TARGET")
      systemctl status "$SVC" --no-pager
    else
      printf "  %-30s %s\n" "SERVICE" "STATUS"
      echo "  $(printf '%0.s─' {1..50})"
      for svc in "${SERVICES[@]}"; do
        STATUS=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
        SINCE=$(systemctl show "$svc" --no-pager -p ActiveEnterTimestampMonotonic \
          2>/dev/null | cut -d= -f2 || echo "")
        if [[ "$STATUS" == "active" ]]; then
          printf "  ${GREEN}●${NC} %-28s ${GREEN}%s${NC}\n" "$svc" "$STATUS"
        else
          printf "  ${RED}●${NC} %-28s ${RED}%s${NC}\n" "$svc" "$STATUS"
        fi
      done
    fi
    ;;

  *)
    error "Unknown action: ${ACTION}. Use: start, stop, restart, reload, status"
    exit 1
    ;;
esac
echo ""
