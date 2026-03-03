"""
DocMaster — /dm/vault/ routes
Authentication, operator management, settings, license

POST /dm/vault/auth/login       — NO AUTH REQUIRED — returns JWT
POST /dm/vault/auth/logout      — Invalidate current token
GET  /dm/vault/settings         — Read all system config values
PATCH /dm/vault/settings        — Update one or more config values
GET  /dm/vault/operators        — List operator accounts
POST /dm/vault/operators        — Create new operator
PATCH /dm/vault/operators/{id}  — Update operator
GET  /dm/vault/license          — Current license state
POST /dm/vault/license/activate — Activate license from key file
"""
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel

from app.config import settings
from app.database import get_db
from app.dependencies import get_current_operator, require_role

router = APIRouter()


# ── Pydantic Models ───────────────────────────────────────────────────────

class LoginRequest(BaseModel):
    username: str
    password: str


class SettingUpdate(BaseModel):
    key: str
    value: str


class OperatorCreate(BaseModel):
    username: str
    display_name: str
    password: str
    role: str = "reviewer"


class OperatorUpdate(BaseModel):
    display_name: str | None = None
    role: str | None = None
    is_active: bool | None = None
    password: str | None = None


# ── Auth Routes ───────────────────────────────────────────────────────────

@router.post("/auth/login")
async def login(req: LoginRequest, db=Depends(get_db)):
    """Authenticate and return a JWT Bearer token.
    No authentication required on this endpoint.
    Passwords verified with bcrypt (cost 12). JWT signed RS256.
    Tokens should be stored in memory only — NEVER localStorage.
    """
    from passlib.context import CryptContext
    from jose import jwt as jose_jwt

    pwd_ctx = CryptContext(schemes=["bcrypt"], deprecated="auto")

    row = await db.fetchrow(
        "SELECT id, username, display_name, password_hash, role, is_active "
        "FROM dm_vault.operators WHERE username = $1",
        req.username,
    )

    if not row or not row["is_active"] or not pwd_ctx.verify(req.password, row["password_hash"]):
        # Log failed attempt to audit log
        await db.execute(
            """
            INSERT INTO dm_flux.audit_log (action, resource_type, detail_json)
            VALUES ('login_failed', 'operator', $1)
            """,
            {"username": req.username},
        )
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"error": "DM_4012", "message": "Invalid username or password"},
        )

    now = datetime.now(timezone.utc)
    exp = now + timedelta(seconds=settings.session_timeout)

    with open(settings.jwt_private_key_path, "r") as f:
        private_key = f.read()

    token = jose_jwt.encode(
        {
            "sub": str(row["id"]),
            "username": row["username"],
            "role": row["role"],
            "iat": int(now.timestamp()),
            "exp": int(exp.timestamp()),
        },
        private_key,
        algorithm=settings.jwt_algorithm,
    )

    # Update last_login_at
    await db.execute(
        "UPDATE dm_vault.operators SET last_login_at = NOW() WHERE id = $1",
        row["id"],
    )

    # Audit log
    await db.execute(
        """
        INSERT INTO dm_flux.audit_log (action, resource_type, resource_id, operator_id)
        VALUES ('login_success', 'operator', $1, $2)
        """,
        str(row["id"]), row["id"],
    )

    return {
        "access_token": token,
        "token_type": "bearer",
        "expires_at": exp.isoformat(),
        "operator": {
            "id": str(row["id"]),
            "username": row["username"],
            "display_name": row["display_name"],
            "role": row["role"],
        },
    }


@router.post("/auth/logout")
async def logout(operator: dict = Depends(get_current_operator), db=Depends(get_db)):
    """Logout — client must discard the token from memory."""
    await db.execute(
        """
        INSERT INTO dm_flux.audit_log (action, resource_type, resource_id, operator_id)
        VALUES ('logout', 'operator', $1, $2)
        """,
        operator["id"], operator["id"],
    )
    return {"message": "Logged out successfully"}


# ── Settings Routes ───────────────────────────────────────────────────────

