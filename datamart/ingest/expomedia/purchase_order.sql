-- Pengadaan per SPK (plan 16): PO dengan project_id proyek SPK (project_purchase); so_id dari proyek, cadangan origin.
-- vendor = nama badan usaha pemasok (bukan data pribadi).
SELECT po.id, po.name, po.state, po.date_approve, po.date_planned, v.name,
       coalesce((SELECT sol.order_id FROM project_project pp JOIN sale_order_line sol ON sol.id = pp.sale_line_id
                 WHERE pp.id = po.project_id), (SELECT so.id FROM sale_order so WHERE so.name = po.origin LIMIT 1)),
       po.amount_untaxed, po.amount_total, po.receipt_status, po.invoice_status, po.effective_date, po.write_date
FROM purchase_order po JOIN res_partner v ON v.id = po.partner_id
