"""
DocMaster — /dm/flux/ routes
File upload and job queue management

POST   /dm/flux/push           — Upload file to pipeline (multipart/form-data)
GET    /dm/flux/queue          — View queued, processing, failed jobs
GET    /dm/flux/job/{id}       — Poll specific job status and progress
POST   /dm/flux/job/{id}/retry — Re-queue a failed job
DELETE /dm/flux/job/{id}       — Cancel and remove a queued job
"""
import hashlib
import json
import os
import shutil
import uuid
from datetime import datetime, timezone

import aiofiles
from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile, status

from app.config import settings
from app.database import get_db
from app.dependencies import get_current_operator, require_role

router = APIRouter()

# Supported MIME types
ALLOWED_MIME_TYPES = {
    "application/pdf",
    "image/png",
    "image/jpeg",
    "image/tiff",
    "image/heic",
    "image/heif",
    "image/bmp",
    "image/webp",
}


@router.post("/push", status_code=202)
async def push_document(
    file: UploadFile = File(...),
    priority: str = Form("normal"),
    instruction: str = Form(None),
    operator: dict = Depends(get_current_operator),
    db=Depends(get_db),
):
    """Upload a document file to the OCR processing pipeline.
    Validates MIME type, computes SHA-256 for deduplication,
    creates job record and pushes to Redis queue.
    """
    import redis.asyncio as aioredis

    # Validate MIME type
    if file.content_type not in ALLOWED_MIME_TYPES:
        raise HTTPException(
            status_code=422,
            detail={
                "error": "DM_4222",
                "message": f"Unsupported file type: {file.content_type}. "
                           f"Accepted: {', '.join(ALLOWED_MIME_TYPES)}",
            },
        )

    # Read file and compute SHA-256
    content = await file.read()
    sha256 = hashlib.sha256(content).hexdigest()

    # Check for duplicate
    existing = await db.fetchrow(
        "SELECT id, status FROM dm_core.documents WHERE hash_sha256 = $1",
        sha256,
    )
    if existing:
        return {
            "status": "duplicate",
            "message": "Document already exists",
            "document_id": str(existing["id"]),
            "document_status": existing["status"],
        }

    # Create job working directory
    job_id = uuid.uuid4()
    job_dir = os.path.join(settings.tmp_path, str(job_id))
    os.makedirs(job_dir, mode=0o700, exist_ok=True)

    # Determine file extension
    ext = os.path.splitext(file.filename or "document")[1] or ".bin"
    stored_filename = f"original{ext}"
    file_path = os.path.join(job_dir, stored_filename)

    # Write file to tmp
    async with aiofiles.open(file_path, "wb") as f:
        await f.write(content)

    file_size = len(content)

    async with db.transaction():
        # Create document record
        doc_id = await db.fetchval(
            """
            INSERT INTO dm_core.documents
                (filename, original_name, hash_sha256, file_path, file_size_bytes,
                 mime_type, doc_type, status, source_channel, operator_id,
                 ingested_at, queued_at)
            VALUES
                ($1, $2, $3, $4, $5, $6, 'unknown', 'queued', 'api', $7, NOW(), NOW())
            RETURNING id
            """,
            stored_filename, file.filename or "document", sha256,
            file_path, file_size, file.content_type, operator["id"],
        )

        # Create job record
        await db.execute(
            """
            INSERT INTO dm_flux.jobs
                (id, document_id, document_hash, priority, status, source_channel,
                 instruction, payload_json, created_at)
            VALUES
                ($1, $2, $3, $4, 'queued', 'api', $5, $6, NOW())
            """,
            job_id, doc_id, sha256, priority, instruction,
            json.dumps({
                "job_id": str(job_id),
                "document_id": str(doc_id),
                "document_hash": sha256,
                "file_path": file_path,
                "original_name": file.filename,
                "mime_type": file.content_type,
                "priority": priority,
                "source_channel": "api",
                "instruction": instruction,
                "retry_count": 0,
                "max_retries": 3,
                "created_at": datetime.now(timezone.utc).isoformat(),
                "metadata": {
                    "fax_source_number": None,
                    "email_sender": None,
                    "drive_file_id": None,
                    "scanner_ip": None,
                },
            }),
        )

        # Log ingestion event
        await db.execute(
            "INSERT INTO dm_core.document_events (document_id, event_type, operator_id) "
            "VALUES ($1, 'ingested', $2)",
            doc_id, operator["id"],
        )

        await db.execute(
            "INSERT INTO dm_core.document_events (document_id, event_type) VALUES ($1, 'queued')",
            doc_id,
        )

    # Push to Redis queue
    queue_key = {
        "high": "dm:queue:high",
        "normal": "dm:queue:normal",
        "low": "dm:queue:low",
    }.get(priority, "dm:queue:normal")

    r = aioredis.from_url(settings.redis_url)
    await r.rpush(
        queue_key,
        json.dumps({"job_id": str(job_id), "document_id": str(doc_id)}),
    )
    await r.aclose()

    return {
        "status": "queued",
        "job_id": str(job_id),
        "document_id": str(doc_id),
        "queue": queue_key,
        "priority": priority,
    }


