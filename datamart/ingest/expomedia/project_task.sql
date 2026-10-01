SELECT t.id, t.name, t.project_id, t.stage_id, t.sale_line_id, t.sale_order_id, t.date_deadline,
       t.date_last_stage_update, t.write_date
FROM project_task t WHERE t.active AND t.sale_order_id IS NOT NULL
