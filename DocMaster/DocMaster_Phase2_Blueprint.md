# DocMaster — Phase 2 Blueprint
## Database, Queue & Storage Layer

**Classification:** Confidential — Internal Engineering Reference  
**Phase:** 2 of 8  
**Complexity:** Medium  
**Prerequisite:** Phase 1 complete and all 50+ validation items confirmed  
**Outcome:** A fully initialized PostgreSQL database with the complete schema aligned to the UI data model, a configured Redis queue with defined job payload structure, an encrypted config vault seeded with default settings, Alembic migration tooling in place, and all connection pooling configured — ready for Phase 3 application code to connect to

---

## Phase 1 Amendments

Before Phase 2 begins, the following gaps in Phase 1 must be addressed. These were identified during cross-analysis of the HTML prototype, the UI design document, and the full system blueprint. Each gap below has a concrete impact on a later phase that cannot be corrected without revisiting the OS layer.

### Amendment 1 — Missing: `dmidecode` Package

**Impact:** Phase 6 — Licensing Engine  
**Detail:** The hardware fingerprint is assembled from CPU ID, Motherboard UUID, NIC MAC address, and root disk serial. The CPU ID and Motherboard UUID are read using `dmidecode`. This tool is not installed by default on minimal Debian or Ubuntu Server and was omitted from the Phase 1 dependency list.

**Fix:** Add `dmidecode` to the system package installation list in Track 4. It must be installed before Phase 6, but installing it in Phase 1 alongside all other system tools is the correct approach — the manifest lock file must capture its version.

### Amendment 2 — Missing: `libpq-dev` Package

**Impact:** Phase 2 (immediate) — Python's asyncpg and psycopg2 build against native PostgreSQL client libraries  
**Detail:** The Python database drivers (asyncpg for async FastAPI use, psycopg2 as a fallback) compile native extensions that require the PostgreSQL client headers. `libpq-dev` provides these headers. Without it, the Phase 3 Python virtual environment build will fail when pip attempts to install asyncpg.

**Fix:** Add `libpq-dev` to the Phase 1 system package list. Install it immediately after PostgreSQL 16 is installed from the PGDG repository — it must come from the PGDG repository too, not from the distribution default, to ensure version alignment.

### Amendment 3 — Missing: `libssl-dev`

**Impact:** Phase 6 — License engine cryptographic operations  
**Detail:** The license validation code uses Python's `cryptography` library for RS256 JWT signature verification. That library builds native extensions against OpenSSL headers provided by `libssl-dev`. Absent on minimal installs.

**Fix:** Add `libssl-dev` to the Phase 1 dependency list alongside `build-essential`.

### Amendment 4 — Missing: `apparmor-utils` and `apparmor`

**Impact:** Phase 8 — Appliance packaging and security hardening  
**Detail:** Phase 8 requires AppArmor profiles for `dm-core`, `dm-flux`, and `dm-ocr-worker`. AppArmor itself and its management tools (`apparmor-utils`) must be installed and active at the OS level before profiles can be written and loaded. On Debian, AppArmor is not enabled by default.

**Fix:** Add `apparmor` and `apparmor-utils` to Phase 1 dependencies. After installing, verify AppArmor is active with `aa-status`. On Debian, you may also need to add `apparmor=1 security=apparmor` to the GRUB kernel command line and reboot — document this in the deployment record.

### Amendment 5 — Missing: `scanuser` Creation Steps

**Impact:** Phase 4 — SMB Scan Drop configuration  
**Detail:** Track 2 in Phase 1 mentions that the Samba scan drop uses a separate `scanuser` with write-only access to `/opt/docmaster/ingest/`. However, no steps were given for creating this user. The user must be created in Phase 1 because the ingest directory permissions (mode `770`, group `docgroup`) only work if `scanuser` is in `docgroup`.

**Fix:** Add to Phase 1 Track 2:
- Create OS user `scanuser` with no shell (`/bin/false`) and no home directory
- Add `scanuser` to `docgroup` — this is the only way `scanuser` gets write access to the `ingest/` directory
- Create a Samba password for `scanuser` using `smbpasswd -a scanuser` — the Samba user database is separate from the OS user database
- Do not grant `scanuser` any other filesystem access — `docgroup` membership alone gives write permission to `ingest/` (mode `770`)

### Amendment 6 — Missing: Environment File Location for `docmaster` User

**Impact:** Phase 2 (immediate) — all systemd service units reference environment variables  
**Detail:** Phase 1 documents that `OLLAMA_HOST`, `OLLAMA_MODELS`, and `CUDA_VISIBLE_DEVICES` must be set for the `docmaster` user environment. However, it does not specify where these variables live or how systemd units inherit them. This must be locked down before Phase 2 starts configuring database connection strings.

**Fix:** The canonical location for all DocMaster application environment variables is `/opt/docmaster/vault/.env`. This file is:
- Owned by `docmaster:docgroup` with mode `600` — readable only by owner
- Sourced by every systemd unit via `EnvironmentFile=/opt/docmaster/vault/.env`
- Plain text (not encrypted) — it contains non-secret environment variables like paths and flags. Actual secrets (passwords, API keys) go into the encrypted `.env.enc` vault, which is a separate mechanism described in Phase 2 Track 4

The `.env` file must be created in Phase 1 and populated with the Ollama environment variables so that when Phase 2 begins starting services, the environment is already defined.

### Amendment 7 — Validation Checklist Addition

The Phase 1 validation checklist must include:

- [ ] `dmidecode` is installed and `dmidecode -s system-uuid` returns a non-empty UUID without requiring sudo when run as the admin user
- [ ] `libpq-dev` is installed and `pg_config --version` returns the PostgreSQL 16 version
- [ ] `libssl-dev` is installed
- [ ] `apparmor` is installed, active, and `aa-status` returns without error
- [ ] `scanuser` OS user exists with no shell
- [ ] `scanuser` is a member of `docgroup`
- [ ] `/opt/docmaster/vault/.env` exists, is owned `docmaster:docgroup`, mode `600`, and contains the Ollama variables

---

## Overview

Phase 2 establishes the persistence and state management layer of DocMaster. Everything that was installed in Phase 1 now gets configured, initialized, and connected. This phase is primarily about data modeling decisions, not application code — the decisions made here about schema design, naming conventions, index strategy, and queue payload structure will be inherited by every other phase. Getting them right now is substantially cheaper than correcting them later.

The work divides into four tracks:

1. PostgreSQL configuration and schema initialization  
2. Redis queue configuration and job payload design  
3. Python virtual environment and database driver setup  
4. Encrypted configuration vault initialization  

---

## Cross-Analysis: UI → Schema Alignment

This section documents the findings from a full analysis of the HTML prototype (`index_2_md.html`) and the UI design document (`ui_`). Every table and column in the schema must trace to something the UI renders or the API serves. Any schema element that has no corresponding UI or API usage is a design smell and should be questioned.

### Data Requirements Derived from the UI

**The Document Table (Documents page):**  
The table renders: status (dot + label), filename, type badge, confidence bar + percentage, and processed timestamp. This maps directly to `dm_core.documents`. The filter pills show live counts per status — the query `SELECT status, COUNT(*) FROM dm_core.documents GROUP BY status` must return in under 10ms. This requires a partial index on status.

**The Top Bar Stats:**  
Three live counters are always visible: today's processed count, current queue depth, and average confidence. The "today" count queries documents processed since midnight UTC. The queue depth comes from Redis (not the database). Average confidence is a DB aggregate. These three numbers are served by a single `/dm/sentinel/health` call that the UI polls every 30 seconds.

