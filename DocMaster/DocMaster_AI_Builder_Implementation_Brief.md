# DocMaster — AI Builder Master Implementation Brief
## Authoritative Reference for AI-Assisted Build Execution

**Classification:** Confidential — Internal Engineering Use Only  
**Product:** DocMaster v1.0 — Document Intelligence Appliance  
**Purpose:** This document is the single source of truth for any AI builder, code assistant (Claude Code, Replit, Cursor, etc.) working on the DocMaster codebase. Every architectural decision, naming convention, API route, database schema, and service boundary is defined here. The AI builder must treat this document as law — nothing contradicts it without explicit human approval.

---

## STRICT RULES — READ BEFORE GENERATING ANY CODE

These rules are non-negotiable. Every code suggestion, file created, route defined, or service named must comply with all of the following:

1. **Product name is DocMaster. No exceptions.** No "Nexus", no "DM App", no generic names. Every service, file, log entry, error code, and API route uses DocMaster or the `dm-` prefix.
2. **API namespace is `/dm/`** — never `/api/`, never `/v1/`. All routes follow `/dm/{domain}/{resource}`.
3. **System user is `dmuser`.** All services run under this non-root system account. Never `root`, never `www-data`.
4. **Install path is `/opt/docmaster/`.** All application files live here exclusively. Symlink architecture: `/opt/docmaster-blue/` (live) and `/opt/docmaster-green/` (standby) with `/opt/docmaster` pointing to the active side.
5. **All services are named `dm-*.service`.** Core services: `dm-core`, `dm-flux`, `dm-mind`, `dm-bridge`, `dm-sentinel`, `dm-vault`, `dm-insights` (v1.1 only).
6. **Database name is `dm_vault`.** Schemas: `dm_core`, `dm_flux`, `dm_sentinel`, `dm_vault`. Never create tables outside these schemas.
7. **Config file is `/opt/docmaster/config/dm.env`** with `600` permissions. Never hardcode credentials anywhere.
8. **Error codes use the `DM_` prefix** (e.g., `DM_4021`, `DM_5001`). Never expose raw stack traces to the UI or API responses.
9. **No internet calls at runtime.** Every dependency — Python packages, OCR models, LLM weights, npm packages — must be vendored. The appliance operates fully air-gapped.
10. **Enum values are fixed.** Document type values (`deed`, `invoice`, `form`, `handwritten`, `table`, `mixed`, `unknown`) and status values (`queued`, `processing`, `complete`, `review`, `failed`) are stored verbatim in the database and must match CSS class names in the UI exactly.
11. **All timestamps are UTC.** No exceptions. Every database column, log entry, and API response uses UTC.
12. **UUIDs for all primary keys** in core tables. Audit log uses BIGSERIAL for write performance.
13. **Passwords hashed with bcrypt, cost factor 12.** JWT tokens use RS256. No MD5, no SHA-1 for authentication.
14. **The Blue/Green update mechanism must never be broken.** All systemd unit files, cron jobs, and config references use `/opt/docmaster/` (the symlink), never the `-blue` or `-green` path directly.

---

## Section 1 — System Architecture Overview

DocMaster is a closed-source, air-gapped, self-hosted Document Intelligence Appliance. It converts physical and digital documents into structured, queryable data using a cascaded OCR engine stack and a local LLM extraction layer. It is designed for deployment in developing nations and infrastructure-limited environments where cloud connectivity cannot be assumed.

### 1.1 Service Topology

All services run as independent systemd units under `dmuser`. Services communicate exclusively via localhost sockets or the internal Redis message queue.

| Service | Function | Port | Depends On | Complexity |
|---------|----------|------|-----------|------------|
| `dm-core.service` | FastAPI REST + WebSocket API server | 8443 | postgres, redis | Medium |
| `dm-flux.service` | File watcher + ingest queue daemon | — | redis, dm-core | Easy |
| `dm-ocr-worker` | OCR engine process pool (inside dm-flux) | — | dm-flux, redis | Hard |
| `dm-mind.service` | Ollama LLM wrapper + inference API | 11434 | ollama.service | Medium |
| `dm-bridge.service` | External connector daemon (Drive, Email, Fax, SFTP) | — | dm-core | Hard |
| `dm-sentinel.service` | Health monitor + watchdog daemon | — | all services | Medium |
| `dm-vault.service` | License engine + encrypted config store | — | none | Hard |
| `dm-insights.service` | Insights Engine — analytics layer (v1.1) | 8444 | postgresql, dm-core | Medium |

### 1.2 Full Directory Tree

```
/opt/docmaster/
├── bin/                  ← Binaries & management scripts
│   ├── dm-core           ← FastAPI/Uvicorn server binary
│   ├── dm-flux           ← File watcher & queue worker
│   ├── dm-mind           ← Ollama wrapper & model router
│   ├── dm-sentinel       ← Health check daemon
│   ├── dm-bridge         ← External connector service
│   ├── dm-update.sh      ← Blue/Green update orchestrator
│   ├── dm-backup.sh      ← Nightly encrypted DB backup
│   └── wait-for-ollama.sh
├── config/
│   ├── dm.env            ← Runtime env vars (600 permissions)
│   ├── license.key       ← Node-locked license file
│   └── schemas/          ← Document-type JSON extraction schemas
├── core/                 ← FastAPI application source
│   ├── .venv/            ← Python 3.12 virtual environment
│   ├── alembic/          ← DB migration scripts
│   └── requirements.txt
├── data/
│   ├── pgdata/           ← PostgreSQL data directory
│   └── vectors/          ← pgvector store
├── ingest/
│   ├── drop/             ← Local folder drop zone
│   ├── smb/              ← Samba network scanner share
│   ├── fax/              ← HylaFAX received PDFs
│   └── email/            ← SMTP attachment staging
├── logs/                 ← All service logs (centralized)
├── models/               ← Ollama model storage + OCR models + ONNX classifier
│   ├── paddleocr/        ← Pre-downloaded PaddleOCR model files
│   ├── kraken/           ← Kraken recognition model files
│   └── classifier/       ← doc_classifier_v1.onnx
├── tmp/                  ← OCR processing scratch space (per-job subdirs)
├── vault/                ← Original document archive (append-only)
├── www/                  ← Compiled React UI static assets
├── reports/              ← Generated report output (v1.1)
│   ├── scheduled/
│   └── on-demand/
└── backups/              ← Encrypted nightly DB and config archives
    ├── daily/
    └── wal/
```

