"""
DocMaster — dm-flux OCR Pipeline Worker
Long-running process managed by dm-flux.service.

Startup:
  - Initializes Redis + PostgreSQL connection pools
  - Loads all document type schemas from /opt/docmaster/config/schemas/
  - Loads ONNX classifier model into memory
  - Enters BLPOP loop across priority queues

Queue priority order (BLPOP): dm:queue:high → dm:queue:normal → dm:queue:low

Per-job working directory: /opt/docmaster/tmp/{job_id}/
Watchdog: pings systemd every 25 seconds (WatchdogSec=30)
"""
import asyncio
import json
import logging
import os
import signal
import socket
import time
import uuid
from pathlib import Path

import asyncpg
import redis.asyncio as aioredis
import structlog

# ── Logging setup ─────────────────────────────────────────────────────────
structlog.configure(
    processors=[
        structlog.processors.TimeStamper(fmt="iso", utc=True),
        structlog.processors.add_log_level,
        structlog.processors.JSONRenderer(),
    ]
)
logger = structlog.get_logger("dm-flux")

# ── Config from environment (sourced from dm.env) ─────────────────────────
DB_DSN = (
    f"postgresql://{os.getenv('DB_USER', 'dm_app')}:"
    f"{os.getenv('DB_PASSWORD', '')}@"
    f"{os.getenv('DB_HOST', '127.0.0.1')}:"
    f"{os.getenv('DB_PORT', '5432')}/"
    f"{os.getenv('DB_NAME', 'dm_vault')}"
)
REDIS_URL = (
    f"redis://:{os.getenv('REDIS_PASSWORD', '')}@"
    f"{os.getenv('REDIS_HOST', '127.0.0.1')}:"
    f"{os.getenv('REDIS_PORT', '6379')}/0"
    if os.getenv("REDIS_PASSWORD")
    else f"redis://{os.getenv('REDIS_HOST', '127.0.0.1')}:{os.getenv('REDIS_PORT', '6379')}/0"
)
OLLAMA_HOST = os.getenv("OLLAMA_HOST", "http://127.0.0.1:11434")
LLM_MODEL = os.getenv("LLM_PRIMARY_MODEL", "llama3.1:8b-q4_K_M")
EMBEDDING_MODEL = os.getenv("EMBEDDING_MODEL", "nomic-embed-text")
WORKER_COUNT = int(os.getenv("DM_WORKER_COUNT", "1"))
WORKER_ID = f"{socket.gethostname()}-{os.getpid()}"

INSTALL_PATH = Path(os.getenv("INSTALL_PATH", "/opt/docmaster"))
SCHEMAS_PATH = INSTALL_PATH / "config" / "schemas"
CLASSIFIER_PATH = INSTALL_PATH / "models" / "classifier" / "doc_classifier_v1.onnx"
TMP_PATH = INSTALL_PATH / "tmp"

PRIORITY_QUEUES = ["dm:queue:high", "dm:queue:normal", "dm:queue:low"]

# ── Global state ──────────────────────────────────────────────────────────
_db_pool: asyncpg.Pool | None = None
_redis: aioredis.Redis | None = None
_schemas: dict = {}
_classifier = None  # ONNX InferenceSession
_shutdown = False


async def initialize():
    """Load all resources at worker startup."""
    global _db_pool, _redis, _schemas, _classifier

    logger.info("dm_flux_worker_starting", worker_id=WORKER_ID)

    # PostgreSQL pool
    _db_pool = await asyncpg.create_pool(dsn=DB_DSN, min_size=1, max_size=3)
    logger.info("dm_flux_db_pool_ready")

    # Redis connection
    _redis = aioredis.from_url(REDIS_URL)
    await _redis.ping()
    logger.info("dm_flux_redis_ready")

    # Load extraction schemas
    if SCHEMAS_PATH.exists():
        for schema_file in SCHEMAS_PATH.glob("*.json"):
            with open(schema_file) as f:
                schema = json.load(f)
                _schemas[schema["doc_type"]] = schema
        logger.info("dm_flux_schemas_loaded", count=len(_schemas), types=list(_schemas.keys()))
    else:
        logger.warning("dm_flux_schemas_missing", path=str(SCHEMAS_PATH))

    # Load ONNX classifier
    if CLASSIFIER_PATH.exists():
        try:
            import onnxruntime as ort
            _classifier = ort.InferenceSession(
                str(CLASSIFIER_PATH),
                providers=["CPUExecutionProvider"],
            )
            logger.info("dm_flux_classifier_loaded", path=str(CLASSIFIER_PATH))
        except Exception as e:
            logger.error("dm_flux_classifier_load_failed", error=str(e))
    else:
        logger.warning("dm_flux_classifier_missing", path=str(CLASSIFIER_PATH))

    logger.info("dm_flux_worker_ready", worker_id=WORKER_ID)


