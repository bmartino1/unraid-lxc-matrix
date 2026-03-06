```bash
#!/bin/bash
# =============================================================================
# scripts/stack-status.sh
# Comprehensive health and status overview of the Matrix stack.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root

SHOW_LOGS=false
JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --logs) SHOW_LOGS=true; shift ;;
    --json) JSON_OUTPUT=true; shift ;;
    *) shift ;;
  esac
done

if [[ ! -f /root/matrix.env ]]; then
  warn "Setup has not been completed. Run: ./setup.sh --domain yourdomain.com"
  exit 0
fi

# Load environment variables
set -a
source /root/matrix.env
set +a


# ── Collect service status ────────────────────────────────────────────────────

SERVICES=(nginx matrix-synapse postgresql valkey prosody jicofo jitsi-videobridge2 coturn)
declare -A SVC_STATUS

for svc in "${SERVICES[@]}"; do
  SVC_STATUS[$svc]=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
done


# ── Synapse health check (FIXED) ──────────────────────────────────────────────

SYNAPSE_HEALTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  "${SYNAPSE}/_matrix/client/versions")

if [[ -z "$SYNAPSE_HEALTH_CODE" ]]; then
  SYNAPSE_HEALTH_CODE="000"
fi


# ── Valkey health check (FIXED) ───────────────────────────────────────────────

VALKEY_PING=$(valkey-cli -a "${VALKEY_PASS}" ping 2>/dev/null | grep -o PONG)

if [[ -z "$VALKEY_PING" ]]; then
  VALKEY_PING="ERROR"
fi


# ── PostgreSQL health ─────────────────────────────────────────────────────────

if pg_isready -U postgres >/dev/null 2>&1; then
  PG_READY="ready"
else
  PG_READY="not ready"
fi


# ── Database statistics ───────────────────────────────────────────────────────

DB_SIZE=$(sudo -u postgres psql -t -c \
  "SELECT pg_size_pretty(pg_database_size('synapse'));" 2>/dev/null | tr -d ' \n' || echo "?")

USER_COUNT=$(sudo -u postgres psql -t -d synapse -c \
  "SELECT COUNT(*) FROM users WHERE deactivated=0;" 2>/dev/null | tr -d ' \n' || echo "?")

MEDIA_SIZE=$(du -sh /var/lib/matrix-synapse/media_store 2>/dev/null | cut -f1 || echo "?")

SYNAPSE_LOG_SIZE=$(du -sh /var/log/matrix-synapse/ 2>/dev/null | cut -f1 || echo "?")

UPTIME=$(uptime -p 2>/dev/null || echo "?")


# ── Certificate expiry check ──────────────────────────────────────────────────

cert_expiry() {
  local CERT="/etc/ssl/nginx/${1}.crt"

  [[ ! -f "$CERT" ]] && echo "NOT FOUND" && return

  local EXPIRY
  EXPIRY=$(openssl x509 -enddate -noout -in "$CERT" 2>/dev/null | cut -d= -f2)

  local DAYS_LEFT
  DAYS_LEFT=$(( ( $(date -d "$EXPIRY" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))

  local ISSUER
  ISSUER=$(openssl x509 -issuer -noout -in "$CERT" 2>/dev/null \
    | grep -o "O=[^,/]*" | head -1 | cut -d= -f2)

  if [[ $DAYS_LEFT -lt 7 ]]; then
    echo "EXPIRES IN ${DAYS_LEFT}d ⚠ (${ISSUER})"
  elif [[ $DAYS_LEFT -lt 30 ]]; then
    echo "expires in ${DAYS_LEFT}d (${ISSUER})"
  else
    echo "valid ${DAYS_LEFT}d (${ISSUER})"
  fi
}


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

if [[ "$SYNAPSE_HEALTH_CODE" == "200" ]]; then
  echo -e "  ${GREEN}✓${NC} Synapse API:  HTTP 200"
else
  echo -e "  ${RED}✗${NC} Synapse API:  HTTP ${SYNAPSE_HEALTH_CODE}"
fi

if [[ "$VALKEY_PING" == "PONG" ]]; then
  echo -e "  ${GREEN}✓${NC} Valkey:       PONG"
else
  echo -e "  ${RED}✗${NC} Valkey:       ERROR"
fi

if [[ "$PG_READY" == "ready" ]]; then
  echo -e "  ${GREEN}✓${NC} PostgreSQL:   ready"
else
  echo -e "  ${RED}✗${NC} PostgreSQL:   ${PG_READY}"
fi


# ── Statistics ────────────────────────────────────────────────────────────────

header "Statistics"

echo -e "  Users:        ${USER_COUNT}"
echo -e "  DB size:      ${DB_SIZE}"
echo -e "  Media store:  ${MEDIA_SIZE}"
echo -e "  Log dir:      ${SYNAPSE_LOG_SIZE}"


# ── SSL Certificates ──────────────────────────────────────────────────────────

header "SSL Certificates"

for fqdn in "${DOMAIN}" "${DOMAIN}" "${MEET}"; do
  EXPIRY_STR=$(cert_expiry "$fqdn")

  if echo "$EXPIRY_STR" | grep -q "⚠\|NOT FOUND"; then
    echo -e "  ${RED}✗${NC} ${fqdn}: ${RED}${EXPIRY_STR}${NC}"
  else
    echo -e "  ${GREEN}✓${NC} ${fqdn}: ${EXPIRY_STR}"
  fi
done


# ── Endpoints ─────────────────────────────────────────────────────────────────

header "Endpoints"

echo -e "  Element Web:  ${CYAN}https://${DOMAIN}${NC}"
echo -e "  Matrix API:   ${CYAN}https://${DOMAIN}${NC}"
echo -e "  Jitsi Meet:   ${CYAN}https://${MEET}${NC}  (widget-only)"


# ── Listening Ports ───────────────────────────────────────────────────────────

header "Listening Ports"

{
  ss -tlnp 2>/dev/null | awk 'NR>1 {print "tcp", $4}'
  ss -ulnp 2>/dev/null | awk 'NR>1 {print "udp", $4}'
} \
| grep -E ':(80|443|3478|5349|8008|5280|5222|5269|5432|6379|9000|10000)$' \
| sort -u \
| while read -r proto addr; do
    echo -e "  ${BLUE}→${NC} ${addr}  (${proto})"
done


echo ""
echo -e "  ${BLUE}Setup date:${NC} ${SETUP_DATE:-unknown}"
echo ""
```
