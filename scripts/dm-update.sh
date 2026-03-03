#!/usr/bin/env bash
# DocMaster — dm-update.sh
# Blue/Green update orchestrator.
# Swaps the /opt/docmaster symlink between -blue and -green.
#
# Usage: dm-update.sh <version>
# Example: dm-update.sh 1.0.1
#
# STRICT RULES:
#   - Always reference /opt/docmaster/ (symlink), never -blue or -green directly
#   - If health check fails within 60 seconds → auto-rollback to previous side
#   - Never break the Blue/Green mechanism

set -euo pipefail

VERSION="${1:-}"
if [ -z "${VERSION}" ]; then
    echo "Usage: dm-update.sh <version>" >&2
    exit 1
fi

INSTALL_BASE="/opt"
SYMLINK="${INSTALL_BASE}/docmaster"
BLUE="${INSTALL_BASE}/docmaster-blue"
GREEN="${INSTALL_BASE}/docmaster-green"
LOG_FILE="/opt/docmaster/logs/dm-update.log"
HEALTH_CHECK_URL="http://127.0.0.1:8443/dm/sentinel/health"
HEALTH_TIMEOUT=60

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [dm-update] $*" | tee -a "${LOG_FILE}"
}

# Determine current and target sides
CURRENT_TARGET=$(readlink -f "${SYMLINK}")
if [ "${CURRENT_TARGET}" = "${BLUE}" ]; then
    ACTIVE="blue"
    STANDBY="green"
    STANDBY_PATH="${GREEN}"
else
    ACTIVE="green"
    STANDBY="blue"
    STANDBY_PATH="${BLUE}"
fi

log "INFO: Starting update to v${VERSION}"
log "INFO: Active side: ${ACTIVE} (${CURRENT_TARGET})"
log "INFO: Target side: ${STANDBY} (${STANDBY_PATH})"

# Verify update bundle exists
UPDATE_BUNDLE="/opt/docmaster-updates/docmaster-${VERSION}.dmupdate"
if [ ! -f "${UPDATE_BUNDLE}" ]; then
    log "ERROR: Update bundle not found: ${UPDATE_BUNDLE}"
    exit 1
fi

# Verify bundle signature
log "INFO: Verifying bundle signature..."
if ! dm-vault-keytool --verify-bundle "${UPDATE_BUNDLE}"; then
    log "ERROR: Bundle signature verification failed. Aborting."
    exit 1
fi

# Apply update to standby side
log "INFO: Applying update to ${STANDBY} side..."
tar -xzf "${UPDATE_BUNDLE}" --directory "${STANDBY_PATH}/"
log "INFO: Update applied to ${STANDBY_PATH}"

# Stop services
log "INFO: Stopping dm-core and dm-flux..."
systemctl stop dm-core dm-flux || true
sleep 2

# Swap symlink atomically
log "INFO: Swapping symlink to ${STANDBY} side..."
ln -sfn "${STANDBY_PATH}" "${SYMLINK}"
sync
log "INFO: Symlink updated: ${SYMLINK} → ${STANDBY_PATH}"

# Restart services
log "INFO: Starting services on new side..."
systemctl start dm-vault dm-core dm-flux dm-sentinel

# Health check with auto-rollback
log "INFO: Waiting for health check (timeout: ${HEALTH_TIMEOUT}s)..."
elapsed=0
while [ "${elapsed}" -lt "${HEALTH_TIMEOUT}" ]; do
    STATUS=$(curl -sf --max-time 5 "${HEALTH_CHECK_URL}" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','unknown'))" 2>/dev/null || echo "unavailable")

    if [ "${STATUS}" = "ok" ]; then
        log "INFO: Health check passed. Update to v${VERSION} successful."
        log "INFO: Active: ${STANDBY} | Standby: ${ACTIVE}"
        exit 0
    fi

    sleep 2
    elapsed=$((elapsed + 2))
    log "INFO: Health check status: ${STATUS} (${elapsed}s elapsed)"
done

# Health check failed — auto-rollback
log "ERROR: Health check failed after ${HEALTH_TIMEOUT}s. Rolling back to ${ACTIVE} side..."
systemctl stop dm-core dm-flux || true
ln -sfn "${CURRENT_TARGET}" "${SYMLINK}"
sync
systemctl start dm-vault dm-core dm-flux dm-sentinel
log "INFO: Rollback complete. Active: ${ACTIVE}"
exit 1
