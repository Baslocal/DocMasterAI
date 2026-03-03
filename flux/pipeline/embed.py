"""
DocMaster — Stage 5: Vector Indexing
Chunks OCR text and generates 768-dim embeddings via nomic-embed-text.

IVFFlat index NOTE: the index is NOT built here. The dm-sentinel cron
monitors embedding row count and builds the IVFFlat index only after
≥3,900 rows exist. Do not trigger index creation from this module.
"""
import uuid
from typing import Optional

import asyncpg
import httpx


async def run_embedding(
    ocr_text: str,
    document_id: uuid.UUID,
    db_pool: asyncpg.Pool,
    ollama_host: str,
    embedding_model: str,
    chunk_size: int = 512,
    chunk_overlap: int = 64,
) -> int:
    """
    Split OCR text into chunks, embed each chunk, and upsert to dm_core.embeddings.

    Returns number of chunks indexed.
    On embedding failure, logs warning and continues — document remains usable
    but will not appear in semantic search results.
    """
    if not ocr_text or not ocr_text.strip():
        return 0

    try:
        chunks = _split_text(ocr_text, chunk_size=chunk_size, chunk_overlap=chunk_overlap)
        if not chunks:
            return 0

        async with db_pool.acquire() as db:
            for idx, chunk in enumerate(chunks):
                embedding = await _embed_chunk(chunk, ollama_host, embedding_model)
                if embedding is None:
                    continue

                await db.execute(
                    """
                    INSERT INTO dm_core.embeddings (document_id, chunk_index, chunk_text, embedding)
                    VALUES ($1, $2, $3, $4::vector)
                    ON CONFLICT (document_id, chunk_index) DO UPDATE
                        SET chunk_text = EXCLUDED.chunk_text,
                            embedding = EXCLUDED.embedding
                    """,
                    document_id, idx, chunk, str(embedding),
                )

        return len(chunks)

    except Exception as e:
        # Embedding failure is non-fatal — log and continue
        import structlog
        log = structlog.get_logger("dm-flux")
        log.warning("dm_flux_embed_failed", document_id=str(document_id), error=str(e))
        return 0


def _split_text(text: str, chunk_size: int = 512, chunk_overlap: int = 64) -> list[str]:
    """Split text using RecursiveCharacterTextSplitter with tiktoken length function."""
    try:
        from langchain.text_splitter import RecursiveCharacterTextSplitter
        import tiktoken

        encoder = tiktoken.get_encoding("cl100k_base")
        splitter = RecursiveCharacterTextSplitter(
            chunk_size=chunk_size,
            chunk_overlap=chunk_overlap,
            length_function=lambda t: len(encoder.encode(t)),
            separators=["\n\n", "\n", ". ", " ", ""],
        )
        return splitter.split_text(text)
    except Exception:
        # Fallback: simple character splitting
        chunks = []
        step = chunk_size - chunk_overlap
        for i in range(0, len(text), step):
            chunks.append(text[i:i + chunk_size])
        return chunks


async def _embed_chunk(chunk_text: str, ollama_host: str, model: str) -> Optional[list[float]]:
    """Generate embedding for a single text chunk via Ollama API."""
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            resp = await client.post(
                f"{ollama_host}/api/embeddings",
                json={"model": model, "prompt": chunk_text},
            )
        if resp.status_code == 200:
            return resp.json().get("embedding")
    except Exception:
        pass
    return None
