SELECT p.id, p.name, p.parent_id, p.is_company FROM res_partner p
WHERE p.id IN (SELECT partner_id FROM sale_order UNION SELECT partner_invoice_id FROM sale_order)
   OR p.id IN (SELECT c.parent_id FROM res_partner c JOIN sale_order so ON so.partner_id = c.id)
