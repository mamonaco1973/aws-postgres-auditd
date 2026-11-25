-- =============================================================================
-- FILE: 04-search-function.sql
-- =============================================================================
-- search_events(ts_from, ts_to, key): filtering INSIDE ausearch (-ts/-te/-k)
-- instead of in SQL. file_fdw can't push a WHERE clause down to the program,
-- so this function builds the ausearch command itself and runs it with
-- COPY ... FROM PROGRAM into a temporary table. It exists to measure that
-- pushdown gap.
--
-- Shell safety: nothing caller-supplied reaches the command line as text.
--   - key must match ^[A-Za-z0-9_-]{1,64}$
--   - timestamps are rendered only by to_char (digits, '/', ':', ' ')
--   - dir is one of two allowed shapes
-- The events wrapper re-validates all of it.
-- =============================================================================

\set ON_ERROR_STOP 1
\connect auditdb

-- -----------------------------------------------------------------------------
-- search_events_in: the worker, also used by the benchmarks on the corpora.
-- ausearch -ts/-te have one-second resolution and are read in local time
-- (the wrapper sets TZ=UTC), so the window is widened to whole seconds for
-- ausearch and then applied exactly, as [ts_from, ts_to), in SQL.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit_fdw.search_events_in(
  dir text, ts_from timestamptz, ts_to timestamptz, key text DEFAULT NULL)
RETURNS SETOF audit_fdw.event_t
LANGUAGE plpgsql VOLATILE SECURITY DEFINER ROWS 1000
SET search_path = pg_catalog, pg_temp
SET client_min_messages = warning
AS $$
DECLARE
  cmd text;
BEGIN
  IF dir IS NULL OR NOT (dir = '/var/log/audit'
                         OR dir ~ '^/bench/corpus/[A-Za-z0-9_]+$') THEN
    RAISE EXCEPTION 'directory not allowed: %', dir;
  END IF;
  IF ts_from IS NULL OR ts_to IS NULL OR ts_from >= ts_to THEN
    RAISE EXCEPTION 'need ts_from < ts_to';
  END IF;
  IF search_events_in.key IS NOT NULL
     AND search_events_in.key !~ '^[A-Za-z0-9_-]{1,64}$' THEN
    RAISE EXCEPTION 'key must match ^[A-Za-z0-9_-]{1,64}$';
  END IF;

  cmd := '/usr/local/lib/audit-fdw/events ' || dir
      || ' -ts ' || to_char(ts_from AT TIME ZONE 'UTC',
                            'MM/DD/YY HH24:MI:SS')
      || ' -te ' || to_char(ts_to AT TIME ZONE 'UTC' + interval '1 second',
                            'MM/DD/YY HH24:MI:SS')
      || coalesce(' -k ' || search_events_in.key, '');

  DROP TABLE IF EXISTS pg_temp.search_buf;
  CREATE TEMP TABLE search_buf (LIKE audit_fdw.events);
  EXECUTE format('COPY pg_temp.search_buf FROM PROGRAM %L '
                 'WITH (format csv, quote %L)', cmd, E'\x01');

  RETURN QUERY
    SELECT t.*
    FROM pg_temp.search_buf AS s,
         LATERAL audit_fdw.to_event(ROW(s.*)::audit_fdw.events) AS t
    WHERE t.event_time >= ts_from AND t.event_time < ts_to
      AND (search_events_in.key IS NULL OR t.key = search_events_in.key);

  DROP TABLE pg_temp.search_buf;
END $$;

-- -----------------------------------------------------------------------------
-- search_events: the public entry point, live logs only.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit_fdw.search_events(
  ts_from timestamptz, ts_to timestamptz, key text DEFAULT NULL)
RETURNS SETOF audit_fdw.event_t
LANGUAGE sql VOLATILE SECURITY DEFINER ROWS 1000
SET search_path = pg_catalog
AS $$
  SELECT * FROM audit_fdw.search_events_in('/var/log/audit', ts_from, ts_to,
                                           key)
$$;

REVOKE ALL ON FUNCTION
  audit_fdw.search_events_in(text, timestamptz, timestamptz, text),
  audit_fdw.search_events(timestamptz, timestamptz, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  audit_fdw.search_events(timestamptz, timestamptz, text) TO audit_reader;
