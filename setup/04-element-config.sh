#!/bin/bash
set -euo pipefail
echo "  Configuring Element Web..."

# Element Web can be at /var/www/element (build download) or /usr/share/element-web (apt)
ELEMENT_DIR="/var/www/element"
[[ -d "/usr/share/element-web" ]] && ELEMENT_DIR="/usr/share/element-web"

cat > "${ELEMENT_DIR}/config.json" <<ECONF
{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "https://${DOMAIN}",
      "server_name": "${DOMAIN}"
    }
  },
  "disable_custom_urls": true,
  "disable_guests": true,
  "brand": "Matrix Chat",
  "default_theme": "dark",
  "room_directory": {
    "servers": ["${DOMAIN}"]
  },
  "show_labs_settings": false,
  "default_country_code": "US",
  "jitsi": {
    "preferred_domain": "${MEET}"
  },
  "jitsi_widget": {
    "skip_built_in_welcome_screen": true
  },
  "features": {
    "feature_video_rooms": false,
    "feature_group_calls": false,
    "feature_element_call_video_rooms": false
  },
  "setting_defaults": {
    "breadcrumbs": true
  },
  "map_style_url": null
}
ECONF

chown www-data:www-data "${ELEMENT_DIR}/config.json" 2>/dev/null || true
echo "  Element Web configured."
