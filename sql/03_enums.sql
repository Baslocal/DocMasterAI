-- DocMaster — Phase 2: Enum Type Definitions
-- Database: dm_vault
--
-- STRICT RULE: These enum values are fixed. They are stored verbatim in the
-- database AND must match CSS class names in the UI exactly.
-- Never alter enum values without updating both the DB and UI simultaneously.

-- ── dm_core enums ─────────────────────────────────────────────────────────

-- Document type — maps to extraction schema files in /opt/docmaster/config/schemas/
CREATE TYPE dm_core.document_type AS ENUM (
    'deed',
    'invoice',
    'form',
    'handwritten',
    'table',
    'mixed',
    'unknown'
);

-- Document processing status — drives UI status filter pills
CREATE TYPE dm_core.document_status AS ENUM (
    'queued',
    'processing',
    'complete',
    'review',
    'failed'
);

-- Ingest channel — how the document arrived
CREATE TYPE dm_core.ingest_channel AS ENUM (
    'filesystem',
    'smb',
    'api',
    'email',
    'fax',
    'google_drive',
    'onedrive',
    'dropbox',
    'sftp',
    'webhook'
);

-- Document event type — activity timeline entries
CREATE TYPE dm_core.event_type AS ENUM (
    'ingested',
    'queued',
    'processing_started',
    'ocr_complete',
    'extraction_complete',
    'flagged_for_review',
    'correction_saved',
    'marked_complete',
    'failed',
    'retried',
    'exported'
);

-- ── dm_flux enums ─────────────────────────────────────────────────────────

CREATE TYPE dm_flux.job_priority AS ENUM (
    'high',
    'normal',
    'low'
);

CREATE TYPE dm_flux.job_status AS ENUM (
    'queued',
    'processing',
    'complete',
    'failed',
    'cancelled'
);

-- ── dm_vault enums ────────────────────────────────────────────────────────

CREATE TYPE dm_vault.operator_role AS ENUM (
    'admin',
    'operator',
    'reviewer',
    'readonly'
);