**The Document Detail Modal:**  
The modal renders: document filename as the title, a page indicator ("Page 2 of 3"), a document-level confidence percentage, and individual extracted fields each with their own confidence badge. This requires:
- `dm_core.documents.page_count` — a field that does not appear in the master plan schema but is visible in the prototype
- `dm_core.extractions` — one row per extracted field, with `field_name`, `field_value`, and `confidence`
- The modal also shows "Save Corrections" — this writes back to `dm_core.extractions` with a `corrected_by` operator ID

**The Settings Page:**  
The settings form (General, Processing Defaults, UI Preferences, Email Notifications sections) reveals exactly which keys must exist in `dm_vault.system_config`. A full enumeration is provided in Track 4 of this blueprint. None of these settings appear in the master plan schema definition but they are clearly required by the UI.

**The Health Page:**  
The health cards show "1,847 documents indexed" — this is a live COUNT from `dm_core.documents`. They also show "4ms latency" — measured during the diagnostic write/read cycle. The Ollama card shows "llama3.1:8b loaded • 340ms inference" — these are runtime values, not database values.

**Document Types (Badge Values):**  
The HTML uses exact CSS class names that must match the enum values stored in the database:
- `deed` → renders purple badge
- `invoice` → renders blue badge
- `form` → renders green badge
- `handwritten` → renders orange badge

The schema must use these exact strings as the enum values. Any mismatch between database and UI will cause badge rendering to fall back to plain text.

**Document Status Values:**  
From the filter pills and status dots:
- `queued` — document received, waiting in Redis queue (no dot shown in table, handled differently)
- `processing` — blue dot, currently being worked on
- `complete` — green dot, extraction done and above confidence threshold
- `review` — orange dot, extraction done but below confidence threshold
- `failed` — red dot, pipeline error after all retries exhausted

**The Activity Timeline (mentioned in UI design doc, not yet rendered in HTML):**  
The UI design document explicitly describes a "linear mini-timeline" showing: Ingested → OCR → Extracted → Reviewed. This requires an event log table that captures timestamps for each stage transition per document. This table is not defined in the master plan and must be added in Phase 2.

---

## Track 1 — PostgreSQL Configuration & Schema

### 1.1 Server Configuration

PostgreSQL configuration is managed through `postgresql.conf` and `pg_hba.conf` in `/etc/postgresql/16/main/`. These files must be edited before initializing the database. The defaults are tuned for a general-purpose server, not a document processing workload with large binary objects and concurrent LLM inference.

**`postgresql.conf` tuning — key directives:**

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `listen_addresses` | `127.0.0.1` | Binds only to localhost — prevents any external connection attempt |
| `max_connections` | `50` | The application pool uses 10 connections maximum; 50 gives headroom for maintenance and psql sessions without wasteful memory allocation |
| `shared_buffers` | 25% of total RAM | Primary PostgreSQL memory cache. Example: on a 32GB server, set to `8GB`. PostgreSQL documentation confirms this is the recommended starting point. |
| `effective_cache_size` | 50% of total RAM | Informs the query planner how much OS-level file cache is available. Does not allocate memory — it is a hint. |
| `work_mem` | `64MB` | Memory per sort or hash operation. OCR extraction queries may involve sorting large result sets by confidence score. |
| `maintenance_work_mem` | `256MB` | Memory for VACUUM, CREATE INDEX operations. The nightly maintenance cron uses this. |
| `wal_level` | `replica` | Required for WAL archiving. Enables point-in-time recovery if the data directory becomes corrupted. |
| `archive_mode` | `on` | Enables WAL segment archiving |
| `archive_command` | `cp %p /opt/docmaster/backups/wal/%f` | Archives WAL segments to the local backups directory. Note: if backups are on the same disk, this protects only against data corruption, not disk failure. |
| `log_destination` | `csvlog` | Structured log output that can be parsed by the sentinel health daemon |
| `logging_collector` | `on` | Enables the log collector process |
| `log_directory` | `/opt/docmaster/logs/postgres` | All PostgreSQL logs go to the DocMaster log directory, not the default `/var/log/postgresql/` |
| `log_min_duration_statement` | `500` | Logs any query taking longer than 500ms. Critical for identifying slow queries in production without logging every single statement. |
| `idle_in_transaction_session_timeout` | `30000` | Kills transactions that have been idle for 30 seconds. Prevents long-held locks from blocking the queue worker. |
| `deadlock_timeout` | `1s` | Standard — detect deadlocks within 1 second |

**`pg_hba.conf` configuration:**

The default `pg_hba.conf` allows local socket connections using `peer` authentication (OS username must match DB username) and TCP connections with md5 password auth. The DocMaster configuration replaces the default with a minimal, explicit ruleset:

```
# TYPE   DATABASE    USER        ADDRESS         METHOD
local    all         postgres                    peer
local    dm_vault    dm_app                      scram-sha-256
host     dm_vault    dm_app      127.0.0.1/32    scram-sha-256
```

Three rules:
1. The `postgres` OS superuser connects via local socket with peer auth — used only for maintenance and initial setup
2. The `dm_app` database user connects via local socket with SCRAM-SHA-256 — used by the FastAPI application running on the same machine
3. The same `dm_app` user can connect via TCP from localhost — used when the application explicitly uses a TCP connection string rather than a Unix socket

No other users or connection methods are permitted. `scram-sha-256` is preferred over `md5` because it is resistant to replay attacks and is the current PostgreSQL security recommendation.

### 1.2 Database and Role Initialization

The following initialization sequence must be run as the `postgres` OS user (the PostgreSQL superuser). It is a one-time operation. All commands are run via `psql` on the local socket.

**Step 1: Create the application database role**

```sql
CREATE ROLE dm_app
  WITH LOGIN
  PASSWORD '<generated_password>'
  NOSUPERUSER
  NOCREATEDB
  NOCREATEROLE
  NOINHERIT
  NOREPLICATION;
```

The password must be a randomly generated 32-character alphanumeric string. It must be immediately written to `/opt/docmaster/vault/.env` under the key `DM_DB_PASSWORD`, owned `docmaster:docgroup`, mode `600`. It is never stored anywhere else.

**Step 2: Create the database**

```sql
CREATE DATABASE dm_vault
  WITH OWNER = dm_app
  ENCODING = 'UTF8'
  LC_COLLATE = 'en_US.UTF-8'
  LC_CTYPE = 'en_US.UTF-8'
  TEMPLATE = template0;
```

The `en_US.UTF-8` collation ensures consistent text sorting across all character sets encountered in multilingual OCR output. Using `template0` instead of `template1` ensures a clean database with no inherited objects.

**Step 3: Connect to `dm_vault` and enable the pgvector extension**

```sql
\c dm_vault
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;
```

- `vector` — provided by the `postgresql-16-pgvector` package installed in Phase 1. Required for semantic embedding storage. Must be enabled as the `postgres` superuser because extensions require elevated privileges.
- `pg_trgm` — trigram text matching. Required for the fuzzy full-text search fallback on document filenames and extracted field values.
- `unaccent` — accent-insensitive text search. Required when OCR output contains accented characters from French, Spanish, or Portuguese text. Allows searching "Jose" to match "José".

### 1.3 Schema Creation

All schemas are created before any tables. The schema namespace is the first line of defense against future table name collisions as the codebase grows.

