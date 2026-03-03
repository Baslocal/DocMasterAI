# DocMaster — Phase 3 Blueprint
## OCR Pipeline — Pre-Processing, Classification, Extraction & Indexing

**Classification:** Confidential — Internal Engineering Reference  
**Phase:** 3 of 8  
**Complexity:** Hard  
**Prerequisite:** Phase 1 and Phase 2 complete and all validation items confirmed  
**Outcome:** A fully operational OCR pipeline capable of receiving a raw document file and producing structured, field-level extracted data with per-field confidence scores, stored in the Phase 2 schema and indexed for semantic search

---

## Project-Level Note: Installation Methods (Formally Recorded Here)

This note is being recorded at Phase 3 because this is the first phase where the distinction between delivery methods becomes a design constraint on how pipeline components are packaged and vendored. The installation method decision affects every subsequent phase.

**DocMaster supports three installation methods. All three are first-class delivery targets.**

### Method A — Bootable ISO Image

A Packer-built ISO that boots directly into a pre-provisioned DocMaster environment. The customer burns this to a USB drive, boots their server from it, and the first-boot wizard launches automatically in the browser. No internet connection is required after burning the image.

- All dependencies, model weights, and binaries are embedded in the image at build time
- Phases 1 through 7 are pre-applied by the Packer build pipeline
- The customer never manually executes installation steps
- Updates are delivered as signed patch archives or new ISO images pushed to an air-gap transfer device
- Primary delivery target for air-gapped and low-infrastructure deployments

### Method B — LXC Container Template

A Proxmox/LXC-compatible container template (`.tar.zst`) for customers running a hypervisor. The customer imports the template, creates a container, and the first-boot wizard launches. Content is identical to the ISO — same phases applied, same model weights, same binary stack.

- Suited for government or NGO environments where Proxmox is already the standard hypervisor platform
- Hardware fingerprint is derived from stable virtual machine identifiers: VM UUID, virtual disk serial, virtual NIC MAC address
- License binding works identically to physical hardware — the fingerprint is stable as long as the VM is not cloned to a different host

### Method C — Installer Script

A single shell script (`dm-install.sh`) that runs on a fresh Debian 12 or Ubuntu 24.04 LTS minimal installation. The script performs all Phase 1 and Phase 2 steps programmatically, installs all pipeline components from a local bundle, and seeds the database.

- Fully automated after initial configuration confirmation — no interactive prompts during execution
- All Phase 1 and Phase 2 validation checks run inline during the script
- The script is idempotent — safe to re-run if it fails partway through
- Internet connectivity is required during installation unless a local mirror is configured
- The script detects the OS at startup and refuses to proceed on unsupported distributions
- Useful for customers who already manage a server and do not want a full image deployment

**Design constraint for Phase 3 and all subsequent phases:** Every pipeline component — every Python package, every OCR model weight file, every system library, every ONNX classifier model — must be installable by the script from a local bundle and must be fully present in the ISO and LXC image with no runtime internet calls. The script and the image are built from the same source manifest. They are not separate codebases. Any component that makes an internet call at runtime is a build defect, not a feature.

---

## Overview

Phase 3 is the intellectual core of DocMaster. Everything in Phase 1 and Phase 2 exists to support what happens here — taking a raw document file and producing structured, field-level, confidence-scored machine-readable data. This phase defines the complete pipeline from the moment a file is dequeued to the moment extracted fields and vector embeddings are committed to the database.

The pipeline consists of five sequential stages that run in the `dm-ocr-worker` process managed by `dm-flux.service`:

1. **Pre-Processing** — normalize the raw document into clean, consistent images the OCR engines can process reliably
2. **Document Classification** — determine the document type to select the correct extraction schema and engine routing
3. **OCR Execution** — extract raw text using the appropriate engine with confidence-scored fallback logic
4. **LLM Extraction** — parse OCR output into structured named fields using the local Ollama LLM
5. **Vector Indexing** — embed document text and store for semantic search

---

## Architecture: The Worker Model

### Worker Process Design

The OCR worker is a long-running Python process that:

