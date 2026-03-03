# DocMaster — Document Intelligence Appliance

**Version:** v1.0 (development)
**Classification:** Confidential — Internal Engineering Use Only
**Branch strategy:** All AI-assisted development on `claude/*` branches → PR to `main`

DocMaster is a closed-source, air-gapped, self-hosted Document Intelligence Appliance. It converts physical and digital documents into structured, queryable data using a cascaded OCR engine stack and a local LLM extraction layer. Designed for deployment in developing nations and infrastructure-limited environments where cloud connectivity cannot be assumed.

---

## Phase Status Tracker

| Phase | Title | Status | Gate Passed |
|-------|-------|--------|-------------|
| **1** | OS Foundation & Environment Hardening | 🔲 Not Started | — |
| **2** | Database, Queue & Storage Layer | 🔲 Not Started | — |
| **3** | OCR Pipeline | 🔲 Not Started | — |
| **4** | Build Execution & Installer Architecture | 🔲 Not Started | — |
| **5** | Insights Engine (v1.1) | 🔲 Not Started | — |
| **6** | Go-Live & Operational Readiness | 🔲 Not Started | — |
| **7** | UI Layer | 🔲 Not Started | — |
| **8** | Appliance Packaging & Delivery | 🔲 Not Started | — |

---

## Repository Structure

```
DocMasterAI/
├── CLAUDE.md              # AI builder rules — read before writing any code
├── README.md              # This file
├── Makefile               # Build pipeline (make build VERSION=1.0.0 METHOD=iso|lxc|installer|docker|all)
├── .gitignore
│
├── DocMaster/             # Specification documents (authoritative reference — do not modify)
│   ├── DocMaster_AI_Builder_Implementation_Brief.md
│   ├── DocMaster_Phase1_Blueprint.md
│   ├── DocMaster_Phase2_Blueprint.md
│   ├── DocMaster_Phase3_Blueprint.md
│   ├── DocMaster_UI_Mockup.html
│   └── *.docx             # Phase 4–8 specs
│
├── core/                  # dm-core: FastAPI REST + WebSocket API server (port 8443)
│   ├── app/
│   │   ├── main.py        # FastAPI application entry point
│   │   ├── config.py      # Settings from dm.env
│   │   ├── database.py    # asyncpg connection pool
│   │   ├── dependencies.py # JWT auth, DB session injection
│   │   ├── middleware.py  # X-DM-Build/Node/Version headers, error handling
│   │   ├── models/        # SQLAlchemy ORM models
│   │   └── routers/       # Route handlers per API domain
│   │       ├── core.py    # /dm/core/ — documents, extractions, search
│   │       ├── flux.py    # /dm/flux/ — job queue management
│   │       ├── mind.py    # /dm/mind/ — LLM status and inference
│   │       ├── bridge.py  # /dm/bridge/ — connector management
│   │       ├── sentinel.py # /dm/sentinel/ — health and diagnostics
│   │       └── vault.py   # /dm/vault/ — auth, operators, settings, license
│   ├── alembic/           # Database migration scripts
│   │   ├── alembic.ini
│   │   └── versions/
│   ├── schemas/           # Document type extraction schemas (JSON)
│   │   ├── deed.json
│   │   ├── invoice.json
│   │   ├── form.json
│   │   ├── handwritten.json
│   │   └── unknown.json
│   └── requirements.txt   # All Python deps pinned with ==
│
├── flux/                  # dm-flux: File watcher + OCR pipeline worker
│   ├── worker.py          # Main BLPOP consumer loop
│   ├── pipeline/
│   │   ├── preprocess.py  # Stage 1: normalize, orient, deskew, denoise, binarize
│   │   ├── classify.py    # Stage 2: ONNX MobileNetV3-Small classifier
│   │   ├── ocr.py         # Stage 3: Tesseract/Paddle/Kraken/olmOCR routing
│   │   ├── extract.py     # Stage 4: LLM field extraction via Ollama
│   │   └── embed.py       # Stage 5: nomic-embed-text vector indexing
│   └── watcher.py         # inotify filesystem drop zone watcher
│
├── sql/                   # Raw SQL (ground truth for Alembic migrations)
│   ├── 01_extensions.sql  # vector, pg_trgm, unaccent
│   ├── 02_schemas.sql     # dm_core, dm_flux, dm_sentinel, dm_vault
│   ├── 03_enums.sql       # document_type, document_status, etc.
│   ├── 04_tables.sql      # All 12 core tables
│   ├── 05_indexes.sql     # All production indexes
│   ├── 06_views.sql       # document_status_counts, daily_summary
│   └── 07_seed_config.sql # 39 system_config seed rows + connector_configs
│
├── systemd/               # systemd unit file templates
│   ├── dm-core.service
│   ├── dm-flux.service
│   ├── dm-mind.service
│   ├── dm-bridge.service
│   ├── dm-sentinel.service
│   └── dm-vault.service
│
├── config/                # Configuration templates
│   ├── dm.env.template    # All environment variables (NO secrets here)
│   └── redis.conf         # Redis configuration template
│
├── scripts/               # Operational scripts deployed to /opt/docmaster/bin/
│   ├── dm-install.sh      # Phase 4 installer (Methods B and C)
│   ├── dm-update.sh       # Blue/Green update orchestrator
│   ├── dm-backup.sh       # Nightly encrypted DB backup
│   ├── dm-init-db.sh      # Idempotent DB initialization (Phase 2 gate)
│   └── wait-for-ollama.sh # Ollama startup health gate
│
└── www/                   # React 18 UI (compiled to /opt/docmaster/www/)
    ├── package.json
    ├── vite.config.js
    └── src/
        ├── main.jsx
        ├── App.jsx
        ├── styles/
        │   └── tokens.css  # CSS custom property design tokens
        └── pages/
            ├── Dashboard.jsx
            ├── Documents.jsx
            ├── Queue.jsx
            ├── Search.jsx
            ├── Integrations.jsx
            ├── Health.jsx
            └── Settings.jsx
```

