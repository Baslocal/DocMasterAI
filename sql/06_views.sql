-- DocMaster — Phase 2: Database Views
-- Database: dm_vault
-- Run after: 04_tables.sql

-- ── dm_core.document_status_counts ───────────────────────────────────────
-- Powers the UI filter pills — shows live count per status
-- Used by: GET /dm/core/stats
CREATE OR REPLACE VIEW dm_core.document_status_counts AS
SELECT
    status,
    COUNT(*) AS doc_count
FROM dm_core.documents
GROUP BY status;

-- ── dm_core.daily_summary ────────────────────────────────────────────────
-- Powers the top bar KPI stats
-- Used by: GET /dm/core/stats
CREATE OR REPLACE VIEW dm_core.daily_summary AS
SELECT
    COUNT(*) FILTER (
        WHERE processed_at >= DATE_TRUNC('day', NOW() AT TIME ZONE 'UTC')
    )                                                               AS processed_today,
    COUNT(*) FILTER (WHERE status = 'queued')                       AS queued_count,
    COUNT(*) FILTER (WHERE status = 'processing')                   AS processing_count,
    COUNT(*) FILTER (WHERE status = 'review')                       AS review_count,
    COUNT(*) FILTER (WHERE status = 'failed')                       AS failed_count,
    COUNT(*)                                                        AS total_documents,
    ROUND(
        AVG(confidence_score) FILTER (WHERE confidence_score IS NOT NULL),
        1
    )                                                               AS avg_confidence
FROM dm_core.documents;

-- Grant SELECT on views to dm_app
GRANT SELECT ON dm_core.document_status_counts TO dm_app;
GRANT SELECT ON dm_core.daily_summary TO dm_app;