@router.get("/queue")
async def view_queue(
    operator: dict = Depends(get_current_operator),
    db=Depends(get_db),
):
    """View all active jobs — queued, processing, and recently failed."""
    rows = await db.fetch(
        """
        SELECT j.id, j.document_id, j.priority, j.status, j.source_channel,
               j.created_at, j.started_at, j.completed_at,
               j.retry_count, j.max_retries, j.error_message,
               d.original_name, d.doc_type
        FROM dm_flux.jobs j
        LEFT JOIN dm_core.documents d ON d.id = j.document_id
        WHERE j.status IN ('queued', 'processing', 'failed')
        ORDER BY
            CASE j.priority WHEN 'high' THEN 0 WHEN 'normal' THEN 1 ELSE 2 END,
            j.created_at ASC
        LIMIT 200
        """,
    )
    return {"jobs": [dict(r) for r in rows]}


@router.get("/job/{job_id}")
async def get_job(
    job_id: uuid.UUID,
    operator: dict = Depends(get_current_operator),
    db=Depends(get_db),
):
    row = await db.fetchrow(
        "SELECT * FROM dm_flux.jobs WHERE id = $1", job_id
    )
    if not row:
        raise HTTPException(
            status_code=404,
            detail={"error": "DM_4043", "message": "Job not found"},
        )
    return dict(row)


@router.post("/job/{job_id}/retry")
async def retry_job(
    job_id: uuid.UUID,
    operator: dict = Depends(require_role("admin", "operator")),
    db=Depends(get_db),
):
    """Re-queue a failed job. Resets retry_count."""
    import redis.asyncio as aioredis

    row = await db.fetchrow(
        "SELECT id, document_id, priority FROM dm_flux.jobs WHERE id = $1 AND status = 'failed'",
        job_id,
    )
    if not row:
        raise HTTPException(
            status_code=404,
            detail={"error": "DM_4044", "message": "Failed job not found"},
        )

    async with db.transaction():
        await db.execute(
            "UPDATE dm_flux.jobs SET status = 'queued', retry_count = 0, error_message = NULL WHERE id = $1",
            job_id,
        )
        await db.execute(
            "UPDATE dm_core.documents SET status = 'queued', retry_count = 0 WHERE id = $1",
            row["document_id"],
        )
        await db.execute(
            "INSERT INTO dm_core.document_events (document_id, event_type, operator_id) VALUES ($1, 'retried', $2)",
            row["document_id"], operator["id"],
        )

    queue_key = {"high": "dm:queue:high", "normal": "dm:queue:normal", "low": "dm:queue:low"}.get(
        row["priority"], "dm:queue:high"
    )
    r = aioredis.from_url(settings.redis_url)
    await r.rpush(queue_key, json.dumps({"job_id": str(job_id), "document_id": str(row["document_id"])}))
    await r.aclose()

    return {"status": "requeued", "job_id": str(job_id)}


@router.delete("/job/{job_id}", status_code=204)
async def cancel_job(
    job_id: uuid.UUID,
    operator: dict = Depends(require_role("admin", "operator")),
    db=Depends(get_db),
):
    """Cancel a queued job. Cannot cancel a job that is already processing."""
    row = await db.fetchrow(
        "SELECT id FROM dm_flux.jobs WHERE id = $1 AND status = 'queued'",
        job_id,
    )
    if not row:
        raise HTTPException(
            status_code=404,
            detail={"error": "DM_4045", "message": "Queued job not found (may already be processing)"},
        )
    await db.execute(
        "UPDATE dm_flux.jobs SET status = 'cancelled' WHERE id = $1", job_id
    )
