# DocMaster — AI Builder Rules
## Authoritative constraints for every Claude Code session working on this codebase

This file is read automatically by Claude Code at session start. Every rule here is derived from
`DocMaster/DocMaster_AI_Builder_Implementation_Brief.md`, which is the single source of truth.
**Nothing contradicts the brief without explicit human approval.**

---

## Hard Rules — No Exceptions

| Rule | Value |
|------|-------|
| Product name | **DocMaster** — never "DM App", "Nexus", or any generic name |
| API namespace | **`/dm/`** — never `/api/`, never `/v1/` |
| System user | **`dmuser`** — never `root`, `www-data`, or `docmaster` |
| Group | **`docgroup`** |
| Install path | **`/opt/docmaster/`** (symlink) — never reference `-blue` or `-green` directly |
| Service names | **`dm-*.service`** pattern — `dm-core`, `dm-flux`, `dm-mind`, `dm-bridge`, `dm-sentinel`, `dm-vault` |
| Database name | **`dm_vault`** |
| DB schemas | **`dm_core`, `dm_flux`, `dm_sentinel`, `dm_vault`** — never create tables outside these |
| Config file | **`/opt/docmaster/config/dm.env`** with `600` permissions |
| Error codes | **`DM_` prefix** (e.g. `DM_4021`, `DM_5001`) — never expose raw stack traces to UI/API |
| Timestamps | **UTC everywhere** — database, logs, API responses, JWT claims |
| Primary keys | **UUIDs** for all core tables; BIGSERIAL only for audit/health snapshot tables |
| Passwords | **bcrypt cost factor 12** — no MD5, no SHA-1 |
| JWT algorithm | **RS256** |
| LLM temperature | **`0.0`** — always. Non-negotiable for audit trail integrity |
| LLM format | **`"format": "json"`** on all Ollama extraction calls — always |
| No internet at runtime | All packages, models, and binaries must be **vendored** |
| Enum values | Fixed — see Section 2 below. Must match DB enum AND CSS class names exactly |

---

## Section 1 — Repository Structure

```
/home/user/DocMasterAI/
├── CLAUDE.md              ← THIS FILE — read first every session
├── README.md              ← Project status and phase tracker
├── Makefile               ← Single build entry point
├── .gitignore
├── DocMaster/             ← Specification documents (read-only reference)
├── core/                  ← dm-core: FastAPI application source
│   ├── app/               ← Application package
│   ├── alembic/           ← DB migrations
│   ├── schemas/           ← Document type extraction schemas (JSON)
│   └── requirements.txt
├── flux/                  ← dm-flux: OCR pipeline worker
├── scripts/               ← Management scripts (dm-update.sh, dm-backup.sh, etc.)
├── systemd/               ← systemd unit file templates
├── sql/                   ← Raw SQL for schema setup (ground truth for Alembic)
├── config/                ← Configuration templates
│   └── dm.env.template
└── www/                   ← React 18 UI source (compiled to /opt/docmaster/www/)
```

---

## Section 2 — Fixed Enum Values

These are stored verbatim in the database AND used as CSS class names. Never alter.

**document_type:** `deed` | `invoice` | `form` | `handwritten` | `table` | `mixed` | `unknown`

**document_status:** `queued` | `processing` | `complete` | `review` | `failed`

**ingest_channel:** `filesystem` | `smb` | `api` | `email` | `fax` | `google_drive` | `onedrive` | `dropbox` | `sftp` | `webhook`

**event_type:** `ingested` | `queued` | `processing_started` | `ocr_complete` | `extraction_complete` | `flagged_for_review` | `correction_saved` | `marked_complete` | `failed` | `retried` | `exported`

**operator_role:** `admin` | `operator` | `reviewer` | `readonly`

---

## Section 3 — API Route Reference (Summary)

All routes require `Authorization: Bearer {jwt}` **except**:
- `GET /dm/sentinel/health`
- `POST /dm/vault/auth/login`

All responses include headers: `X-DM-Build`, `X-DM-Node`, `X-DM-Version`

| Domain | Base Path | Service |
|--------|-----------|---------|
| Documents | `/dm/core/` | dm-core |
| Pipeline / Jobs | `/dm/flux/` | dm-core → dm-flux |
| LLM / Inference | `/dm/mind/` | dm-mind |
| Connectors | `/dm/bridge/` | dm-bridge |
| Health / Monitoring | `/dm/sentinel/` | dm-sentinel |
| Auth / Config / Users | `/dm/vault/` | dm-vault |
| Insights (v1.1) | `/dm/insights/` | dm-insights |

---

## Section 4 — Service Architecture

| Service | Port | Depends On |
|---------|------|-----------|
| `dm-core.service` | 8443 | postgres, redis |
| `dm-flux.service` | — | redis, dm-core |
| `dm-mind.service` | 11434 | ollama.service |
| `dm-bridge.service` | — | dm-core |
| `dm-sentinel.service` | — | all |
| `dm-vault.service` | — | none |
| `dm-insights.service` | 8444 | postgresql, dm-core (v1.1 only) |