```sql
CREATE SCHEMA dm_core AUTHORIZATION dm_app;
CREATE SCHEMA dm_flux AUTHORIZATION dm_app;
CREATE SCHEMA dm_sentinel AUTHORIZATION dm_app;
CREATE SCHEMA dm_vault;  -- vault schema owned by postgres superuser, not dm_app
```

The `dm_vault` schema is intentionally NOT owned by `dm_app`. The application user can read config values but cannot modify the schema structure of the vault. This prevents application-level bugs from altering the license or config table definitions.

Grant selective access on `dm_vault`:

```sql
GRANT USAGE ON SCHEMA dm_vault TO dm_app;
GRANT SELECT, INSERT, UPDATE ON dm_vault.system_config TO dm_app;
GRANT SELECT ON dm_vault.license_records TO dm_app;  -- read-only on license
```

The application can read and write config, but can only read license records — it cannot create or modify them. That privilege is reserved for the license engine (`dm-vault.service`), which runs as a separate process with a different database connection using a separate elevated role.

### 1.4 Complete Table Definitions

All tables are documented with their columns, types, constraints, and the UI element or API endpoint that consumes each field. No column exists without a documented reason.

---

#### `dm_core.documents`

The central table. Every document that enters the system gets one row here. The UI document table, dashboard counts, and filter pills all read from this table.

```sql
CREATE TABLE dm_core.documents (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    filename        TEXT NOT NULL,
    original_name   TEXT NOT NULL,
    hash_sha256     CHAR(64) NOT NULL UNIQUE,
    file_path       TEXT NOT NULL,
    file_size_bytes BIGINT NOT NULL,
    mime_type       TEXT NOT NULL,
    page_count      INTEGER NOT NULL DEFAULT 1,
    doc_type        dm_core.document_type NOT NULL DEFAULT 'unknown',
    status          dm_core.document_status NOT NULL DEFAULT 'queued',
    confidence_score NUMERIC(5,2),
    source_channel  dm_core.ingest_channel NOT NULL DEFAULT 'api',
    operator_id     UUID REFERENCES dm_vault.operators(id) ON DELETE SET NULL,
    ingested_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    queued_at       TIMESTAMPTZ,
    processing_started_at TIMESTAMPTZ,
    processed_at    TIMESTAMPTZ,
    reviewed_at     TIMESTAMPTZ,
    reviewed_by     UUID REFERENCES dm_vault.operators(id) ON DELETE SET NULL,
    retry_count     SMALLINT NOT NULL DEFAULT 0,
    error_message   TEXT,
    metadata_json   JSONB NOT NULL DEFAULT '{}'
);
```

**Column notes:**

- `id` — UUID primary key. Never an integer — UUIDs prevent enumeration attacks on the document API
- `filename` — sanitized filename safe for filesystem operations (slashes stripped, length limited)
- `original_name` — the original filename as submitted by the user or scanner, preserved exactly for display in the UI
- `hash_sha256` — SHA-256 of the raw file bytes, computed before any processing. The UNIQUE constraint implements deduplication — attempting to insert a document already in the system silently returns the existing record's ID without creating a duplicate job
- `file_path` — absolute path to the stored document file. After processing, points to the archive location under `/opt/docmaster/data/documents/{year}/{month}/{id}/`
- `page_count` — derived during pre-processing by poppler-utils (`pdfinfo`). Required for the "Page 2 of 3" indicator in the document detail modal
- `doc_type` — uses the `dm_core.document_type` enum defined below
- `status` — uses the `dm_core.document_status` enum defined below
- `confidence_score` — NUMERIC(5,2) allows values like `94.20`, range 0.00–100.00. NULL when status is `queued` or `processing`
- `source_channel` — records which ingestion channel delivered this document. Used for reporting ("which scanner is producing the most low-confidence documents?")
- `metadata_json` — a JSONB catch-all for channel-specific metadata: fax source number, email sender, Drive file ID, scanner IP address, etc.

---

#### `dm_core.document_type` (Enum)

```sql
CREATE TYPE dm_core.document_type AS ENUM (
    'deed',
    'invoice',
    'form',
    'handwritten',
    'table',
    'mixed',
    'unknown'
);
```

These exact string values must be used throughout the codebase. The HTML prototype uses these as CSS class names on type badges. Any value not in this enum will fail the NOT NULL constraint.

---

#### `dm_core.document_status` (Enum)

```sql
CREATE TYPE dm_core.document_status AS ENUM (
    'queued',
    'processing',
    'complete',
    'review',
    'failed'
);
```

`review` maps to the UI label "Needs Review" and the orange status dot. The enum stores `review`; the UI renders "Needs Review". This mapping is the responsibility of the API serialization layer, not the database.

---

#### `dm_core.ingest_channel` (Enum)

```sql
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
```

---

#### `dm_core.extractions`

One row per extracted field per document. The document detail modal renders every row in this table for the selected document, sorted by `field_order`.

```sql
CREATE TABLE dm_core.extractions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id     UUID NOT NULL REFERENCES dm_core.documents(id) ON DELETE CASCADE,
    field_name      TEXT NOT NULL,
    field_value     TEXT,
    field_order     SMALLINT NOT NULL DEFAULT 0,
    confidence      NUMERIC(5,2) NOT NULL,
    is_corrected    BOOLEAN NOT NULL DEFAULT FALSE,
    original_value  TEXT,
    corrected_by    UUID REFERENCES dm_vault.operators(id) ON DELETE SET NULL,
    corrected_at    TIMESTAMPTZ,
    ocr_engine      TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

**Column notes:**

- `field_order` — controls the display order in the detail modal. The LLM extraction defines the order based on the document schema definition.
- `is_corrected` — when an operator saves a correction, this flips to TRUE and `original_value` is populated with the pre-correction text. This preserves the history without requiring a separate corrections table.
- `original_value` — stores the pre-correction value when `is_corrected` is TRUE. NULL otherwise.
- `ocr_engine` — records which OCR engine produced the text that the LLM then extracted. Useful for identifying which engine systematically produces low-confidence results for a specific document type.
- The `confidence` field renders the color-coded badge in the modal: >= 90 → green, 75–89 → orange, < 75 → red (these thresholds are defined in the UI design doc as high/medium/low)

---

#### `dm_core.document_events`

The activity timeline shown in the document detail view. Every significant state transition for a document gets an event record. This table was not in the original master plan and is added here based on the UI design document's description of the timeline.

```sql
CREATE TABLE dm_core.document_events (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id  UUID NOT NULL REFERENCES dm_core.documents(id) ON DELETE CASCADE,
    event_type   dm_core.event_type NOT NULL,
    event_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    duration_ms  INTEGER,
    detail       TEXT,
    operator_id  UUID REFERENCES dm_vault.operators(id) ON DELETE SET NULL,
    metadata_json JSONB NOT NULL DEFAULT '{}'
);

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
```

**Why this table matters:** The timeline in the UI requires knowing not just what the final status is, but when each stage happened and how long it took. `duration_ms` on the `ocr_complete` event tells you how long OCR took. `duration_ms` on `extraction_complete` tells you how long the LLM extraction took. This data is valuable for tuning the pipeline.

---

#### `dm_core.embeddings`

Stores document text embeddings for semantic search. One row per chunk of text.

```sql
CREATE TABLE dm_core.embeddings (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id  UUID NOT NULL REFERENCES dm_core.documents(id) ON DELETE CASCADE,
    chunk_index  SMALLINT NOT NULL,
    chunk_text   TEXT NOT NULL,
    embedding    vector(768) NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (document_id, chunk_index)
);
```

**Column notes:**

- `embedding vector(768)` — `nomic-embed-text` produces 768-dimensional embeddings. The vector dimension is locked to the model. If the embedding model is ever changed, all existing embeddings must be regenerated.
- `chunk_text` — stores the original text of the chunk. Required for displaying matching text snippets in search results.
- `chunk_index` — sequential within each document. The UNIQUE constraint prevents duplicate chunks on reprocessing.

---

#### `dm_flux.jobs`

The persistent job queue record. Redis holds the live queue; this table holds the durable record of every job that has ever been enqueued. The two are reconciled on startup.

```sql
CREATE TABLE dm_flux.jobs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id     UUID REFERENCES dm_core.documents(id) ON DELETE SET NULL,
    document_hash   CHAR(64) NOT NULL,
    priority        dm_flux.job_priority NOT NULL DEFAULT 'normal',
    status          dm_flux.job_status NOT NULL DEFAULT 'queued',
    source_channel  dm_core.ingest_channel NOT NULL,
    instruction     TEXT,
    worker_id       TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    started_at      TIMESTAMPTZ,
    completed_at    TIMESTAMPTZ,
    retry_count     SMALLINT NOT NULL DEFAULT 0,
    max_retries     SMALLINT NOT NULL DEFAULT 3,
    error_message   TEXT,
    error_detail    TEXT,
    payload_json    JSONB NOT NULL DEFAULT '{}'
);

