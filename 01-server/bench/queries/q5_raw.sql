-- Q5 (raw layer): top 10 absolute paths named in PATH records.
SELECT fields->>'name' AS name, count(*) AS n
FROM :rel
WHERE record_type = 'PATH' AND fields->>'name' LIKE '/data/%'
  AND fields->>'nametype' IN ('NORMAL', 'CREATE', 'DELETE')
GROUP BY 1
ORDER BY n DESC, 1
LIMIT 10;
