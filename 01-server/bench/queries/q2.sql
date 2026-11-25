-- Q2: selective filter, one key and a 1-hour window.
SELECT event_time, serial, subj_prime, action, result, obj_prime, obj2
FROM :rel
WHERE key = 'data_watch'
  AND event_time >= to_timestamp(:a) AND event_time < to_timestamp(:b)
ORDER BY event_time, serial;