1. At startup, initializes connection pools to Redis and PostgreSQL, loads all document type schemas from `/opt/docmaster/core/schemas/`, and loads the ONNX classifier model into memory
2. Enters a blocking loop using Redis `BLPOP` against the three priority queues in order: `dm:queue:high`, `dm:queue:normal`, `dm:queue:low`
3. When a job is received, deserializes the JSON payload and executes the five-stage pipeline
4. On completion or failure, writes results to the database and returns to the blocking loop
5. Pings the systemd watchdog (`sd_notify WATCHDOG=1`) every 25 seconds. If the watchdog is not pinged within the 30-second `WatchdogSec` window, systemd kills and restarts the worker

### Concurrency Model

**CPU-only deployment:** One worker process. The local LLM runs single-threaded on CPU. A second worker would compete for the same Ollama instance, causing queued inference requests that degrade throughput rather than improving it.

**GPU deployment with sufficient VRAM:** Two worker processes, with `OLLAMA_NUM_PARALLEL=2` in the environment. Ollama can serve two concurrent inference requests on GPU. The second worker picks up the next job from the queue while the first is waiting on inference, improving throughput on batch processing workloads.

The number of workers is controlled by `DM_WORKER_COUNT` in `/opt/docmaster/vault/.env`. Default is `1`. The systemd unit file reads this variable to determine how many worker instances to launch.

### Per-Job Working Directory

Every job gets an isolated working directory at `/opt/docmaster/tmp/{job_id}/`. Created at job start, deleted at job completion. On failure, retained for 24 hours for debugging, then removed by the nightly cleanup cron.

```
/opt/docmaster/tmp/{job_id}/
├── original.{ext}          — copy of the original submitted file
├── pages/                  — one PNG per page after rasterization
│   ├── page_001.png
│   ├── page_002.png
│   └── ...
├── preprocessed/           — deskewed, denoised, binarized images
│   └── page_001.png ...
├── ocr_raw/                — per-page OCR output
│   ├── page_001.txt
│   └── page_001.hocr       — hOCR with word bounding boxes
├── ocr_merged.txt          — all pages concatenated with page markers
├── extraction.json         — raw LLM JSON output before validation
└── job.log                 — structured per-job log
```

---

## Stage 1 — Pre-Processing

### Purpose

Documents arrive in inconsistent states. A 1960s land deed may be skewed 3 degrees with coffee stains and faded ink. A fax arrives as a compressed TIFF with block artifacts. A photographed form may have perspective distortion from the camera angle. Pre-processing normalizes all inputs to clean binary or grayscale images at consistent resolution before OCR. The accuracy improvement from proper pre-processing on degraded documents is 20–30 percentage points.

### Step 1.1 — Format Normalization

Convert all supported input formats to individual per-page PNG images in `pages/`.

**PDF:** Use `pdftoppm` at 300 DPI. This is the minimum resolution for reliable OCR on standard text. Historical or small-print documents may warrant 400 DPI at the cost of larger intermediate files.

```bash
pdftoppm -r 300 -png original.pdf pages/page
# produces: pages/page-001.png, pages/page-002.png, ...
```

**Single-image files (JPEG, PNG, BMP):** Convert to PNG with consistent color space using OpenCV `imread` / `imwrite`. Copy to `pages/page_001.png`.

**Multi-page TIFF (fax):** Use Pillow to split frames. TIFF frames from fax transmissions are often 200 DPI — upsample to 300 DPI using Lanczos resampling before handing to pre-processing.

**HEIC/HEIF (smartphone photographs):** Use `pyheif` to decode. These are increasingly common when field workers photograph paper documents with modern smartphones. After decoding, follow the single-image path.

After this step, count the PNG files in `pages/` and write the count to `dm_core.documents.page_count`. This is the value that powers the "Page 2 of 3" indicator in the document detail modal.

### Step 1.2 — Orientation Detection and Correction

Use Tesseract's OSD (Orientation and Script Detection) module to detect page rotation:

```python
osd_data = pytesseract.image_to_osd(page_image, output_type=Output.DICT)
rotation = osd_data['rotate']  # 0, 90, 180, or 270
```

Apply the inverse rotation with OpenCV `warpAffine` if rotation is non-zero. If OSD confidence falls below 1.5, do not rotate — low confidence typically means the page has very little text content and a spurious rotation would cause more harm than leaving the original orientation.

### Step 1.3 — Deskewing

Correct scanner placement skew of ±1 to ±5 degrees. Even 2-degree skew measurably reduces OCR accuracy because character baselines no longer align with the OCR engine's row detection logic.

