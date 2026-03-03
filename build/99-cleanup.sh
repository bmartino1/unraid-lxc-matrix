#!/bin/bash
# Stage 99 - Final cleanup, service verification, and summary
set -euo pipefail

echo "==> Running apt cleanup..."
apt-get autoremove -y
apt-get autoclean
rm -rf /tmp/build /tmp/*.deb /tmp/*.tar.gz /tmp/*.log

echo "==> Clearing bash history..."
find / -name ".bash_history" -exec rm -f {} \; 2>/dev/null || true
history -c 2>/dev/null || true

echo "==> Final service status check..."
SERVICES=(nginx matrix-synapse postgresql valkey prosody jicofo jitsi-videobridge2 coturn)
ALL_OK=true
for svc in "${SERVICES[@]}"; do
  STATUS=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
  if [[ "$STATUS" == "active" ]]; then
    echo "   ✓ ${svc}: ${STATUS}"
  else
    echo "   ✗ ${svc}: ${STATUS} (attempting restart...)"
    systemctl start "$svc" 2>/dev/null || true
    ALL_OK=false
  fi
done

echo ""
if [[ "$ALL_OK" == "true" ]]; then
  echo "All services are running."
else
  echo "WARNING: Some services had issues - review with: journalctl -xe"
fi

echo ""
echo "==> Stack ports in use:"
ss -tlnp | grep -E ':(80|443|8008|8443|5280|5347|3478|5349|5432|6379)' | awk '{print $4, $6}' | sort -t: -k2 -n

echo ""
echo "Completed Stage 99 - Cleanup"
echo ""
echo "=== Build Complete ==="
