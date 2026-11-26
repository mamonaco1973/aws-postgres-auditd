-- =============================================================================
-- FILE: queries.sql   ("Try it"; also in README.md)
-- =============================================================================
-- Each query is written twice, identical except for the table:
--   audit_fdw.events     virtual: rebuilt from the log files on every query
--   audit_native.events  real: loaded every 60 s, indexed
-- Run them as audit_reader in pgweb and compare the results and the query
-- time pgweb shows. The real table can be up to 60 s behind, so right after
-- new activity its numbers may briefly trail the virtual table's.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. How many changes were made under /data
-- -----------------------------------------------------------------------------
SELECT count(*) FROM audit_fdw.events    WHERE key = 'data_watch';

SELECT count(*) FROM audit_native.events WHERE key = 'data_watch';


-- -----------------------------------------------------------------------------
-- 2. Who did what: an aggregation
-- -----------------------------------------------------------------------------
SELECT who, action, result, count(*)
FROM audit_fdw.events
WHERE key = 'data_watch'
GROUP BY who, action, result
ORDER BY who, count(*) DESC;

SELECT who, action, result, count(*)
FROM audit_native.events
WHERE key = 'data_watch'
GROUP BY who, action, result
ORDER BY who, count(*) DESC;


-- -----------------------------------------------------------------------------
-- 3. The ten most recent changes. new_value is a rename target, or the new
--    mode/owner for chmod/chown.
-- -----------------------------------------------------------------------------
SELECT event_time, who, action, result, file, new_value
FROM audit_fdw.events
WHERE key = 'data_watch'
ORDER BY event_time DESC
LIMIT 10;

SELECT event_time, who, action, result, file, new_value
FROM audit_native.events
WHERE key = 'data_watch'
ORDER BY event_time DESC
LIMIT 10;
