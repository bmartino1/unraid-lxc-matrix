#!/bin/bash
# scripts/stack-status.sh — Matrix Stack status overview
set -euo pipefail

if [[ ! -f /root/.matrix-stack.env ]]; then
  echo "Setup has not been run. Execute: ./setup.sh --domain yourdomain.com"
  exit 0
fi
set -a; source /root/.matrix-stack.env; set +a

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "${CYAN}   Matrix Stack - Service Status${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "  Domain:  ${DOMAIN}  (LXC IP: ${LXC_IP})"
echo ""

SERVICES=(nginx matrix-synapse postgresql valkey prosody jicofo jitsi-videobridge2 coturn)
for svc in "${SERVICES[@]}"; do
  STATUS=$(systemctl is-active "$svc" 2>/dev/null || echo "not-found")
  if [[ "$STATUS" == "active" ]]; then
    echo -e "  ${GREEN}●${NC} ${svc}"
  else
    echo -e "  ${RED}●${NC} ${svc}: ${RED}${STATUS}${NC}"
  fi
done

echo ""
echo -e "${CYAN}Endpoints:${NC}"
echo -e "  Element Web:  https://${ELEMENT_DOMAIN}"
echo -e "  Matrix API:   https://${MATRIX_DOMAIN}"
echo -e "  Jitsi Meet:   https://${JITSI_DOMAIN}  (widget-only)"
echo ""

echo -e "${CYAN}SSL Certs:${NC}"
for fqdn in "${DOMAIN}" "${MATRIX_DOMAIN}" "${JITSI_DOMAIN}"; do
  CERT="/etc/ssl/nginx/${fqdn}.crt"
  if [[ -f "$CERT" ]]; then
    EXPIRY=$(openssl x509 -enddate -noout -in "$CERT" 2>/dev/null | cut -d= -f2)
    ISSUER=$(openssl x509 -issuer -noout -in "$CERT" 2>/dev/null | grep -o "O=[^,/]*" | head -1)
    echo "  ${fqdn}: expires ${EXPIRY} (${ISSUER})"
  else
    echo -e "  ${RED}${fqdn}: cert not found${NC}"
  fi
done

echo ""
echo -e "${CYAN}Health:${NC}"
HTTP=$(curl -so /dev/null -w "%{http_code}" http://127.0.0.1:9000/health 2>/dev/null || echo "err")
echo "  Synapse health: HTTP ${HTTP}"
VPONG=$(/usr/local/bin/valkey-cli -a "${VALKEY_PASS}" ping 2>/dev/null || echo "no response")
echo "  Valkey: ${VPONG}"
PG=$(pg_isready -U postgres 2>/dev/null && echo "ready" || echo "not ready")
echo "  PostgreSQL: ${PG}"

echo ""
