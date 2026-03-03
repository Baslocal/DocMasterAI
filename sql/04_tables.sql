-- DocMaster — Phase 2: Core Table Definitions
-- Database: dm_vault
-- Run after: 01_extensions.sql, 02_schemas.sql, 03_enums.sql
--
-- STRICT RULES:
--   - UUID primary keys on all core tables
--   - BIGSERIAL only for audit_log and health_snapshots (write performance)
--   - All timestamps are TIMESTAMPTZ (UTC enforced at app layer)
--   - No tables outside the four defined schemas

-- ── dm_vault.operators ────────────────────────────────────────────────────
-- Must exist before dm_core.documents (FK reference)
CREATE TABLE IF NOT EXISTS dm_vault.operators (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    username        TEXT            NOT NULL UNIQUE,
    display_name    TEXT            NOT NULL,
    password_hash   TEXT            NOT NULL,       -- bcrypt cost 12
    role            dm_vault.operator_role NOT NULL DEFAULT 'reviewer',
    is_active       BOOLEAN         NOT NULL DEFAULT TRUE,
    last_login_at   TIMESTAMPTZ,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    created_by      UUID            REFERENCES dm_vault.operators (id) ON DELETE SET NULL
);

-- ── dm_core.documents ─────────────────────────────────────────────────────
-- Central document record — every ingested document has exactly one row here
CREATE TABLE IF NOT EXISTS dm_core.documents (
    id                      UUID                    PRIMARY KEY DEFAULT gen_random_uuid(),
    filename                TEXT                    NOT NULL,
    original_name           TEXT                    NOT NULL,
    hash_sha256             CHAR(64)                NOT NULL UNIQUE,   -- deduplication
    file_path               TEXT                    NOT NULL,
    file_size_bytes         BIGINT,
    mime_type               TEXT,
    page_count              INTEGER                 NOT NULL DEFAULT 1,
    doc_type                dm_core.document_type   NOT NULL DEFAULT 'unknown',
    status                  dm_core.document_status NOT NULL DEFAULT 'queued',
    confidence_score        NUMERIC(5,2),                              -- 0.00–100.00
    source_channel          dm_core.ingest_channel  NOT NULL DEFAULT 'api',
    operator_id             UUID                    REFERENCES dm_vault.operators (id) ON DELETE SET NULL,
    ingested_at             TIMESTAMPTZ             NOT NULL DEFAULT NOW(),
    queued_at               TIMESTAMPTZ,
    processing_started_at   TIMESTAMPTZ,
    processed_at            TIMESTAMPTZ,
    reviewed_at             TIMESTAMPTZ,
    reviewed_by             UUID                    REFERENCES dm_vault.operators (id) ON DELETE SET NULL,
    retry_count             SMALLINT                NOT NULL DEFAULT 0,
    error_message           TEXT,
    metadata_json           JSONB                   NOT NULL DEFAULT '{}'
);

