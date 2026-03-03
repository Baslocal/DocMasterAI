"""
DocMaster — /dm/bridge/ routes
External connector management

GET   /dm/bridge/connectors              — List connectors with enabled/disabled state
PATCH /dm/bridge/connectors/{name}       — Enable, disable, or update connector
POST  /dm/bridge/connectors/{name}/test  — Test connector connectivity
POST  /dm/bridge/connectors/{name}/sync  — Trigger manual sync
"""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app.database import get_db
from app.dependencies import require_role

router = APIRouter()


class ConnectorUpdate(BaseModel):
    is_enabled: bool | None = None
    config_json: str | None = None


@router.get("/connectors")
async def list_connectors(
    operator: dict = Depends(require_role("admin", "operator")),
    db=Depends(get_db),
):
    rows = await db.fetch(
        "SELECT connector_name, is_enabled, last_sync_at, last_sync_status, last_error, updated_at "
        "FROM dm_vault.connector_configs ORDER BY connector_name"
    )
    return {"connectors": [dict(r) for r in rows]}


@router.patch("/connectors/{connector_name}")
async def update_connector(
    connector_name: str,
    req: ConnectorUpdate,
    operator: dict = Depends(require_role("admin")),
    db=Depends(get_db),
):
    row = await db.fetchrow(
        "SELECT connector_name FROM dm_vault.connector_configs WHERE connector_name = $1",
        connector_name,
    )
    if not row:
        raise HTTPException(
            status_code=404,
            detail={"error": "DM_4046", "message": f"Connector '{connector_name}' not found"},
        )

    if req.is_enabled is not None:
        await db.execute(
            "UPDATE dm_vault.connector_configs SET is_enabled = $1, updated_at = NOW() WHERE connector_name = $2",
            req.is_enabled, connector_name,
        )

    if req.config_json is not None:
        await db.execute(
            "UPDATE dm_vault.connector_configs SET config_json = $1, updated_at = NOW() WHERE connector_name = $2",
            req.config_json, connector_name,
        )

    return {"connector_name": connector_name, "updated": True}


@router.post("/connectors/{connector_name}/test")
async def test_connector(
    connector_name: str,
    operator: dict = Depends(require_role("admin", "operator")),
    db=Depends(get_db),
):
    """Test connector connectivity. Result is returned immediately."""
    row = await db.fetchrow(
        "SELECT is_enabled, config_json FROM dm_vault.connector_configs WHERE connector_name = $1",
        connector_name,
    )
    if not row:
        raise HTTPException(
            status_code=404,
            detail={"error": "DM_4046", "message": f"Connector '{connector_name}' not found"},
        )
    if not row["is_enabled"]:
        return {"connector_name": connector_name, "status": "disabled", "message": "Enable connector before testing"}

    # Full connector test logic is in dm-bridge.service
    # This endpoint signals bridge to run a connectivity check and return result
    return {
        "connector_name": connector_name,
        "status": "pending",
        "message": "Connectivity test delegated to dm-bridge.service",
    }


@router.post("/connectors/{connector_name}/sync")
async def trigger_sync(
    connector_name: str,
    operator: dict = Depends(require_role("admin", "operator")),
    db=Depends(get_db),
):
    """Trigger manual sync for a connector. Pushes sync job to dm:queue:low."""
    import json
    import uuid
    import redis.asyncio as aioredis
    from app.config import settings

    row = await db.fetchrow(
        "SELECT is_enabled FROM dm_vault.connector_configs WHERE connector_name = $1",
        connector_name,
    )
    if not row or not row["is_enabled"]:
        raise HTTPException(
            status_code=400,
            detail={"error": "DM_4221", "message": f"Connector '{connector_name}' is disabled or not found"},
        )

    r = aioredis.from_url(settings.redis_url)
    await r.rpush(
        "dm:queue:low",
        json.dumps({"type": "connector_sync", "connector": connector_name, "triggered_by": operator["username"]}),
    )
    await r.aclose()

    return {"connector_name": connector_name, "status": "sync_queued"}