CREATE TYPE dm_flux.job_priority AS ENUM ('high', 'normal', 'low');

CREATE TYPE dm_flux.job_status AS ENUM (
    'queued',
    'processing',
    'complete',
    'failed',
    'cancelled'
);
```

**Column notes:**

- `instruction` — the natural language instruction from an email subject line or API `instruction` field. Passed as the LLM system prompt. NULL for filesystem and fax ingestion where no instruction is provided.
- `worker_id` — the ID of the OCR worker process that picked up this job. On a single-worker deployment, this is always the same. On a multi-worker deployment, this identifies which worker handled the job.
- `error_detail` — the full stack trace or extended error information, stored separately from `error_message` to keep the main error field concise for display.
- `payload_json` — additional channel-specific data: fax source number, email sender address, Drive file URL, etc.

---

#### `dm_flux.audit_log`

Immutable record of every significant action in the system. Write-only — no row is ever updated or deleted.

```sql
CREATE TABLE dm_flux.audit_log (
    id           BIGSERIAL PRIMARY KEY,
    action       TEXT NOT NULL,
    resource_type TEXT NOT NULL,
    resource_id  TEXT,
    operator_id  UUID REFERENCES dm_vault.operators(id) ON DELETE SET NULL,
    ip_address   INET,
    user_agent   TEXT,
    detail_json  JSONB NOT NULL DEFAULT '{}',
    logged_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

**Why BIGSERIAL, not UUID?** The audit log is append-only and extremely high-volume. BIGSERIAL provides a natural ordering guarantee and is more efficient for sequential insert patterns than UUID. UUID is preferred for tables where rows are retrieved by ID — the audit log is typically queried by time range or action type, not by ID.

---

#### `dm_sentinel.health_snapshots`

Stores the result of every automated health check run by the sentinel cron job. Provides a time-series record of system health.

```sql
CREATE TABLE dm_sentinel.health_snapshots (
    id             BIGSERIAL PRIMARY KEY,
    captured_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    overall_status TEXT NOT NULL CHECK (overall_status IN ('ok', 'degraded', 'critical')),
    components_json JSONB NOT NULL,
    triggered_by   TEXT NOT NULL DEFAULT 'cron'
);
```

---

#### `dm_vault.operators`

User accounts for DocMaster. The first-boot wizard creates the initial admin operator. Additional operators can be created through the Settings → Security & Access panel.

```sql
CREATE TABLE dm_vault.operators (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username        TEXT NOT NULL UNIQUE,
    display_name    TEXT NOT NULL,
    password_hash   TEXT NOT NULL,
    role            dm_vault.operator_role NOT NULL DEFAULT 'reviewer',
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    last_login_at   TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by      UUID REFERENCES dm_vault.operators(id) ON DELETE SET NULL
);

CREATE TYPE dm_vault.operator_role AS ENUM (
    'admin',
    'operator',
    'reviewer',
    'readonly'
);
```

**Role definitions:**
- `admin` — full system access including settings, user management, service restarts
- `operator` — can ingest documents, correct extractions, export data; cannot change system settings
- `reviewer` — can view and correct extractions but cannot upload or export
- `readonly` — view-only access to the document list and extraction results

**Password storage:** `password_hash` stores a bcrypt hash (cost factor 12). The first-boot wizard uses the same table. The plain-text password is never stored.

---

#### `dm_vault.system_config`

Key-value store for all configurable settings. Populated with defaults during Phase 2 initialization. Updated through the Settings UI. Each row stores one setting.

```sql
CREATE TABLE dm_vault.system_config (
    key          TEXT PRIMARY KEY,
    value        TEXT NOT NULL,
    is_encrypted BOOLEAN NOT NULL DEFAULT FALSE,
    description  TEXT NOT NULL,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_by   UUID REFERENCES dm_vault.operators(id) ON DELETE SET NULL
);
```

The `value` column stores plain text for non-sensitive settings. For sensitive settings (API keys, OAuth tokens), `is_encrypted = TRUE` and the value is AES-256-GCM encrypted with the vault master key before being written. The API layer handles encryption/decryption transparently.

**Default seed values** (inserted during Phase 2 initialization):

| Key | Default Value | Encrypted | Description |
|-----|--------------|-----------|-------------|
| `appliance_name` | `docmaster-node-01` | No | Visible in logs and network discovery |
| `timezone_display` | `UTC` | No | Display timezone for the UI |
| `display_language` | `en_US` | No | UI language |
| `default_queue_priority` | `normal` | No | Priority for manually uploaded documents |
| `auto_retry_failed` | `true` | No | Automatically re-queue failed extractions |
| `max_retry_attempts` | `3` | No | Maximum retry attempts before marking failed |
| `confidence_threshold` | `85` | No | Documents below this percentage require review |
| `docs_per_page` | `25` | No | Documents shown per page in the UI table |
| `date_format` | `YYYY-MM-DD` | No | Display date format in the UI |
| `enable_notifications` | `true` | No | Real-time UI notifications enabled |
| `show_confidence_scores` | `true` | No | Show confidence bar in document table |
| `dark_mode` | `false` | No | Experimental dark mode |
| `admin_email` | `` | No | Email address for system alerts |
| `notify_on_failed_jobs` | `true` | No | Email alert on job failure |
| `notify_daily_summary` | `true` | No | Send daily processing summary email |
| `notify_low_disk` | `true` | No | Alert when disk usage exceeds 80% |
| `notify_license_expiry` | `true` | No | Alert when license expires within 30 days |
| `max_upload_size_mb` | `50` | No | Maximum file size for API uploads |
| `ocr_primary_engine` | `tesseract` | No | Primary OCR engine selection |
| `ocr_fallback_engine` | `paddle` | No | Fallback engine when primary confidence is low |
| `ocr_fallback_threshold` | `75` | No | Confidence below which fallback engine is used |
| `llm_primary_model` | `llama3.1:8b-q4_K_M` | No | Primary local LLM model |
| `llm_use_external_api` | `false` | No | Allow use of Claude API for high-priority jobs |
| `claude_api_key` | `` | **Yes** | Encrypted Claude API key |
| `google_drive_enabled` | `false` | No | Google Drive connector enabled |
| `google_drive_token` | `` | **Yes** | Encrypted OAuth2 token |
| `onedrive_enabled` | `false` | No | OneDrive connector enabled |
| `onedrive_token` | `` | **Yes** | Encrypted OAuth2 token |
| `smtp_enabled` | `false` | No | Outbound SMTP for email notifications |
| `smtp_host` | `` | No | SMTP server hostname |
| `smtp_port` | `587` | No | SMTP server port |
| `smtp_username` | `` | No | SMTP username |
| `smtp_password` | `` | **Yes** | Encrypted SMTP password |
| `webhook_enabled` | `false` | No | Outbound webhook enabled |
| `webhook_url` | `` | No | Outbound webhook URL |
| `webhook_token` | `` | **Yes** | Encrypted webhook auth token |
| `fax_enabled` | `false` | No | Fax receiver enabled |
| `fax_modem_device` | `/dev/ttyUSB0` | No | USB modem device path |
| `backup_retention_days` | `7` | No | Days to retain daily backups |
| `setup_complete` | `false` | No | Set to true after first-boot wizard completes |

---

#### `dm_vault.license_records`

Stores the validated license state. Written by the `dm-vault.service` on boot after validating the `license.key` file. Read-only for the application.

```sql
CREATE TABLE dm_vault.license_records (
    id                BIGSERIAL PRIMARY KEY,
    fingerprint_hash  CHAR(64) NOT NULL,
    customer_id       TEXT NOT NULL,
    seat_max          SMALLINT NOT NULL DEFAULT 1,
    feature_flags     JSONB NOT NULL DEFAULT '{}',
    issued_at         TIMESTAMPTZ NOT NULL,
    expires_at        TIMESTAMPTZ NOT NULL,
    activated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_active         BOOLEAN NOT NULL DEFAULT TRUE,
    validation_log    TEXT
);
```

---

#### `dm_vault.connector_configs`

One row per configured external connector. Stores the connector state used by `dm-bridge.service`. Added here as it was missing from the master plan but is required by the Integrations nav page.

```sql
CREATE TABLE dm_vault.connector_configs (
    connector_name  TEXT PRIMARY KEY,
    is_enabled      BOOLEAN NOT NULL DEFAULT FALSE,
    config_json     TEXT NOT NULL DEFAULT '{}',
    last_sync_at    TIMESTAMPTZ,
    last_sync_status TEXT,
    last_error      TEXT,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

`config_json` stores the connector's configuration as an AES-256-GCM encrypted JSON string — the entire JSON blob is encrypted as one unit, not individual fields. Decrypted in memory by `dm-bridge.service` at runtime.

Initial seed rows (all disabled):

```sql
INSERT INTO dm_vault.connector_configs (connector_name) VALUES
    ('google_drive'), ('onedrive'), ('dropbox'), ('sftp'),
    ('email_ingest'), ('fax'), ('claude_api'), ('webhook_outbound');
```

---

### 1.5 Indexes

Indexes must be defined after tables are created. These are chosen specifically to support the queries that the UI generates.

```sql
-- Document table: fast filter by status (used by filter pills)
CREATE INDEX idx_documents_status ON dm_core.documents (status);

-- Document table: fast count of today's processed docs (top bar stat)
CREATE INDEX idx_documents_processed_at_date ON dm_core.documents (DATE(processed_at));

-- Document table: sort by ingested date (default table sort)
CREATE INDEX idx_documents_ingested_at ON dm_core.documents (ingested_at DESC);

-- Document table: fast filter by type
CREATE INDEX idx_documents_doc_type ON dm_core.documents (doc_type);

-- Document table: hash lookup for deduplication check on ingest
-- Already covered by UNIQUE constraint, which creates an index implicitly

-- Extractions: fetch all fields for a document (modal load)
CREATE INDEX idx_extractions_document_id ON dm_core.extractions (document_id, field_order);

-- Document events: fetch timeline for a document
CREATE INDEX idx_events_document_id ON dm_core.document_events (document_id, event_at);

-- Jobs: find stuck processing jobs (queue watchdog cron)
CREATE INDEX idx_jobs_status_started ON dm_flux.jobs (status, started_at)
    WHERE status = 'processing';

-- Jobs: find jobs for a document (used when retrying)
CREATE INDEX idx_jobs_document_hash ON dm_flux.jobs (document_hash);

-- Audit log: time-range queries
CREATE INDEX idx_audit_logged_at ON dm_flux.audit_log (logged_at DESC);

-- Health snapshots: recent snapshots
CREATE INDEX idx_health_captured_at ON dm_sentinel.health_snapshots (captured_at DESC);

-- Embeddings: vector similarity search (pgvector)
CREATE INDEX idx_embeddings_vector ON dm_core.embeddings
    USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100);

