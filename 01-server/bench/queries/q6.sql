-- Q6: failed operations in a 24-hour window.
SELECT event_time, serial, who, action, file
FROM :rel
WHERE result = 'failed'
  AND event_time >= to_timestamp(:c) AND event_time < to_timestamp(:d)
ORDER BY event_time, serial;
