-- Q3 (raw layer): by login user and syscall, from SYSCALL records.
SELECT fields->>'AUID' AS auid, fields->>'SYSCALL' AS syscall, count(*) AS n
FROM :rel
WHERE record_type = 'SYSCALL'
GROUP BY 1, 2
ORDER BY n DESC, 1, 2;