-- Full-text search on filename using trigram index
CREATE INDEX idx_documents_filename_trgm ON dm_core.documents
    USING gin (original_name gin_trgm_ops);

-- Full-text search on extracted field values
CREATE INDEX idx_extractions_value_trgm ON dm_core.extractions
    USING gin (field_value gin_trgm_ops);
```

**Notes on the IVFFlat index for vectors:**
The `lists = 100` parameter controls index precision. At document counts under 100,000, `lists = 100` is appropriate. Recalculate as `sqrt(row_count)` when the document count grows significantly. An IVFFlat index requires training data — it cannot be built on an empty table. Build this index after the first batch of documents has been processed, not during initialization.

### 1.6 Database Views

Three read-only views serve the recurring dashboard queries efficiently.

```sql
-- Top bar: document count by status
CREATE VIEW dm_core.document_status_counts AS
SELECT
    status,
    COUNT(*) AS doc_count
FROM dm_core.documents
GROUP BY status;

-- Top bar: today's processed count and average confidence
CREATE VIEW dm_core.daily_summary AS
SELECT
    COUNT(*) FILTER (WHERE processed_at >= DATE_TRUNC('day', NOW() AT TIME ZONE 'UTC')) AS processed_today,
    ROUND(AVG(confidence_score) FILTER (WHERE confidence_score IS NOT NULL), 1) AS avg_confidence
FROM dm_core.documents;

-- Health page: recent failures for error reporting
CREATE VIEW dm_core.recent_failures AS
SELECT
    id,
    original_name,
    doc_type,
    error_message,
    processed_at
