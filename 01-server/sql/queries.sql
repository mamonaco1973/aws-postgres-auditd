-- =============================================================================
-- FILE: queries.sql   ("Try it" walkthrough; also in README.md)
-- =============================================================================
-- Run in pgweb as audit_reader, database auditdb. Two tables, same columns:
--   audit_fdw.events     virtual: rebuilt from the log files on every query
--   audit_native.events  real: loaded every 60 s, indexed
-- Steps 3 and 4 also need a shell on the server (aws ssm start-session);
-- those commands are in the comments.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. The files the virtual table reads. Oldest first: compressed history,
--    the uncompressed .1 left by the last rotation, and the active audit.log.
--    Nothing has been loaded anywhere: this is a listing of /var/log/audit.
-- -----------------------------------------------------------------------------
SELECT * FROM audit_fdw.log_files;


-- -----------------------------------------------------------------------------
-- 2. Who did what in /data, straight from those files. who is the login
--    user, file the object, new_value a rename target or new mode/owner.
-- -----------------------------------------------------------------------------
SELECT event_time, who, action, result, file, new_value
FROM audit_fdw.events
WHERE key = 'data_watch'
ORDER BY event_time DESC
LIMIT 20;


-- -----------------------------------------------------------------------------
-- 3. Freshness. On the server, make an event:
--      sudo bash /opt/aws-postgres-auditd/01-server/bench/generate_events.sh \
--        --rounds 1
--    then run these right away and again a minute later. The virtual table
--    has the new rows at once; the real one gets them at the next ingest,
--    within 60 s.
-- -----------------------------------------------------------------------------
SELECT 'virtual' AS side, count(*) AS events, max(event_time) AS newest
FROM audit_fdw.events
UNION ALL
SELECT 'real', count(*), max(event_time)
FROM audit_native.events;

-- how far behind the real table is, and its recent ingest runs
SELECT * FROM audit_native.ingest_lag;

SELECT run_at, rows_loaded, rows_skipped_dup, duration_ms, max_event_time,
       exit_code, note
FROM audit_native.ingest_log
ORDER BY run_id DESC
LIMIT 5;


-- -----------------------------------------------------------------------------
-- 4. Rotation. Run this, then on the server:
--      sudo audit-rotate
--    then step 1 (the chain shifted by one: .1 became .2.gz) and this again.
--    The counts are unchanged: the virtual table reads the .gz files like
--    the active one, and audit-rotate ingests before it compresses.
-- -----------------------------------------------------------------------------
SELECT 'virtual' AS side, count(*) AS data_watch_events
FROM audit_fdw.events WHERE key = 'data_watch'
UNION ALL
SELECT 'real', count(*)
FROM audit_native.events WHERE key = 'data_watch';


-- -----------------------------------------------------------------------------
-- 5. The same selective query on both. The virtual table's Foreign Scan
--    runs the wrapper over every file and filters afterwards ("Rows Removed
--    by Filter": file_fdw has no pushdown). The real table uses an index.
-- -----------------------------------------------------------------------------
EXPLAIN ANALYZE
SELECT * FROM audit_fdw.events
WHERE key = 'data_watch' AND event_time >= now() - interval '1 hour';

EXPLAIN ANALYZE
SELECT * FROM audit_native.events
WHERE key = 'data_watch' AND event_time >= now() - interval '1 hour';
