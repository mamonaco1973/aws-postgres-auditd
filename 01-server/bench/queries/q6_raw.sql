-- Q6 (raw layer): failed syscalls in the window.
SELECT event_time, serial, fields->>'AUID' AS auid, fields->>'SYSCALL' AS syscall
FROM :rel
WHERE record_type = 'SYSCALL' AND fields->>'success' = 'no'
  AND event_time >= to_timestamp(:c) AND event_time < to_timestamp(:d)
ORDER BY event_time, serial;