### 1.3 Technology Stack

| Layer | Technology | Version |
|-------|-----------|---------|
| OS | Debian 12 (Bookworm) or Ubuntu Server 24.04 LTS | LTS only |
| API Framework | FastAPI + Uvicorn (ASGI) | 0.109.0 / 0.27.0 |
| Database | PostgreSQL 16 (PGDG repo) + pgvector | 16.x |
| Queue | Redis 7.x (official repo) | 7.x |
| LLM Runtime | Ollama (vendored binary) | pinned |
| Primary OCR | Tesseract 5 (LSTM engine) | 5.x |
| Secondary OCR | PaddleOCR (local model paths) | 2.7.3 |
| Historical OCR | Kraken (trained models) | 4.3.13 |
| Last-Resort OCR | olmOCR via Qwen2.5-VL through Ollama | 7b |
| Classifier | MobileNetV3-Small → ONNX Runtime | 1.17.0 |
| Python | 3.12 (venv at `/opt/docmaster/core/.venv/`) | 3.12 |
| Node.js | 22 LTS (NodeSource repo) | 22.x |
| UI Framework | React 18 (compiled static bundle via Vite) | 18 |
| CSS | CSS custom properties + vanilla CSS (no Tailwind) | — |
| Charts | Chart.js (vendored) | vendored |
| HTTP Client | Native fetch() + custom hook | — |

---

## Section 2 — Phase Breakdown

### Phase 1 — OS Foundation & Environment Hardening

**Goal:** Produce a hardened, minimal Linux environment with the correct user, directory structure, pinned dependencies, and service permissions. Nothing from Phase 2 onward is reliable without this phase being complete.

**Key deliverables:**
- Debian 12 or Ubuntu 24.04 LTS minimal install (no GUI, no snap)
- Static IP, hostname set to `docmaster-node-01`, timezone to UTC
- UFW firewall: deny all inbound except SSH (admin IP only), port 8443 (LAN only), ICMP
- SSH: key-only auth, `PasswordAuthentication no`, `PermitRootLogin no`
- System user `dmuser` (no shell, no home) and group `docgroup`
- `scanuser` added to `docgroup` for SMB ingest write access
- Full directory tree at `/opt/docmaster-blue/` with symlink `/opt/docmaster → /opt/docmaster-blue/`
- Directory permissions: `vault/`, `tmp/`, `data/`, `queue/` → mode `700`; `ingest/` → `770`; all others → `750`

**Required system packages (pinned, from official repos):**
PostgreSQL 16 + pgvector (PGDG), Redis 7 (official), Python 3.12, Node.js 22 LTS (NodeSource), Tesseract 5, poppler-utils, imagemagick, ghostscript, opencv dependencies, ffmpeg, postfix (local-only), samba, hylafax-server, chrony, ufw, dmidecode, libpq-dev, libssl-dev, apparmor + apparmor-utils, libheif-dev

**Ollama setup:**
- Binary at `/opt/docmaster/bin/ollama`, owned `dmuser:docgroup`, mode `750`
- `OLLAMA_HOST=127.0.0.1:11434`, `OLLAMA_MODELS=/opt/docmaster/models`
- Pre-pull models: `llama3.1:8b-q4_K_M`, `nomic-embed-text`, `qwen2.5-vl:7b`
- `wait-for-ollama.sh` polls health endpoint with 120-second timeout

**Environment file:** `/opt/docmaster/config/dm.env`, mode `600`, sourced by all systemd units via `EnvironmentFile=`

**Manifest:** All installed package versions, model SHA-256 digests, OS info written to `/opt/docmaster/vault/manifest.lock` — read-only after generation.

---

### Phase 2 — Database, Queue & Storage Layer

**Goal:** Fully initialized PostgreSQL schema aligned to the UI data model, Redis queue configured, Python virtual environment built, encrypted config vault seeded.

#### PostgreSQL Configuration

- Listen on `127.0.0.1` only
- `max_connections=50`, `shared_buffers=25% RAM`, `work_mem=64MB`
- `log_min_duration_statement=500` (slow query logging)
- `idle_in_transaction_session_timeout=30000`
- `pg_hba.conf`: only `dm_app` role, SCRAM-SHA-256, local socket + `127.0.0.1/32`

**Initialization sequence:**
1. Create role `dm_app` (LOGIN, no superuser, no createdb)
2. Create database `dm_vault` with UTF-8, `template0`
3. Enable extensions: `vector`, `pg_trgm`, `unaccent`
4. Create schemas: `dm_core`, `dm_flux`, `dm_sentinel`, `dm_vault`

#### Complete Schema Definitions

**`dm_core.document_type` (enum):** `deed`, `invoice`, `form`, `handwritten`, `table`, `mixed`, `unknown`

**`dm_core.document_status` (enum):** `queued`, `processing`, `complete`, `review`, `failed`

**`dm_core.ingest_channel` (enum):** `filesystem`, `smb`, `api`, `email`, `fax`, `google_drive`, `onedrive`, `dropbox`, `sftp`, `webhook`

**`dm_core.event_type` (enum):** `ingested`, `queued`, `processing_started`, `ocr_complete`, `extraction_complete`, `flagged_for_review`, `correction_saved`, `marked_complete`, `failed`, `retried`, `exported`