Method: Probabilistic Hough Transform on a binary version of the image to detect line angles. The median angle of detected lines represents the document's skew. Apply inverse rotation with `warpAffine`. Gate: only apply if the detected angle is between -10 and +10 degrees. Outside this range, the detected "lines" are likely table borders or form elements rather than text baselines — do not correct.

### Step 1.4 — Denoising

Noise sources differ by document origin:

- Scanner grain and aged paper: Apply OpenCV `fastNlMeansDenoising` with `h=10`. Values above 15 blur character edges and degrade OCR accuracy — do not over-denoise.
- Fax TIFF compression artifacts: Apply mild median blur (`cv2.medianBlur`, kernel size 3) instead — compression artifacts have a different spatial profile than grain.

Do not apply aggressive denoising to historical documents. The low-contrast strokes that denoise removes are precisely what the OCR engine needs to read characters from faded ink.

### Step 1.5 — Binarization

Convert grayscale to binary (black text on white) for OCR. A global threshold fails on documents with uneven illumination or aged yellowed paper. Use **Sauvola's adaptive binarization**:

```python
from skimage.filters import threshold_sauvola
window_size = 25  # must be odd; 25px works well at 300 DPI
thresh = threshold_sauvola(gray_image, window_size=window_size, k=0.2)
binary = gray_image > thresh
```

Sauvola computes a local threshold per pixel based on the local mean and standard deviation — highly effective on aged documents with non-uniform background color.

**Exception:** Do not binarize documents where color is semantically meaningful (government forms with colored sections, stamps, watermarks). The document classifier in Stage 2 sets `use_color_ocr = True` for these — check this flag before binarizing.

### Step 1.6 — New System Packages Required (Phase 1 Amendment)

Add to the Phase 1 installer script and ISO build:
- `libheif-dev` — native library for HEIC decoding by `pyheif`

---

## Stage 2 — Document Classification

### Purpose

Different document types have different field structures. A land deed extracts grantor, grantee, parcel number, registration date. An invoice extracts vendor, total amount, line items, due date. Classification happens before OCR so the pipeline can route to the best engine and apply the correct extraction schema.

### Classifier Architecture

A fine-tuned MobileNetV3-Small convolutional neural network (~2.5M parameters) runs inference on the first page thumbnail in under 100ms on CPU. Image-based classification rather than text-based means engine selection decisions are made before OCR runs — the correct order.

**Why not text-based?** Classifying after OCR requires OCR to run first, defeating the purpose of routing the pipeline based on document type.

**Model format:** ONNX, stored at `/opt/docmaster/models/classifier/doc_classifier_v1.onnx`. ONNX Runtime runs inference without requiring PyTorch or TensorFlow at runtime, reducing the dependency footprint significantly.

**Training data requirements:** Minimum 500 labeled samples per document class. For initial deployment, the target document types are those defined in the `dm_core.document_type` enum: `deed`, `invoice`, `form`, `handwritten`, `mixed`. Training data must be sourced from representative samples in the deployment regions — Caribbean land registries, clinic forms, government certificates. A generic ImageNet-trained classifier will not achieve sufficient accuracy for historical regional document formats.

**Classifier output schema:**

```python
{
    "doc_type": "deed",           # maps to dm_core.document_type enum value
    "confidence": 0.94,           # float 0.0–1.0
    "is_handwritten": False,      # significant handwriting detected on page
    "has_table": True,            # tabular structure detected
    "has_stamp": False,           # stamp or seal elements detected
    "use_color_ocr": False,       # preserve color for OCR pass
    "recommended_engine": "tesseract"
}
```

**Low-confidence fallback:** Classifier confidence below 0.60 → classify as `unknown`, assign `mixed` processing path. Extract full text as a single "content" field. Flag for operator manual classification through the document detail UI.

**Package requirements:**
- `onnxruntime==1.17.0` — CPU build. On GPU deployments, substitute `onnxruntime-gpu==1.17.0` and detect at runtime.

---

## Stage 3 — OCR Execution

### Engine Selection Logic

The pipeline supports four OCR engines. Selection is driven by classifier output.

