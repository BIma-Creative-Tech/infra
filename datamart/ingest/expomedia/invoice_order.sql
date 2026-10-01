SELECT DISTINCT aml.move_id, sol.order_id
FROM sale_order_line_invoice_rel rel
JOIN account_move_line aml ON aml.id = rel.invoice_line_id
JOIN sale_order_line sol ON sol.id = rel.order_line_id