**`dm_core.documents`** — central document table:
```sql
id UUID PK, filename TEXT, original_name TEXT, hash_sha256 CHAR(64) UNIQUE,
file_path TEXT, file_size_bytes BIGINT, mime_type TEXT, page_count INTEGER DEFAULT 1,
doc_type dm_core.document_type DEFAULT 'unknown',
status dm_core.document_status DEFAULT 'queued',
confidence_score NUMERIC(5,2), source_channel dm_core.ingest_channel DEFAULT 'api',
operator_id UUID → dm_vault.operators, ingested_at TIMESTAMPTZ, queued_at TIMESTAMPTZ,
processing_started_at TIMESTAMPTZ, processed_at TIMESTAMPTZ, reviewed_at TIMESTAMPTZ,
reviewed_by UUID → dm_vault.operators, retry_count SMALLINT DEFAULT 0,
error_message TEXT, metadata_json JSONB DEFAULT '{}'
```

**`dm_core.extractions`** — per-field extracted data:
```sql
id UUID PK, document_id UUID → dm_core.documents CASCADE,
field_name TEXT, field_value TEXT, field_order SMALLINT DEFAULT 0,
confidence NUMERIC(5,2), is_corrected BOOLEAN DEFAULT FALSE,
original_value TEXT, corrected_by UUID → dm_vault.operators,
corrected_at TIMESTAMPTZ, ocr_engine TEXT, created_at TIMESTAMPTZ
```

**`dm_core.document_events`** — activity timeline per document:
```sql
id UUID PK, document_id UUID → dm_core.documents CASCADE,
event_type dm_core.event_type, event_at TIMESTAMPTZ, duration_ms INTEGER,
detail TEXT, operator_id UUID, metadata_json JSONB
```

**`dm_core.embeddings`** — vector chunks for semantic search:
```sql
id UUID PK, document_id UUID CASCADE, chunk_index SMALLINT,
chunk_text TEXT, embedding vector(768), created_at TIMESTAMPTZ,
UNIQUE(document_id, chunk_index)
```

**`dm_flux.jobs`** — persistent job queue record:
```sql
id UUID PK, document_id UUID → dm_core.documents, document_hash CHAR(64),
priority dm_flux.job_priority DEFAULT 'normal',
status dm_flux.job_status DEFAULT 'queued',
source_channel dm_core.ingest_channel, instruction TEXT, worker_id TEXT,
created_at TIMESTAMPTZ, started_at TIMESTAMPTZ, completed_at TIMESTAMPTZ,
retry_count SMALLINT DEFAULT 0, max_retries SMALLINT DEFAULT 3,
error_message TEXT, error_detail TEXT, payload_json JSONB
```

**`dm_flux.audit_log`** — immutable append-only log (BIGSERIAL PK):
```sql
id BIGSERIAL PK, action TEXT, resource_type TEXT, resource_id TEXT,
operator_id UUID, ip_address INET, user_agent TEXT, detail_json JSONB, logged_at TIMESTAMPTZ
```

**`dm_sentinel.health_snapshots`**:
```sql
id BIGSERIAL PK, captured_at TIMESTAMPTZ, overall_status TEXT CHECK IN ('ok','degraded','critical'),
components_json JSONB, triggered_by TEXT DEFAULT 'cron'
```

**`dm_vault.operators`** — user accounts:
```sql
id UUID PK, username TEXT UNIQUE, display_name TEXT, password_hash TEXT,
role dm_vault.operator_role DEFAULT 'reviewer', is_active BOOLEAN DEFAULT TRUE,
last_login_at TIMESTAMPTZ, created_at TIMESTAMPTZ, created_by UUID
```
Roles: `admin`, `operator`, `reviewer`, `readonly`

**`dm_vault.system_config`** — key-value settings store:
```sql
key TEXT PK, value TEXT, is_encrypted BOOLEAN DEFAULT FALSE,
description TEXT, updated_at TIMESTAMPTZ, updated_by UUID
```

**`dm_vault.license_records`**:
```sql
id BIGSERIAL PK, fingerprint_hash CHAR(64), customer_id TEXT,
seat_max SMALLINT DEFAULT 1, feature_flags JSONB, issued_at TIMESTAMPTZ,
expires_at TIMESTAMPTZ, activated_at TIMESTAMPTZ, is_active BOOLEAN, validation_log TEXT
```

**`dm_vault.connector_configs`**:
```sql
connector_name TEXT PK, is_enabled BOOLEAN DEFAULT FALSE,
config_json TEXT DEFAULT '{}', last_sync_at TIMESTAMPTZ,
last_sync_status TEXT, last_error TEXT, updated_at TIMESTAMPTZ
```
Seed: `google_drive`, `onedrive`, `dropbox`, `sftp`, `email_ingest`, `fax`, `claude_api`, `webhook_outbound`

#### Critical Indexes

```sql
-- Status filter (UI filter pills)
CREATE INDEX idx_documents_status ON dm_core.documents (status);
-- Today's count (top bar stat)
CREATE INDEX idx_documents_processed_at_date ON dm_core.documents (DATE(processed_at));
-- Default sort
CREATE INDEX idx_documents_ingested_at ON dm_core.documents (ingested_at DESC);
-- Extraction field fetch (modal load)
CREATE INDEX idx_extractions_document_id ON dm_core.extractions (document_id, field_order);
-- Timeline fetch
CREATE INDEX idx_events_document_id ON dm_core.document_events (document_id, event_at);
-- Vector search (build AFTER first 3900+ embeddings exist)
CREATE INDEX idx_embeddings_vector ON dm_core.embeddings
    USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
-- Trigram search on filenames
CREATE INDEX idx_documents_filename_trgm ON dm_core.documents
    USING gin (original_name gin_trgm_ops);
```

#### Database Views

```sql
CREATE VIEW dm_core.document_status_counts AS
SELECT status, COUNT(*) AS doc_count FROM dm_core.documents GROUP BY status;

CREATE VIEW dm_core.daily_summary AS
SELECT
    COUNT(*) FILTER (WHERE processed_at >= DATE_TRUNC('day', NOW() AT TIME ZONE 'UTC')) AS processed_today,
    ROUND(AVG(confidence_score) FILTER (WHERE confidence_score IS NOT NULL), 1) AS avg_confidence
FROM dm_core.documents;
```

#### Redis Queue Configuration

- Bind: `127.0.0.1:6379`, password required (32-char random)
- `maxmemory=512mb`, `maxmemory-policy=allkeys-lru`
- RDB + AOF persistence to `/opt/docmaster/queue/`
- Logs to `/opt/docmaster/logs/redis.log`

