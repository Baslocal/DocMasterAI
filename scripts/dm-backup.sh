#!/usr/bin/env bash
# DocMaster — dm-backup.sh
# Nightly encrypted PostgreSQL database backup.
# Scheduled: 02:30 UTC daily via /etc/cron.d/docmaster
# Run as: dmuser
#
# Encryption: GPG symmetric with hardware-derived passphrase (from dm-vault)
# Recovery: Shamir's Secret Sharing (3-of-5 vendor key shares)
# Retention: 7 days (configurable via backup_retention_days in system_config)
#
# Output: /opt/docmaster/backups/daily/docmaster_YYYYMMDD_HHMMSS.sql.gz.gpg

set -euo pipefail

INSTALL_PATH="${INSTALL_PATH:-/opt/docmaster}"
BACKUP_DIR="${INSTALL_PATH}/backups/daily"
LOG_FILE="${INSTALL_PATH}/logs/dm-backup.log"
DB_NAME="${DB_NAME:-dm_vault}"
DB_USER="${DB_USER:-dm_app}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"

TIMESTAMP=$(date -u +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/docmaster_${TIMESTAMP}.sql.gz.gpg"
CHECKSUM_FILE="${BACKUP_FILE}.sha256"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [dm-backup] $*" | tee -a "${LOG_FILE}"
}

log "INFO: Starting nightly backup — ${TIMESTAMP}"

# Verify backup directory exists
mkdir -p "${BACKUP_DIR}"

# Derive GPG passphrase from dm-vault (hardware-derived key)
# In production, dm-vault exposes a restricted socket endpoint for backup scripts
# to retrieve the passphrase without writing it to disk.
if command -v dm-vault-keytool &> /dev/null; then
    GPG_PASSPHRASE=$(dm-vault-keytool --get-backup-passphrase)
else
    log "WARN: dm-vault-keytool not available — using BACKUP_GPG_PASSPHRASE from environment"
    GPG_PASSPHRASE="${BACKUP_GPG_PASSPHRASE:-}"
fi

if [ -z "${GPG_PASSPHRASE}" ]; then
    log "ERROR: No backup passphrase available. Cannot encrypt backup."
    exit 1
fi

# Create encrypted backup: pg_dump | gzip | gpg
log "INFO: Dumping dm_vault database..."
PGPASSWORD="${DB_PASSWORD}" pg_dump \
    --host="${DB_HOST}" \
    --port="${DB_PORT}" \
    --username="${DB_USER}" \
    --format=plain \
    --no-password \
    "${DB_NAME}" \
    | gzip -9 \
    | gpg --symmetric \
          --cipher-algo AES256 \
          --passphrase-fd 3 \
          --batch \
          --output "${BACKUP_FILE}" 3<<<"${GPG_PASSPHRASE}"

log "INFO: Backup written: $(basename "${BACKUP_FILE}")"

# Generate checksum
sha256sum "${BACKUP_FILE}" > "${CHECKSUM_FILE}"
log "INFO: Checksum: $(cat "${CHECKSUM_FILE}")"

# Cleanup old backups beyond retention window
log "INFO: Removing backups older than ${RETENTION_DAYS} days..."
find "${BACKUP_DIR}" -name "docmaster_*.sql.gz.gpg" -mtime "+${RETENTION_DAYS}" -delete
find "${BACKUP_DIR}" -name "docmaster_*.sha256" -mtime "+${RETENTION_DAYS}" -delete

log "INFO: Backup complete. Current backups:"
ls -lh "${BACKUP_DIR}" >> "${LOG_FILE}"
