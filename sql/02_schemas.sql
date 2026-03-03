-- DocMaster — Phase 2: Schema Creation and Role Grants
-- Database: dm_vault
-- Role: dm_app (LOGIN, no superuser, no createdb)
--
-- STRICT RULE: Never create tables outside these four schemas.

-- Create schemas
CREATE SCHEMA IF NOT EXISTS dm_core;
CREATE SCHEMA IF NOT EXISTS dm_flux;
CREATE SCHEMA IF NOT EXISTS dm_sentinel;
CREATE SCHEMA IF NOT EXISTS dm_vault;

-- Grant schema usage to dm_app role
GRANT USAGE ON SCHEMA dm_core     TO dm_app;
GRANT USAGE ON SCHEMA dm_flux     TO dm_app;
GRANT USAGE ON SCHEMA dm_sentinel TO dm_app;
GRANT USAGE ON SCHEMA dm_vault    TO dm_app;

-- Grant default privileges for future objects created in each schema
ALTER DEFAULT PRIVILEGES IN SCHEMA dm_core
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO dm_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA dm_flux
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO dm_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA dm_sentinel
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO dm_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA dm_vault
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO dm_app;

ALTER DEFAULT PRIVILEGES IN SCHEMA dm_core
    GRANT USAGE, SELECT ON SEQUENCES TO dm_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA dm_flux
    GRANT USAGE, SELECT ON SEQUENCES TO dm_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA dm_sentinel
    GRANT USAGE, SELECT ON SEQUENCES TO dm_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA dm_vault
    GRANT USAGE, SELECT ON SEQUENCES TO dm_app;
