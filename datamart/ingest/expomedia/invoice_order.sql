-- Invoice pelanggan ↔ SPK: baris SO yang ditagih (sale_order_line_invoice_rel).
-- plan 18: + invoice/nota kredit tanpa baris SO tetapi berkunci SPK custom_doc_trace (to_jsonb → NULL di DB tanpa modul).
SELECT DISTINCT aml.move_id, sol.order_id
FROM sale_order_line_invoice_rel rel
JOIN account_move_line aml ON aml.id = rel.invoice_line_id
JOIN sale_order_line sol ON sol.id = rel.order_line_id
UNION
SELECT m.id, (to_jsonb(m) ->> 'x_custom_trace_order_id')::int
FROM account_move m
WHERE m.move_type IN ('out_invoice', 'out_refund') AND (to_jsonb(m) ->> 'x_custom_trace_order_id')::int IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM account_move_line aml JOIN sale_order_line_invoice_rel rel ON rel.invoice_line_id = aml.id
                  WHERE aml.move_id = m.id)