| Condition | Primary Engine | Fallback Engine |
|-----------|---------------|-----------------|
| Modern printed document | Tesseract 5 | PaddleOCR |
| Primary confidence < `ocr_fallback_threshold` | Tesseract 5 | Kraken |
| `is_handwritten = True` | Kraken | olmOCR (Qwen2.5-VL) |
| Multilingual or non-Latin script | PaddleOCR | Tesseract 5 |
| `has_table = True` | PaddleOCR PP-Structure | Tesseract 5 |

The fallback is reactive, not pre-emptive. The primary engine always runs first. Its output is evaluated for confidence. Only if the mean confidence falls below `ocr_fallback_threshold` (default 75%) does the fallback run on the same pre-processed image.

### Engine 1 — Tesseract 5

Primary engine for most printed document types. The binary was installed in Phase 1. Python access is via `pytesseract`.

```python
custom_config = r'--oem 3 --psm 3'
# oem 3: LSTM + legacy engine combined (highest accuracy)
# psm 3: Fully automatic page segmentation, no OSD
#         OSD was applied in pre-processing Stage 1.2 — do not re-run it here

data = pytesseract.image_to_data(
    preprocessed_image,
    config=custom_config,
    output_type=Output.DICT,
    lang='eng'  # configured per deployment region
)
```

`image_to_data` returns word-level results with per-word confidence scores — critical for field-level confidence calculation in Stage 4.

Request hOCR output as well: `image_to_pdf_or_hocr(preprocessed_image, extension='hocr')`. Store the hOCR in `ocr_raw/page_NNN.hocr`. The bounding boxes in hOCR are used later to highlight field locations on the scanned image in the document detail modal.

**Confidence calculation:** Mean of all `conf` values from `image_to_data()`, excluding entries where `conf == -1` (empty space, detected punctuation).

### Engine 2 — PaddleOCR

Fallback for modern printed documents. Primary engine for table extraction and multilingual text.

**Air-gap requirement:** PaddleOCR downloads model weights on first use by default. This must be disabled. Pre-download all model weights in the build environment and store at `/opt/docmaster/models/paddleocr/`. Initialize PaddleOCR with explicit local model paths:

```python
from paddleocr import PaddleOCR

ocr = PaddleOCR(
    use_angle_cls=True,
    lang='en',
    det_model_dir='/opt/docmaster/models/paddleocr/en/det',
    rec_model_dir='/opt/docmaster/models/paddleocr/en/rec',
    cls_model_dir='/opt/docmaster/models/paddleocr/en/cls',
    show_log=False
)
```

Set environment variable `PADDLE_PDX_CACHE_HOME=/opt/docmaster/models/paddleocr` to prevent any background model update checks.

**PP-Structure for tables:** When `has_table = True`, use the PP-Structure module. It detects table boundaries, extracts the HTML structure with cell-level boundaries, and returns the table as a structured representation rather than flat text. The structured output is passed to Stage 4 with table structure preserved.

```python
from paddleocr import PPStructure

table_engine = PPStructure(
    table=True, ocr=True, show_log=False,
    layout_model_dir='/opt/docmaster/models/paddleocr/layout',
    table_model_dir='/opt/docmaster/models/paddleocr/table'
)
```

### Engine 3 — Kraken

Specialist engine for historical manuscripts and handwritten documents. Designed for the exact use case of pre-modern documents with historical typefaces and non-Latin scripts.

Kraken requires trained recognition models vendored to `/opt/docmaster/models/kraken/`. Generic models are insufficient — purpose-trained models must be sourced from the Kraken model repository for the target document types.

**Models to vendor:**
- `en_best.mlmodel` — PyLaia model for printed historical English text
- `Fraktur_5000000.mlmodel` — German Fraktur typeface (present in colonial-era Caribbean documents)
- `arabic_best.mlmodel` — Arabic script (relevant for MENA regional deployments)

**Usage:**
```python
from kraken import blla, rpred
from kraken.lib import models as kraken_models

model = kraken_models.load_any('/opt/docmaster/models/kraken/en_best.mlmodel')
baseline_seg = blla.segment(preprocessed_image)
records = rpred.rpred(model, preprocessed_image, baseline_seg)
```

Kraken returns word-level output with bounding polygons (not rectangles) — important for curved or wavy text baselines common in handwriting.

### Engine 4 — olmOCR via Qwen2.5-VL

