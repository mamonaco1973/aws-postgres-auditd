-- Q3: aggregate by user and action.
SELECT subj_prime, action, count(*) AS n
FROM :rel
GROUP BY subj_prime, action
ORDER BY n DESC, subj_prime, action;
