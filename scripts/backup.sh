#!/bin/bash
# =============================================================================
# scripts/backup.sh
# Backup all Matrix stack configuration and data.
# Backs up: Synapse config+media, PostgreSQL dump, Valkey config,
#           Nginx vhosts, SSL certs, and the .env file.
#
# Usage:
#   ./scripts/backup.sh
#   ./scripts/backup.sh --dest /mnt/user/backups
#   ./scripts/backup.sh --no-media   # skip media store (faster)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root
load_env

DEST_DIR="/root/backups"
INCLUDE_MEDIA=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest|-d)     DEST_DIR="$2"; shift 2 ;;
    --no-media)    INCLUDE_MEDIA=false; shift ;;
    --help|-h)
      echo "Usage: $0 [--dest DIR] [--no-media]"
      exit 0 ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
done

TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
BACKUP_DIR="${DEST_DIR}/matrix-backup-${TIMESTAMP}"
mkdir -p "${BACKUP_DIR}"

header "Matrix Stack Backup"
echo ""
info "Backup destination: ${BACKUP_DIR}"
echo ""

# ── Environment / secrets ────────────────────────────────────────────────────
info "Backing up environment file..."
cp /root/.matrix-stack.env "${BACKUP_DIR}/matrix-stack.env"
chmod 600 "${BACKUP_DIR}/matrix-stack.env"
log "Environment saved"

# ── Synapse config ────────────────────────────────────────────────────────────
info "Backing up Matrix Synapse configuration..."
tar -czf "${BACKUP_DIR}/synapse-config.tar.gz" \
  /etc/matrix-synapse/ 2>/dev/null
log "Synapse config saved ($(du -sh "${BACKUP_DIR}/synapse-config.tar.gz" | cut -f1))"

# ── Signing key (critical - don't lose this) ─────────────────────────────────
SIGNING_KEY="/var/lib/matrix-synapse/${DOMAIN}.signing.key"
if [[ -f "$SIGNING_KEY" ]]; then
  cp "$SIGNING_KEY" "${BACKUP_DIR}/matrix-signing.key"
  chmod 600 "${BACKUP_DIR}/matrix-signing.key"
  log "Signing key saved (CRITICAL - protect this file)"
fi

# ── PostgreSQL dump ───────────────────────────────────────────────────────────
info "Dumping PostgreSQL synapse database..."
PGPASSWORD="${POSTGRES_PASS}" pg_dump \
  -h 127.0.0.1 -U synapse -d synapse \
  --format=custom \
  --file="${BACKUP_DIR}/synapse-db.pgdump" 2>/dev/null && \
  log "Database dump saved ($(du -sh "${BACKUP_DIR}/synapse-db.pgdump" | cut -f1))" || \
  warn "Database dump failed - check PostgreSQL is running"

# ── Media store ───────────────────────────────────────────────────────────────
if [[ "$INCLUDE_MEDIA" == true ]]; then
  info "Backing up media store..."
  MEDIA_SIZE=$(du -sh /var/lib/matrix-synapse/media_store 2>/dev/null | cut -f1)
  info "  Media store size: ${MEDIA_SIZE} (this may take a while)"
  tar -czf "${BACKUP_DIR}/synapse-media.tar.gz" \
    /var/lib/matrix-synapse/media_store/ 2>/dev/null && \
    log "Media store saved" || \
    warn "Media store backup failed"
else
  warn "Skipping media store (--no-media)"
fi

# ── Nginx config ──────────────────────────────────────────────────────────────
info "Backing up Nginx configuration..."
tar -czf "${BACKUP_DIR}/nginx-config.tar.gz" \
  /etc/nginx/ 2>/dev/null
log "Nginx config saved"

# ── SSL certificates ──────────────────────────────────────────────────────────
info "Backing up SSL certificates..."
tar -czf "${BACKUP_DIR}/ssl-certs.tar.gz" \
  /etc/ssl/nginx/ \
  /etc/letsencrypt/ 2>/dev/null
log "SSL certs saved"

# ── Valkey / coturn / Jitsi configs ──────────────────────────────────────────
info "Backing up service configs..."
tar -czf "${BACKUP_DIR}/service-configs.tar.gz" \
  /etc/valkey/ \
  /etc/turnserver.conf \
  /etc/jitsi/ \
  /etc/prosody/ \
  /usr/share/jitsi-meet/config.js \
  /var/www/element/config.json \
  2>/dev/null
log "Service configs saved"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
TOTAL_SIZE=$(du -sh "${BACKUP_DIR}" | cut -f1)
log "Backup complete!"
echo ""
echo -e "  ${BOLD}Location:${NC}  ${BACKUP_DIR}"
echo -e "  ${BOLD}Size:${NC}      ${TOTAL_SIZE}"
echo ""
echo "  Files:"
ls -lh "${BACKUP_DIR}" | awk '{print "    "$0}'
echo ""
warn "The backup contains secrets. Protect it:"
echo "  chmod 700 ${BACKUP_DIR}"
echo "  chmod 600 ${BACKUP_DIR}/*"
chmod 700 "${BACKUP_DIR}"
chmod 600 "${BACKUP_DIR}"/* 2>/dev/null || true
echo ""
info "To restore the database:"
echo "  PGPASSWORD=... pg_restore -h 127.0.0.1 -U synapse -d synapse ${BACKUP_DIR}/synapse-db.pgdump"
echo ""
