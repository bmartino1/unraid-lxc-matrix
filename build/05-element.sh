#!/bin/bash
# Stage 05 - Element Web (Matrix client) install
# Downloads latest production release tarball from GitHub
set -euo pipefail

ELEMENT_INSTALL_DIR="/var/www/element"
ELEMENT_API_URL="https://api.github.com/repos/element-hq/element-web/releases/latest"

echo "==> Fetching latest Element Web release info..."
RELEASE_JSON=$(curl -fsSL "${ELEMENT_API_URL}")
ELEMENT_VERSION=$(echo "$RELEASE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")
ELEMENT_URL=$(echo "$RELEASE_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assets = data.get('assets', [])
for a in assets:
    if a['name'].endswith('.tar.gz') and 'element-' in a['name']:
        print(a['browser_download_url'])
        break
")

echo "==> Downloading Element Web ${ELEMENT_VERSION}..."
mkdir -p /tmp/element-build
wget -O /tmp/element-build/element.tar.gz "${ELEMENT_URL}"

echo "==> Extracting Element Web to ${ELEMENT_INSTALL_DIR}..."
mkdir -p "${ELEMENT_INSTALL_DIR}"
tar -xzf /tmp/element-build/element.tar.gz -C "${ELEMENT_INSTALL_DIR}" --strip-components=1

echo "==> Writing Element Web config.json..."
cat > "${ELEMENT_INSTALL_DIR}/config.json" <<EOF
{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "https://${MATRIX_DOMAIN}",
      "server_name": "${DOMAIN}"
    },
    "m.identity_server": {
      "base_url": "https://vector.im"
    }
  },
  "brand": "Element",
  "integrations_ui_url": "https://scalar.vector.im/",
  "integrations_rest_url": "https://scalar.vector.im/api",
  "integrations_widgets_urls": [
    "https://scalar.vector.im/_matrix/integrations/v1",
    "https://scalar.vector.im/api",
    "https://scalar-staging.vector.im/_matrix/integrations/v1",
    "https://scalar-staging.vector.im/api"
  ],
  "bug_report_endpoint_url": "https://element.io/bugreports/submit",
  "default_country_code": "GB",
  "show_labs_settings": false,
  "features": {
    "feature_spotlight": false
  },
  "default_theme": "dark",
  "room_directory": {
    "servers": [
      "${DOMAIN}"
    ]
  },
  "enable_presence_by_hs_url": {
    "https://${MATRIX_DOMAIN}": true
  },
  "jitsi": {
    "preferred_domain": "${JITSI_DOMAIN}"
  },
  "element_call": {
    "url": "https://${JITSI_DOMAIN}"
  }
}
EOF

echo "==> Setting permissions..."
chown -R www-data:www-data "${ELEMENT_INSTALL_DIR}"
chmod -R 755 "${ELEMENT_INSTALL_DIR}"

rm -rf /tmp/element-build

echo "==> Element Web ${ELEMENT_VERSION} installed at ${ELEMENT_INSTALL_DIR}"
echo "Completed Stage 05 - Element Web"
