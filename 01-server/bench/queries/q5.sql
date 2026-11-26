-- Q5: top 10 files by event count.
SELECT file, count(*) AS n
FROM :rel
WHERE obj_kind = 'file'
GROUP BY file
ORDER BY n DESC, file
LIMIT 10;
