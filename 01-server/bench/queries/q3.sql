-- Q3: aggregate by user and action.
SELECT who, action, count(*) AS n
FROM :rel
GROUP BY who, action
ORDER BY n DESC, who, action;