Last-resort engine for documents that defeat all other approaches — severely degraded handwriting, unusual mixed layouts, documents where all other engines produce confidence below 60%.

Rather than maintaining a separate Qwen2.5-VL process, route through the Ollama API using a pre-pulled vision model. This integrates olmOCR into the existing Ollama infrastructure.

```python
response = await httpx.AsyncClient(timeout=180.0).post(
    'http://127.0.0.1:11434/api/generate',
    json={
        'model': 'qwen2.5-vl:7b',
        'prompt': (
            'Transcribe all text exactly as it appears in this scanned document. '
            'Preserve line breaks. Do not interpret or correct. '
            'Output raw transcription only.'
        ),
        'images': [base64_encoded_page_image],
        'stream': False
    }
)
```

**Phase 1 amendment:** Add `qwen2.5-vl:7b` to the Ollama model pre-pull list alongside `llama3.1:8b-q4_K_M` and `nomic-embed-text`. This model is approximately 15 GB. It is mandatory in the ISO image but may be marked optional in constrained deployments via a build flag.

**Confidence assignment:** olmOCR does not return per-word confidence. Assign a fixed score of 0.65 to all olmOCR output — this automatically triggers the `review` status (below the default 75% threshold), ensuring human verification of any document that required the last-resort engine.

### Multi-Page Merging

After OCR completes for all pages, merge per-page text into `ocr_merged.txt` with structured page markers:

```
=== PAGE 1 OF 3 ===

[page 1 text content]

=== PAGE 2 OF 3 ===

[page 2 text content]
```

The LLM receives this merged text. The page markers allow the LLM to record the source page for each extracted field, stored in `dm_core.extractions` metadata.

---

## Stage 4 — LLM Extraction

### Document Type Schemas

Each document type has a JSON schema defining the fields to extract. Schemas are stored as files in `/opt/docmaster/core/schemas/`, loaded at worker startup, and cached in memory. Adding a new document type requires adding a schema file and restarting the worker — no database migration.

**Example schema — `deed.json`:**

```json
{
    "doc_type": "deed",
    "display_name": "Land Registry Deed",
    "fields": [
        {
            "name": "property_address",
            "display_name": "Property Address",
            "type": "text",
            "required": true,
            "description": "Full street address of the property being transferred"
        },
        {
            "name": "owner_name",
            "display_name": "Owner Name",
            "type": "text",
            "required": true,
            "description": "Full legal name of the property owner or grantee"
        },
        {
            "name": "plot_number",
            "display_name": "Plot Number",
            "type": "identifier",
            "required": false,
            "description": "Government-assigned lot or plot identifier",
            "example": "LOT-2024-0342"
        },
        {
            "name": "registration_date",
            "display_name": "Registration Date",
            "type": "date",
            "required": true,
            "description": "Date the deed was officially registered",
            "format": "YYYY-MM-DD"
        },
        {
            "name": "grantor_name",
            "display_name": "Grantor Name",
            "type": "text",
            "required": false,
            "description": "Previous owner who transferred the property"
        },
        {
            "name": "parcel_area",
            "display_name": "Parcel Area",
            "type": "text",
            "required": false,
            "description": "Size of the parcel, e.g., '0.75 acres' or '3,000 sq ft'"
        }
    ]
}
```

Initial schemas required at Phase 3 completion: `deed.json`, `invoice.json`, `form.json`, `handwritten.json`, `unknown.json`. The `handwritten` and `unknown` schemas extract full text as a single "content" field — no structured field extraction.

### Prompt Engineering

The extraction prompt is constructed dynamically from the document schema. Prompt quality directly determines extraction accuracy.

**System prompt (fixed):**

```
You are a precise document data extraction assistant. You extract specific information from OCR-processed documents.

Rules:
1. Extract ONLY information explicitly present in the document text
2. Do NOT invent, infer, or assume values not in the text
3. If a field is not found, set its value to null
4. Return ONLY valid JSON — no preamble, no explanation, no markdown fences
5. Dates must be in YYYY-MM-DD format
6. Preserve exact spelling found in the document for names and addresses
```

**User prompt (dynamic, built from schema):**

