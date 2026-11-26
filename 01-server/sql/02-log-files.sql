-- =============================================================================
-- FILE: 02-log-files.sql
-- =============================================================================
-- audit_fdw.log_files: the chain itself, oldest first. Nothing is loaded;
-- it lists /var/log/audit, so the walkthrough can show that the virtual
-- table reads rotated and compressed files as well as the active one.
-- =============================================================================

\set ON_ERROR_STOP 1
\connect auditdb

-- -----------------------------------------------------------------------------
-- pg_ls_dir on an absolute path needs pg_read_server_files, which would let
-- audit_reader read ANY file the server can. Instead a SECURITY DEFINER
-- function lists exactly two kinds of directory and nothing else.
-- The ordering matches list_files in /usr/local/lib/audit-fdw/common.sh.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit_fdw.list_log_files(
  dir text DEFAULT '/var/log/audit')
RETURNS TABLE (file_order int, name text, size_bytes bigint,
               modified timestamptz, compressed boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF dir IS NULL OR NOT (dir = '/var/log/audit'
                         OR dir ~ '^/bench/corpus/[A-Za-z0-9_]+$') THEN
    RAISE EXCEPTION 'directory not allowed: %', dir;
  END IF;
  RETURN QUERY
    SELECT (row_number() OVER (ORDER BY x.n DESC))::int,
           f, s.size, s.modification, f LIKE '%.gz'
    FROM pg_ls_dir(dir) AS f,
         LATERAL pg_stat_file(dir || '/' || f, true) AS s,
         LATERAL (SELECT coalesce(substring(f FROM '^audit\.log\.(\d+)')::int,
                                  0) AS n) AS x
    WHERE f ~ '^audit\.log(\.\d+(\.gz)?)?$'
      AND s.size IS NOT NULL          -- vanished mid-rotation
    ORDER BY 1;
END $$;

-- A view's caller still needs EXECUTE on the functions it calls.
REVOKE ALL ON FUNCTION audit_fdw.list_log_files(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION audit_fdw.list_log_files(text) TO audit_reader;

CREATE OR REPLACE VIEW audit_fdw.log_files AS
  SELECT * FROM audit_fdw.list_log_files('/var/log/audit');

GRANT SELECT ON audit_fdw.log_files TO audit_reader;