**Queue names (priority order for BLPOP):**

| Queue Key | Priority | Used For |
|-----------|----------|----------|
| `dm:queue:high` | Highest | Email ingest, API with `priority=high`, manual re-queue |
| `dm:queue:normal` | Default | Filesystem drop, SMB scan drop, standard API uploads |
| `dm:queue:low` | Background | Drive/OneDrive/SFTP sync, scheduled batch |
| `dm:queue:failed` | Retry pool | Failed jobs awaiting retry cron |

**Job payload JSON structure (exact schema — do not deviate):**
```json
{
  "job_id": "UUID",
  "document_id": "UUID",
  "document_hash": "SHA256",
  "file_path": "/opt/docmaster/tmp/{job_id}/original.pdf",
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

#### Python Virtual Environment

Location: `/opt/docmaster/core/.venv/` (Python 3.12)

**Core packages (all pinned with `==`):**
```
asyncpg==0.29.0, psycopg2-binary==2.9.9, redis==5.0.1, SQLAlchemy==2.0.23, alembic==1.13.0
fastapi==0.109.0, uvicorn[standard]==0.27.0, pydantic==2.6.0, python-multipart==0.0.9
passlib[bcrypt]==1.7.4, python-jose[cryptography]==3.3.0, cryptography==42.0.0
python-dotenv==1.0.1, structlog==24.1.0, httpx==0.27.0, aiofiles==23.2.1
opencv-python-headless==4.9.0.80, Pillow==10.2.0, pytesseract==0.3.10
scikit-image==0.23.1, pyheif==0.8.0, numpy==1.26.4
paddleocr==2.7.3, paddlepaddle==2.6.1, kraken==4.3.13
onnxruntime==1.17.0, langchain-text-splitters==0.0.1, tiktoken==0.6.0
```

#### Encrypted Config Vault

- Master key derived at boot from hardware: CPU ID + Motherboard UUID + NIC MAC + disk serial
- PBKDF2-SHA256, 600,000 iterations, 32-byte output
- Key held in memory only — never written to disk
- Encrypted values stored in `dm_vault.system_config` where `is_encrypted = TRUE`
- Format: `base64(nonce[12] || ciphertext || auth_tag[16])` using AES-256-GCM
- If drive is stolen/moved, key derivation fails → encrypted config inaccessible

---

### Phase 3 — OCR Pipeline

**Goal:** A complete pipeline from raw document file to structured, confidence-scored field-level data stored in the database and indexed for semantic search.

#### Worker Architecture

- Long-running Python process under `dm-flux.service`
- Startup: initializes Redis + PostgreSQL connection pools, loads all schemas from `/opt/docmaster/config/schemas/`, loads ONNX classifier
- Main loop: `BLPOP` across `[dm:queue:high, dm:queue:normal, dm:queue:low]` in priority order
- Systemd watchdog: ping every 25 seconds (WatchdogSec=30)
- Per-job working directory: `/opt/docmaster/tmp/{job_id}/`

#### Stage 1 — Pre-Processing

1. **Format normalization:** PDF → `pdftoppm -r 300 -png`; TIFF → Pillow frame split + upsample to 300 DPI; HEIC → pyheif decode; single images → OpenCV normalize
2. **Orientation detection:** Tesseract OSD — rotate if confidence ≥ 1.5
3. **Deskewing:** Probabilistic Hough Transform — correct if angle between -10° and +10°
4. **Denoising:** `fastNlMeansDenoising(h=10)` for grain; `medianBlur(kernel=3)` for fax artifacts
5. **Binarization:** Sauvola adaptive threshold (window=25, k=0.2) — skip if `use_color_ocr=True`

Write `page_count` to `dm_core.documents.page_count` after counting pages in `pages/`.

#### Stage 2 — Document Classification

- **Model:** MobileNetV3-Small, ~2.5M params, ONNX format
- **Location:** `/opt/docmaster/models/classifier/doc_classifier_v1.onnx`
- **Runtime:** ONNX Runtime (`onnxruntime==1.17.0`) — CPU inference <100ms
- **Output:** `doc_type`, `confidence`, `is_handwritten`, `has_table`, `has_stamp`, `use_color_ocr`, `recommended_engine`
- **Low-confidence fallback:** confidence < 0.60 → classify as `unknown`, use generic schema

#### Stage 3 — OCR Engine Selection

| Condition | Primary Engine | Fallback |
|-----------|---------------|---------|
| Modern printed document | Tesseract 5 | PaddleOCR |
| Primary confidence < `ocr_fallback_threshold` (default 75%) | Tesseract 5 | Kraken |
| `is_handwritten = True` | Kraken | olmOCR (Qwen2.5-VL) |
| Multilingual / non-Latin script | PaddleOCR | Tesseract 5 |
| `has_table = True` | PaddleOCR PP-Structure | Tesseract 5 |

**Tesseract:** `--oem 3 --psm 3`. Call `image_to_data()` for word-level confidence. Also generate hOCR for bounding boxes.

**PaddleOCR:** Must use local model paths — disable all auto-download. Set `PADDLE_PDX_CACHE_HOME=/opt/docmaster/models/paddleocr`. For tables: PP-Structure module with local layout + table model dirs.

**Kraken:** Vendored models at `/opt/docmaster/models/kraken/`. Use `blla.segment()` + `rpred.rpred()`.

**olmOCR (Qwen2.5-VL):** Route through Ollama API with base64-encoded page image. Assign fixed confidence 0.65 (auto-triggers `review` status).

Merge all page OCR to `ocr_merged.txt` with `=== PAGE N OF M ===` markers.

#### Stage 4 — LLM Extraction

**Schema files:** One JSON file per document type in `/opt/docmaster/config/schemas/`. Fields: `name`, `display_name`, `type`, `required`, `description`, `example`.

**Ollama API call:**
```json
{
  "model": "llama3.1:8b-q4_K_M",
  "messages": [{"role": "system", "content": "..."}, {"role": "user", "content": "..."}],
  "format": "json",
  "stream": false,
  "options": {"temperature": 0.0, "num_ctx": 8192}
}
```
`format: "json"` and `temperature: 0.0` are mandatory — never change these.

**Review status logic:** A document is marked `review` if **any single required field** has confidence below `review_threshold` (default 75%) — not just the mean.

**Database write:** Atomic transaction updating `dm_core.documents`, inserting into `dm_core.extractions`, and inserting `dm_core.document_events` records.

**Hybrid routing:** If `llm_use_external_api=true` AND internet available AND `dm:queue:high` → route to Claude API. Store `ocr_engine='claude_api'` or `'ollama'` in extractions for audit trail.

#### Stage 5 — Vector Indexing

- Chunk `ocr_merged.txt` using `RecursiveCharacterTextSplitter`: `chunk_size=512`, `chunk_overlap=64`
- Embed each chunk via Ollama `nomic-embed-text` → 768-dimensional vector
- Upsert to `dm_core.embeddings` with `ON CONFLICT DO UPDATE`
- Build IVFFlat index only after ≥3,900 rows exist (sentinel cron monitors)

---

### Phase 4 — Build Execution & Installer Architecture

**Goal:** Dual installer (ISO + bash script) producing identical environments. This is where the codebase becomes a shippable product.

**Three delivery formats:**
- **Method A — Bootable ISO:** Packer QEMU build, ~8-12 GB (models embedded), USB-boot for air-gapped deployments
- **Method B — LXC Container Template:** `.tar.zst` for Proxmox environments, ~6-9 GB
- **Method C — Bash Installer Script:** `dm-install.sh` + offline bundle, ~500 MB, for existing Debian/Ubuntu servers
- **Method D — Docker Compose Bundle:** Development and pilot deployments

All methods produce identical application code, schema, and service structure. Data migration between methods uses standard `dm-backup/restore` tooling.

**Makefile build pipeline:** Single `make build VERSION=1.0.0 METHOD=iso|lxc|installer|docker|all` command. No manual build steps permitted.

**systemd Unit File Pattern (all services):**
```ini
[Unit]
Description=DocMaster [Service Name]
After=network.target postgresql.service redis.service
Requires=postgresql.service