async def shutdown():
    """Clean shutdown."""
    global _db_pool, _redis, _shutdown
    _shutdown = True
    if _redis:
        await _redis.aclose()
    if _db_pool:
        await _db_pool.close()
    logger.info("dm_flux_worker_shutdown", worker_id=WORKER_ID)


def notify_watchdog():
    """Ping systemd watchdog. Called every 25 seconds (WatchdogSec=30)."""
    try:
        import sdnotify
        n = sdnotify.SystemdNotifier()
        n.notify("WATCHDOG=1")
    except ImportError:
        pass  # sdnotify not available in dev environment


async def process_job(payload: dict) -> None:
    """Execute the full 5-stage OCR pipeline for a single job."""
    job_id = payload.get("job_id")
    document_id = payload.get("document_id")

    if not job_id or not document_id:
        logger.error("dm_flux_invalid_payload", payload=payload)
        return

    log = logger.bind(job_id=job_id, document_id=document_id)
    log.info("dm_flux_job_started")

    async with _db_pool.acquire() as db:
        # Mark job as processing
        await db.execute(
            "UPDATE dm_flux.jobs SET status = 'processing', started_at = NOW(), worker_id = $1 WHERE id = $2",
            WORKER_ID, uuid.UUID(job_id),
        )
        await db.execute(
            "UPDATE dm_core.documents SET status = 'processing', processing_started_at = NOW() WHERE id = $1",
            uuid.UUID(document_id),
        )
        await db.execute(
            "INSERT INTO dm_core.document_events (document_id, event_type) VALUES ($1, 'processing_started')",
            uuid.UUID(document_id),
        )

        # Fetch full job payload from DB
        job_row = await db.fetchrow(
            "SELECT payload_json FROM dm_flux.jobs WHERE id = $1",
            uuid.UUID(job_id),
        )
        if not job_row:
            log.error("dm_flux_job_not_found")
            return

        job_data = json.loads(job_row["payload_json"])
        file_path = job_data.get("file_path")

        try:
            start_time = time.monotonic()

            # ── Stage 1: Pre-Processing ───────────────────────────────────
            from flux.pipeline.preprocess import preprocess_document
            job_dir = TMP_PATH / job_id
            pages, page_count = await preprocess_document(file_path, job_dir)
            await db.execute(
                "UPDATE dm_core.documents SET page_count = $1 WHERE id = $2",
                page_count, uuid.UUID(document_id),
            )
            log.info("dm_flux_stage1_complete", pages=page_count)

            # ── Stage 2: Classification ───────────────────────────────────
            from flux.pipeline.classify import classify_document
            classification = classify_document(pages[0] if pages else None, _classifier)
            doc_type = classification["doc_type"]
            schema = _schemas.get(doc_type, _schemas.get("unknown", {}))
            log.info("dm_flux_stage2_complete", doc_type=doc_type, confidence=classification["confidence"])

            # ── Stage 3: OCR Execution ────────────────────────────────────
            from flux.pipeline.ocr import run_ocr
            ocr_text, ocr_engine = await run_ocr(pages, classification, job_dir)
            elapsed_ocr = int((time.monotonic() - start_time) * 1000)
            await db.execute(
                "INSERT INTO dm_core.document_events (document_id, event_type, duration_ms) VALUES ($1, 'ocr_complete', $2)",
                uuid.UUID(document_id), elapsed_ocr,
            )
            log.info("dm_flux_stage3_complete", engine=ocr_engine, duration_ms=elapsed_ocr)

            # ── Stage 4: LLM Extraction ───────────────────────────────────
            from flux.pipeline.extract import run_extraction
            extractions, mean_confidence, needs_review = await run_extraction(
                ocr_text, schema, doc_type, OLLAMA_HOST, LLM_MODEL
            )

            final_status = "review" if needs_review else "complete"

            async with db.transaction():
                await db.execute(
                    """
                    UPDATE dm_core.documents
                    SET status = $1::dm_core.document_status,
                        doc_type = $2::dm_core.document_type,
                        confidence_score = $3,
                        processed_at = NOW()
                    WHERE id = $4
                    """,
                    final_status, doc_type, round(mean_confidence * 100, 2), uuid.UUID(document_id),
                )
                for field in extractions:
                    await db.execute(
                        """
                        INSERT INTO dm_core.extractions
                            (document_id, field_name, field_value, field_order, confidence, ocr_engine)
                        VALUES ($1, $2, $3, $4, $5, $6)
                        """,
                        uuid.UUID(document_id), field["name"], field["value"],
                        field.get("order", 0), field.get("confidence"), ocr_engine,
                    )
                elapsed_total = int((time.monotonic() - start_time) * 1000)
                await db.execute(
                    "INSERT INTO dm_core.document_events (document_id, event_type, duration_ms) VALUES ($1, 'extraction_complete', $2)",
                    uuid.UUID(document_id), elapsed_total,
                )
                if needs_review:
                    await db.execute(
                        "INSERT INTO dm_core.document_events (document_id, event_type) VALUES ($1, 'flagged_for_review')",
                        uuid.UUID(document_id),
                    )

            log.info("dm_flux_stage4_complete", status=final_status, confidence=mean_confidence)

            # ── Stage 5: Vector Indexing ──────────────────────────────────
            from flux.pipeline.embed import run_embedding
            chunks_indexed = await run_embedding(
                ocr_text, uuid.UUID(document_id), _db_pool, OLLAMA_HOST, EMBEDDING_MODEL
            )
            log.info("dm_flux_stage5_complete", chunks_indexed=chunks_indexed)

            # Mark job complete
            await db.execute(
                "UPDATE dm_flux.jobs SET status = 'complete', completed_at = NOW() WHERE id = $1",
                uuid.UUID(job_id),
            )
            log.info("dm_flux_job_complete", duration_ms=elapsed_total, status=final_status)

        except Exception as e:
            log.error("dm_flux_job_failed", error=str(e))
            async with db.transaction():
                retry_count = await db.fetchval(
                    "SELECT retry_count FROM dm_flux.jobs WHERE id = $1", uuid.UUID(job_id)
                ) or 0
                max_retries = await db.fetchval(
                    "SELECT max_retries FROM dm_flux.jobs WHERE id = $1", uuid.UUID(job_id)
                ) or 3

                if retry_count < max_retries:
                    await db.execute(
                        "UPDATE dm_flux.jobs SET status = 'queued', retry_count = retry_count + 1, error_message = $1 WHERE id = $2",
                        str(e), uuid.UUID(job_id),
                    )
                    await db.execute(
                        "UPDATE dm_core.documents SET status = 'queued', retry_count = retry_count + 1 WHERE id = $1",
                        uuid.UUID(document_id),
                    )
                    await _redis.rpush("dm:queue:failed", json.dumps(payload))
                    log.info("dm_flux_job_requeued", retry_count=retry_count + 1)
                else:
                    await db.execute(
                        "UPDATE dm_flux.jobs SET status = 'failed', error_message = $1 WHERE id = $2",
                        str(e), uuid.UUID(job_id),
                    )
                    await db.execute(
                        "UPDATE dm_core.documents SET status = 'failed', error_message = $1 WHERE id = $2",
                        str(e), uuid.UUID(document_id),
                    )
                    await db.execute(
                        "INSERT INTO dm_core.document_events (document_id, event_type, detail) VALUES ($1, 'failed', $2)",
                        uuid.UUID(document_id), str(e),
                    )
                    log.error("dm_flux_job_exhausted", error=str(e))


async def main_loop():
    """Main BLPOP consumer loop. Runs until SIGTERM."""
    last_watchdog = time.monotonic()

    while not _shutdown:
        # Ping systemd watchdog every 25 seconds
        if time.monotonic() - last_watchdog >= 25:
            notify_watchdog()
            last_watchdog = time.monotonic()

        try:
            # Block for up to 5 seconds waiting for a job
            result = await _redis.blpop(PRIORITY_QUEUES, timeout=5)
            if result is None:
                continue  # timeout — loop back and check watchdog

            _, raw_payload = result
            payload = json.loads(raw_payload)
            await process_job(payload)

        except asyncio.CancelledError:
            break
        except Exception as e:
            logger.error("dm_flux_loop_error", error=str(e))
            await asyncio.sleep(1)  # Brief pause before retrying


async def run():
    await initialize()
    try:
        await main_loop()
    finally:
        await shutdown()


if __name__ == "__main__":
    asyncio.run(run())
