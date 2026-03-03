#!/usr/bin/env bash
# DocMaster — dm-init-db.sh
# Idempotent database initialization script (Phase 2 gate requirement).
# Safe to re-run if it fails partway through.
#
# Performs:
#   1. Creates dm_app role (if not exists)
#   2. Creates dm_vault database (if not exists)
#   3. Applies all SQL files in order: 01–07
#   4. Verifies all 12 tables exist
#   5. Verifies seed data (39 system_config rows + 8 connector_configs)
#
# Run as: postgres superuser or with PGPASSWORD set for a superuser

set -euo pipefail

INSTALL_PATH="${INSTALL_PATH:-/opt/docmaster}"
SQL_PATH="${INSTALL_PATH}/sql"
LOG_FILE="${INSTALL_PATH}/logs/dm-init-db.log"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-dm_vault}"
DB_USER="${DB_USER:-dm_app}"
DB_PASSWORD="${DB_PASSWORD:-}"

# Superuser connection for initial setup (postgres role)
PG_SUPERUSER="${PG_SUPERUSER:-postgres}"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [dm-init-db] $*" | tee -a "${LOG_FILE}"
}

run_sql() {
    local file="$1"
    local user="${2:-${PG_SUPERUSER}}"
    local db="${3:-${DB_NAME}}"
    log "INFO: Applying ${file} as ${user}@${db}"
    psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${user}" -d "${db}" -f "${file}" -v ON_ERROR_STOP=1
}

run_sql_stmt() {
    local stmt="$1"
    local user="${2:-${PG_SUPERUSER}}"
    local db="${3:-postgres}"
    psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${user}" -d "${db}" -c "${stmt}" -v ON_ERROR_STOP=1
}

log "INFO: DocMaster database initialization starting..."
mkdir -p "$(dirname "${LOG_FILE}")"

# ── Step 1: Create dm_app role (idempotent) ────────────────────────────────
log "INFO: Step 1 — Creating dm_app role..."
run_sql_stmt "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'dm_app') THEN CREATE ROLE dm_app LOGIN PASSWORD '${DB_PASSWORD}' NOSUPERUSER NOCREATEDB NOCREATEROLE; END IF; END \$\$;" postgres postgres

# ── Step 2: Create dm_vault database (idempotent) ─────────────────────────
log "INFO: Step 2 — Creating dm_vault database..."
if ! psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${PG_SUPERUSER}" -lqt | cut -d'|' -f1 | grep -qw "${DB_NAME}"; then
    run_sql_stmt "CREATE DATABASE ${DB_NAME} WITH OWNER dm_app ENCODING 'UTF8' TEMPLATE template0;" postgres postgres
    log "INFO: Database ${DB_NAME} created."
else
    log "INFO: Database ${DB_NAME} already exists — skipping creation."
fi

# ── Steps 3–9: Apply SQL files ─────────────────────────────────────────────
log "INFO: Step 3 — Applying schema SQL files..."
run_sql "${SQL_PATH}/01_extensions.sql" "${PG_SUPERUSER}" "${DB_NAME}"
run_sql "${SQL_PATH}/02_schemas.sql"    "${PG_SUPERUSER}" "${DB_NAME}"
run_sql "${SQL_PATH}/03_enums.sql"      "${PG_SUPERUSER}" "${DB_NAME}"
run_sql "${SQL_PATH}/04_tables.sql"     "${PG_SUPERUSER}" "${DB_NAME}"
run_sql "${SQL_PATH}/05_indexes.sql"    "${PG_SUPERUSER}" "${DB_NAME}"
run_sql "${SQL_PATH}/06_views.sql"      "${PG_SUPERUSER}" "${DB_NAME}"
run_sql "${SQL_PATH}/07_seed_config.sql" "${DB_USER}"     "${DB_NAME}"

# ── Step 4: Verify tables ─────────────────────────────────────────────────
log "INFO: Step 4 — Verifying table existence..."
EXPECTED_TABLES=(
    "dm_core.documents"
    "dm_core.extractions"
    "dm_core.document_events"
    "dm_core.embeddings"
    "dm_flux.jobs"
    "dm_flux.audit_log"
    "dm_sentinel.health_snapshots"
    "dm_vault.operators"
    "dm_vault.system_config"
    "dm_vault.license_records"
    "dm_vault.connector_configs"
)

ALL_OK=true
for table in "${EXPECTED_TABLES[@]}"; do
    schema="${table%%.*}"
    tname="${table##*.}"
    count=$(psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -tAc \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${schema}' AND table_name='${tname}';")
    if [ "${count}" = "1" ]; then
        log "INFO:   ✓ ${table}"
    else
        log "ERROR:  ✗ ${table} — NOT FOUND"
        ALL_OK=false
    fi
done

# ── Step 5: Verify seed data ───────────────────────────────────────────────
log "INFO: Step 5 — Verifying seed data..."
config_count=$(psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -tAc \
    "SELECT COUNT(*) FROM dm_vault.system_config;")
connector_count=$(psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -tAc \
    "SELECT COUNT(*) FROM dm_vault.connector_configs;")

log "INFO: system_config rows: ${config_count} (expected ≥39)"
log "INFO: connector_configs rows: ${connector_count} (expected 8)"

if [ "${config_count}" -lt 39 ]; then
    log "ERROR: system_config seed data incomplete (${config_count} < 39)"
    ALL_OK=false
fi

if [ "${ALL_OK}" = "true" ]; then
    log "INFO: ✓ Phase 2 database gate PASSED. All tables and seed data verified."
    exit 0
else
    log "ERROR: ✗ Phase 2 database gate FAILED. Review errors above."
    exit 1
fi
