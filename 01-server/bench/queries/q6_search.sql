-- Q6 via search_events_in(): window filtered inside ausearch, result in SQL
-- (search_events has no result filter).
SELECT event_time, serial, subj_prime, action, obj_prime
FROM audit_fdw.search_events_in(:'dir', to_timestamp(:c), to_timestamp(:d))
WHERE result = 'failed'
ORDER BY event_time, serial;
