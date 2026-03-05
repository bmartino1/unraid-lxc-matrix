#!/bin/bash
# =============================================================================
# scripts/admin.sh
# Interactive admin menu for the Matrix Stack.
# Provides a menu-driven interface to all management scripts.
#
# Usage:
#   ./scripts/admin.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root

# Source env if setup has been run (don't fail if not)
[[ -f /root/.matrix-stack.env ]] && { set -a; source /root/.matrix-stack.env; set +a; }

DOMAIN="${DOMAIN:-<not configured>}"

clear_screen() { clear; }

print_banner() {
  clear_screen
  echo ""
  echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}${BOLD}║       Matrix Stack — Admin Console                       ║${NC}"
  echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
  echo -e "  Domain: ${BOLD}${DOMAIN}${NC}"
  echo ""
}

pause() {
  echo ""
  read -rp "  Press Enter to return to menu..." _
}

run_script() {
  local SCRIPT="${SCRIPT_DIR}/${1}"
  shift
  if [[ -x "$SCRIPT" ]]; then
    bash "$SCRIPT" "$@"
  else
    error "Script not found: $SCRIPT"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN MENU
# ─────────────────────────────────────────────────────────────────────────────
while true; do
  print_banner

  echo -e "  ${BOLD}── Stack ─────────────────────────────────────${NC}"
  echo "  1)  Stack Status           (health + services + SSL)"
  echo "  2)  View Logs              (tail / search logs)"
  echo "  3)  Service Control        (start / stop / restart)"
  echo "  4)  Update Stack           (Element, packages, Valkey)"
  echo "  5)  Backup                 (config, DB, media, certs)"
  echo ""
  echo -e "  ${BOLD}── Users ─────────────────────────────────────${NC}"
  echo "  6)  Create User"
  echo "  7)  List Users"
  echo "  8)  Manage User            (deactivate/promote/reset-pw/info)"
  echo "  9)  Get Admin Token"
  echo ""
  echo -e "  ${BOLD}── Registration ──────────────────────────────${NC}"
  echo " 10)  Registration Tokens    (create / list / delete invite tokens)"
  echo " 11)  Toggle Registration    (enable/disable open registration)"
  echo ""
  echo -e "  ${BOLD}── Rooms ─────────────────────────────────────${NC}"
  echo " 12)  Room Management        (list / info / delete / purge)"
  echo ""
  echo -e "  ${BOLD}── SSL / Domain ──────────────────────────────${NC}"
  echo " 13)  Renew SSL Certificates"
  echo ""
  echo "  q)  Quit"
  echo ""
  read -rp "  Choice: " CHOICE

  case "$CHOICE" in

    1)  # Stack status
        print_banner
        run_script "stack-status.sh"
        pause
        ;;

    2)  # Logs
        print_banner
        run_script "logs.sh"
        pause
        ;;

    3)  # Service control
        print_banner
        echo ""
        echo "  Services: all, synapse, nginx, postgresql, valkey, prosody, jicofo, jvb, coturn"
        echo "  Actions:  start, stop, restart, status"
        echo ""
        read -rp "  Action: " SVC_ACTION
        read -rp "  Service (or 'all'): " SVC_TARGET
        run_script "service-control.sh" "$SVC_ACTION" "$SVC_TARGET"
        pause
        ;;

    4)  # Update
        print_banner
        echo ""
        echo "  Targets: all, element, packages, valkey"
        read -rp "  Target (default: all): " UPD_TARGET
        run_script "update-stack.sh" "${UPD_TARGET:-all}"
        pause
        ;;

    5)  # Backup
        print_banner
        echo ""
        read -rp "  Backup destination [/root/backups]: " DEST
        DEST="${DEST:-/root/backups}"
        read -rp "  Include media store? [Y/n]: " MEDIA_ANS
        MEDIA_FLAG=""
        [[ "${MEDIA_ANS,,}" == "n" ]] && MEDIA_FLAG="--no-media"
        run_script "backup.sh" --dest "$DEST" $MEDIA_FLAG
        pause
        ;;

    6)  # Create user
        print_banner
        run_script "create-user.sh"
        pause
        ;;

    7)  # List users
        print_banner
        echo ""
        echo "  Options: (leave blank for default, or type: --guests --deactivated --csv)"
        read -rp "  Extra options: " LIST_OPTS
        # shellcheck disable=SC2086
        run_script "list-users.sh" $LIST_OPTS
        pause
        ;;

    8)  # Manage user
        print_banner
        echo ""
        echo "  Actions: info, deactivate, reactivate, promote, demote, reset-password, shadow-ban, logout-all"
        echo ""
        read -rp "  Username (without @domain): " MGMT_USER
        read -rp "  Action: " MGMT_ACTION
        run_script "user-manage.sh" --user "$MGMT_USER" --action "$MGMT_ACTION"
        pause
        ;;

    9)  # Get admin token
        print_banner
        echo ""
        read -rp "  Save token to .env file? [y/N]: " SAVE_TOK
        SAVE_FLAG=""
        [[ "${SAVE_TOK,,}" == "y" ]] && SAVE_FLAG="--save"
        run_script "get-admin-token.sh" $SAVE_FLAG
        pause
        ;;

    10) # Registration tokens
        print_banner
        echo ""
        echo "  Commands: list, create, delete, info"
        read -rp "  Command (default: list): " TOK_CMD
        run_script "registration-tokens.sh" "${TOK_CMD:-list}"
        pause
        ;;

    11) # Toggle registration
        print_banner
        echo ""
        echo "  Actions: enable, disable, status"
        read -rp "  Action (default: status): " REG_ACTION
        run_script "registration-toggle.sh" "${REG_ACTION:-status}"
        pause
        ;;

    12) # Room management
        print_banner
        echo ""
        echo "  Commands: list, info, members, delete, purge"
        read -rp "  Command (default: list): " ROOM_CMD
        run_script "room-manage.sh" "${ROOM_CMD:-list}"
        pause
        ;;

    13) # Renew SSL
        print_banner
        run_script "renew-ssl.sh"
        pause
        ;;

    q|Q|quit|exit)
        echo ""
        echo "  Goodbye."
        echo ""
        exit 0
        ;;

    *)
        warn "Invalid choice: ${CHOICE}"
        sleep 1
        ;;
  esac
done
