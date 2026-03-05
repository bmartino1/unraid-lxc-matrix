#!/bin/bash
# =============================================================================
# scripts/stack-status.sh
# Comprehensive health and status overview of the Matrix stack.
# Shows: service status, port bindings, SSL cert expiry,
#        database size, Synapse health, Valkey ping, recent logs.
#
# Usage:
#   ./scripts/stack-status.sh
#   ./scripts/stack-status.sh --logs      # show last 20 lines of each log
#   ./scripts/stack-status.sh --json      # machine-readable JSON output
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root

SHOW_LOGS=false
JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --logs) SHOW_LOGS=true;   shift ;;
    --json) JSON_OUTPUT=true; shift ;;
    *) shift ;;
  esac
done

if [[ ! -f /root/.matrix-stack.env ]]; then
  warn "Setup has not been completed. Run: ./setup.sh --domain yourdomain.com"
  exit 0
fi
load_env

# ── Collect status data ───────────────────────────────────────────────────────

SERVICES=(nginx matrix-synapse postgresql valkey prosody jicofo jitsi-videobridge2 coturn)
declare -A SVC_STATUS

for svc in "${SERVICES[@]}"; do
  SVC_STATUS[$svc]=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
done

# Synapse health HTTP — try metrics port first, fall back to main port
SYNAPSE_HEALTH_CODE=$(curl -so /dev/null -w "%{http_code}" \
  "http://127.0.0.1:9000/health" 2>/dev/null || echo "000")
if [[ "$SYNAPSE_HEALTH_CODE" == "000" ]]; then
  SYNAPSE_HEALTH_CODE=$(curl -so /dev/null -w "%{http_code}" \
    "http://127.0.0.1:8008/_matrix/client/versions" 2>/dev/null || echo "000")
fi

# Valkey ping
VALKEY_PING=$(/usr/local/bin/valkey-cli --no-auth-warning -a "${VALKEY_PASS}" ping 2>/dev/null)
# Fallback if --no-auth-warning not supported
if [[ -z "$VALKEY_PING" ]]; then
  VALKEY_PING=$(/usr/local/bin/valkey-cli -a "${VALKEY_PASS}" ping 2>/dev/null || echo "ERROR")
fi
# Strip any warning text, keep only PONG
VALKEY_PING=$(echo "$VALKEY_PING" | grep -oE '^PONG$' || echo "ERROR")

# PostgreSQL
if pg_isready -U postgres >/dev/null 2>&1; then
  PG_READY="ready"
else
  PG_READY="not ready"
fi

# DB size
DB_SIZE=$(sudo -u postgres psql -t -c \
  "SELECT pg_size_pretty(pg_database_size('synapse'));" 2>/dev/null | tr -d ' \n' || echo "?")

# User count (no auth needed for this internal query)
USER_COUNT=$(sudo -u postgres psql -t -d synapse -c \
  "SELECT COUNT(*) FROM users WHERE deactivated=0;" 2>/dev/null | tr -d ' \n' || echo "?")

# Media store size
MEDIA_SIZE=$(du -sh /var/lib/matrix-synapse/media_store 2>/dev/null | cut -f1 || echo "?")

# Log file sizes
SYNAPSE_LOG_SIZE=$(du -sh /var/log/matrix-synapse/ 2>/dev/null | cut -f1 || echo "?")

# Uptime
UPTIME=$(uptime -p 2>/dev/null || echo "?")

