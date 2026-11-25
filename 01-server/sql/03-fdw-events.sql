-- =============================================================================
-- FILE: 03-fdw-events.sql
-- =============================================================================
-- The ausearch layer: auparse correlates the records of each event and
-- normalizes them (subject, action, object, result), so one row = one event.
--   audit_fdw.events    raw ausearch CSV, every column text
--   audit_fdw.event_t   the typed row shape, shared with audit_native.events
--   audit_fdw.to_event  text row -> typed row (the ONE place casts live)
--   audit_fdw.events_v  typed view
-- =============================================================================

\set ON_ERROR_STOP 1
\connect auditdb

-- -----------------------------------------------------------------------------
-- events: every column text. PostgreSQL 18's on_error 'ignore' covers only
-- type-conversion errors, not a wrong column count, so casting is deferred
-- to the view where a bad value fails one query visibly instead of being
-- skipped.
-- -----------------------------------------------------------------------------
DROP FOREIGN TABLE IF EXISTS audit_fdw.events CASCADE;
CREATE FOREIGN TABLE audit_fdw.events (
  node text, event text, date text, "time" text, year text, month text,
  day text, weekday text, hour text, milli text, gmt_offset text,
  serial_num text, event_kind text, session text, subj_prime text,
  subj_sec text, subj_kind text, action text, result text, obj_prime text,
  obj_sec text, obj2 text, obj_kind text, how text, key text)
  SERVER audit_files
  OPTIONS (program '/usr/local/lib/audit-fdw/events /var/log/audit',
           format 'csv', quote E'\x01');

-- -----------------------------------------------------------------------------
-- event_t: names follow ausearch's normalizer (see ausearch --format csv):
--   subj_prime  the login user (auid) behind the action, "system" if unset
--   subj_sec    the user the process ran as (uid)
--   obj_prime   the main object (file path), obj2 the second (rename target)
-- -----------------------------------------------------------------------------
DROP TYPE IF EXISTS audit_fdw.event_t CASCADE;
CREATE TYPE audit_fdw.event_t AS (
  event_time timestamptz, serial bigint, node text, event_type text,
  event_kind text, session text, subj_prime text, subj_sec text,
  subj_kind text, action text, result text, obj_prime text, obj_sec text,
  obj2 text, obj_kind text, how text, key text);

-- -----------------------------------------------------------------------------
-- to_event: DATE/TIME are local time; the timestamp is rebuilt from the
-- --extra-time columns with ausearch's own GMT_OFFSET, so it is exact in any
-- server time zone (verified: TZ=America/Chicago prints -06:00).
-- MILLI is printed without zero padding, hence lpad.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit_fdw.to_event(e audit_fdw.events)
RETURNS audit_fdw.event_t
LANGUAGE sql STABLE PARALLEL SAFE
AS $$
  SELECT ROW(
    (e.year || '-' || e.month || '-' || e.day || ' ' || e."time" || '.' ||
     lpad(e.milli, 3, '0') || e.gmt_offset)::timestamptz,
    e.serial_num::bigint, e.node, e.event, e.event_kind, e.session,
    e.subj_prime, e.subj_sec, e.subj_kind, e.action, e.result, e.obj_prime,
    e.obj_sec, e.obj2, e.obj_kind, e.how, e.key)::audit_fdw.event_t
$$;

CREATE OR REPLACE VIEW audit_fdw.events_v AS
  SELECT t.*
  FROM audit_fdw.events AS e,
       LATERAL audit_fdw.to_event(e) AS t;

GRANT SELECT ON audit_fdw.events, audit_fdw.events_v TO audit_reader;
GRANT EXECUTE ON FUNCTION audit_fdw.to_event(audit_fdw.events)
  TO audit_reader;
