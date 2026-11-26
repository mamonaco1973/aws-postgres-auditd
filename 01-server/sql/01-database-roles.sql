-- =============================================================================
-- FILE: 01-database-roles.sql
-- =============================================================================
-- Database, roles, extension and schemas. Run as the postgres superuser:
--   psql -v postgres_password=... -v audit_reader_password=... -f this
-- Idempotent: every object is created only if missing, passwords are reset.
-- =============================================================================

\set ON_ERROR_STOP 1

-- -----------------------------------------------------------------------------
-- Database
-- -----------------------------------------------------------------------------
SELECT 'CREATE DATABASE auditdb'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'auditdb')
\gexec

-- -----------------------------------------------------------------------------
-- Roles
-- -----------------------------------------------------------------------------
-- postgres keeps superuser: file_fdw's "program" option needs
-- pg_execute_server_program, and the foreign tables and SECURITY DEFINER
-- functions are owned by it.
-- audit_reader is what pgweb users sign in as: SELECT on the two tables
-- being compared and their bookkeeping views, nothing else.
-- -----------------------------------------------------------------------------
SELECT 'CREATE ROLE audit_reader LOGIN'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'audit_reader')
\gexec

SELECT format('ALTER ROLE postgres PASSWORD %L', :'postgres_password') \gexec
SELECT format('ALTER ROLE audit_reader PASSWORD %L', :'audit_reader_password')
\gexec

-- An FDW scan holds the shared rotation lock for its whole duration;
-- cap it so a forgotten query in pgweb can't block rotation indefinitely.
ALTER ROLE audit_reader SET statement_timeout = '5min';

REVOKE ALL ON DATABASE auditdb FROM PUBLIC;
GRANT CONNECT ON DATABASE auditdb TO audit_reader;

\connect auditdb

-- -----------------------------------------------------------------------------
-- file_fdw and its server
-- -----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS file_fdw;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_foreign_server WHERE srvname = 'audit_files')
  THEN
    CREATE SERVER audit_files FOREIGN DATA WRAPPER file_fdw;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- Schemas
-- -----------------------------------------------------------------------------
-- audit_fdw     the virtual table: reads the log files on every query
-- audit_native  the real table: ingested every 60 s, indexed
-- audit_bench   benchmark objects (postgres only; created by run_bench.sh)
-- -----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS audit_fdw;
CREATE SCHEMA IF NOT EXISTS audit_native;
CREATE SCHEMA IF NOT EXISTS audit_bench;

REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA audit_fdw, audit_native TO audit_reader;
