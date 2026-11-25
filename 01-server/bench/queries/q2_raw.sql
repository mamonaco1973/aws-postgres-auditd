-- Q2 (raw layer): the SYSCALL record carries the key; same key and window.
SELECT event_time, serial, fields->>'AUID' AS auid, fields->>'SYSCALL' AS syscall,
       fields->>'success' AS success
FROM :rel
WHERE record_type = 'SYSCALL' AND fields->>'key' = 'data_watch'
  AND event_time >= to_timestamp(:a) AND event_time < to_timestamp(:b)
ORDER BY event_time, serial;