[Service]
User=dmuser
Group=docgroup
EnvironmentFile=/opt/docmaster/config/dm.env
WorkingDirectory=/opt/docmaster
ExecStart=/opt/docmaster/bin/dm-[service]
Restart=on-failure
RestartSec=5
WatchdogSec=30
StandardOutput=journal
StandardError=journal
SyslogIdentifier=dm-[service]

[Install]
WantedBy=multi-user.target
```

**Cron file:** `/etc/cron.d/docmaster` — all scheduled jobs in one file:
- `02:30 UTC` — encrypted DB backup
- `04:00 UTC` — backup verification
- `03:00 UTC` — tmp cleanup (failed job dirs > 24h)
- `03:30 UTC` — IVFFlat index check + rebuild if needed
- `*/30 * * *` — sentinel health snapshot

---

### Phase 5 — Insights Engine (DocMaster v1.1)

**Scope:** Additive upgrade to v1.0. Introduces `dm-insights.service` on port 8444, three new DB schemas (`dm_analytics`, `dm_graph`, `dm_reports`), new API domain `/dm/insights/`, and new UI section. Does NOT modify any Phase 1–4 component.

**Key rule:** The Insights Engine is read-only against `dm_core` and `dm_flux` schemas. It never writes to them. No FK constraints cross from Insights schemas back to core. Any Insights failure is completely isolated from document processing.

**Insights Indexer:** Background process inside `dm-insights.service`. Polls `dm_core.documents` for unindexed records (tracked in `dm_analytics.index_state`). For each unindexed document: reads `extracted_json`, runs entity extraction via Ollama, updates entity graph, recalculates aggregates, marks indexed.

**New schemas (additive only):**
- `dm_analytics` — `index_state`, `volume_metrics`, `anomalies`, `insight_cache`
- `dm_graph` — `entities`, entity relationships
- `dm_reports` — scheduled and on-demand report records

**Six Insights Engine modules:** Indexer, Trend Engine, Entity Extractor, Anomaly Detector, Natural Language Query, Report Generator

**NL Query security:** SQL allowlist validator — must be pen-tested before v1.1 release. No unrestricted SQL generation.

---

### Phase 6 — Go-Live & Operational Readiness

**Scope:** Business readiness, not technical architecture. Defines pricing tiers, license activation workflow, multi-language OCR validation, ARM64 path (v1.1), and vendor operations framework.

**Product tiers:** Tier 1 (Site), Tier 2 (Pro Site with Insights), Tier 3 (Multi-Site, up to 10 nodes), Tier 4 (Enterprise, unlimited nodes + custom OCR)

**License model:** Annual subscription baseline. Perpetual option at 2.5× annual. Grant/donor pricing available.

**Offline license activation workflow:** Vendor Portal → QR code → operator scans → license.key delivered. No email with attachment.

**Hardware fingerprint:** 6 sources (TPM EK hash, motherboard UUID, machine-id, primary NIC MAC, CPU model+cores, root disk serial). Minimum 2 sources required. Format: `DM-XXXX-XXXX-XXXX-XXXX`. Tolerance: 1 source changed → accept + warn; 2 sources → 14-day grace; 3+ sources → locked.

**Release roadmap:**
- **v1.0** — Full Phase 1–4 core: OCR, extraction, all ingest channels, API, UI, health, licensing
- **v1.1** — Phase 5 Insights Engine as Blue/Green update to all v1.0 customers; ARM64 variant
- **v1.2** — Scale & Reach: multi-node, additional language models, enterprise connectors

---

### Phase 7 — UI Layer Specification

**Goal:** Complete browser-based interface specification. The UI is compiled to a static bundle served from `/opt/docmaster/www/` with zero CDN dependency.

**Design system tokens (exact CSS custom properties — do not deviate):**

| Token | Value | Usage |
|-------|-------|-------|
| `--color-bg-primary` | `#f8fafc` | Page background |
| `--color-bg-secondary` | `#ffffff` | Cards, modals |
| `--color-bg-dark` | `#1e293b` | Sidebar |
| `--color-text-primary` | `#0f172a` | Body text |
| `--color-accent` | `#38bdf8` | CTA buttons, active nav, focus rings |
| `--color-success` | `#10b981` | Complete status, healthy |
| `--color-warning` | `#f59e0b` | Review status, disk warnings |
| `--color-error` | `#ef4444` | Failed status, critical alerts |
| `--color-processing` | `#3b82f6` | Active queue items |
| `--color-border` | `#e2e8f0` | Default borders |

