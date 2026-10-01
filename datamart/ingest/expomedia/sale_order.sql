SELECT so.id, so.name, so.x_quotation_name, so.client_order_ref, so.state, so.date_order, so.partner_id,
       so.partner_invoice_id, so.user_id, so.amount_untaxed, so.amount_total, so.invoice_status,
       EXISTS (SELECT 1 FROM sale_order_tag_rel r JOIN crm_tag t ON t.id = r.tag_id
               WHERE r.order_id = so.id AND t.name->>'en_US' = 'MOCKUP'),
       so.write_date
FROM sale_order so
