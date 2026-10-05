-- plan 20 #8: project_id (proyek bersama SPK per lokasi), nama event & lokasi SPK (cl_expomedia_sale; to_jsonb → NULL
-- di DB tanpa field). Proyek = project_id SPK, atau proyek yang dibuat baris SPK.
SELECT so.id, so.name, so.x_quotation_name, so.client_order_ref, so.state, so.date_order, so.partner_id,
       so.partner_invoice_id, so.user_id, so.amount_untaxed, so.amount_total, so.invoice_status,
       EXISTS (SELECT 1 FROM sale_order_tag_rel r JOIN crm_tag t ON t.id = r.tag_id
               WHERE r.order_id = so.id AND t.name->>'en_US' = 'MOCKUP'),
       so.write_date,
       coalesce(so.project_id, (SELECT sol.project_id FROM sale_order_line sol WHERE sol.order_id = so.id
                                  AND sol.project_id IS NOT NULL ORDER BY sol.sequence, sol.id LIMIT 1)),
       to_jsonb(so) ->> 'x_event_name', to_jsonb(so) ->> 'x_location'
FROM sale_order so