```
Extract the following fields from this {doc_type} document:

{field_list_with_descriptions}

Document text (OCR output):
---
{ocr_merged_text}
---

Return a JSON object with this exact structure:
{
    "fields": [
        {
            "name": "field_name_from_schema",
            "value": "extracted value or null",
            "confidence": 0.0 to 1.0,
            "source_page": 1
        }
    ]
}

Confidence scoring guide:
- 0.90–1.00: Value found clearly and unambiguously
- 0.75–0.89: Value found but required minor interpretation
- 0.60–0.74: Value inferred from context
- Below 0.60: Very uncertain — flag for human review
```

### Ollama API Call

```python
async def run_llm_extraction(ocr_text: str, schema: dict) -> dict:
    response = await httpx.AsyncClient(timeout=120.0).post(
        'http://127.0.0.1:11434/api/chat',
        json={
            'model': 'llama3.1:8b-q4_K_M',
            'messages': [
                {'role': 'system', 'content': SYSTEM_PROMPT},
                {'role': 'user', 'content': build_user_prompt(ocr_text, schema)}
            ],
            'format': 'json',    # Ollama JSON mode — guarantees valid JSON output
            'stream': False,
            'options': {
                'temperature': 0.0,   # deterministic — same doc always produces same result
                'num_ctx': 8192       # sufficient for most multi-page documents
            }
        }
    )
    return parse_and_validate_extraction(response.json()['message']['content'], schema)
```

`format: 'json'` is non-negotiable. Without it, a percentage of responses will include markdown fences or natural language preamble that breaks JSON parsing. `temperature: 0.0` ensures two runs of the same document produce identical output, which is required for the audit trail.

### Extraction Validation

Before any database write, validate the LLM output:

1. Confirm valid JSON was returned (edge case catch even with JSON mode)
2. Confirm all schema-required fields are present as keys (value may be null — but the key must exist)
3. Confirm date fields match YYYY-MM-DD format
4. Confirm numeric fields contain only numeric content
5. Confirm confidence values are floats between 0.0 and 1.0

Any validation failure produces a `flagged_for_review` event and routes the document to `review` status. The raw LLM output is preserved in `extraction.json` for debugging.

### Hybrid Routing — Claude API

When `llm_use_external_api = true` and internet connectivity is confirmed by `dm-bridge.service`, high-priority jobs can route to Claude instead of the local Ollama. The same prompt is used. The routing decision:

- `dm:queue:high` + internet available + Claude API key configured → Claude API
- Any other condition → local Ollama

The extraction record's `ocr_engine` field stores `'claude_api'` or `'ollama'` to preserve the audit trail of which model performed the extraction.

### Database Write Transaction

All extraction results are written atomically:

```sql
BEGIN;

UPDATE dm_core.documents SET
    status = '<complete_or_review>',
    confidence_score = <mean_field_confidence>,
    processed_at = NOW()
WHERE id = <document_id>;

INSERT INTO dm_core.extractions
    (document_id, field_name, field_value, field_order, confidence, ocr_engine)
VALUES ... ;

INSERT INTO dm_core.document_events
    (document_id, event_type, duration_ms)
VALUES
    (<doc_id>, 'extraction_complete', <duration_ms>);

-- Conditionally if any field confidence < review_threshold:
INSERT INTO dm_core.document_events (document_id, event_type)
VALUES (<doc_id>, 'flagged_for_review');

COMMIT;
```

**Review status logic:** A document is marked `review` (orange dot in UI) if **any single required field** has confidence below the `review_threshold` setting — not just if the mean is low. A deed where owner name extracts at 62% confidence must be reviewed even if all other fields are at 95%.

---

## Stage 5 — Vector Indexing

### Chunking

Chunk the full OCR text from `ocr_merged.txt` into segments the embedding model can process. `nomic-embed-text` has a 512-token maximum input.

```python
from langchain.text_splitter import RecursiveCharacterTextSplitter
import tiktoken

encoder = tiktoken.get_encoding('cl100k_base')
splitter = RecursiveCharacterTextSplitter(
    chunk_size=512,
    chunk_overlap=64,
    length_function=lambda text: len(encoder.encode(text)),
    separators=['\n\n', '\n', '. ', ' ', '']
)
chunks = splitter.split_text(ocr_merged_text)
```

The 64-token overlap prevents semantic context from being cut across chunk boundaries.

### Embedding Generation

