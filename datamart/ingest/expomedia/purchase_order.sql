-- Pengadaan per SPK (plan 16): PO dengan project_id proyek SPK (project_purchase); so_id dari proyek, cadangan origin.
-- vendor = nama badan usaha pemasok (bukan data pribadi).
-- plan 18: kunci SPK custom_doc_trace (x_custom_trace_order_id) = link utama bila ada. Dibaca lewat to_jsonb(baris)
-- agar query tetap jalan di DB tanpa modul (kunci tidak ada → NULL → fallback proyek/origin).
SELECT po.id, po.name, po.state, po.date_approve, po.date_planned, v.name,
       coalesce((to_jsonb(po) ->> 'x_custom_trace_order_id')::int,
                (SELECT sol.order_id FROM project_project pp JOIN sale_order_line sol ON sol.id = pp.sale_line_id
                 WHERE pp.id = po.project_id), (SELECT so.id FROM sale_order so WHERE so.name = po.origin LIMIT 1)),
       po.amount_untaxed, po.amount_total, po.receipt_status, po.invoice_status, po.effective_date, po.write_date
FROM purchase_order po JOIN res_partner v ON v.id = po.partner_id