# Cert expiry check
cert_expiry() {
  local CERT="/etc/ssl/nginx/${1}.crt"
  [[ ! -f "$CERT" ]] && echo "NOT FOUND" && return
  local EXPIRY
  EXPIRY=$(openssl x509 -enddate -noout -in "$CERT" 2>/dev/null | cut -d= -f2)
  local DAYS_LEFT
  DAYS_LEFT=$(( ( $(date -d "$EXPIRY" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$EXPIRY" +%s 2>/dev/null) - $(date +%s) ) / 86400 ))
  local ISSUER
  ISSUER=$(openssl x509 -issuer -noout -in "$CERT" 2>/dev/null | grep -o "O=[^,/]*" | head -1 | cut -d= -f2)
  if [[ $DAYS_LEFT -lt 7 ]]; then
    echo "EXPIRES IN ${DAYS_LEFT}d ⚠  (${ISSUER})"
  elif [[ $DAYS_LEFT -lt 30 ]]; then
    echo "expires in ${DAYS_LEFT}d (${ISSUER})"
  else
    echo "valid ${DAYS_LEFT}d (${ISSUER})"
  fi
}

# ── JSON output ───────────────────────────────────────────────────────────────
if [[ "$JSON_OUTPUT" == true ]]; then
  python3 -c "
import json, sys

services = $(
  echo "{"
  for svc in "${SERVICES[@]}"; do
    echo "  \"${svc}\": \"${SVC_STATUS[$svc]}\","
  done
  echo "}"
)

print(json.dumps({
  'domain': '${DOMAIN}',
  'lxc_ip': '${LXC_IP}',
  'services': services,
  'synapse_health_http': '${SYNAPSE_HEALTH_CODE}',
  'valkey_ping': '${VALKEY_PING}',
  'postgres': '${PG_READY}',
  'db_size': '${DB_SIZE}',
  'user_count': '${USER_COUNT}',
  'media_size': '${MEDIA_SIZE}',
  'uptime': '${UPTIME}',
}, indent=2))
"
  exit 0
fi

# ── Human-readable output ─────────────────────────────────────────────────────
clear
echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║         Matrix Stack — Status Dashboard                  ║${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo -e "  Domain:   ${BOLD}${DOMAIN}${NC}   •   LXC IP: ${LXC_IP}   •   ${UPTIME}"
echo ""

# ── Services ──────────────────────────────────────────────────────────────────
header "Services"
for svc in "${SERVICES[@]}"; do
  STATUS="${SVC_STATUS[$svc]}"
  if [[ "$STATUS" == "active" ]]; then
    echo -e "  ${GREEN}●${NC} ${svc}"
  elif [[ "$STATUS" == "inactive" ]]; then
    echo -e "  ${YELLOW}●${NC} ${svc}: ${YELLOW}inactive${NC}"
  else
    echo -e "  ${RED}●${NC} ${svc}: ${RED}${STATUS}${NC}"
  fi
done

# ── Health checks ─────────────────────────────────────────────────────────────
header "Health"
[[ "$SYNAPSE_HEALTH_CODE" == "200" ]] && \
  echo -e "  ${GREEN}✓${NC} Synapse API:  HTTP ${SYNAPSE_HEALTH_CODE}" || \
  echo -e "  ${RED}✗${NC} Synapse API:  HTTP ${SYNAPSE_HEALTH_CODE}"

[[ "$VALKEY_PING" == "PONG" ]] && \
  echo -e "  ${GREEN}✓${NC} Valkey:       PONG" || \
  echo -e "  ${RED}✗${NC} Valkey:       ${VALKEY_PING}"

[[ "$PG_READY" == "ready" ]] && \
  echo -e "  ${GREEN}✓${NC} PostgreSQL:   ready" || \
  echo -e "  ${RED}✗${NC} PostgreSQL:   ${PG_READY}"

# ── Statistics ────────────────────────────────────────────────────────────────
header "Statistics"
echo -e "  Users:        ${USER_COUNT}"
echo -e "  DB size:      ${DB_SIZE}"
echo -e "  Media store:  ${MEDIA_SIZE}"
echo -e "  Log dir:      ${SYNAPSE_LOG_SIZE}"

# ── SSL Certificates ──────────────────────────────────────────────────────────
header "SSL Certificates"
for fqdn in "${DOMAIN}" "${MATRIX_DOMAIN}" "${JITSI_DOMAIN}"; do
  EXPIRY_STR=$(cert_expiry "$fqdn")
  if echo "$EXPIRY_STR" | grep -q "⚠\|NOT FOUND"; then
    echo -e "  ${RED}✗${NC} ${fqdn}: ${RED}${EXPIRY_STR}${NC}"
  else
    echo -e "  ${GREEN}✓${NC} ${fqdn}: ${EXPIRY_STR}"
  fi
done

# ── Endpoints ─────────────────────────────────────────────────────────────────
header "Endpoints"
echo -e "  Element Web:  ${CYAN}https://${ELEMENT_DOMAIN}${NC}"
echo -e "  Matrix API:   ${CYAN}https://${MATRIX_DOMAIN}${NC}"
echo -e "  Jitsi Meet:   ${CYAN}https://${JITSI_DOMAIN}${NC}  (widget-only)"

# ── Port bindings ─────────────────────────────────────────────────────────────
header "Listening Ports"
{
  ss -tlnp 2>/dev/null | awk 'NR>1 {print "tcp", $4}'
  ss -ulnp 2>/dev/null | awk 'NR>1 {print "udp", $4}'
} | grep -E ':(80|443|3478|5349|8008|8443|5280|5222|5269|5347|5432|6379|9000|9090|10000|4443)$' \
  | sort -u \
  | while read -r proto addr; do
      echo -e "  ${BLUE}→${NC} ${addr}  (${proto})"
    done

# ── DNS check ─────────────────────────────────────────────────────────────────
header "DNS Check (against LXC IP: ${LXC_IP})"
# Use an external resolver to avoid /etc/hosts entries (meet.* -> 127.0.0.1)
DNS_SERVER="1.1.1.1"
for fqdn in "${DOMAIN}" "${MATRIX_DOMAIN}" "${JITSI_DOMAIN}"; do
  RESOLVED=$(dig +short "$fqdn" @${DNS_SERVER} 2>/dev/null | head -1 || echo "?")
  if [[ "$RESOLVED" == "$LXC_IP" ]]; then
    echo -e "  ${GREEN}✓${NC} ${fqdn} → ${RESOLVED}"
  elif [[ -z "$RESOLVED" || "$RESOLVED" == "?" ]]; then
    echo -e "  ${YELLOW}?${NC} ${fqdn} → (not resolving)"
  else
    echo -e "  ${YELLOW}!${NC} ${fqdn} → ${RESOLVED}  (expected ${LXC_IP})"
  fi
done

# ── Recent log tail ───────────────────────────────────────────────────────────
if [[ "$SHOW_LOGS" == true ]]; then
  header "Recent Logs (last 15 lines each)"
  LOG_FILES=(
    "/var/log/matrix-synapse/homeserver.log"
    "/var/log/nginx/error.log"
    "/var/log/valkey/valkey.log"
    "/var/log/coturn/turn.log"
  )
  for log_file in "${LOG_FILES[@]}"; do
    if [[ -f "$log_file" ]]; then
      echo ""
      echo -e "  ${BOLD}${log_file}:${NC}"
      tail -15 "$log_file" 2>/dev/null | sed 's/^/    /'
    fi
  done
fi

echo ""
echo -e "  ${BLUE}Setup date:${NC} ${SETUP_DATE:-unknown}"
echo ""
