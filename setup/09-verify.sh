#!/bin/bash
# SETUP PHASE - 09: Final verification
set -euo pipefail

echo "  Running final service verification..."
echo ""

ALL_OK=true
declare -A EXPECTED_PORTS=(
  [nginx]="80,443,8443"
  [matrix-synapse]="8008,9000"
  [postgresql]="5432"
  [valkey]="6379"
  [prosody]="5222,5269,5280"
  [jicofo]=""
  [jitsi-videobridge2]=""
  [coturn]="3478"
)

for svc in "${!EXPECTED_PORTS[@]}"; do
  STATUS=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
  if [[ "$STATUS" == "active" ]]; then
    echo "    ✓ ${svc}"
  else
    echo "    ✗ ${svc} is ${STATUS}"
    ALL_OK=false
    # Try once more
    systemctl start "$svc" 2>/dev/null && sleep 2 && \
      systemctl is-active --quiet "$svc" && \
      echo "      → started OK" || echo "      → still failing - check: journalctl -u ${svc}"
  fi
done

echo ""
echo "  Synapse health check..."
if curl -sf "http://127.0.0.1:9000/health" | grep -q "OK\|ok\|{}"; then
  echo "    ✓ Synapse responding"
else
  # Synapse returns empty 200 on health - check HTTP code
  HTTP_CODE=$(curl -so /dev/null -w "%{http_code}" "http://127.0.0.1:9000/health" 2>/dev/null || echo "000")
  [[ "$HTTP_CODE" == "200" ]] && echo "    ✓ Synapse HTTP 200" || echo "    ✗ Synapse health: HTTP ${HTTP_CODE}"
fi

echo ""
echo "  Valkey ping..."
if /usr/local/bin/valkey-cli -a "${VALKEY_PASS}" ping 2>/dev/null | grep -q PONG; then
  echo "    ✓ Valkey PONG"
else
  echo "    ✗ Valkey not responding"
fi

echo ""
echo "  Nginx config test..."
nginx -t 2>&1 | grep -E "ok|error" | sed 's/^/    /'

echo ""
echo "  Active ports:"
ss -tlnp 2>/dev/null | grep -E ':(80|443|8008|8443|5280|5432|6379|3478)\s' | \
  awk '{print "    " $4}' | sort -t: -k2 -n

echo ""
[[ "$ALL_OK" == "true" ]] && \
  echo "  All services verified OK." || \
  echo "  Some services had issues — review above output."