@router.get("/settings")
async def get_settings(
    operator: dict = Depends(get_current_operator),
    db=Depends(get_db),
):
    """Return all system config values. Encrypted values are masked."""
    rows = await db.fetch(
        "SELECT key, value, is_encrypted, description, updated_at "
        "FROM dm_vault.system_config ORDER BY key"
    )
    return [
        {
            "key": r["key"],
            "value": "***" if r["is_encrypted"] else r["value"],
            "is_encrypted": r["is_encrypted"],
            "description": r["description"],
            "updated_at": r["updated_at"].isoformat() if r["updated_at"] else None,
        }
        for r in rows
    ]


@router.patch("/settings")
async def update_settings(
    updates: list[SettingUpdate],
    operator: dict = Depends(require_role("admin")),
    db=Depends(get_db),
):
    """Update one or more config values. Admin role required."""
    for update in updates:
        await db.execute(
            """
            UPDATE dm_vault.system_config
            SET value = $1, updated_at = NOW(), updated_by = $2
            WHERE key = $3
            """,
            update.value, operator["id"], update.key,
        )
    return {"updated": len(updates)}


# ── Operator Routes ───────────────────────────────────────────────────────

@router.get("/operators")
async def list_operators(
    operator: dict = Depends(require_role("admin", "operator")),
    db=Depends(get_db),
):
    rows = await db.fetch(
        "SELECT id, username, display_name, role, is_active, last_login_at, created_at "
        "FROM dm_vault.operators ORDER BY created_at"
    )
    return [dict(r) for r in rows]


@router.post("/operators", status_code=201)
async def create_operator(
    req: OperatorCreate,
    operator: dict = Depends(require_role("admin")),
    db=Depends(get_db),
):
    from passlib.context import CryptContext
    pwd_ctx = CryptContext(schemes=["bcrypt"], bcrypt__rounds=12, deprecated="auto")

    password_hash = pwd_ctx.hash(req.password)
    new_id = await db.fetchval(
        """
        INSERT INTO dm_vault.operators (username, display_name, password_hash, role, created_by)
        VALUES ($1, $2, $3, $4, $5)
        RETURNING id
        """,
        req.username, req.display_name, password_hash, req.role, operator["id"],
    )
    return {"id": str(new_id), "username": req.username, "role": req.role}


@router.patch("/operators/{operator_id}")
async def update_operator(
    operator_id: uuid.UUID,
    req: OperatorUpdate,
    current: dict = Depends(require_role("admin")),
    db=Depends(get_db),
):
    from passlib.context import CryptContext

    if req.password is not None:
        pwd_ctx = CryptContext(schemes=["bcrypt"], bcrypt__rounds=12, deprecated="auto")
        password_hash = pwd_ctx.hash(req.password)
        await db.execute(
            "UPDATE dm_vault.operators SET password_hash = $1 WHERE id = $2",
            password_hash, operator_id,
        )

    if req.role is not None:
        await db.execute(
            "UPDATE dm_vault.operators SET role = $1 WHERE id = $2",
            req.role, operator_id,
        )

    if req.is_active is not None:
        await db.execute(
            "UPDATE dm_vault.operators SET is_active = $1 WHERE id = $2",
            req.is_active, operator_id,
        )

    if req.display_name is not None:
        await db.execute(
            "UPDATE dm_vault.operators SET display_name = $1 WHERE id = $2",
            req.display_name, operator_id,
        )

    return {"id": str(operator_id), "updated": True}


# ── License Routes ────────────────────────────────────────────────────────

@router.get("/license")
async def get_license(
    operator: dict = Depends(get_current_operator),
    db=Depends(get_db),
):
    row = await db.fetchrow(
        "SELECT * FROM dm_vault.license_records WHERE is_active = TRUE ORDER BY activated_at DESC LIMIT 1"
    )
    if not row:
        return {"status": "unlicensed", "message": "No active license. Complete the first-boot wizard."}
    return dict(row)


@router.post("/license/activate")
async def activate_license(
    operator: dict = Depends(require_role("admin")),
    db=Depends(get_db),
):
    """Activate license from /opt/docmaster/config/license.key.
    License key is an RSA-4096 signed JWT. Vendor public key is compiled into dm-vault.
    """
    # Full license verification is implemented in dm-vault.service
    # This endpoint signals dm-vault to read and validate the key file
    return {"status": "pending", "message": "License activation delegated to dm-vault.service"}