---

## Quick Reference

### Key Constraints
- **System user:** `dmuser` (no shell, no sudo)
- **API port:** `8443` (TLS)
- **API namespace:** `/dm/` only — never `/api/` or `/v1/`
- **DB name:** `dm_vault` with schemas `dm_core`, `dm_flux`, `dm_sentinel`, `dm_vault`
- **Config:** `/opt/docmaster/config/dm.env` (mode 600)
- **No internet at runtime** — fully air-gapped

### Build Commands
```bash
make build VERSION=1.0.0 METHOD=iso        # Bootable ISO (~8-12 GB)
make build VERSION=1.0.0 METHOD=lxc        # LXC container template
make build VERSION=1.0.0 METHOD=installer  # Bash installer + bundle
make build VERSION=1.0.0 METHOD=docker     # Docker Compose (dev/pilot)
make build VERSION=1.0.0 METHOD=all        # All delivery formats
make schema                                 # Apply SQL schema to local dev DB
make lint                                  # Run all linters
make test                                  # Run test suite
```

### Service Management (on deployed appliance)
```bash
systemctl status dm-core dm-flux dm-mind dm-sentinel dm-vault dm-bridge
journalctl -u dm-core -f
/opt/docmaster/bin/dm-update.sh 1.0.1      # Blue/Green update
/opt/docmaster/bin/dm-backup.sh            # Manual backup
```

---

## Delivery Formats

| Method | Format | Size | Use Case |
|--------|--------|------|----------|
| A — ISO | Bootable USB image | ~8-12 GB | Air-gapped bare metal |
| B — LXC | `.tar.zst` container template | ~6-9 GB | Proxmox environments |
| C — Installer | `dm-install.sh` + offline bundle | ~500 MB | Existing Debian/Ubuntu servers |
| D — Docker | Docker Compose bundle | Variable | Development and pilots |

---

## Specification Documents

All specification documents are in `DocMaster/`. These are the authoritative reference.
Do not modify spec documents — raise a PR with proposed changes for human review.

| Document | Phase | Format |
|----------|-------|--------|
| `DocMaster_AI_Builder_Implementation_Brief.md` | All | Markdown |
| `DocMaster_Phase1_Blueprint.md` | Phase 1 | Markdown |
| `DocMaster_Phase2_Blueprint.md` | Phase 2 | Markdown |
| `DocMaster_Phase3_Blueprint.md` | Phase 3 | Markdown |
| `DocMaster_Phase4_Build_Execution_Spec.docx` | Phase 4 | Word |
| `DocMaster_Phase5_Insights_Engine_Spec.docx` | Phase 5 | Word |
| `DocMaster_Phase6_GoLive_Operational_Readiness.docx` | Phase 6 | Word |
| `DocMaster_Phase6_Licensing_Engine.docx` | Phase 6 | Word |
| `DocMaster_Phase7_UI_Layer_Specification.docx` | Phase 7 | Word |
| `DocMaster_Phase8_Packaging_Delivery_Spec.docx` | Phase 8 | Word |
| `DocMaster_UI_Workflow_API_Specification.docx` | Phase 7 | Word |
| `DocMaster_UI_Mockup.html` | Phase 7 | HTML prototype |

---

*DocMaster v1.0 — Internal Engineering Reference*
