#!/bin/bash
set -euo pipefail
echo "  Final verification..."

SERVICES=(nginx matrix-synapse postgresql coturn prosody jicofo jitsi-videobridge2)
# Add valkey only if installed
command -v valkey-server >/dev/null 2>&1 && SERVICES+=(valkey-server)

ALL_OK=true
for svc in "${SERVICES[@]}"; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    echo "    ✓ ${svc}"
  else
    echo "    ✗ ${svc} — attempting start..."
    systemctl start "$svc" 2>/dev/null || true
    sleep 2
    systemctl is-active --quiet "$svc" && echo "      → started" || { echo "      → FAILED"; ALL_OK=false; }
  fi
done

echo ""
echo "  Synapse API check..."
HTTP=$(curl -so /dev/null -w "%{http_code}" http://127.0.0.1:8008/_matrix/client/versions 2>/dev/null || echo "000")
[[ "$HTTP" == "200" ]] && echo "    ✓ HTTP 200" || { echo "    ✗ HTTP ${HTTP}"; ALL_OK=false; }

echo ""
[[ "$ALL_OK" == "true" ]] && echo "  ✓ All services OK." || echo "  ⚠ Some services need attention."
