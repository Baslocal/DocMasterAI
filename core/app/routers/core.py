"""
DocMaster — /dm/core/ routes
Document management, extraction, search, stats

GET  /dm/core/documents              — Paginated, filterable document list
GET  /dm/core/documents/{id}         — Full document detail with extractions + events
POST /dm/core/documents/{id}/export  — Export as CSV, JSON, PDF, or XLSX
POST /dm/core/documents/{id}/corrections — Submit human correction for a field
PATCH /dm/core/documents/{id}/status — Update document status
POST /dm/core/search                 — Semantic vector search
GET  /dm/core/stats                  — Dashboard KPI summary
"""
import uuid
from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel

from app.database import get_db
from app.dependencies import get_current_operator, require_role

router = APIRouter()


# ── Pydantic Models ───────────────────────────────────────────────────────

class CorrectionRequest(BaseModel):
    field_name: str
    corrected_value: str


class StatusUpdate(BaseModel):
    status: str


class SearchRequest(BaseModel):
    query: str
    limit: int = 10
    doc_type: Optional[str] = None


# ── Routes ────────────────────────────────────────────────────────────────

@router.get("/documents")
async def list_documents(
    page: int = Query(1, ge=1),
    limit: int = Query(25, ge=1, le=100),
    status: Optional[str] = None,
    doc_type: Optional[str] = None,
    search: Optional[str] = None,
    date_from: Optional[str] = None,
    date_to: Optional[str] = None,
    operator: dict = Depends(get_current_operator),
    db=Depends(get_db),
):
    """Paginated, filterable document list. Powers the Documents page table."""
    offset = (page - 1) * limit
    conditions = []
    params = []
    param_idx = 1

    if status:
        conditions.append(f"status = ${param_idx}::dm_core.document_status")
        params.append(status)
        param_idx += 1

    if doc_type:
        conditions.append(f"doc_type = ${param_idx}::dm_core.document_type")
        params.append(doc_type)
        param_idx += 1

    if search:
        conditions.append(f"original_name ILIKE ${param_idx}")
        params.append(f"%{search}%")
        param_idx += 1

    if date_from:
        conditions.append(f"ingested_at >= ${param_idx}::TIMESTAMPTZ")
        params.append(date_from)
        param_idx += 1

    if date_to:
        conditions.append(f"ingested_at <= ${param_idx}::TIMESTAMPTZ")
        params.append(date_to)
        param_idx += 1

    where = "WHERE " + " AND ".join(conditions) if conditions else ""

    total = await db.fetchval(
        f"SELECT COUNT(*) FROM dm_core.documents {where}", *params
    )
    rows = await db.fetch(
        f"""
        SELECT id, filename, original_name, doc_type, status, confidence_score,
               source_channel, page_count, file_size_bytes, ingested_at, processed_at,
               retry_count
        FROM dm_core.documents
        {where}
        ORDER BY ingested_at DESC
        LIMIT {limit} OFFSET {offset}
        """,
        *params,
    )

    return {
        "total": total,
        "page": page,
        "limit": limit,
        "pages": (total + limit - 1) // limit,
        "documents": [dict(r) for r in rows],
    }


@router.get("/documents/{doc_id}")
async def get_document(
    doc_id: uuid.UUID,
    operator: dict = Depends(get_current_operator),
    db=Depends(get_db),
):
    """Full document detail with extractions and event timeline.
    Powers the Document Detail Modal.
    """
    doc = await db.fetchrow(
        "SELECT * FROM dm_core.documents WHERE id = $1", doc_id
    )
    if not doc:
        raise HTTPException(
            status_code=404,
            detail={"error": "DM_4041", "message": "Document not found"},
        )

    extractions = await db.fetch(
        """
        SELECT id, field_name, field_value, field_order, confidence, is_corrected,
               original_value, ocr_engine, corrected_at
        FROM dm_core.extractions
        WHERE document_id = $1
        ORDER BY field_order
        """,
        doc_id,
    )

    events = await db.fetch(
        """
        SELECT id, event_type, event_at, duration_ms, detail, operator_id
        FROM dm_core.document_events
        WHERE document_id = $1
        ORDER BY event_at
        """,
        doc_id,
    )

    return {
        "document": dict(doc),
        "extractions": [dict(e) for e in extractions],
        "events": [dict(ev) for ev in events],
    }


