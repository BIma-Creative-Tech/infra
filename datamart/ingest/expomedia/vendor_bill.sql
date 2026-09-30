-- Tagihan vendor per PO (plan 16): baris bill → purchase_line_id → PO. Satu baris per (bill, PO), nilai penuh bill.
SELECT DISTINCT m.id, pol.order_id, m.name, m.state, m.move_type, m.invoice_date, m.amount_untaxed, m.amount_total,
       m.amount_residual, m.payment_state
FROM account_move m
JOIN account_move_line aml ON aml.move_id = m.id
JOIN purchase_order_line pol ON pol.id = aml.purchase_line_id
WHERE m.move_type IN ('in_invoice', 'in_refund')
