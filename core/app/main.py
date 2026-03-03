"""
DocMaster — dm-core
FastAPI REST + WebSocket API server
Port: 8443 | User: dmuser | Install: /opt/docmaster/

API namespace: /dm/ — NEVER /api/ or /v1/
All routes require Authorization: Bearer {jwt} except:
  - GET  /dm/sentinel/health
  - POST /dm/vault/auth/login
"""
import structlog
from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.config import settings
from app.database import get_pool, close_pool
from app.middleware import DMHeadersMiddleware, DMErrorMiddleware
from app.routers import core, flux, mind, bridge, sentinel, vault

logger = structlog.get_logger("dm-core")


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup and shutdown lifecycle."""
    logger.info(
        "dm_core_starting",
        version=settings.dm_version,
        build=settings.dm_build,
        node=settings.dm_node,
        port=settings.dm_port,
    )
    # Initialize DB connection pool
    await get_pool()
    logger.info("dm_core_db_pool_ready")

    yield

    # Shutdown
    await close_pool()
    logger.info("dm_core_shutdown")


app = FastAPI(
    title="DocMaster API",
    version=settings.dm_version,
    docs_url=None,       # Disable Swagger UI in production
    redoc_url=None,      # Disable ReDoc in production
    openapi_url=None,    # Disable OpenAPI schema endpoint
    lifespan=lifespan,
)

# ── Middleware ─────────────────────────────────────────────────────────────
# Order matters: error handler wraps everything, headers added to all responses
app.add_middleware(DMErrorMiddleware)
app.add_middleware(DMHeadersMiddleware)

# CORS: restrict to LAN — no external origins
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],      # Tighten to LAN CIDR in production via nginx
    allow_credentials=True,
    allow_methods=["GET", "POST", "PATCH", "DELETE"],
    allow_headers=["Authorization", "Content-Type", "X-DM-Build"],
)

# ── Routers ────────────────────────────────────────────────────────────────
# API namespace: /dm/ — see CLAUDE.md Section 3
app.include_router(core.router,     prefix="/dm/core",     tags=["Documents"])
app.include_router(flux.router,     prefix="/dm/flux",     tags=["Pipeline"])
app.include_router(mind.router,     prefix="/dm/mind",     tags=["LLM"])
app.include_router(bridge.router,   prefix="/dm/bridge",   tags=["Connectors"])
app.include_router(sentinel.router, prefix="/dm/sentinel", tags=["Health"])
app.include_router(vault.router,    prefix="/dm/vault",    tags=["Auth & Config"])


@app.get("/")
async def root():
    return {
        "service": "DocMaster dm-core",
        "version": settings.dm_version,
        "node": settings.dm_node,
        "status": "running",
    }
