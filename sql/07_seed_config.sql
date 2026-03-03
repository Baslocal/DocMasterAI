-- DocMaster — Phase 2: Seed Data
-- Database: dm_vault
-- Run after: 04_tables.sql
-- Idempotent: uses ON CONFLICT DO UPDATE so safe to re-run

-- ── dm_vault.system_config (39 seed rows) ────────────────────────────────

INSERT INTO dm_vault.system_config (key, value, is_encrypted, description) VALUES

-- Core processing thresholds
('confidence_threshold',       '85',                   FALSE, 'Documents below this % confidence require operator review'),
('review_threshold',           '75',                   FALSE, 'Field confidence below which review is triggered (any single required field)'),
('ocr_fallback_threshold',     '75',                   FALSE, 'OCR engine confidence below which fallback engine is triggered'),
('max_retry_attempts',         '3',                    FALSE, 'Maximum job retries before marking as failed'),

-- OCR engine settings
('ocr_primary_engine',         'tesseract',            FALSE, 'Primary OCR engine: tesseract|paddle|kraken'),
('ocr_fallback_engine',        'paddle',               FALSE, 'Fallback OCR engine: paddle|kraken|olmocr'),
('ocr_language',               'eng',                  FALSE, 'Tesseract language code(s), comma-separated'),
('rasterization_dpi',          '300',                  FALSE, 'PDF-to-image rasterization DPI (minimum 300)'),
('deskew_max_angle',           '10',                   FALSE, 'Maximum deskew correction angle in degrees'),
('denoise_strength',           '10',                   FALSE, 'OpenCV fastNlMeansDenoising h parameter'),
('max_page_count',             '50',                   FALSE, 'Maximum pages to process per document'),
('olmocr_fallback_enabled',    'true',                 FALSE, 'Enable Qwen2.5-VL via Ollama as last-resort OCR engine'),

-- LLM / extraction settings
('llm_primary_model',          'llama3.1:8b-q4_K_M',  FALSE, 'Primary Ollama extraction model'),
('llm_context_window',         '8192',                 FALSE, 'LLM token context window'),
('llm_temperature',            '0.0',                  FALSE, 'LLM temperature — MUST remain 0.0 for audit trail integrity'),
('llm_use_external_api',       'false',                FALSE, 'Allow Claude API for high-priority jobs when internet available'),
('claude_api_key',             '',                     TRUE,  'Encrypted Claude API key — stored as base64(nonce||ciphertext||tag)'),

-- Vector / embedding settings
('chunk_size_tokens',          '512',                  FALSE, 'Embedding chunk size in tokens'),
('chunk_overlap_tokens',       '64',                   FALSE, 'Embedding chunk overlap in tokens'),
('embedding_model',            'nomic-embed-text',     FALSE, 'Ollama embedding model name'),
('ivfflat_build_threshold',    '3900',                 FALSE, 'Minimum embedding rows before IVFFlat index is built'),

-- Storage and retention
('backup_retention_days',      '7',                    FALSE, 'Days to retain daily encrypted backups'),
('tmp_cleanup_age_hours',      '24',                   FALSE, 'Failed job tmp directories older than this are removed by cron'),
('vault_path',                 '/opt/docmaster/vault', FALSE, 'Original document archive path (append-only)'),

-- System / application settings
('setup_complete',             'false',                FALSE, 'Set to true after first-boot wizard completes'),
('node_hostname',              'docmaster-node-01',    FALSE, 'Node identifier used in API response headers and health checks'),
('dm_version',                 '1.0.0',                FALSE, 'Current DocMaster application version'),
('dm_build',                   '',                     FALSE, 'Build identifier, set during deployment'),
('session_timeout',            '3600',                 FALSE, 'JWT session timeout in seconds'),
('max_upload_size_mb',         '500',                  FALSE, 'Maximum single file upload size in MB'),

-- Security
('jwt_algorithm',              'RS256',                FALSE, 'JWT signing algorithm — do not change'),
('bcrypt_cost',                '12',                   FALSE, 'bcrypt password hash cost factor — do not decrease'),
('api_rate_limit',             '60',                   FALSE, 'API rate limit: requests per minute per token'),

-- Notification settings
('smtp_enabled',               'false',                FALSE, 'Enable SMTP email notifications'),
('smtp_host',                  '',                     FALSE, 'SMTP server host'),
('smtp_port',                  '587',                  FALSE, 'SMTP server port'),
('smtp_username',              '',                     FALSE, 'SMTP authentication username'),
('smtp_password',              '',                     TRUE,  'Encrypted SMTP password'),
('notification_email',         '',                     FALSE, 'Admin notification email address'),

-- Connector master switch
('connectors_enabled',         'false',                FALSE, 'Master switch for all dm-bridge external connectors'),

-- Samba / SMB ingest
('smb_enabled',                'false',                FALSE, 'Enable SMB network scan drop share'),
('fax_enabled',                'false',                FALSE, 'Enable HylaFAX ingest channel')

ON CONFLICT (key) DO UPDATE SET
    description = EXCLUDED.description;
-- Note: value and is_encrypted are NOT updated on conflict — preserves operator changes

-- ── dm_vault.connector_configs (seed rows) ───────────────────────────────

INSERT INTO dm_vault.connector_configs (connector_name, is_enabled, config_json) VALUES
('google_drive',        FALSE, '{"folder_id": null, "poll_interval_minutes": 15}'),
('onedrive',            FALSE, '{"folder_path": null, "poll_interval_minutes": 15}'),
('dropbox',             FALSE, '{"folder_path": "/DocMaster", "poll_interval_minutes": 15}'),
('sftp',                FALSE, '{"host": null, "port": 22, "username": null, "remote_path": "/docmaster"}'),
('email_ingest',        FALSE, '{"imap_host": null, "imap_port": 993, "username": null, "folder": "INBOX"}'),
('fax',                 FALSE, '{"hylafax_host": "127.0.0.1", "receive_dir": "/var/spool/hylafax/recvq"}'),
('claude_api',          FALSE, '{"api_version": "2023-06-01", "model": "claude-opus-4-6"}'),
('webhook_outbound',    FALSE, '{"url": null, "secret": null, "events": ["complete", "failed"]}')

ON CONFLICT (connector_name) DO NOTHING;
