"""
DocMaster — dm-core Database Connection Pool
asyncpg connection pool — PostgreSQL 16, db: dm_vault
"""
import asyncpg
from app.config import settings

_pool: asyncpg.Pool | None = None


async def get_pool() -> asyncpg.Pool:
    global _pool
    if _pool is None:
        _pool = await asyncpg.create_pool(
            dsn=(
                f"postgresql://{settings.db_user}:{settings.db_password}"
                f"@{settings.db_host}:{settings.db_port}/{settings.db_name}"
            ),
            min_size=settings.db_pool_min_size,
            max_size=settings.db_pool_max_size,
            command_timeout=30,
        )
    return _pool


async def close_pool() -> None:
    global _pool
    if _pool is not None:
        await _pool.close()
        _pool = None


async def get_db():
    """FastAPI dependency — yields a database connection from the pool."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        yield conn
