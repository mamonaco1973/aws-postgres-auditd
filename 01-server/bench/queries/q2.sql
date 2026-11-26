-- Q2: selective filter, one key and a 1-hour window.
SELECT event_time, serial, who, action, result, file, new_value
FROM :rel
WHERE key = 'data_watch'
  AND event_time >= to_timestamp(:a) AND event_time < to_timestamp(:b)
ORDER BY event_time, serial;
