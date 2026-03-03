-- DocMaster — Phase 2: PostgreSQL Extensions
-- Must be run as superuser before creating schemas/tables
-- Database: dm_vault

CREATE EXTENSION IF NOT EXISTS vector;        -- pgvector: semantic search embeddings
CREATE EXTENSION IF NOT EXISTS pg_trgm;       -- trigram indexing: filename fuzzy search
CREATE EXTENSION IF NOT EXISTS unaccent;      -- unaccent: normalize diacritic characters in search

-- Verify extensions installed correctly
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector') THEN
        RAISE EXCEPTION 'DM_5001: pgvector extension not installed. Install postgresql-16-pgvector from PGDG.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm') THEN
        RAISE EXCEPTION 'DM_5002: pg_trgm extension not installed.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'unaccent') THEN
        RAISE EXCEPTION 'DM_5003: unaccent extension not installed.';
    END IF;
END $$;
