"""
DocMaster — dm-core Middleware
- Injects X-DM-Build, X-DM-Node, X-DM-Version response headers
- Converts unhandled exceptions to DM_ error codes (no raw stack traces to clients)
"""
import traceback

import structlog
from fastapi import Request, Response
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

from app.config import settings

logger = structlog.get_logger("dm-core")


class DMHeadersMiddleware(BaseHTTPMiddleware):
    """Add DocMaster response headers to every API response."""

    async def dispatch(self, request: Request, call_next) -> Response:
        response = await call_next(request)
        response.headers["X-DM-Version"] = settings.dm_version
        response.headers["X-DM-Build"] = settings.dm_build
        response.headers["X-DM-Node"] = settings.dm_node
        return response


class DMErrorMiddleware(BaseHTTPMiddleware):
    """Catch unhandled exceptions and return sanitized DM_ error responses.

    STRICT RULE: Never expose raw stack traces to the UI or API responses.
    Stack traces are logged internally but never sent to the client.
    """

    async def dispatch(self, request: Request, call_next) -> Response:
        try:
            return await call_next(request)
        except Exception as exc:
            # Log full traceback internally
            logger.error(
                "dm_unhandled_exception",
                path=request.url.path,
                method=request.method,
                error=str(exc),
                traceback=traceback.format_exc(),
            )
            # Return sanitized error — no stack trace to client
            return JSONResponse(
                status_code=500,
                content={
                    "error": "DM_5000",
                    "message": "An internal error occurred. Check dm-core logs for details.",
                },
            )
