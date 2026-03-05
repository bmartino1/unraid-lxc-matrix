#!/bin/bash
# SETUP PHASE - 09: Final verification
set -euo pipefail

echo "  Running final service verification..."
echo ""

ALL_OK=true

SERVICES=(
  nginx
  matrix-synapse
  postgresql
  valkey
  prosody
  jicofo
  jitsi-videobridge2
  coturn
)

for svc in "${SERVICES[@]}"; do

  STATUS=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")

  if [[ "$STATUS" == "active" ]]; then
    echo "    ✓ ${svc}"
  else
    echo "    ✗ ${svc} is ${STATUS}"
    ALL_OK=false

    systemctl start "$svc" 2>/dev/null || true
    sleep 2

    if systemctl is-active --quiet "$svc"; then
      echo "      → started OK"
    else
      echo "      → still failing - check: journalctl -u ${svc}"
    fi
  fi

done

echo ""
echo "  Synapse health check..."

HTTP_CODE=$(curl -so /dev/null -w "%{http_code}" \
  "http://127.0.0.1:9000/health" 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" == "200" ]]; then
  echo "    ✓ Synapse responding (HTTP 200)"
else
  echo "    ✗ Synapse health check failed (HTTP ${HTTP_CODE})"
  ALL_OK=false
fi


echo ""
echo "  Valkey ping..."

VALKEY_CLI=$(command -v valkey-cli || true)

if [[ -n "$VALKEY_CLI" ]]; then

  if "$VALKEY_CLI" -a "${VALKEY_PASS}" ping 2>/dev/null | grep -q PONG; then
    echo "    ✓ Valkey PONG"
  else
    echo "    ✗ Valkey not responding"
    ALL_OK=false
  fi

else
  echo "    ✗ valkey-cli not found"
  ALL_OK=false
fi


echo ""
echo "  PostgreSQL readiness..."

if pg_isready -U postgres >/dev/null 2>&1; then
  echo "    ✓ PostgreSQL ready"
else
  echo "    ✗ PostgreSQL not responding"
  ALL_OK=false
fi


echo ""
echo "  Nginx config test..."

if nginx -t >/dev/null 2>&1; then
  echo "    ✓ nginx configuration OK"
else
  nginx -t
  ALL_OK=false
fi


echo ""
echo "  Active ports:"

EXPECTED_PORTS=':(80|443|8008|8443|5280|5222|5269|9090|5432|6379|3478|5349)\s'

ss -tlnp 2>/dev/null \
  | grep -E "$EXPECTED_PORTS" \
  | awk '{print "    " $4}' \
  | sort -t: -k2 -n


echo ""
if [[ "$ALL_OK" == "true" ]]; then
  echo "  ✓ All services verified OK."
else
  echo "  ⚠ Some services reported issues — review above output."
fi
