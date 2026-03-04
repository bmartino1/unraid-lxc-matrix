#!/bin/bash
# =============================================================================
# scripts/update-stack.sh
# Update stack components to latest versions.
# Safely updates: Element Web (new release tarball), Valkey binary,
# and triggers apt upgrade for Synapse, Jitsi, PostgreSQL, Nginx.
#
# Usage:
#   ./scripts/update-stack.sh            # update all
#   ./scripts/update-stack.sh element    # update Element Web only
#   ./scripts/update-stack.sh packages   # apt upgrade only
#   ./scripts/update-stack.sh valkey     # update Valkey binary
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

require_root
load_env

TARGET="${1:-all}"

header "Stack Update — ${TARGET}"
echo ""

update_element() {
  info "Checking latest Element Web release..."
  ELEMENT_API="https://api.github.com/repos/element-hq/element-web/releases/latest"
  RELEASE_JSON=$(curl -fsSL "${ELEMENT_API}" 2>/dev/null) || {
    warn "Could not reach GitHub API. Skipping Element update."; return 1
  }

  LATEST=$(echo "$RELEASE_JSON" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null)
  CURRENT=$(cat /var/www/element/version 2>/dev/null || echo "unknown")

  info "Installed: ${CURRENT}  /  Latest: ${LATEST}"

  if [[ "$CURRENT" == "$LATEST" ]]; then
    log "Element Web is up to date (${LATEST})."
    return 0
  fi

  ELEMENT_URL=$(echo "$RELEASE_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for a in d.get('assets', []):
    if a['name'].endswith('.tar.gz') and 'element-' in a['name']:
        print(a['browser_download_url']); break
" 2>/dev/null)

  [[ -z "$ELEMENT_URL" ]] && { warn "Could not find Element tarball URL."; return 1; }

  info "Downloading Element Web ${LATEST}..."
  mkdir -p /tmp/element-update
  wget -q --show-progress -O /tmp/element-update/element.tar.gz "${ELEMENT_URL}"

  info "Backing up current config.json..."
  cp /var/www/element/config.json /tmp/element-update/config.json.bak

  info "Extracting new version..."
  rm -rf /var/www/element/*
  tar -xzf /tmp/element-update/element.tar.gz \
    -C /var/www/element --strip-components=1

  info "Restoring config.json..."
  cp /tmp/element-update/config.json.bak /var/www/element/config.json

  # Record version
  echo "$LATEST" > /var/www/element/version

  chown -R www-data:www-data /var/www/element
  chmod -R 755 /var/www/element

  rm -rf /tmp/element-update
  log "Element Web updated to ${LATEST}"
}

update_packages() {
  info "Running apt update and upgrade for stack packages..."
  export DEBIAN_FRONTEND=noninteractive

  apt-get update -q

  # Upgrade specific packages only (avoid surprise OS changes)
  PKGS=(
    matrix-synapse-py3
    nginx
    postgresql-16
    coturn
    prosody
    jicofo
    jitsi-videobridge2
    jitsi-meet
    jitsi-meet-web-config
    jitsi-meet-prosody
    certbot
    python3-certbot-nginx
  )

  for pkg in "${PKGS[@]}"; do
    if dpkg -l "$pkg" &>/dev/null; then
      apt-get install -y --only-upgrade "$pkg" 2>/dev/null && \
        log "${pkg} checked/updated" || warn "${pkg}: upgrade skipped or failed"
    fi
  done

  info "Reloading services after package updates..."
  systemctl reload nginx          2>/dev/null || true
  systemctl restart matrix-synapse 2>/dev/null || true
}

update_valkey() {
  CURRENT_VER=$(/usr/local/bin/valkey-server --version 2>/dev/null | \
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")

  info "Checking latest Valkey release... (installed: ${CURRENT_VER})"

  LATEST_JSON=$(curl -fsSL \
    "https://api.github.com/repos/valkey-io/valkey/releases/latest" 2>/dev/null) || {
    warn "Could not reach GitHub API. Skipping Valkey update."; return 1
  }

  LATEST=$(echo "$LATEST_JSON" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))" 2>/dev/null)

  if [[ "$CURRENT_VER" == "$LATEST" ]]; then
    log "Valkey is up to date (${LATEST})."; return 0
  fi

  info "Updating Valkey ${CURRENT_VER} → ${LATEST}..."
  TARBALL="valkey-${LATEST}-linux-x86_64.tar.gz"
  URL="https://github.com/valkey-io/valkey/releases/download/${LATEST}/${TARBALL}"

  mkdir -p /tmp/valkey-update
  wget -q --show-progress -O "/tmp/valkey-update/${TARBALL}" "${URL}"

  systemctl stop valkey 2>/dev/null || true
  tar -xzf "/tmp/valkey-update/${TARBALL}" \
    -C /opt/valkey --strip-components=1
  systemctl start valkey

  rm -rf /tmp/valkey-update
  log "Valkey updated to ${LATEST}"
}

case "$TARGET" in
  all)
    update_packages
    echo ""
    update_element
    echo ""
    update_valkey
    ;;
  element)   update_element  ;;
  packages)  update_packages ;;
  valkey)    update_valkey   ;;
  *)
    error "Unknown target: ${TARGET}. Use: all, element, packages, valkey"
    exit 1 ;;
esac

echo ""
log "Update complete."
echo ""
info "Check status: ./scripts/stack-status.sh"
echo ""