**Typography:** 28px/semibold headings, 18px/semibold sections, 14px/regular body, 12px/regular meta. System font stack only — zero external font loading.

**All margins/padding/gaps are multiples of 8px. No exceptions.**

**Application Shell:** Left sidebar (240px fixed, `#1e293b`), Top bar (56px, `#ffffff`), Main content area (overflow-y: auto, padding 32px, `#f8fafc`).

**UI Pages:**

| Route | Page | Key Components |
|-------|------|----------------|
| `/` | Dashboard | KPI cards, trend chart (Chart.js), activity feed, review spotlight |
| `/documents` | Documents | Paginated table, filter pills with live counts, bulk actions, upload modal, document detail modal |
| `/queue` | Queue | Live WebSocket table, job detail drawer, retry/cancel, stuck job detection |
| `/insights` | Insights | 6 sub-pages: Overview, Trends, Entity Graph (D3.js), Anomalies, NL Query, Reports |
| `/search` | Search | Semantic + keyword, result cards, search history |
| `/integrations` | Integrations | Connector cards, OAuth flow, SMTP config |
| `/health` | System Health | Service cards, diagnostic suite, live log terminal, update panel |
| `/settings` | Settings | 8 sub-sections: General, OCR, Extraction, Storage, Security, License, Notifications, Advanced |

**Authentication:** JWT Bearer tokens. Stored in memory only — never localStorage. 401 triggers auto re-auth prompt. Tokens expire per `session_timeout` setting.

**First-boot Setup Wizard:** 5-screen flow: License Activation → Hardware Fingerprint → Admin Account → Basic Settings → Completion. Runs before any other UI is accessible. Sets `dm_vault.system_config.setup_complete = true` on completion.

**Document Detail Modal states:**
- Source image with page indicator ("Page 2 of 3")
- Extracted fields table with per-field confidence badges (≥90 → green, 75–89 → orange, <75 → red)
- Editable correction inputs for low-confidence fields
- "Save Corrections" → `POST /dm/core/documents/{id}/corrections`
- "Mark as Reviewed" → `PATCH /dm/core/documents/{id}/status`

---

### Phase 8 — Appliance Packaging & Delivery

**Goal:** Shippable, verifiable, and field-supportable release artifacts.

**Build environment requirements:** Dedicated build server (not dev machine), 16+ cores, 64GB RAM, 1TB NVMe, Ubuntu 24.04 LTS, QEMU/KVM, Packer 1.10.x (pinned). Air-gapped during production builds — all dependencies from local vendor mirror.

**Offline dependency bundle must include:**
- APT mirror (all Phase 1 system packages at pinned versions)
- pip cache (all Python packages at pinned versions)
- npm bundle (all Node.js packages)
- Ollama model files (`llama3.1:8b-q4_K_M`, `nomic-embed-text`, `qwen2.5-vl:7b`)
- PaddleOCR model directories (det, rec, cls, layout, table)
- Kraken model files (`en_best.mlmodel`, `Fraktur_5000000.mlmodel`, `arabic_best.mlmodel`)
- ONNX classifier model (`doc_classifier_v1.onnx`)
- Vendored Ollama binary

**Artifact signing:** Ed25519 vendor key. Customer verification workflow documented in release runbook. `sha256sum` + `sha512sum` checksums for all artifacts.

**Blue/Green update format (`.dmupdate` bundle):**
- Signed archive containing application delta
- Swap active symlink (`/opt/docmaster` → `-green`)
- If health check fails within 60 seconds → auto-rollback to `-blue`

**AppArmor profiles required for:** `dm-core`, `dm-flux`, `dm-ocr-worker`

**Pre-seal hardening checklist:**
- Scrub all development credentials and sample data
- Randomize all default passwords
- Verify no hardcoded IPs or hostnames
- Confirm all API keys are empty in `dm_vault.system_config`
- Verify AppArmor profiles loaded and enforcing

---

## Section 3 — Complete API Route Reference

All routes require `Authorization: Bearer {jwt}` except `GET /dm/sentinel/health` and `POST /dm/vault/auth/login`.

All responses include: `X-DM-Build`, `X-DM-Node`, `X-DM-Version` headers.

### Core Document Routes — `/dm/core/`

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/dm/core/documents` | GET | Paginated filterable document list. Params: `page`, `limit`, `status`, `doc_type`, `search`, `date_from`, `date_to` |
| `/dm/core/documents/{id}` | GET | Full document detail with extractions and event timeline |
| `/dm/core/documents/{id}/export` | POST | Export as CSV, JSON, PDF, or XLSX |
| `/dm/core/documents/{id}/corrections` | POST | Submit human correction for an extraction field |
| `/dm/core/documents/{id}/status` | PATCH | Update document status (operator actions) |
| `/dm/core/search` | POST | Semantic vector search across all indexed documents |
| `/dm/core/stats` | GET | Dashboard KPI summary (status counts, today's total, avg confidence) |

### Pipeline Routes — `/dm/flux/`

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/dm/flux/push` | POST | Upload file to processing pipeline (`multipart/form-data`) |
| `/dm/flux/queue` | GET | View queued, processing, failed jobs |
| `/dm/flux/job/{id}` | GET | Poll specific job status and progress |
| `/dm/flux/job/{id}/retry` | POST | Re-queue a failed job |
| `/dm/flux/job/{id}` | DELETE | Cancel and remove a queued job |

