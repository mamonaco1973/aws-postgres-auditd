-- Q5: top 10 files by event count.
SELECT obj_prime, count(*) AS n
FROM :rel
WHERE obj_kind = 'file'
GROUP BY obj_prime
ORDER BY n DESC, obj_prime
LIMIT 10;
