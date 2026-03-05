#!/bin/bash
# =============================================================================
# scripts/registration-toggle.sh
# Enable or disable open registration on the Matrix homeserver.
# When disabled, new accounts require a registration token (invite-only).
#
# Usage:
#   ./scripts/registration-toggle.sh enable
#   ./scripts/registration-toggle.sh disable
#   ./scripts/registration-toggle.sh status
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_env

HOMESERVER_YAML="/etc/matrix-synapse/homeserver.yaml"
ACTION="${1:-status}"

header "Registration Toggle"
echo ""

case "$ACTION" in
  status)
    CURRENT=$(grep "^enable_registration:" "$HOMESERVER_YAML" 2>/dev/null \
      | awk '{print $2}' || echo "false")
    if [[ "$CURRENT" == "true" ]]; then
      warn "Open registration is ENABLED — anyone can create an account."
    else
      log "Open registration is DISABLED — users need a token to register."
      info "Create invite tokens with: ./scripts/registration-tokens.sh create"
    fi
    echo ""
    info "Registration URL: https://${ELEMENT_DOMAIN}/#/register"
    ;;

  enable)
    warn "Enabling open registration — anyone will be able to create an account."
    read -rp "  Confirm [y/N]: " CONFIRM
    [[ "${CONFIRM,,}" != "y" ]] && { echo "Aborted."; exit 0; }

    if grep -q "^enable_registration:" "$HOMESERVER_YAML"; then
      sed -i "s/^enable_registration:.*/enable_registration: true/" "$HOMESERVER_YAML"
    else
      echo "enable_registration: true" >> "$HOMESERVER_YAML"
    fi

    systemctl reload matrix-synapse 2>/dev/null || systemctl restart matrix-synapse
    log "Open registration enabled."
    warn "Anyone can now register at https://${ELEMENT_DOMAIN}/#/register"
    ;;

  disable)
    info "Disabling open registration (invite-token mode)."

    if grep -q "^enable_registration:" "$HOMESERVER_YAML"; then
      sed -i "s/^enable_registration:.*/enable_registration: false/" "$HOMESERVER_YAML"
    else
      echo "enable_registration: false" >> "$HOMESERVER_YAML"
    fi

    systemctl reload matrix-synapse 2>/dev/null || systemctl restart matrix-synapse
    log "Open registration disabled."
    info "Create invite tokens: ./scripts/registration-tokens.sh create"
    ;;

  *)
    error "Unknown action: ${ACTION}. Use: enable, disable, status"
    exit 1
    ;;
esac
echo ""