### LLM Routes — `/dm/mind/`

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/dm/mind/status` | GET | Loaded model name, VRAM usage, inference latency |
| `/dm/mind/models` | GET | List all locally available pinned models |
| `/dm/mind/infer` | POST | Direct inference for advanced integrations |

### Bridge Routes — `/dm/bridge/`

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/dm/bridge/connectors` | GET | List all connectors with enabled/disabled state |
| `/dm/bridge/connectors/{name}` | PATCH | Enable, disable, or update a connector |
| `/dm/bridge/connectors/{name}/test` | POST | Test connector connectivity |
| `/dm/bridge/connectors/{name}/sync` | POST | Trigger manual sync |

### Sentinel Routes — `/dm/sentinel/`

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/dm/sentinel/health` | GET | **No auth required.** Overall health status + component breakdown |
| `/dm/sentinel/diagnostics` | POST | Run full diagnostic suite |
| `/dm/sentinel/logs` | GET | Recent structured log entries |
| `/dm/sentinel/logs/stream` | WS | Live log streaming WebSocket |

### Vault Routes — `/dm/vault/`

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/dm/vault/auth/login` | POST | **No auth required.** Returns JWT on valid credentials |
| `/dm/vault/auth/logout` | POST | Invalidate current token |
| `/dm/vault/settings` | GET | Read all system config values |
| `/dm/vault/settings` | PATCH | Update one or more config values |
| `/dm/vault/operators` | GET | List operator accounts |
| `/dm/vault/operators` | POST | Create new operator |
| `/dm/vault/operators/{id}` | PATCH | Update operator (role, active status, password) |
| `/dm/vault/license` | GET | Current license state and fingerprint |
| `/dm/vault/license/activate` | POST | Activate license from key file |

