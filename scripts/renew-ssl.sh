#!/bin/bash
# scripts/renew-ssl.sh
# Re-run SSL certificate provisioning after DNS has propagated.
# Usage: ./scripts/renew-ssl.sh  (run from repo root)

set -euo pipefail

if [[ ! -f /root/.matrix-stack.env ]]; then
  echo "ERROR: /root/.matrix-stack.env not found. Run setup.sh first."
  exit 1
fi

source /root/.matrix-stack.env
export DOMAIN MATRIX_DOMAIN JITSI_DOMAIN ELEMENT_DOMAIN \
       ADMIN_USER ADMIN_PASS JITSI_PASS TURN_SECRET \
       POSTGRES_PASS VALKEY_PASS MATRIX_SHARED_SECRET \
       JITSI_APP_SECRET SKIP_SSL STAGING SCRIPT_DIR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash "${SCRIPT_DIR}/build/09-ssl.sh"
