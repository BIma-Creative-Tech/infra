SELECT e.id, e.name FROM hr_employee e WHERE e.id IN (SELECT employee_id FROM account_analytic_line WHERE employee_id IS NOT NULL)
