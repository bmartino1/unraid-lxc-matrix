#!/bin/bash
###############################################################################
# rotate-secrets.sh — Rotate ALL secrets across the Matrix stack
#
# Updates: matrix.env, homeserver.yaml, turnserver.conf, prosody, jitsi configs
# Restarts all affected services afterward.
#
# Usage:
#   ./scripts/rotate-secrets.sh              # rotate everything
#   ./scripts/rotate-secrets.sh --turn-only  # only rotate TURN secret
###############################################################################
set -euo pipefail

ENV_FILE="/root/matrix.env"
[[ ! -f "$ENV_FILE" ]] && { echo "ERROR: $ENV_FILE not found. Run setup.sh first."; exit 1; }
[[ $EUID -ne 0 ]] && { echo "Must run as root"; exit 1; }

source "$ENV_FILE"

TURN_ONLY=false
[[ "${1:-}" == "--turn-only" ]] && TURN_ONLY=true

echo "╔══════════════════════════════════════╗"
echo "║     Matrix Stack — Secret Rotation   ║"
echo "╚══════════════════════════════════════╝"
echo ""

# Backup current env
cp "$ENV_FILE" "${ENV_FILE}.bak.$(date +%s)"
echo "  Backed up current secrets."

# ── Generate new secrets ───────────────────────────────────────────────────
NEW_TURN_SECRET=$(openssl rand -base64 48)

if [[ "$TURN_ONLY" == "false" ]]; then
  NEW_REG_SECRET=$(openssl rand -hex 32)
  NEW_MACAROON=$(openssl rand -hex 32)
  NEW_FORM_SECRET=$(openssl rand -hex 32)
  NEW_PG_PASS=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9/' | head -c 32)
  NEW_JICOFO_PASS=$(openssl rand -base64 18 | cut -c1-24)
  NEW_JVB_PASS=$(openssl rand -base64 18 | cut -c1-24)
fi

# ── Update TURN secret everywhere ─────────────────────────────────────────
echo "  Rotating TURN secret..."

# turnserver.conf
sed -i "s|^static-auth-secret=.*|static-auth-secret=${NEW_TURN_SECRET}|" /etc/turnserver.conf

# homeserver.yaml
sed -i "s|^turn_shared_secret:.*|turn_shared_secret: \"${NEW_TURN_SECRET}\"|" /etc/matrix-synapse/homeserver.yaml

# prosody external_service_secret
for f in /etc/prosody/conf.avail/*.cfg.lua /etc/prosody/conf.d/*.cfg.lua; do
  [[ -f "$f" ]] && sed -i "s|external_service_secret = \".*\"|external_service_secret = \"${NEW_TURN_SECRET}\"|" "$f"
done

# matrix.env
sed -i "s|^TURN_SECRET=.*|TURN_SECRET=${NEW_TURN_SECRET}|" "$ENV_FILE"

echo "    ✓ TURN secret rotated in: turnserver.conf, homeserver.yaml, prosody, matrix.env"

if [[ "$TURN_ONLY" == "false" ]]; then
  echo "  Rotating Synapse secrets..."

  # homeserver.yaml
  sed -i "s|^registration_shared_secret:.*|registration_shared_secret: \"${NEW_REG_SECRET}\"|" /etc/matrix-synapse/homeserver.yaml
  sed -i "s|^macaroon_secret_key:.*|macaroon_secret_key: \"${NEW_MACAROON}\"|" /etc/matrix-synapse/homeserver.yaml
  sed -i "s|^form_secret:.*|form_secret: \"${NEW_FORM_SECRET}\"|" /etc/matrix-synapse/homeserver.yaml

  # matrix.env
  sed -i "s|^REG_SECRET=.*|REG_SECRET=${NEW_REG_SECRET}|" "$ENV_FILE"
  sed -i "s|^MACAROON_SECRET=.*|MACAROON_SECRET=${NEW_MACAROON}|" "$ENV_FILE"
  sed -i "s|^FORM_SECRET=.*|FORM_SECRET=${NEW_FORM_SECRET}|" "$ENV_FILE"

  echo "    ✓ Synapse secrets rotated"

  echo "  Rotating PostgreSQL password..."
  sed -i "s|password: \".*\"|password: \"${NEW_PG_PASS}\"|" /etc/matrix-synapse/homeserver.yaml
  sudo -u postgres psql -c "ALTER ROLE synapse_user WITH PASSWORD '${NEW_PG_PASS}';" 2>/dev/null || true
  sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${NEW_PG_PASS}|" "$ENV_FILE"
  echo "    ✓ PostgreSQL password rotated"

  echo "  Rotating Jitsi passwords..."
  # jicofo
  sed -i "s|password: \".*\"|password: \"${NEW_JICOFO_PASS}\"|" /etc/jitsi/jicofo/jicofo.conf 2>/dev/null || true
  # jvb
  sed -i "s|PASSWORD=\".*\"|PASSWORD=\"${NEW_JVB_PASS}\"|" /etc/jitsi/videobridge/jvb.conf 2>/dev/null || true
  # Re-register prosody users
  MEET="${MEET:-meet.${DOMAIN}}"
  prosodyctl register focus "auth.${MEET}" "${NEW_JICOFO_PASS}" 2>/dev/null || true
  prosodyctl register jvb   "auth.${MEET}" "${NEW_JVB_PASS}"    2>/dev/null || true
  sed -i "s|^JICOFO_PASS=.*|JICOFO_PASS=${NEW_JICOFO_PASS}|" "$ENV_FILE"
  sed -i "s|^JVB_PASS=.*|JVB_PASS=${NEW_JVB_PASS}|" "$ENV_FILE"
  echo "    ✓ Jitsi passwords rotated"

  # Rotate Valkey password if present
  if grep -q "^VALKEY_PASS=" "$ENV_FILE" 2>/dev/null; then
    NEW_VALKEY=$(openssl rand -hex 16)
    sed -i "s|^requirepass .*|requirepass ${NEW_VALKEY}|" /etc/valkey/valkey.conf 2>/dev/null || true
    sed -i "s|password: \".*\"|password: \"${NEW_VALKEY}\"|" /etc/matrix-synapse/homeserver.yaml 2>/dev/null || true
    sed -i "s|^VALKEY_PASS=.*|VALKEY_PASS=${NEW_VALKEY}|" "$ENV_FILE"
    echo "    ✓ Valkey password rotated"
  fi
fi

# ── Restart services ───────────────────────────────────────────────────────
echo ""
echo "  Restarting services..."
systemctl restart coturn
systemctl restart matrix-synapse
systemctl restart prosody
systemctl restart jicofo
systemctl restart jitsi-videobridge2
[[ -f /etc/valkey/valkey.conf ]] && systemctl restart valkey-server 2>/dev/null || true

echo ""
echo "  ✓ All secrets rotated. New values saved to $ENV_FILE"
echo "  ✓ Previous secrets backed up to ${ENV_FILE}.bak.*"
echo ""
