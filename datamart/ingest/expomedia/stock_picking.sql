-- Logistik per SPK (plan 16): penerimaan material (incoming, dari PO) dan Surat Jalan ke venue (outgoing, sale_id).
-- plan 18: kunci SPK custom_doc_trace = link utama bila ada (to_jsonb → NULL di DB tanpa modul).
SELECT sp.id, sp.name, spt.code, sp.state, sp.origin, sp.scheduled_date, sp.date_done,
       coalesce((to_jsonb(sp) ->> 'x_custom_trace_order_id')::int, sp.sale_id,
                (SELECT sol.order_id FROM project_project pp JOIN sale_order_line sol ON sol.id = pp.sale_line_id
                 WHERE pp.id = coalesce(sp.project_id, po.project_id)),
                (SELECT so.id FROM sale_order so WHERE so.name = coalesce(po.origin, sp.origin) LIMIT 1)),
       po.id, sp.write_date
FROM stock_picking sp
JOIN stock_picking_type spt ON spt.id = sp.picking_type_id
LEFT JOIN purchase_order po ON po.name = sp.origin
