-- =============================================================================
-- FILE: queries.sql   ("Try it" walkthrough; also in README.md)
-- =============================================================================
-- Run in pgweb as audit_reader, database auditdb. Steps 5 and 7 also need a
-- shell on the server (aws ssm start-session); those commands are in the
-- comments.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. The files. Oldest first: compressed history, the uncompressed .1 that
--    rotation leaves behind (delaycompress), and the active audit.log.
--    Nothing has been loaded anywhere: this is pg_ls_dir on /var/log/audit.
-- -----------------------------------------------------------------------------
SELECT * FROM audit_fdw.log_files;


-- -----------------------------------------------------------------------------
-- 2. Raw records of one rename. A single syscall is several records that
--    share one serial: SYSCALL, CWD, a PATH per name involved (four for a
--    rename: both parent directories and both names), PROCTITLE.
-- -----------------------------------------------------------------------------
SELECT record_type, event_time, serial, raw_line
FROM audit_fdw.records
WHERE serial = (SELECT serial FROM audit_fdw.records
                WHERE record_type = 'SYSCALL'
                  AND fields->>'SYSCALL' = 'renameat2'
                  AND fields->>'key' = 'data_watch'
                ORDER BY event_time DESC LIMIT 1)
ORDER BY record_type;


-- -----------------------------------------------------------------------------
-- 3. Correlating by hand: group the records of each event and collect their
--    parsed fields. This is the work auparse does for you in step 4.
-- -----------------------------------------------------------------------------
SELECT serial, min(event_time) AS event_time,
       jsonb_agg(jsonb_build_object('type', record_type) || fields
                 ORDER BY record_type) AS records
FROM audit_fdw.records
WHERE serial IN (SELECT serial FROM audit_fdw.records
                 WHERE fields->>'key' = 'data_watch')
GROUP BY serial
ORDER BY serial DESC
LIMIT 5;


-- -----------------------------------------------------------------------------
-- 4. The same events, one readable row each, through ausearch.
--    subj_prime is the login user, obj_prime the file, obj2 the rename
--    target (or new mode/owner for chmod/chown).
-- -----------------------------------------------------------------------------
SELECT event_time, serial, subj_prime AS who, action, result,
       obj_prime AS object, obj2
FROM audit_fdw.events_v
WHERE key = 'data_watch'
ORDER BY event_time DESC
LIMIT 20;


-- -----------------------------------------------------------------------------
-- 5. No ETL. On the server, make more events:
--      sudo bash /opt/aws-postgres-auditd/01-server/bench/generate_events.sh \
--        --rounds 2
--    then run step 4 again: the new rows are there immediately.
-- -----------------------------------------------------------------------------


-- -----------------------------------------------------------------------------
-- 6. Filter, sort, aggregate: ordinary SQL over the log files.
-- -----------------------------------------------------------------------------

-- by user and action
SELECT subj_prime AS who, action, count(*)
FROM audit_fdw.events_v
WHERE key = 'data_watch'
GROUP BY 1, 2
ORDER BY 1, 3 DESC;

-- most-touched files
SELECT obj_prime AS file, count(*)
FROM audit_fdw.events_v
WHERE key = 'data_watch' AND obj_kind = 'file'
GROUP BY 1
ORDER BY 2 DESC
LIMIT 10;

-- activity per hour
SELECT date_trunc('hour', event_time) AS hour, count(*)
FROM audit_fdw.events_v
GROUP BY 1
ORDER BY 1;

-- failed operations only
SELECT event_time, subj_prime AS who, action, obj_prime AS object
FROM audit_fdw.events_v
WHERE key = 'data_watch' AND result = 'failed'
ORDER BY event_time DESC;


-- -----------------------------------------------------------------------------
-- 7. Rotation. On the server:
--      sudo audit-rotate
--    Then step 1 again (the chain shifted by one, .1 became .2.gz) and
--    step 6 again: the counts are unchanged, because older events are read
--    from the .1 and .gz files just like the active one.
-- -----------------------------------------------------------------------------


-- -----------------------------------------------------------------------------
-- 8. The conventional copy. audit_native.events is loaded every 60 s, so it
--    answers from indexes but can be up to a minute behind.
-- -----------------------------------------------------------------------------
SELECT subj_prime AS who, action, count(*)
FROM audit_native.events
WHERE key = 'data_watch'
GROUP BY 1, 2
ORDER BY 1, 3 DESC;

-- how far behind, and the recent ingest runs
SELECT * FROM audit_native.ingest_lag;

SELECT run_at, rows_loaded, rows_skipped_dup, duration_ms, max_event_time,
       exit_code, note
FROM audit_native.ingest_log
ORDER BY run_id DESC
LIMIT 10;

-- events the FDW sees that the native table doesn't have yet
SELECT count(*) AS not_yet_ingested
FROM audit_fdw.events_v f
WHERE NOT EXISTS (SELECT 1 FROM audit_native.events n
                  WHERE n.serial = f.serial AND n.event_time = f.event_time);


-- -----------------------------------------------------------------------------
-- 9. One selective question, three ways. Compare the plans and the times.
--    events_v: the Foreign Scan reads the WHOLE chain; the filter is applied
--    afterwards ("Rows Removed by Filter"). file_fdw has no pushdown.
-- -----------------------------------------------------------------------------
EXPLAIN ANALYZE
SELECT * FROM audit_fdw.events_v
WHERE key = 'data_watch' AND event_time >= now() - interval '1 hour';

-- search_events: ausearch filters (-ts/-k) before PostgreSQL sees a row.
EXPLAIN ANALYZE
SELECT * FROM audit_fdw.search_events(now() - interval '1 hour', now(),
                                      'data_watch');

-- native: an index scan over a real table.
EXPLAIN ANALYZE
SELECT * FROM audit_native.events
WHERE key = 'data_watch' AND event_time >= now() - interval '1 hour';
