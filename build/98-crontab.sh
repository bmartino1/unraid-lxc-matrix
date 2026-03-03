#!/bin/bash
# Stage 98 - Crontab, timers, and update hooks
set -euo pipefail

echo "==> Installing crontab for maintenance tasks..."
cat > /etc/cron.d/matrix-stack <<EOF
# Matrix Stack maintenance cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Restart coturn nightly to flush stale sessions
0 4 * * *   root  systemctl restart coturn

# Rotate Nginx logs weekly
0 5 * * 0   root  /usr/sbin/logrotate -f /etc/logrotate.d/nginx

# Check all stack services are running
*/5 * * * *  root  /usr/local/bin/matrix-stack-healthcheck.sh
EOF

echo "==> Writing stack health-check script..."
cat > /usr/local/bin/matrix-stack-healthcheck.sh <<'HCEOF'
#!/bin/bash
# Health-check for matrix-stack services
SERVICES=(nginx matrix-synapse postgresql valkey prosody jicofo jitsi-videobridge2 coturn)
FAILED=()

for svc in "${SERVICES[@]}"; do
  if ! systemctl is-active --quiet "$svc"; then
    FAILED+=("$svc")
    systemctl start "$svc" 2>/dev/null || true
  fi
done

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "$(date): Restarted failed services: ${FAILED[*]}" >> /var/log/matrix-stack-health.log
fi
HCEOF
chmod +x /usr/local/bin/matrix-stack-healthcheck.sh

echo "==> Configuring logrotate for stack services..."
cat > /etc/logrotate.d/matrix-stack <<EOF
/var/log/matrix-synapse/*.log
/var/log/valkey/*.log
/var/log/coturn/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        systemctl reload matrix-synapse 2>/dev/null || true
    endscript
}
EOF

echo "Completed Stage 98 - Crontab and timers"
