#!/bin/bash
# =============================================================================
# patch.sh — Matrix Synapse + Element Web + Jitsi + coturn Configurator
# =============================================================================
# Architecture:
#   https://DOMAIN         → Element Web + Synapse
#   https://meet.DOMAIN    → Jitsi Meet
#   turn.DOMAIN:443/5349   → coturn TURNS
#   turn.DOMAIN:3478       → coturn TURN
#
# DNS required:
#   DOMAIN, meet.DOMAIN, turn.DOMAIN
# Update script puling data from lxc matrix.env to secure nginx meet
# =============================================================================

set -euo pipefail

#WIP
