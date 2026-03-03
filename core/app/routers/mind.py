"""
DocMaster — /dm/mind/ routes
LLM status, model management, direct inference

GET  /dm/mind/status   — Loaded model name, VRAM usage, inference latency
GET  /dm/mind/models   — List all locally available pinned models
POST /dm/mind/infer    — Direct inference (advanced integrations)
"""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app.config import settings
from app.dependencies import require_role

router = APIRouter()


class InferRequest(BaseModel):
    prompt: str
    model: str | None = None
    format: str = "json"


@router.get("/status")
async def mind_status(operator: dict = Depends(require_role("admin", "operator"))):
    """Return Ollama service status — loaded model, VRAM, latency."""
    import httpx
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.get(f"{settings.ollama_host}/api/tags")
            if resp.status_code != 200:
                return {"status": "unavailable", "error": f"HTTP {resp.status_code}"}
            data = resp.json()
        return {
            "status": "ok",
            "host": settings.ollama_host,
            "primary_model": settings.llm_primary_model,
            "embedding_model": settings.embedding_model,
            "models": data.get("models", []),
        }
    except Exception as e:
        return {"status": "unavailable", "error": str(e)}


@router.get("/models")
async def list_models(operator: dict = Depends(require_role("admin", "operator"))):
    """List all locally available Ollama models."""
    import httpx
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.get(f"{settings.ollama_host}/api/tags")
    if resp.status_code != 200:
        raise HTTPException(status_code=502, detail={"error": "DM_5020", "message": "Ollama unavailable"})
    return resp.json()


@router.post("/infer")
async def direct_infer(
    req: InferRequest,
    operator: dict = Depends(require_role("admin")),
):
    """Direct LLM inference — for advanced integrations and debugging only.
    STRICT RULES: temperature=0.0, format='json' enforced on extraction calls.
    This endpoint allows flexibility for non-extraction use cases.
    """
    import httpx
    model = req.model or settings.llm_primary_model
    async with httpx.AsyncClient(timeout=120.0) as client:
        resp = await client.post(
            f"{settings.ollama_host}/api/generate",
            json={
                "model": model,
                "prompt": req.prompt,
                "format": req.format,
                "stream": False,
                "options": {"temperature": 0.0},
            },
        )
    if resp.status_code != 200:
        raise HTTPException(status_code=502, detail={"error": "DM_5021", "message": "Ollama inference failed"})
    return resp.json()
