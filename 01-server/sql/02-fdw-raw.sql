-- =============================================================================
-- FILE: 02-fdw-raw.sql
-- =============================================================================
-- The raw layer: the log files themselves, one row per audit record, parsed
-- with regular expressions. No ausearch involved.
--   audit_fdw.log_files    inventory of the chain, oldest first
--   audit_fdw.raw_records  every raw line, oldest file to newest
--   audit_fdw.records      the same lines, parsed
-- =============================================================================

\set ON_ERROR_STOP 1
\connect auditdb

-- =============================================================================
-- log_files
-- =============================================================================
-- pg_ls_dir on an absolute path needs pg_read_server_files, which would let
-- audit_reader read ANY file the server can. Instead a SECURITY DEFINER
-- function lists exactly two kinds of directory and nothing else.
-- The ordering matches list_files in /usr/local/lib/audit-fdw/common.sh.
-- =============================================================================

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

REVOKE ALL ON FUNCTION audit_fdw.list_log_files(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION audit_fdw.list_log_files(text) TO audit_reader;

CREATE OR REPLACE VIEW audit_fdw.log_files AS
  SELECT * FROM audit_fdw.list_log_files('/var/log/audit');

-- =============================================================================
-- raw_records
-- =============================================================================
-- One text column per line. CSV mode with a delimiter and quote that never
-- occur in audit logs, because text mode would treat backslashes as escapes.
-- (0x1d does occur: it separates the kernel fields from auditd's ENRICHED
-- ones, so it can't be the delimiter.)
-- =============================================================================

DROP FOREIGN TABLE IF EXISTS audit_fdw.raw_records CASCADE;
CREATE FOREIGN TABLE audit_fdw.raw_records (line text)
  SERVER audit_files
  OPTIONS (program '/usr/local/lib/audit-fdw/raw-records /var/log/audit',
           format 'csv', delimiter E'\x1f', quote E'\x01');

-- =============================================================================
-- Parsing helpers
-- =============================================================================

-- -----------------------------------------------------------------------------
-- unhex(value): decode the kernel's hex encoding of "untrusted" strings
-- (names with spaces or non-ASCII, proctitle with NUL-separated argv).
-- NULs become spaces. Invalid UTF-8 falls back to bytea escape form instead
-- of failing the query; the exception block (a subtransaction) is entered
-- only when a high byte is present, so the common case stays cheap.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit_fdw.unhex(v text) RETURNS text
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
AS $$
DECLARE
  b bytea;
  p int;
BEGIN
  IF v !~ '^([0-9A-F]{2})+$' THEN
    RETURN v;
  END IF;
  b := decode(v, 'hex');
  LOOP
    p := position('\x00'::bytea IN b);
    EXIT WHEN p = 0;
    b := overlay(b PLACING '\x20'::bytea FROM p FOR 1);
  END LOOP;
  IF encode(b, 'escape') !~ '\\[23][0-7]{2}' THEN
    RETURN rtrim(convert_from(b, 'UTF8'));
  END IF;
  BEGIN
    RETURN rtrim(convert_from(b, 'UTF8'));
  EXCEPTION WHEN character_not_in_repertoire OR untranslatable_character THEN
    RETURN encode(b, 'escape');
  END;
END $$;

-- -----------------------------------------------------------------------------
-- parse_fields(rest): key=value pairs after the "msg=audit(...):" header,
-- as jsonb.
--   - 0x1d (start of the ENRICHED fields) is treated as a space
--   - msg='op=... res=success' (USER_* records) is unwrapped so its inner
--     pairs become top-level keys
--   - "double-quoted" values lose their quotes
--   - unquoted values of the keys the kernel hex-encodes are decoded
--   - a repeated key keeps its last value (jsonb semantics)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit_fdw.parse_fields(rest text) RETURNS jsonb
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$
  SELECT coalesce(jsonb_object_agg(m[1],
           CASE
             WHEN left(m[2], 1) = '"' THEN substr(m[2], 2, length(m[2]) - 2)
             WHEN m[1] IN ('name', 'proctitle', 'cwd', 'comm', 'exe', 'path',
                           'data', 'cmd', 'key', 'acct', 'old', 'new')
               THEN audit_fdw.unhex(m[2])
             ELSE m[2]
           END), '{}'::jsonb)
  FROM regexp_matches(
         translate(regexp_replace(rest, 'msg=''([^'']*)''', '\1'),
                   E'\x1d', ' '),
         '([A-Za-z0-9_-]+)=("[^"]*"|\S+)', 'g') AS m
$$;

-- -----------------------------------------------------------------------------
-- parse_record(line): split one raw line. A line that doesn't match still
-- comes back (all NULLs but raw_line), so nothing is silently dropped.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit_fdw.parse_record(line text)
RETURNS TABLE (record_type text, event_epoch numeric,
               event_time timestamptz, serial bigint, fields jsonb,
               raw_line text)
LANGUAGE sql STABLE PARALLEL SAFE
AS $$
  SELECT m[1], m[2]::numeric, to_timestamp(m[2]::numeric), m[3]::bigint,
         audit_fdw.parse_fields(m[4]), line
  FROM (SELECT regexp_match(line,
          '^type=(\S+) msg=audit\((\d+\.\d+):(\d+)\): ?(.*)$') AS m) AS x
$$;

-- =============================================================================
-- records
-- =============================================================================

CREATE OR REPLACE VIEW audit_fdw.records AS
  SELECT p.*
  FROM audit_fdw.raw_records AS r,
       LATERAL audit_fdw.parse_record(r.line) AS p;

GRANT SELECT ON audit_fdw.log_files, audit_fdw.raw_records, audit_fdw.records
  TO audit_reader;
GRANT EXECUTE ON FUNCTION audit_fdw.unhex(text),
                          audit_fdw.parse_fields(text),
                          audit_fdw.parse_record(text) TO audit_reader;
