-- Q1 (raw layer): events = distinct (serial, time) over all records.
SELECT count(DISTINCT (serial, event_epoch)) AS events FROM :rel;
