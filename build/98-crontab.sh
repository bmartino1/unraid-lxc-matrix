#!/bin/bash
# =============================================================================
# BUILD PHASE - Stage 98: Pre-stage cron and logrotate configs
# Actual service-aware cron entries added by setup.sh after services configured
# =============================================================================
set -euo pipefail

echo "==> [98] Pre-staging logrotate config..."
cat > /etc/logrotate.d/matrix-stack <<'EOF'
/var/log/matrix-synapse/*.log
/var/log/valkey/*.log
/var/log/coturn/*.log
/var/log/nginx/stream.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        systemctl reload matrix-synapse 2>/dev/null || true
        systemctl reload nginx          2>/dev/null || true
    endscript
}
EOF

echo "==> [98] Pre-staging health-check script (populated at setup time)..."
cat > /usr/local/bin/matrix-healthcheck <<'EOF'
#!/bin/bash
# Matrix stack health-check - populated at setup time
# If setup.sh has not been run, this script does nothing
if [[ ! -f /root/matrix.env ]]; then
  exit 0
fi
source /root/matrix.env
SERVICES=(nginx matrix-synapse postgresql valkey prosody jicofo jitsi-videobridge2 coturn)
for svc in "${SERVICES[@]}"; do
  if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
    echo "$(date): restarting $svc" >> /var/log/matrix-stack-health.log
    systemctl start "$svc" 2>/dev/null || true
  fi
done
EOF
chmod +x /usr/local/bin/matrix-healthcheck

echo "==> [98] Pre-staging cron entry (will only act after .env file exists)..."
echo "*/5 * * * * root /usr/local/bin/matrix-healthcheck" \
  > /etc/cron.d/matrix-stack

echo "==> Completed Stage 98 - Crontab pre-staged"