-- ── dm_core.extractions ───────────────────────────────────────────────────
-- Per-field extracted data — one row per field per document
CREATE TABLE IF NOT EXISTS dm_core.extractions (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id     UUID        NOT NULL REFERENCES dm_core.documents (id) ON DELETE CASCADE,
    field_name      TEXT        NOT NULL,
    field_value     TEXT,
    field_order     SMALLINT    NOT NULL DEFAULT 0,
    confidence      NUMERIC(5,2),                  -- 0.00–1.00 from LLM
    is_corrected    BOOLEAN     NOT NULL DEFAULT FALSE,
    original_value  TEXT,                          -- preserved when operator corrects
    corrected_by    UUID        REFERENCES dm_vault.operators (id) ON DELETE SET NULL,
    corrected_at    TIMESTAMPTZ,
    ocr_engine      TEXT,                          -- 'tesseract'|'paddle'|'kraken'|'olmocr'|'claude_api'|'ollama'
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── dm_core.document_events ───────────────────────────────────────────────
-- Immutable activity timeline — one row per event per document
CREATE TABLE IF NOT EXISTS dm_core.document_events (
    id              UUID                    PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id     UUID                    NOT NULL REFERENCES dm_core.documents (id) ON DELETE CASCADE,
    event_type      dm_core.event_type      NOT NULL,
    event_at        TIMESTAMPTZ             NOT NULL DEFAULT NOW(),
    duration_ms     INTEGER,
    detail          TEXT,
    operator_id     UUID                    REFERENCES dm_vault.operators (id) ON DELETE SET NULL,
    metadata_json   JSONB
);

-- ── dm_core.embeddings ────────────────────────────────────────────────────
-- Vector chunks for semantic search — 768-dim nomic-embed-text vectors
CREATE TABLE IF NOT EXISTS dm_core.embeddings (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id     UUID        NOT NULL REFERENCES dm_core.documents (id) ON DELETE CASCADE,
    chunk_index     SMALLINT    NOT NULL,
    chunk_text      TEXT        NOT NULL,
    embedding       vector(768) NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (document_id, chunk_index)
);

-- ── dm_flux.jobs ──────────────────────────────────────────────────────────
-- Persistent job queue record — mirrors what is in Redis
CREATE TABLE IF NOT EXISTS dm_flux.jobs (
    id              UUID                    PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id     UUID                    REFERENCES dm_core.documents (id) ON DELETE SET NULL,
    document_hash   CHAR(64),
    priority        dm_flux.job_priority    NOT NULL DEFAULT 'normal',
    status          dm_flux.job_status      NOT NULL DEFAULT 'queued',
    source_channel  dm_core.ingest_channel,
    instruction     TEXT,
    worker_id       TEXT,
    created_at      TIMESTAMPTZ             NOT NULL DEFAULT NOW(),
    started_at      TIMESTAMPTZ,
    completed_at    TIMESTAMPTZ,
    retry_count     SMALLINT                NOT NULL DEFAULT 0,
    max_retries     SMALLINT                NOT NULL DEFAULT 3,
    error_message   TEXT,
    error_detail    TEXT,
    payload_json    JSONB
);

-- ── dm_flux.audit_log ────────────────────────────────────────────────────
-- Append-only immutable audit trail — BIGSERIAL for write performance
-- NEVER UPDATE OR DELETE rows from this table
CREATE TABLE IF NOT EXISTS dm_flux.audit_log (
    id              BIGSERIAL   PRIMARY KEY,
    action          TEXT        NOT NULL,
    resource_type   TEXT        NOT NULL,
    resource_id     TEXT,
    operator_id     UUID,
    ip_address      INET,
    user_agent      TEXT,
    detail_json     JSONB,
    logged_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── dm_sentinel.health_snapshots ─────────────────────────────────────────
-- Periodic health state log captured by sentinel cron (*/30 * * *)
CREATE TABLE IF NOT EXISTS dm_sentinel.health_snapshots (
    id              BIGSERIAL   PRIMARY KEY,
    captured_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    overall_status  TEXT        NOT NULL CHECK (overall_status IN ('ok', 'degraded', 'critical')),
    components_json JSONB       NOT NULL DEFAULT '{}',
    triggered_by    TEXT        NOT NULL DEFAULT 'cron'
);

-- ── dm_vault.system_config ────────────────────────────────────────────────
-- Key-value settings store — 39 seed rows inserted in 07_seed_config.sql
CREATE TABLE IF NOT EXISTS dm_vault.system_config (
    key             TEXT        PRIMARY KEY,
    value           TEXT        NOT NULL DEFAULT '',
    is_encrypted    BOOLEAN     NOT NULL DEFAULT FALSE,
    description     TEXT,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_by      UUID        REFERENCES dm_vault.operators (id) ON DELETE SET NULL
);

-- ── dm_vault.license_records ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS dm_vault.license_records (
    id              BIGSERIAL   PRIMARY KEY,
    fingerprint_hash CHAR(64),
    customer_id     TEXT,
    seat_max        SMALLINT    NOT NULL DEFAULT 1,
    feature_flags   JSONB       NOT NULL DEFAULT '{}',
    issued_at       TIMESTAMPTZ,
    expires_at      TIMESTAMPTZ,
    activated_at    TIMESTAMPTZ,
    is_active       BOOLEAN     NOT NULL DEFAULT FALSE,
    validation_log  TEXT
);

-- ── dm_vault.connector_configs ───────────────────────────────────────────
-- One row per connector — seeded in 07_seed_config.sql
CREATE TABLE IF NOT EXISTS dm_vault.connector_configs (
    connector_name      TEXT        PRIMARY KEY,
    is_enabled          BOOLEAN     NOT NULL DEFAULT FALSE,
    config_json         TEXT        NOT NULL DEFAULT '{}',
    last_sync_at        TIMESTAMPTZ,
    last_sync_status    TEXT,
    last_error          TEXT,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