FROM dm_core.documents
WHERE status = 'failed'
ORDER BY processed_at DESC
LIMIT 20;
```

### 1.7 Schema Migration with Alembic

All schema changes after initial deployment are managed through Alembic, the SQLAlchemy migration tool. Alembic must be installed in the Python virtual environment (Phase 2 Track 3) and initialized in Phase 2.

**Why Alembic matters here:** When Phase 3 application code runs and DocMaster receives its first update in Phase 8, the Blue/Green update may include schema changes. Without Alembic, schema changes require manual SQL execution. With Alembic, the application runs pending migrations automatically on startup before accepting connections.

The Alembic configuration file (`alembic.ini`) is placed at `/opt/docmaster/core/alembic.ini`. Migration scripts are stored in `/opt/docmaster/core/alembic/versions/`. The initial migration script captures the entire schema defined in this blueprint as version `0001`.

---

## Track 2 — Redis Queue Configuration

### 2.1 Redis Configuration

Redis is configured in `/etc/redis/redis.conf`. The default configuration must be replaced with a hardened, DocMaster-specific configuration.

**Key directives:**

| Directive | Value | Rationale |
|-----------|-------|-----------|
| `bind` | `127.0.0.1` | Localhost only — never exposed to network |
| `port` | `6379` | Default port — acceptable since it is localhost-only |
| `requirepass` | `<generated_password>` | Strong 32-char random password required for all connections |
| `maxmemory` | `512mb` | Hard cap to prevent Redis from consuming all available RAM during document spikes |
| `maxmemory-policy` | `allkeys-lru` | Evict least recently used keys when at capacity. Job queue items are typically consumed quickly; if a queue backs up badly enough to hit this limit, there are larger problems. |
| `save 900 1` | — | Write RDB snapshot if at least 1 key changed in 900 seconds |
| `save 300 10` | — | Write RDB snapshot if at least 10 keys changed in 300 seconds |
| `save 60 10000` | — | Write RDB snapshot if at least 10,000 keys changed in 60 seconds |
| `dir` | `/opt/docmaster/queue` | RDB and AOF files go to the DocMaster directory |
| `dbfilename` | `dm_queue.rdb` | Named file instead of the generic `dump.rdb` |
| `appendonly` | `yes` | Enable AOF persistence for crash recovery |
| `appendfilename` | `dm_queue.aof` | Named AOF file |
| `appendfsync` | `everysec` | Sync AOF to disk every second — balances durability and performance |
| `loglevel` | `notice` | Reduces log verbosity while preserving important events |
| `logfile` | `/opt/docmaster/logs/redis.log` | All Redis logs go to the DocMaster log directory |

The generated Redis password must be written to `/opt/docmaster/vault/.redis.secret`, owned `docmaster:docgroup`, mode `600`. The password is also added to the `.env` file as `DM_REDIS_PASSWORD` so the application can read it at runtime.

### 2.2 Queue Names and Priority Model

DocMaster uses four Redis lists as its queue structure. Workers process jobs using a blocking pop (`BLPOP`) with priority ordering — they always drain `high` before reading from `normal`, and always drain `normal` before reading from `low`. The `failed` list is not consumed by workers — it is processed by the retry cron job.

| Queue Key | Priority | Used For |
|-----------|----------|---------|
| `dm:queue:high` | Highest | Email ingest (user-facing, reply expected), API uploads with `priority=high`, manual re-queue from UI |
| `dm:queue:normal` | Default | Standard filesystem drop, SMB scan drop, API uploads with no priority specified |
| `dm:queue:low` | Background | External bridge sync (Drive, OneDrive, SFTP), scheduled batch operations |
| `dm:queue:failed` | Retry pool | Jobs that have failed at least once, waiting for retry cron |

### 2.3 Job Payload JSON Structure

Every item pushed to a Redis queue is a JSON string with this exact structure. The schema is fixed — the OCR worker deserializes it and validates required fields before processing.

```json
{
    "job_id": "550e8400-e29b-41d4-a716-446655440000",
    "document_id": "7c9e6679-7425-40de-944b-e07fc1f90ae7",
    "document_hash": "a665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3",
    "file_path": "/opt/docmaster/tmp/7c9e6679/original.pdf",
    "original_name": "Land_Registry_Deed_034.pdf",
    "mime_type": "application/pdf",
    "priority": "normal",
    "source_channel": "filesystem",
    "instruction": null,
    "retry_count": 0,
    "max_retries": 3,
    "created_at": "2026-01-15T09:23:11.000Z",
    "metadata": {
        "fax_source_number": null,
        "email_sender": null,
        "drive_file_id": null,
        "scanner_ip": null
    }
}
```

**Field notes:**

- `job_id` — matches the UUID primary key in `dm_flux.jobs`
- `document_hash` — included in the payload so the worker can verify the file has not been corrupted in transit (re-compute hash from `file_path` and compare)
- `instruction` — NULL for all channels except email ingest and direct API upload with instruction parameter
- All `metadata` fields are NULL except the one relevant to the source channel

### 2.4 Atomic Deduplication Pattern

Before pushing a new job to Redis, the ingest handler must check whether a job for this `document_hash` already exists in the queue or is currently processing. This is a two-step check:

1. Query `dm_flux.jobs` where `document_hash = ?` and `status IN ('queued', 'processing')`
2. If a matching job exists, do not push to Redis — return the existing `job_id` to the caller

This pattern prevents duplicate jobs when the same file is deposited in multiple channels simultaneously (e.g., a file is both dropped in the SMB share and uploaded via the API).

The check must be performed within a database transaction with `SELECT FOR UPDATE SKIP LOCKED` to prevent race conditions between concurrent ingest handlers.

---

## Track 3 — Python Virtual Environment & Drivers

### 3.1 Virtual Environment Creation

The Python virtual environment for the DocMaster application is isolated from the system Python. It lives inside the application directory and is owned by `docmaster`.

```
/opt/docmaster/core/.venv/
```

Create the virtual environment as `docmaster` user:

```bash
python3.12 -m venv /opt/docmaster/core/.venv
```

All subsequent `pip install` commands must be run with the virtual environment activated or by calling `/opt/docmaster/core/.venv/bin/pip` directly.

### 3.2 Core Python Package Dependencies

The following packages must be installed into the virtual environment. Versions must be pinned with `==` not `>=`. After installing, generate a `requirements.txt` with `pip freeze > /opt/docmaster/core/requirements.txt` and add this file to the manifest.

**Database and queue:**
- `asyncpg==0.29.0` — async PostgreSQL driver for FastAPI. Zero-copy binary protocol, significantly faster than psycopg2 for async workloads.
- `psycopg2-binary==2.9.9` — synchronous PostgreSQL driver, used for Alembic migrations (which run synchronously at startup)
- `redis==5.0.1` — Redis client with connection pooling. Pin to 5.x which introduced the async client used by the queue worker.
- `SQLAlchemy==2.0.23` — ORM and query builder. Used for Alembic schema management and optional ORM-layer queries. FastAPI interacts with the database primarily through asyncpg directly, but SQLAlchemy provides the Alembic integration.
- `alembic==1.13.0` — database migration tool

**API framework:**
- `fastapi==0.109.0` — the application framework
- `uvicorn[standard]==0.27.0` — ASGI server. The `[standard]` extras include `uvloop` (faster event loop) and `websockets` (for real-time queue status streaming)
- `pydantic==2.6.0` — data validation for request/response serialization
- `python-multipart==0.0.9` — required for FastAPI file upload handling (`multipart/form-data`)

**Authentication and security:**
- `passlib[bcrypt]==1.7.4` — bcrypt password hashing for operator accounts
- `python-jose[cryptography]==3.3.0` — JWT creation and validation for the license engine and API session tokens
- `cryptography==42.0.0` — foundational cryptographic operations: AES-256-GCM for config encryption, RSA operations for license key validation

**Utilities:**
- `python-dotenv==1.0.1` — loads the `/opt/docmaster/vault/.env` file into the process environment
- `structlog==24.1.0` — structured JSON logging. All DocMaster services use structlog for consistent, parseable log output
- `httpx==0.27.0` — async HTTP client for calling Ollama, Claude API, and bridge connectors
- `aiofiles==23.2.1` — async file operations for the ingest pipeline

### 3.3 Database Connection Pool Design

The FastAPI application connects to PostgreSQL using an asyncpg connection pool. The pool is initialized at application startup and shared across all request handlers.

**Pool parameters:**
- `min_size=2` — always keep 2 connections open. On a lightly loaded appliance this avoids connection establishment latency on the first request after idle periods.
- `max_size=10` — maximum 10 concurrent connections. This is well within the `max_connections=50` set in PostgreSQL. The remaining connections are reserved for maintenance, psql sessions, and sentinel queries.
- `max_inactive_connection_lifetime=300` — close connections that have been idle for 5 minutes, reducing resource consumption during overnight periods when no documents are being processed.
- `command_timeout=30` — any query taking longer than 30 seconds is cancelled and returns an error. Prevents runaway queries from blocking the worker.

The connection string format:
```
postgresql://dm_app:<password>@127.0.0.1:5432/dm_vault
```

The password comes from the `DM_DB_PASSWORD` environment variable, never hardcoded.

---

## Track 4 — Encrypted Configuration Vault

### 4.1 Design Philosophy

The configuration vault serves two purposes: it stores sensitive secrets (API keys, OAuth tokens, passwords) that must never appear in plaintext on disk, and it stores operational settings (confidence threshold, notification preferences) that the UI can read and update.

The design must satisfy three constraints:
1. The appliance must function without any internet connection
2. If someone steals the hard drive, they must not be able to read the secrets
3. The application must be able to decrypt secrets on boot without human input (a passphrase entered at the keyboard every reboot would make the appliance unusable)

These constraints rule out most external key management solutions. The approach chosen is **hardware-derived key material** — the encryption key is derived from data that only exists on this specific machine's hardware, regenerated on every boot, never stored anywhere.

### 4.2 Master Key Derivation

On every boot, the `dm-vault.service` performs the following:

1. Collects hardware data using the same method as the license fingerprint:
   - CPU ID via `dmidecode -s processor-id`
   - Motherboard UUID via `dmidecode -s system-uuid`
   - Primary NIC MAC via `ip link show` parsing
   - Root disk serial via `lsblk -o SERIAL`

2. Concatenates the four values with a fixed internal application salt (compiled into the binary, not on disk)

3. Derives the master encryption key using PBKDF2:
   - Hash function: SHA-256
   - Salt: the SHA-256 hash of the concatenated hardware values (itself used as a salt, not stored)
   - Iterations: 600,000 (NIST recommended minimum for PBKDF2-SHA-256 as of 2024)
   - Output length: 32 bytes (256 bits)

4. Holds this key in memory for the lifetime of the `dm-vault.service` process — never written to disk, never logged

The derived key is used for all AES-256-GCM encryption and decryption operations on `dm_vault.system_config` values where `is_encrypted = TRUE`.

**Security properties:** If the hard drive is removed to another machine, the hardware values change, the PBKDF2 derivation produces a different key, and all encrypted config values are permanently unreadable. The application will start in a degraded state (connector credentials unavailable) but will not expose the secrets.

### 4.3 AES-256-GCM Encryption Scheme

Each encrypted value is stored as a base64-encoded string containing three components:

```
base64( nonce || ciphertext || auth_tag )
```

- `nonce`: 12 bytes, randomly generated for each encryption operation. Never reused.
- `ciphertext`: the encrypted value bytes
- `auth_tag`: 16 bytes, the GCM authentication tag. Detects tampering.

The format is opaque to the database — the `value` column in `dm_vault.system_config` stores the base64 string as plain text. The encryption and decryption happen entirely in the application layer.

**Why GCM (not CBC)?** GCM provides authenticated encryption — any modification to the ciphertext causes decryption to fail with an authentication error rather than silently producing garbage plaintext. This is essential for a vault that must detect if someone has tampered with a stored value.

### 4.4 `.env` File Structure

The `/opt/docmaster/vault/.env` file holds non-secret environment variables that all systemd services inherit via `EnvironmentFile`. The complete set of variables for Phase 2:

```bash
# DocMaster Application Environment
# Non-secret variables only — secrets are in the encrypted vault

