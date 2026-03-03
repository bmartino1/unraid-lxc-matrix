#!/bin/bash
# scripts/stack-status.sh
# Show status of all matrix stack services and endpoints

set -euo pipefail

source /root/.matrix-stack.env 2>/dev/null || { echo "Run setup.sh first."; exit 1; }

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

echo ""
echo -e "${CYAN}═══════════════════════════════════════════${NC}"
echo -e "${CYAN}   Matrix Stack Status${NC}"
echo -e "${CYAN}═══════════════════════════════════════════${NC}"
echo ""

SERVICES=(nginx matrix-synapse postgresql valkey prosody jicofo jitsi-videobridge2 coturn)
for svc in "${SERVICES[@]}"; do
  STATUS=$(systemctl is-active "$svc" 2>/dev/null || echo "not-found")
  if [[ "$STATUS" == "active" ]]; then
    echo -e "  ${GREEN}●${NC} ${svc}: ${GREEN}${STATUS}${NC}"
  else
    echo -e "  ${RED}●${NC} ${svc}: ${RED}${STATUS}${NC}"
  fi
done

echo ""
echo -e "${CYAN}Endpoints:${NC}"
LXC_IP=$(hostname -I | awk '{print $1}')
echo -e "  Element Web:   https://${DOMAIN}  (${LXC_IP})"
echo -e "  Matrix API:    https://${MATRIX_DOMAIN}"
echo -e "  Jitsi Meet:    https://${JITSI_DOMAIN}"
echo ""

echo -e "${CYAN}Port bindings:${NC}"
ss -tlnp 2>/dev/null | grep -E ':(80|443|8008|8443|5280|5347|3478|5349|5432|6379)\s' | \
  awk '{print "  " $4}' | sort -t: -k2 -n || true

echo ""
echo -e "${CYAN}Synapse health:${NC}"
HEALTH=$(curl -sf http://127.0.0.1:9000/health 2>/dev/null || echo "unreachable")
echo "  $HEALTH"

echo ""
echo -e "${CYAN}Valkey:${NC}"
VALKEY_PONG=$(valkey-cli -a "${VALKEY_PASS}" ping 2>/dev/null || echo "unreachable")
echo "  $VALKEY_PONG"

echo ""
echo -e "${CYAN}PostgreSQL:${NC}"
PG_STATUS=$(pg_isready -U postgres 2>/dev/null && echo "ready" || echo "not ready")
echo "  $PG_STATUS"
echo ""