@router.post("/documents/{doc_id}/corrections")
async def submit_correction(
    doc_id: uuid.UUID,
    req: CorrectionRequest,
    operator: dict = Depends(require_role("admin", "operator", "reviewer")),
    db=Depends(get_db),
):
    """Submit a human correction for an extraction field.
    Preserves original_value, sets is_corrected = true.
    """
    async with db.transaction():
        row = await db.fetchrow(
            "SELECT id, field_value FROM dm_core.extractions "
            "WHERE document_id = $1 AND field_name = $2",
            doc_id, req.field_name,
        )
        if not row:
            raise HTTPException(
                status_code=404,
                detail={"error": "DM_4042", "message": f"Field '{req.field_name}' not found"},
            )

        await db.execute(
            """
            UPDATE dm_core.extractions
            SET field_value = $1,
                is_corrected = TRUE,
                original_value = COALESCE(original_value, field_value),
                corrected_by = $2,
                corrected_at = NOW()
            WHERE document_id = $3 AND field_name = $4
            """,
            req.corrected_value, operator["id"], doc_id, req.field_name,
        )

        await db.execute(
            """
            INSERT INTO dm_core.document_events (document_id, event_type, operator_id, detail)
            VALUES ($1, 'correction_saved', $2, $3)
            """,
            doc_id, operator["id"], f"Field '{req.field_name}' corrected",
        )

    return {"status": "saved", "field_name": req.field_name}


@router.patch("/documents/{doc_id}/status")
async def update_status(
    doc_id: uuid.UUID,
    req: StatusUpdate,
    operator: dict = Depends(require_role("admin", "operator", "reviewer")),
    db=Depends(get_db),
):
    """Update document status — operator actions like marking review→complete."""
    valid_statuses = {"queued", "processing", "complete", "review", "failed"}
    if req.status not in valid_statuses:
        raise HTTPException(
            status_code=422,
            detail={"error": "DM_4221", "message": f"Invalid status: {req.status}"},
        )

    async with db.transaction():
        await db.execute(
            """
            UPDATE dm_core.documents
            SET status = $1::dm_core.document_status,
                reviewed_at = CASE WHEN $1 = 'complete' THEN NOW() ELSE reviewed_at END,
                reviewed_by = CASE WHEN $1 = 'complete' THEN $2 ELSE reviewed_by END
            WHERE id = $3
            """,
            req.status, operator["id"], doc_id,
        )

        event_map = {
            "complete": "marked_complete",
            "review": "flagged_for_review",
        }
        event_type = event_map.get(req.status)
        if event_type:
            await db.execute(
                "INSERT INTO dm_core.document_events (document_id, event_type, operator_id) "
                "VALUES ($1, $2, $3)",
                doc_id, event_type, operator["id"],
            )

    return {"id": str(doc_id), "status": req.status}


@router.post("/search")
async def semantic_search(
    req: SearchRequest,
    operator: dict = Depends(get_current_operator),
    db=Depends(get_db),
):
    """Semantic vector search across all indexed documents.
    Embeds query via nomic-embed-text, performs cosine similarity search.
    Falls back to trigram text search if no embeddings exist.
    """
    import httpx
    from app.config import settings

    # Generate query embedding
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            resp = await client.post(
                f"{settings.ollama_host}/api/embeddings",
                json={"model": settings.embedding_model, "prompt": req.query},
            )
        query_vector = resp.json()["embedding"]

        # Vector similarity search
        results = await db.fetch(
            """
            SELECT d.id, d.original_name, d.doc_type, d.status, d.confidence_score,
                   d.ingested_at,
                   1 - (e.embedding <=> $1::vector) AS similarity,
                   e.chunk_text
            FROM dm_core.embeddings e
            JOIN dm_core.documents d ON d.id = e.document_id
            ORDER BY e.embedding <=> $1::vector
            LIMIT $2
            """,
            str(query_vector), req.limit,
        )
    except Exception:
        # Fallback to trigram text search
        results = await db.fetch(
            """
            SELECT id, original_name, doc_type, status, confidence_score, ingested_at,
                   NULL AS similarity, NULL AS chunk_text
            FROM dm_core.documents
            WHERE original_name % $1
            ORDER BY similarity(original_name, $1) DESC
            LIMIT $2
            """,
            req.query, req.limit,
        )

    return {
        "query": req.query,
        "results": [dict(r) for r in results],
    }


@router.get("/stats")
async def get_stats(
    operator: dict = Depends(get_current_operator),
    db=Depends(get_db),
):
    """Dashboard KPI summary — status counts, today's total, avg confidence.
    Powers the top bar pills and Dashboard KPI cards.
    """
    summary = await db.fetchrow("SELECT * FROM dm_core.daily_summary")
    status_counts = await db.fetch("SELECT * FROM dm_core.document_status_counts")

    return {
        "summary": dict(summary),
        "by_status": {r["status"]: r["doc_count"] for r in status_counts},
    }
