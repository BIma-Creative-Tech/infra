-- Tagihan vendor per PO (plan 16): baris bill → purchase_line_id → PO. Satu baris per (bill, PO), nilai penuh bill.
-- plan 18: kolom terakhir so_id = kunci SPK custom_doc_trace (to_jsonb → NULL di DB tanpa modul). Tagihan TANPA
-- baris PO tetapi berkunci SPK ikut sebagai purchase_id = 0 (PK (id, purchase_id) tidak menerima NULL) → tampil di
-- detail SPK sebagai "tagihan tanpa PO".
SELECT DISTINCT m.id, pol.order_id, m.name, m.state, m.move_type, m.invoice_date, m.amount_untaxed, m.amount_total,
       m.amount_residual, m.payment_state, (to_jsonb(m) ->> 'x_custom_trace_order_id')::int
FROM account_move m
JOIN account_move_line aml ON aml.move_id = m.id
JOIN purchase_order_line pol ON pol.id = aml.purchase_line_id
WHERE m.move_type IN ('in_invoice', 'in_refund')
UNION ALL
SELECT m.id, 0, m.name, m.state, m.move_type, m.invoice_date, m.amount_untaxed, m.amount_total,
       m.amount_residual, m.payment_state, (to_jsonb(m) ->> 'x_custom_trace_order_id')::int
FROM account_move m
WHERE m.move_type IN ('in_invoice', 'in_refund') AND (to_jsonb(m) ->> 'x_custom_trace_order_id')::int IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM account_move_line aml WHERE aml.move_id = m.id AND aml.purchase_line_id IS NOT NULL)
