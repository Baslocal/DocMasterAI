"""
DocMaster — dm-core Configuration
Reads from /opt/docmaster/config/dm.env (mode 600, sourced by systemd EnvironmentFile=)
"""
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file="/opt/docmaster/config/dm.env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    # ── Application Identity ──────────────────────────────────────────────
    dm_version: str = "1.0.0"
    dm_build: str = ""
    dm_node: str = "docmaster-node-01"

    # ── API / Server ──────────────────────────────────────────────────────
    dm_host: str = "0.0.0.0"
    dm_port: int = 8443
    dm_workers: int = 1

    # ── Database ──────────────────────────────────────────────────────────
    db_host: str = "127.0.0.1"
    db_port: int = 5432
    db_name: str = "dm_vault"
    db_user: str = "dm_app"
    db_password: str = ""
    db_pool_min_size: int = 2
    db_pool_max_size: int = 10

    # ── Redis ─────────────────────────────────────────────────────────────
    redis_host: str = "127.0.0.1"
    redis_port: int = 6379
    redis_password: str = ""
    redis_db: int = 0

    # ── Ollama ────────────────────────────────────────────────────────────
    ollama_host: str = "http://127.0.0.1:11434"
    llm_primary_model: str = "llama3.1:8b-q4_K_M"
    embedding_model: str = "nomic-embed-text"

    # ── JWT / Security ────────────────────────────────────────────────────
    jwt_private_key_path: str = "/opt/docmaster/config/jwt_private.pem"
    jwt_public_key_path: str = "/opt/docmaster/config/jwt_public.pem"
    jwt_algorithm: str = "RS256"
    session_timeout: int = 3600

    # ── Paths ─────────────────────────────────────────────────────────────
    install_path: str = "/opt/docmaster"
    schemas_path: str = "/opt/docmaster/config/schemas"
    classifier_model_path: str = "/opt/docmaster/models/classifier/doc_classifier_v1.onnx"
    vault_path: str = "/opt/docmaster/vault"
    tmp_path: str = "/opt/docmaster/tmp"

    @property
    def db_dsn(self) -> str:
        return (
            f"postgresql+asyncpg://{self.db_user}:{self.db_password}"
            f"@{self.db_host}:{self.db_port}/{self.db_name}"
        )

    @property
    def db_dsn_sync(self) -> str:
        return (
            f"postgresql://{self.db_user}:{self.db_password}"
            f"@{self.db_host}:{self.db_port}/{self.db_name}"
        )

    @property
    def redis_url(self) -> str:
        if self.redis_password:
            return f"redis://:{self.redis_password}@{self.redis_host}:{self.redis_port}/{self.redis_db}"
        return f"redis://{self.redis_host}:{self.redis_port}/{self.redis_db}"


settings = Settings()