### Insights Routes — `/dm/insights/` (v1.1 only)

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/dm/insights/overview` | GET | Summary metrics: document volume, entity counts, anomaly count |
| `/dm/insights/trends` | GET | Time-bucketed volume metrics (`bucket_size`: hour/day/week/month) |
| `/dm/insights/entities` | GET | Entity list with relationship counts |
| `/dm/insights/entities/{id}` | GET | Single entity detail with linked documents |
| `/dm/insights/anomalies` | GET | Anomaly list with severity filter |
| `/dm/insights/anomalies/{id}/acknowledge` | POST | Acknowledge an anomaly |
| `/dm/insights/query` | POST | Natural language query → structured result |
| `/dm/insights/reports` | GET | List generated reports |
| `/dm/insights/reports` | POST | Generate report on-demand |
| `/dm/insights/reports/{id}/download` | GET | Download report file (PDF/CSV/XLSX) |

---

## Section 4 — Master Operator Workflow

The complete lifecycle of every document through the system:

1. **Ingest** → Document enters via SFTP watcher, API push, drag-and-drop, or filesystem drop. SHA-256 computed for deduplication. Job record created in `dm_flux.jobs`, pushed to Redis.
2. **Pre-process** → Image deskewed, denoised, binarized. Document type classified (invoice, deed, form, handwritten). Routed to appropriate OCR engine.
3. **OCR** → Selected engine processes each page. Per-word bounding boxes and confidence scores generated. Multi-engine fallback if primary confidence < 75%.
4. **Extract** → OCR text passed to LLM with schema-driven prompt. JSON output validated against schema before writing to `dm_core.extractions`. Fields below 0.80 flagged for review.
5. **Review** → Documents with confidence below threshold (default 85%) shown as "Needs Review" (orange dot). Operator corrects fields in Document Detail Modal and saves.
6. **Complete** → Operator marks reviewed, or system auto-completes if all fields exceed threshold. Status → `complete`. Webhook fires if configured.
7. **Export** → Operator exports as JSON, CSV, or PDF. Outbound webhook delivers JSON. BI direct connect via read-only PostgreSQL port for Power BI/Metabase.

---

## Section 5 — Ingest Channel Reference

| Channel | How Documents Arrive | Config Key | Phase |
|---------|---------------------|-----------|-------|
| Filesystem Drop | Files placed in `/opt/docmaster/ingest/drop/` | Built-in | Phase 1 |
| SMB Network Scan | Scanner deposits to Samba share; `scanuser` writes to `ingest/` | `smb_enabled` | Phase 1 |
| Direct API Push | `POST /dm/flux/push` with `multipart/form-data` | Built-in | Phase 4 |
| Email Ingest | Postfix receives email; attachments extracted to `ingest/email/` | `smtp_enabled` | Phase 4 |
| Fax | HylaFAX receives fax; PDFs written to `ingest/fax/` | `fax_enabled` | Phase 4 |
| Google Drive | `dm-bridge.service` polls Drive API with stored OAuth token | `google_drive_enabled` | Phase 4 |
| OneDrive | `dm-bridge.service` polls OneDrive with OAuth token | `onedrive_enabled` | Phase 4 |
| Dropbox | `dm-bridge.service` polls Dropbox API | `dropbox_enabled` | Phase 4 |
| SFTP | `dm-bridge.service` polls SFTP path | `sftp_enabled` | Phase 4 |
| Webhook | External system pushes file via webhook | `webhook_enabled` | Phase 4 |

---

## Section 6 — Document Status State Machine

Every status transition is an explicit, documented action:

```
(none) → queued       POST /dm/flux/push
queued → processing   Internal (dm-ocr-worker picks up job)
processing → complete Internal (confidence >= threshold on all fields)
processing → review   Internal (confidence < threshold on any required field)
processing → failed   Internal (OCR/extraction error after max retries)
review → complete     PATCH /dm/core/documents/{id}/status (operator)
failed → queued       POST /dm/flux/job/{id}/retry
complete → review     POST /dm/flux/jobs {document_id} (operator re-process)
any → archived        DELETE /dm/core/documents/{id} (admin soft delete)
```

---

## Section 7 — Security Model

- **No root processes.** All services run as `dmuser` (no shell, no sudo)
- **Localhost-only services.** PostgreSQL: `127.0.0.1:5432`. Redis: `127.0.0.1:6379`. Ollama: `127.0.0.1:11434`. Never exposed to network.
- **UFW defaults:** deny all inbound. Only SSH (admin IP range), port 8443 (LAN), ICMP allowed.
- **Session tokens:** JWT, RS256, memory-only (never localStorage)
- **Passwords:** bcrypt cost factor 12. No plain-text storage anywhere.
- **Config encryption:** AES-256-GCM with hardware-derived key. Nonce per encryption. GCM auth tag detects tampering.
- **License signing:** RSA-4096 JWT. Vendor private key never distributed. Public key compiled into `dm-vault.service` binary.
- **Backup encryption:** GPG symmetric with hardware-derived passphrase. Recovery via Shamir's Secret Sharing (3-of-5).
- **AppArmor profiles:** Enforcing for `dm-core`, `dm-flux`, `dm-ocr-worker`.
- **Audit log:** `dm_flux.audit_log` — append-only, never updated or deleted.

---

## Section 8 — Configuration Keys Reference

Key settings in `dm_vault.system_config` (partial — see Phase 2 for full 39-key seed):

| Key | Default | Encrypted | Description |
|-----|---------|-----------|-------------|
| `confidence_threshold` | `85` | No | Documents below this % require review |
| `review_threshold` | `75` | No | Field confidence below which review is triggered |
| `ocr_fallback_threshold` | `75` | No | OCR confidence below which fallback engine runs |
| `max_retry_attempts` | `3` | No | Max retries before marking failed |
| `llm_primary_model` | `llama3.1:8b-q4_K_M` | No | Primary Ollama extraction model |
| `llm_use_external_api` | `false` | No | Allow Claude API for high-priority jobs |
| `claude_api_key` | `` | **Yes** | Encrypted Claude API key |
| `setup_complete` | `false` | No | Set to `true` after first-boot wizard |
| `rasterization_dpi` | `300` | No | PDF rasterization DPI |
| `chunk_size_tokens` | `512` | No | Embedding chunk size |
| `backup_retention_days` | `7` | No | Days to retain daily backups |

---

## Section 9 — Build Checklist Summary (Phase Gates)

The AI builder must not proceed to the next phase without all gate criteria met.

**Phase 1 gate:** Hostname `docmaster-node-01`, UTC timezone, key-only SSH, UFW active, `dmuser` system user, symlink `/opt/docmaster → /opt/docmaster-blue/`, all 14 subdirectories with correct permissions, all packages installed and version-confirmed, Ollama test inference succeeds as `dmuser`, `manifest.lock` complete.

**Phase 2 gate:** All four schemas exist with correct grants, all 12 tables defined with correct column types, all 39 system_config seed rows inserted, Redis `PONG` with auth, Python venv with all packages importable, Alembic at `head` revision, `dm-init-db.sh` idempotent.

**Phase 3 gate:** Pre-processing converts a 3-page test PDF to 3 PNG files at 300 DPI, ONNX classifier loads and classifies a test image, Tesseract 5 processes a test image and returns confidence scores, PaddleOCR uses local model paths (no internet), LLM extraction returns valid JSON matching a schema, vector embeddings inserted to `dm_core.embeddings`, end-to-end pipeline runs on a test document from `queued` to `complete`.

**Phase 4 gate:** `dm-install.sh` runs idempotently on clean Debian 12/Ubuntu 24.04, Packer dry-run completes without error, all `dm-*.service` units start/stop cleanly, Blue/Green symlink swap tested and rolls back correctly on simulated failure.

**Phase 5 gate (v1.1):** `dm-insights.service` starts without error, `dm_analytics`/`dm_graph`/`dm_reports` schemas exist, Insights Indexer processes 10 test documents and populates `index_state`, NL Query returns results for a test query, report generation produces a valid PDF.

**Phase 6 gate:** First-boot wizard completes without error and sets `setup_complete=true`, license.key file activates successfully, hardware fingerprint displays in Settings → License.

**Phase 7 gate:** All 8 UI routes render without console errors, Document Detail Modal opens and shows extracted fields, Save Corrections writes to `dm_core.extractions`, WebSocket live queue updates visible in Queue page.

**Phase 8 gate:** ISO boots on target hardware and shows first-boot wizard, `sha256sum` of ISO matches published checksum, Blue/Green update package applies and rolls back correctly, all 20 QA matrix test cases pass.

---

## Section 10 — Common Implementation Pitfalls

1. **Never auto-download OCR models at runtime.** PaddleOCR and Kraken will attempt internet downloads if not given explicit local model paths. This breaks air-gapped deployments silently.
2. **Never use `exit` or `exit 1` in provisioner scripts without explicit approval.** Scripts must be idempotent and end gracefully.
3. **Never store JWT tokens in localStorage.** Memory only. A 401 triggers re-auth prompt.
4. **Never reference `/opt/docmaster-blue/` or `/opt/docmaster-green/` directly.** Always use `/opt/docmaster/` (the symlink).
5. **Never use `WidthType.PERCENTAGE` in docx generation.** Always `WidthType.DXA`.
6. **Never create tables outside the four defined schemas.** Any new table must be in `dm_core`, `dm_flux`, `dm_sentinel`, or `dm_vault`.
7. **Never expose PostgreSQL, Redis, or Ollama ports to the network.** These are localhost-only services, enforced by both bind configuration and UFW.
8. **IVFFlat index cannot be built on an empty table.** The sentinel cron monitors row count and builds the index only after ≥3,900 embeddings exist.
9. **`temperature: 0.0` on all LLM extraction calls is mandatory.** Any non-zero temperature produces non-deterministic extraction, breaking the audit trail requirement.
10. **`format: "json"` on all Ollama extraction calls is mandatory.** Without it, responses may contain markdown fences that break JSON parsing in edge cases.

---

*DocMaster AI Builder Implementation Brief — Synthesized from 10 source documents*  
*Revision 1.0 — Confidential — Internal Engineering Use Only*  
*Cross-references: Phase1 Blueprint · Phase2 Blueprint · Phase3 Blueprint · Phase4 Build Exec · Phase5 Insights · Phase6 GoLive · Phase6 Licensing · Phase7 UI Layer · Phase8 Packaging · UI/Workflow API Spec*
