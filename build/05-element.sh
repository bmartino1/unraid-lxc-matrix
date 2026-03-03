#!/bin/bash
# =============================================================================
# BUILD PHASE - Stage 05: Element Web download and stage
# config.json (domain/homeserver URL) written at setup time
# =============================================================================
set -euo pipefail

ELEMENT_INSTALL_DIR="/var/www/element"
ELEMENT_API="https://api.github.com/repos/element-hq/element-web/releases/latest"

echo "==> [05] Fetching latest Element Web release..."
RELEASE_JSON=$(curl -fsSL "${ELEMENT_API}")
ELEMENT_VERSION=$(echo "$RELEASE_JSON" | python3 -c \
  "import sys,json; print(json.load(sys.stdin)['tag_name'])")
ELEMENT_URL=$(echo "$RELEASE_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for a in d.get('assets', []):
    if a['name'].endswith('.tar.gz') and 'element-' in a['name']:
        print(a['browser_download_url']); break
")

echo "==> [05] Downloading Element Web ${ELEMENT_VERSION}..."
mkdir -p /tmp/element-build
wget -q --show-progress -O /tmp/element-build/element.tar.gz "${ELEMENT_URL}"

echo "==> [05] Extracting to ${ELEMENT_INSTALL_DIR}..."
mkdir -p "${ELEMENT_INSTALL_DIR}"
tar -xzf /tmp/element-build/element.tar.gz \
  -C "${ELEMENT_INSTALL_DIR}" --strip-components=1

echo "==> [05] Setting ownership..."
chown -R www-data:www-data "${ELEMENT_INSTALL_DIR}"
chmod -R 755 "${ELEMENT_INSTALL_DIR}"

# Remove the default config.json - setup phase writes a real one
rm -f "${ELEMENT_INSTALL_DIR}/config.json"

# Leave a placeholder so the directory is obviously incomplete without setup
cat > "${ELEMENT_INSTALL_DIR}/config.json.placeholder" <<'EOF'
{
  "_comment": "This file is replaced by setup.sh - do not edit directly",
  "_run": "Run setup.sh --domain yourdomain.com to configure"
}
EOF

rm -rf /tmp/element-build
echo "==> [05] Element Web ${ELEMENT_VERSION} staged at ${ELEMENT_INSTALL_DIR}"
echo "==> Completed Stage 05 - Element Web staged (not yet configured)"