All services run as `dmuser:docgroup`. All use `EnvironmentFile=/opt/docmaster/config/dm.env`.

---

## Section 5 — Database Schema (Key Tables)

All in `dm_core` schema unless noted:

- `dm_core.documents` — central document record, UUID PK
- `dm_core.extractions` — per-field extracted data, UUID PK
- `dm_core.document_events` — activity timeline, UUID PK
- `dm_core.embeddings` — 768-dim vector chunks, UUID PK
- `dm_flux.jobs` — persistent job queue, UUID PK
- `dm_flux.audit_log` — append-only log, BIGSERIAL PK
- `dm_sentinel.health_snapshots` — health state log, BIGSERIAL PK
- `dm_vault.operators` — user accounts, UUID PK
- `dm_vault.system_config` — key-value settings, TEXT PK
- `dm_vault.license_records` — license state, BIGSERIAL PK
- `dm_vault.connector_configs` — connector settings, TEXT PK

---

## Section 6 — OCR Pipeline Stages

1. **Pre-Processing** — normalize to PNG at 300 DPI, orient, deskew, denoise, binarize (Sauvola)
2. **Classification** — ONNX MobileNetV3-Small at `/opt/docmaster/models/classifier/doc_classifier_v1.onnx`
3. **OCR Execution** — Tesseract 5 → PaddleOCR → Kraken → olmOCR (Qwen2.5-VL via Ollama)
4. **LLM Extraction** — `llama3.1:8b-q4_K_M` via Ollama, `temperature: 0.0`, `format: "json"`
5. **Vector Indexing** — `nomic-embed-text` → 768-dim vectors → `dm_core.embeddings`

---

## Section 7 — Phase Status

| Phase | Title | Status |
|-------|-------|--------|
| 1 | OS Foundation & Environment Hardening | 🔲 Not Started |
| 2 | Database, Queue & Storage Layer | 🔲 Not Started |
| 3 | OCR Pipeline | 🔲 Not Started |
| 4 | Build Execution & Installer Architecture | 🔲 Not Started |
| 5 | Insights Engine (v1.1) | 🔲 Not Started |
| 6 | Go-Live & Operational Readiness | 🔲 Not Started |
| 7 | UI Layer | 🔲 Not Started |
| 8 | Appliance Packaging & Delivery | 🔲 Not Started |

---

## Section 8 — Common Pitfalls (Do Not Repeat)

1. **Never auto-download OCR models at runtime** — PaddleOCR and Kraken will silently attempt downloads without explicit local model paths
2. **Never use `exit` in provisioner scripts** without explicit approval — scripts must be idempotent
3. **Never store JWT tokens in localStorage** — memory only; 401 triggers re-auth prompt
4. **Never reference `/opt/docmaster-blue/` or `/opt/docmaster-green/` directly** — always use the symlink
5. **Never use `WidthType.PERCENTAGE` in docx generation** — always `WidthType.DXA`
6. **Never create tables outside the four defined schemas**
7. **Never expose PostgreSQL (5432), Redis (6379), or Ollama (11434) ports to the network**
8. **IVFFlat index requires ≥3,900 embeddings** — sentinel cron builds it, never build manually on empty table
9. **`temperature: 0.0` is mandatory on all LLM extraction calls**
10. **`format: "json"` is mandatory on all Ollama extraction calls**

---

## Section 9 — Python Stack (Pinned Versions)

All packages must be installed from vendored sources. No `pip install` from PyPI at runtime.

Key pinned versions (full list in `core/requirements.txt`):
```
fastapi==0.109.0
uvicorn[standard]==0.27.0
asyncpg==0.29.0
SQLAlchemy==2.0.23
alembic==1.13.0
pydantic==2.6.0
passlib[bcrypt]==1.7.4
python-jose[cryptography]==3.3.0
paddleocr==2.7.3
kraken==4.3.13
onnxruntime==1.17.0
```

---

## Section 10 — UI Design Tokens (Exact Values)

```css
--color-bg-primary: #f8fafc;
--color-bg-secondary: #ffffff;
--color-bg-dark: #1e293b;
--color-text-primary: #0f172a;
--color-accent: #38bdf8;
--color-success: #10b981;
--color-warning: #f59e0b;
--color-error: #ef4444;
--color-processing: #3b82f6;
--color-border: #e2e8f0;
```

Sidebar: 240px fixed width. Top bar: 56px. Content padding: 32px. All spacing in multiples of 8px.
System font stack only — zero external font loading.

---

*This file is maintained as the living AI builder contract for DocMaster.*
*Regenerate or update this file whenever the master brief is revised.*
*Spec source: `DocMaster/DocMaster_AI_Builder_Implementation_Brief.md`*