```python
async def embed_chunk(chunk_text: str) -> list[float]:
    response = await httpx.AsyncClient(timeout=30.0).post(
        'http://127.0.0.1:11434/api/embeddings',
        json={'model': 'nomic-embed-text', 'prompt': chunk_text}
    )
    return response.json()['embedding']  # 768-dimensional float list
```

Process chunks sequentially on CPU deployments — concurrent requests to Ollama serialize internally and the HTTP overhead degrades throughput.

### Database Write

```sql
INSERT INTO dm_core.embeddings
    (document_id, chunk_index, chunk_text, embedding)
VALUES ($1, $2, $3, $4)
ON CONFLICT (document_id, chunk_index) DO UPDATE
    SET chunk_text = EXCLUDED.chunk_text,
        embedding = EXCLUDED.embedding;
```

`ON CONFLICT DO UPDATE` handles reprocessing — replaces existing embeddings rather than creating duplicates.

### IVFFlat Index Build Timing

The IVFFlat index defined in Phase 2 requires training data. It cannot be built on an empty table. The Phase 5 sentinel cron checks the embedding row count after each nightly maintenance window. When the count first exceeds 3,900 rows (the minimum needed for `lists = 100`), the index is built. After that, it is rebuilt periodically when the count grows significantly.

---

## Pipeline Error Handling

### Failure Hierarchy

| Condition | Behavior |
|-----------|----------|
| `retry_count < max_retries` | Increment retry count, reset status to `queued`, push to `dm:queue:failed` |
| `retry_count >= max_retries` | Mark job `failed`, write `failed` event, update document status, do not requeue |
| Dead letter | After max retries, move to `dm:queue:deadletter` — visible in Queue UI as "Requires Attention" |

### Per-Stage Error Behavior

| Stage | Common Failure | Error Behavior |
|-------|---------------|----------------|
| Pre-processing | Corrupt or unsupported file | Mark `failed` immediately, no retry — file is unreadable regardless of retry |
| Classification | Model file missing | Classify as `unknown`, continue with generic schema — do not fail the job |
| OCR primary engine | Engine crash or timeout | Attempt fallback engine immediately |
| OCR fallback engine | Fallback also fails | Retry the job. After max retries, mark `failed` |
| LLM extraction | Ollama timeout | Do not consume from queue. Watchdog health check will detect Ollama is down. |
| LLM extraction | JSON validation failure | Mark `review`, preserve raw output. Do not retry — the failure may be deterministic for this document. |
| Embedding | Embedding timeout | Log warning, continue without embeddings. Document usable, just not semantically searchable. Schedule re-embedding. |

---

## Configuration Keys

Add these keys to the `dm_vault.system_config` seed data from Phase 2:

| Key | Default | Description |
|-----|---------|-------------|
| `ocr_primary_engine` | `tesseract` | Primary OCR engine |
| `ocr_fallback_engine` | `paddle` | Fallback engine |
| `ocr_fallback_threshold` | `75` | Confidence % below which fallback runs |
| `llm_primary_model` | `llama3.1:8b-q4_K_M` | Ollama extraction model |
| `llm_context_window` | `8192` | Token context window |
| `llm_temperature` | `0.0` | LLM temperature (keep at 0) |
| `max_page_count` | `50` | Maximum pages to process |
| `rasterization_dpi` | `300` | PDF rasterization DPI |
| `deskew_max_angle` | `10` | Max deskew angle in degrees |
| `denoise_strength` | `10` | OpenCV denoising filter strength |
| `chunk_size_tokens` | `512` | Embedding chunk size |
| `chunk_overlap_tokens` | `64` | Embedding chunk overlap |
| `review_threshold` | `75` | Field confidence % below which review is triggered |
| `olmocr_fallback_enabled` | `true` | Enable Qwen2.5-VL as last-resort engine |

---

## Python Packages Summary

Add to `requirements.txt` (all must be vendored in ISO and installer bundle):

```
opencv-python-headless==4.9.0.80
Pillow==10.2.0
pytesseract==0.3.10
scikit-image==0.23.1
pyheif==0.8.0
numpy==1.26.4
paddleocr==2.7.3
paddlepaddle==2.6.1
kraken==4.3.13
onnxruntime==1.17.0
langchain-text-splitters==0.0.1
tiktoken==0.6.0
```

---

## Validation Checklist

### Pre-Processing
- [ ] `pdftoppm` rasterizes a 3-page test PDF to