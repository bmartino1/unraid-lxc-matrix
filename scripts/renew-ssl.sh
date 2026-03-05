#!/bin/bash
# scripts/renew-ssl.sh
# Re-run SSL certificate provisioning after DNS has propagated.
# Safe to run multiple times.
set -euo pipefail

if [[ ! -f /root/matrix.env ]]; then
  echo "ERROR: /root/matrix.env not found. Run setup.sh first."
  exit 1
fi

set -a; source /root/matrix.env; set +a
export SETUP_DIR="${SETUP_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

echo "Re-running SSL provisioning for: ${DOMAIN}, ${DOMAIN}, ${MEET}"
bash "${SETUP_DIR}/setup/08-ssl.sh"
