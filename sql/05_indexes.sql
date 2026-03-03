-- DocMaster — Phase 2: Production Indexes
-- Database: dm_vault
-- Run after: 04_tables.sql
--
-- NOTE: The IVFFlat vector index (idx_embeddings_vector) is NOT created here.
-- It requires ≥3,900 rows to train. The dm-sentinel cron builds it automatically
-- when the embedding count crosses that threshold. Do not create it manually
-- on an empty or sparse table — it will produce a useless index.

-- ── dm_core.documents ─────────────────────────────────────────────────────

-- Status filter — powers the UI filter pills and status count badges
CREATE INDEX IF NOT EXISTS idx_documents_status
    ON dm_core.documents (status);

-- Today's count — powers the "Processed Today" stat in the top bar
CREATE INDEX IF NOT EXISTS idx_documents_processed_at_date
    ON dm_core.documents (DATE(processed_at));

-- Default sort — newest first for the documents list
CREATE INDEX IF NOT EXISTS idx_documents_ingested_at
    ON dm_core.documents (ingested_at DESC);

-- Channel filter
CREATE INDEX IF NOT EXISTS idx_documents_source_channel
    ON dm_core.documents (source_channel);

-- Operator filter
CREATE INDEX IF NOT EXISTS idx_documents_operator_id
    ON dm_core.documents (operator_id);

-- Type filter
CREATE INDEX IF NOT EXISTS idx_documents_doc_type
    ON dm_core.documents (doc_type);

-- Filename trigram search — powers the global search bar
CREATE INDEX IF NOT EXISTS idx_documents_filename_trgm
    ON dm_core.documents USING gin (original_name gin_trgm_ops);

-- ── dm_core.extractions ───────────────────────────────────────────────────

-- Field fetch — powers document detail modal load (document_id + ordered fields)
CREATE INDEX IF NOT EXISTS idx_extractions_document_id
    ON dm_core.extractions (document_id, field_order);

-- Corrected fields filter — for audit/QA queries
CREATE INDEX IF NOT EXISTS idx_extractions_is_corrected
    ON dm_core.extractions (is_corrected)
    WHERE is_corrected = TRUE;

-- ── dm_core.document_events ───────────────────────────────────────────────

-- Timeline fetch — powers document detail modal activity feed
CREATE INDEX IF NOT EXISTS idx_events_document_id
    ON dm_core.document_events (document_id, event_at);

-- ── dm_core.embeddings ────────────────────────────────────────────────────

-- IVFFlat vector index — created by sentinel cron ONLY after ≥3,900 rows exist
-- DO NOT uncomment this block here. It is managed by dm-sentinel.
--
-- CREATE INDEX idx_embeddings_vector
--     ON dm_core.embeddings
--     USING ivfflat (embedding vector_cosine_ops)
--     WITH (lists = 100);

-- ── dm_flux.jobs ──────────────────────────────────────────────────────────

-- Job status filter — Queue UI
CREATE INDEX IF NOT EXISTS idx_jobs_status
    ON dm_flux.jobs (status);

-- Priority ordering within status
CREATE INDEX IF NOT EXISTS idx_jobs_priority_created
    ON dm_flux.jobs (priority, created_at);

-- Document linkage
CREATE INDEX IF NOT EXISTS idx_jobs_document_id
    ON dm_flux.jobs (document_id);

-- ── dm_flux.audit_log ─────────────────────────────────────────────────────

-- Operator audit trail lookup
CREATE INDEX IF NOT EXISTS idx_audit_log_operator_id
    ON dm_flux.audit_log (operator_id, logged_at DESC);

-- Resource lookup
CREATE INDEX IF NOT EXISTS idx_audit_log_resource
    ON dm_flux.audit_log (resource_type, resource_id);

-- ── dm_sentinel.health_snapshots ─────────────────────────────────────────

-- Latest health state lookup
CREATE INDEX IF NOT EXISTS idx_health_snapshots_captured_at
    ON dm_sentinel.health_snapshots (captured_at DESC);
