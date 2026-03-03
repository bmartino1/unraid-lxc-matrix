#!/bin/bash
# SETUP PHASE - 04: Write Element Web config.json
set -euo pipefail

ELEMENT_DIR="/var/www/element"

echo "  Writing Element Web config.json..."
cat > "${ELEMENT_DIR}/config.json" <<EOF
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
    "https://scalar.vector.im/api"
  ],
  "show_labs_settings": false,
  "features": {},
  "default_theme": "dark",
  "room_directory": {
    "servers": ["${DOMAIN}"]
  },
  "enable_presence_by_hs_url": {
    "https://${MATRIX_DOMAIN}": true
  },
  "jitsi": {
    "preferred_domain": "${JITSI_DOMAIN}"
  },
  "map_style_url": "https://api.maptiler.com/maps/streets/style.json?key=fU3vleas53NIPBBmaNfB"
}
EOF

chown www-data:www-data "${ELEMENT_DIR}/config.json"
echo "  Element Web configured for https://${MATRIX_DOMAIN}"
