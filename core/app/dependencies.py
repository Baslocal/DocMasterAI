"""
DocMaster — dm-core FastAPI Dependencies
JWT auth, DB connection injection, role enforcement
"""
from __future__ import annotations

import uuid
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jose import JWTError, jwt

from app.config import settings
from app.database import get_db

security = HTTPBearer()


def _load_public_key() -> str:
    try:
        with open(settings.jwt_public_key_path, "r") as f:
            return f.read()
    except FileNotFoundError:
        raise RuntimeError(
            f"DM_5010: JWT public key not found at {settings.jwt_public_key_path}. "
            "Run the first-boot wizard to generate keys."
        )


async def get_current_operator(
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db=Depends(get_db),
) -> dict:
    """Validate JWT Bearer token and return the operator record.

    Tokens are stored in memory only — never localStorage.
    RS256 algorithm, public key loaded from /opt/docmaster/config/jwt_public.pem.
    """
    token = credentials.credentials
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail={"error": "DM_4011", "message": "Invalid or expired token"},
        headers={"WWW-Authenticate": "Bearer"},
    )

    try:
        public_key = _load_public_key()
        payload = jwt.decode(
            token,
            public_key,
            algorithms=[settings.jwt_algorithm],
        )
        operator_id: str | None = payload.get("sub")
        if operator_id is None:
            raise credentials_exception
    except JWTError:
        raise credentials_exception

    row = await db.fetchrow(
        """
        SELECT id, username, display_name, role, is_active
        FROM dm_vault.operators
        WHERE id = $1
        """,
        uuid.UUID(operator_id),
    )

    if row is None or not row["is_active"]:
        raise credentials_exception

    return dict(row)


def require_role(*roles: str):
    """Role-based access control dependency factory."""

    async def _check(operator: dict = Depends(get_current_operator)) -> dict:
        if operator["role"] not in roles:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail={
                    "error": "DM_4031",
                    "message": f"Requires one of: {', '.join(roles)}",
                },
            )
        return operator

    return _check
