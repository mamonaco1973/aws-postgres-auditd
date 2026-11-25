-- Q4 (raw layer): every record of one event.
SELECT record_type, event_time, serial, fields FROM :rel
WHERE serial = :serial ORDER BY record_type;
