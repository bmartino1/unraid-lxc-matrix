#!/bin/bash
# scripts/renew-ssl.sh
# Re-run SSL certificate provisioning after DNS has propagated.
# Safe to run multiple times.
set -euo pipefail

if [[ ! -f /root/.matrix-stack.env ]]; then
  echo "ERROR: /root/.matrix-stack.env not found. Run setup.sh first."
  exit 1
fi

set -a; source /root/.matrix-stack.env; set +a
export SETUP_DIR="${SETUP_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

echo "Re-running SSL provisioning for: ${DOMAIN}, ${MATRIX_DOMAIN}, ${JITSI_DOMAIN}"
bash "${SETUP_DIR}/setup/08-ssl.sh"
