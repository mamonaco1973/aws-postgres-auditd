-- Q2 via search_events_in(): key and window filtered inside ausearch.
SELECT event_time, serial, subj_prime, action, result, obj_prime, obj2
FROM audit_fdw.search_events_in(:'dir', to_timestamp(:a), to_timestamp(:b),
                                'data_watch')
ORDER BY event_time, serial;
