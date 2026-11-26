-- =============================================================================
-- FILE: 04-native.sql
-- =============================================================================
-- The real table: audit-ingest.timer loads new events every 60 s.
--   audit_native.events        same columns and types as audit_fdw.events
--   audit_native.events_stage  per-run landing table (text, like the FDW)
--   audit_native.ingest_log    one row per ingest run
--   audit_native.ingest_lag    how far behind the table is right now
-- Idempotent: IF NOT EXISTS throughout, so a re-run keeps loaded data. That
-- also means a re-run keeps the columns the table was first created with;
-- after a change to audit_fdw.event_t, rebuild the server (destroy/apply).
-- =============================================================================

\set ON_ERROR_STOP 1
\connect auditdb

CREATE TABLE IF NOT EXISTS audit_native.events (
  LIKE audit_fdw.event_t,
  -- serial resets at boot, so it is unique only together with the time.
  -- The constraint is what makes a duplicate load impossible; leading with
  -- serial also serves single-event lookups.
  CONSTRAINT events_serial_time_key UNIQUE (serial, event_time)
);

-- The two secondary indexes the selective queries need: a time window and
-- a watch key. bench/run_bench.sh measures the same set (plus serial).
CREATE INDEX IF NOT EXISTS events_event_time_idx
  ON audit_native.events (event_time);
CREATE INDEX IF NOT EXISTS events_key_idx
  ON audit_native.events (key);

CREATE UNLOGGED TABLE IF NOT EXISTS audit_native.events_stage
  (LIKE audit_fdw.events_csv);

CREATE TABLE IF NOT EXISTS audit_native.ingest_log (
  run_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_at           timestamptz NOT NULL DEFAULT now(),
  rows_loaded      bigint NOT NULL,
  rows_skipped_dup bigint NOT NULL DEFAULT 0,
  duration_ms      bigint NOT NULL,
  max_event_time   timestamptz,
  exit_code        int NOT NULL,
  note             text
);

CREATE OR REPLACE VIEW audit_native.ingest_lag AS
  SELECT now() AS checked_at,
         (SELECT max(run_at) FROM audit_native.ingest_log) AS last_ingest,
         (SELECT max(event_time) FROM audit_native.events) AS newest_native,
         now() - (SELECT max(event_time) FROM audit_native.events)
           AS native_behind_by;

GRANT SELECT ON audit_native.events, audit_native.ingest_log,
                audit_native.ingest_lag TO audit_reader;
