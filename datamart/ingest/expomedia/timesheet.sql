SELECT a.id, a.date, a.employee_id, a.task_id, a.project_id, a.order_id, a.unit_amount, -a.amount, a.x_giat_type,
       a.x_giat_slot, left(a.name, 120), a.write_date
FROM account_analytic_line a WHERE a.project_id IS NOT NULL AND a.employee_id IS NOT NULL