# Database
DM_DB_HOST=127.0.0.1
DM_DB_PORT=5432
DM_DB_NAME=dm_vault
DM_DB_USER=dm_app
DM_DB_PASSWORD=<generated_at_init>
DM_DB_POOL_MIN=2
DM_DB_POOL_MAX=10

# Redis
DM_REDIS_HOST=127.0.0.1
DM_REDIS_PORT=6379
DM_REDIS_PASSWORD=<generated_at_init>

# Ollama
OLLAMA_HOST=127.0.0.1:11434
OLLAMA_MODELS=/opt/docmaster/models
OLLAMA_KEEP_ALIVE=5m
OLLAMA_NUM_PARALLEL=1

# Application
DM_APP_HOST=127.0.0.1
DM_APP_PORT=8080
DM_LOG_LEVEL=INFO
DM_LOG_DIR=/opt/docmaster/logs
DM_DATA_DIR=/opt/docmaster/data
DM_TMP_DIR=/opt/docmaster/tmp
DM_BACKUP_DIR=/opt/docmaster/backups
DM_INGEST_DIR=/opt/docmaster/ingest
DM_MODELS_DIR=/opt/docmaster/models

# GPU (set to empty string if no GPU)
CUDA_VISIBLE_DEVICES=0
```

**Important:** `DM_DB_PASSWORD` and `DM_REDIS_PASSWORD` are in this file. They are not the "secrets in the encrypted vault" — they are database/queue passwords that the application uses to authenticate to services it controls on the same machine. These are protected by the file's `600` permissions. True secrets (customer API keys, OAuth tokens) are in the encrypted config vault in the database.

### 4.5 Initialization Script

Phase 2 initialization is orchestrated by a script at `/opt/docmaster/bin/dm-init-db.sh`. This script is idempotent — running it twice does not create duplicate objects. It performs:

1. Verify PostgreSQL is running and accepting connections
2. Create the `dm_app` role if it does not exist
3. Create the `dm_vault` database if it does not exist
4. Enable required extensions
5. Create schemas
6. Run Alembic migrations (applies all migrations up to `head`)
7. Seed `dm_vault.system_config` with default values if the table is empty
8. Seed `dm_vault.connector_configs` with initial disabled connector rows if empty
9. Verify Redis is running and the password is correct
10. Write a `phase2_complete` marker to `/opt/docmaster/vault/.setup_flags`

The script must be run as the `docmaster` user (not as `postgres` or root). The PostgreSQL superuser operations (creating extensions) are handled by a separate one-time superuser initialization script that must be run first.

---

## Track 5 — Backup Infrastructure

### 5.1 Backup Strategy

DocMaster implements a three-level backup strategy:

- **WAL archiving** (continuous) — PostgreSQL WAL segments are written to `/opt/docmaster/backups/wal/` as they are generated. This provides point-in-time recovery for any moment since the last base backup.
- **Daily database dump** (nightly at 02:30 UTC) — `pg_dump` produces a full SQL dump, encrypted and stored in `/opt/docmaster/backups/daily/`
- **Document file archive** (weekly) — a compressed archive of the `/opt/docmaster/data/documents/` directory

### 5.2 Dump Encryption

Daily backup encryption uses GPG symmetric encryption with a passphrase derived from the hardware fingerprint. The passphrase is regenerated on each backup run using the same PBKDF2 derivation used by the vault (different salt, same hardware material). This means:

- Backups created on this appliance can only be decrypted on this appliance
- A replacement appliance with the same hardware would produce a different passphrase
- Emergency recovery requires either the original hardware or a manually-recorded decryption passphrase

**Emergency recovery passphrase:** During the first-boot wizard setup (Phase 7), the admin must record a manually-entered recovery passphrase. This passphrase is stored alongside the hardware-derived passphrase in a two-key encryption scheme — the backup can be decrypted with either the hardware fingerprint (automated, on this machine) or the manually-recorded recovery passphrase (emergency, from any machine with GPG). This passphrase must be written down and stored securely offline by the customer.

### 5.3 Backup Retention and Verification

- **Daily backups:** retain 7 most recent, delete older
- **WAL files:** retain 24 hours of WAL segments. The sentinel cron verifies WAL files are being generated and alerts if the last WAL segment is older than 1 hour.
- **Backup verification:** A separate cron job runs nightly at 04:00 UTC. It takes the most recent daily backup, decrypts it, restores it to a temporary database (`dm_vault_verify`), runs a sanity check (COUNT on `dm_core.documents`), then drops the temporary database. If verification fails, an alert is written to the health log.

---

## Validation Checklist

### PostgreSQL

- [ ] `psql -U dm_app -d dm_vault -c "\dn"` lists all four schemas: `dm_core`, `dm_flux`, `dm_sentinel`, `dm_vault`
- [ ] `psql -U dm_app -d dm_vault -c "\dx"` shows `vector`, `pg_trgm`, `unaccent` extensions installed
- [ ] `psql -U dm_app -d dm_vault -c "\dt dm_core.*"` lists: `documents`, `extractions`, `document_events`, `embeddings`
- [ ] `psql -U dm_app -d dm_vault -c "\dt dm_flux.*"` lists: `jobs`, `audit_log`
- [ ] `psql -U dm_app -d dm_vault -c "\dt dm_sentinel.*"` lists: `health_snapshots`
- [ ] `psql -U dm_app -d dm_vault -c "\dt dm_vault.*"` lists: `operators`, `system_config`, `license_records`, `connector_configs`
- [ ] All four enum types exist: `document_type`, `document_status`, `ingest_channel`, `event_type`
- [ ] All three views exist in `dm_core`: `document_status_counts`, `daily_summary`, `recent_failures`
- [ ] `dm_vault.system_config` contains all 39 seed rows listed in Track 4
- [ ] `dm_vault.connector_configs` contains 8 seed rows (all disabled)
- [ ] `dm_app` role cannot connect to any database other than `dm_vault` (test: `psql -U dm_app -d postgres` must fail)
- [ ] PostgreSQL listens only on `127.0.0.1` (test from another host: connection refused)
- [ ] `log_min_duration_statement` is set to 500 (slow query logging active)
- [ ] Alembic reports `head` revision with `alembic current`

### Redis

- [ ] `redis-cli -a <password> ping` returns `PONG`
- [ ] Connection without password is refused: `redis-cli ping` returns authentication error
- [ ] Connection from outside localhost is refused
- [ ] `/opt/docmaster/vault/.redis.secret` exists, owned `docmaster:docgroup`, mode `600`
- [ ] `DM_REDIS_PASSWORD` is present in `/opt/docmaster/vault/.env`
- [ ] RDB file `dm_queue.rdb` exists in `/opt/docmaster/queue/`
- [ ] All four queue keys can be tested: push a test item to each queue and pop it back

### Python Environment

- [ ] `/opt/docmaster/core/.venv/bin/python --version` returns 3.12.x
- [ ] `asyncpg`, `fastapi`, `redis`, `alembic`, `cryptography`, `passlib` all importable
- [ ] `/opt/docmaster/core/requirements.txt` exists and is committed to manifest
- [ ] Alembic can connect to the database and run `alembic history` without error

### Encrypted Config Vault

- [ ] `/opt/docmaster/vault/.env` exists, owned `docmaster:docgroup`, mode `600`
- [ ] All required environment variables are present in `.env`
- [ ] The vault master key derivation produces consistent output on two consecutive runs (same hardware = same key)
- [ ] An encrypted config value (e.g., a test key with `is_encrypted = TRUE`) can be written and read back correctly through the vault API

### Backup Infrastructure

- [ ] WAL archiving is active: `SELECT pg_is_in_recovery()` returns `f`, and WAL files appear in `/opt/docmaster/backups/wal/`
- [ ] Manual `dm-backup.sh` run completes successfully and produces an encrypted file in `/opt/docmaster/backups/daily/`
- [ ] The encrypted backup can be decrypted using the hardware fingerprint passphrase
- [ ] Backup verification script runs without error on the latest backup

### Initialization

- [ ] `/opt/docmaster/vault/.setup_flags` contains `phase2_complete`
- [ ] `dm-init-db.sh` is idempotent: running it a second time produces no errors and no duplicate rows

---

## Common Failure Points & Mitigation

**PGDG pgvector package not found:**  
The `postgresql-16-pgvector` package is only available from the PGDG repository. If the PGDG repository was not added in Phase 1 before PostgreSQL was installed, the package manager may be looking at the wrong repository. Verify with `apt-cache policy postgresql-16-pgvector` — the candidate version should come from `packages.postgresql.org`, not from the distribution default.

**`CREATE EXTENSION vector` fails with "could not open file":**  
This means the `postgresql-16-pgvector` package was installed but the extension files are in the wrong location for the PostgreSQL 16 installation. Verify with `pg_config --sharedir` — the `.control` file for pgvector should be in `$sharedir/extension/vector.control`.

**asyncpg fails to build with "pg_config not found":**  
`libpq-dev` from the PGDG repository installs `pg_config` to a non-standard path on some systems. Check `which pg_config` and `pg_config --version`. If it points to an older version, explicitly set `PATH` to include the PGDG binaries before running pip.

**Redis authentication failures after restart:**  
Redis reads the password from `redis.conf`. If the file was edited but Redis was not restarted, the old (possibly empty) password is still active. After editing `redis.conf`, always restart Redis and verify with `redis-cli -a <new_password> ping`.

**PBKDF2 key derivation produces inconsistent output between runs:**  
This indicates one of the hardware values is non-deterministic between reads. `dmidecode` output is stable for physical hardware but may vary on virtual machines depending on the hypervisor. On VMs, test that `dmidecode -s system-uuid` returns the same value on five consecutive reads. If it varies, the VM's hardware emulation has a bug — switch to a different field (e.g., use the disk UUID from `blkid` instead of the disk serial from `lsblk`).

**Alembic cannot connect to the database:**  
Alembic uses a synchronous connection (psycopg2). Verify `psycopg2-binary` is installed in the venv. Also verify the `sqlalchemy.url` in `alembic.ini` uses the `postgresql+psycopg2://` driver prefix, not the `postgresql+asyncpg://` prefix that the application uses.

---

## Phase 2 Completion Criteria

Phase 2 is formally complete when:

1. All items in the validation checklist are confirmed on the live system
2. A test document record can be manually inserted into `dm_core.documents` and read back through all three views without error
3. A test job payload can be pushed to `dm:queue:normal` and popped back correctly
4. A test encrypted config value (using a test key) can be written and decrypted successfully through the vault API
5. The `dm-init-db.sh` script runs idempotently a second time without errors
6. The Phase 2 completion is documented in the project log with the manifest hash and verifying engineer name

**Do not proceed to Phase 3 until all six criteria are met.** Phase 3 application code will immediately begin reading from the database and Redis on startup. Schema errors discovered during Phase 3 development are substantially more expensive to fix than during Phase 2 initialization.

---

*DocMaster Master Implementation Plan — Phase 2 Blueprint*  
*Revision 1.0 — Confidential — Internal Engineering Use Only*
