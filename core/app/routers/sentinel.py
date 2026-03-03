"""
DocMaster — /dm/sentinel/ routes
Health monitoring, diagnostics, log streaming

GET  /dm/sentinel/health      — NO AUTH REQUIRED — overall health + component breakdown
POST /dm/sentinel/diagnostics — Run full diagnostic suite
GET  /dm/sentinel/logs        — Recent structured log entries
WS   /dm/sentinel/logs/stream — Live log streaming WebSocket
"""
import asyncio
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse

from app.database import get_db

router = APIRouter()


@router.get("/health")
async def health(db=Depends(get_db)):
    """Overall health status + component breakdown.
    No authentication required — used by load balancers and monitoring.
    """
    components = {}
    overall = "ok"

    # PostgreSQL check
    try:
        await db.fetchval("SELECT 1")
        components["postgresql"] = {"status": "ok"}
    except Exception as e:
        components["postgresql"] = {"status": "critical", "error": str(e)}
        overall = "critical"

    # Redis check (import here to avoid circular deps)
    try:
        import redis.asyncio as aioredis
        from app.config import settings
        r = aioredis.from_url(settings.redis_url)
        await r.ping()
        await r.aclose()
        components["redis"] = {"status": "ok"}
    except Exception as e:
        components["redis"] = {"status": "degraded", "error": str(e)}
        if overall == "ok":
            overall = "degraded"

    # Ollama check
    try:
        import httpx
        from app.config import settings
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(f"{settings.ollama_host}/api/tags")
            if resp.status_code == 200:
                components["ollama"] = {"status": "ok"}
            else:
                components["ollama"] = {"status": "degraded", "http_status": resp.status_code}
                if overall == "ok":
                    overall = "degraded"
    except Exception as e:
        components["ollama"] = {"status": "degraded", "error": str(e)}
        if overall == "ok":
            overall = "degraded"

    return {
        "status": overall,
        "checked_at": datetime.now(timezone.utc).isoformat(),
        "components": components,
    }


@router.post("/diagnostics")
async def run_diagnostics(db=Depends(get_db)):
    """Run the full diagnostic suite and return detailed results.
    Requires authentication (standard Bearer token).
    """
    results = {}

    # Document counts
    rows = await db.fetch(
        "SELECT status, COUNT(*) AS count FROM dm_core.documents GROUP BY status"
    )
    results["document_counts"] = {row["status"]: row["count"] for row in rows}

    # Queue depth
    try:
        embedding_count = await db.fetchval(
            "SELECT COUNT(*) FROM dm_core.embeddings"
        )
        results["embedding_count"] = embedding_count
        results["ivfflat_threshold"] = 3900
        results["ivfflat_ready"] = embedding_count >= 3900
    except Exception as e:
        results["embedding_error"] = str(e)

    # Recent failures
    failed = await db.fetch(
        """
        SELECT id, original_name, error_message, processed_at
        FROM dm_core.documents
        WHERE status = 'failed'
        ORDER BY processed_at DESC
        LIMIT 5
        """,
    )
    results["recent_failures"] = [dict(r) for r in failed]

    return results


@router.get("/logs")
async def get_logs():
    """Return recent structured log entries from dm-core service log.
    Reads from /opt/docmaster/logs/dm-core.log (last 200 lines).
    """
    import os
    log_path = "/opt/docmaster/logs/dm-core.log"
    if not os.path.exists(log_path):
        return {"entries": [], "note": "Log file not found — service may not be running under systemd"}
    try:
        with open(log_path, "r") as f:
            lines = f.readlines()[-200:]
        return {"entries": [line.rstrip() for line in lines]}
    except PermissionError:
        return {"entries": [], "error": "DM_4033: Insufficient permissions to read log file"}


@router.websocket("/logs/stream")
async def stream_logs(websocket: WebSocket):
    """Live log streaming WebSocket — tails /opt/docmaster/logs/dm-core.log."""
    import os
    await websocket.accept()
    log_path = "/opt/docmaster/logs/dm-core.log"
    try:
        with open(log_path, "r") as f:
            f.seek(0, 2)  # Seek to end
            while True:
                line = f.readline()
                if line:
                    await websocket.send_text(line.rstrip())
                else:
                    await asyncio.sleep(0.1)
    except FileNotFoundError:
        await websocket.send_text('{"error": "DM_5011: Log file not found"}')
        await websocket.close()
    except WebSocketDisconnect:
        pass
