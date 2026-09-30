-- Perintah produksi per SPK (plan 16): MO dengan project_id proyek SPK (project_mrp), cadangan origin = No. SPK.
SELECT mo.id, mo.name, mo.state, mo.origin, mo.product_qty, mo.date_start, mo.date_finished,
       coalesce((SELECT sol.order_id FROM project_project pp JOIN sale_order_line sol ON sol.id = pp.sale_line_id
                 WHERE pp.id = mo.project_id), (SELECT so.id FROM sale_order so WHERE so.name = mo.origin LIMIT 1)),
       mo.write_date
FROM mrp_production mo
