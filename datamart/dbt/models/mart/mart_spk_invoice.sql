-- Satu baris per (SPK, invoice pelanggan) — detail penagihan Quotation Tracker (plan 15). Invoice yang menagih
-- beberapa SPK muncul di setiap SPK dengan nilai penuh invoice (sama seperti agregat di mart_spk). Batal tidak ikut.
SELECT io.client_slug, io.env, io.order_id AS so_id, i.id AS invoice_id, i.name AS invoice_no, i.move_type,
       i.state, i.invoice_date, i.invoice_date_due,
       CASE WHEN i.move_type = 'out_refund' THEN -1 ELSE 1 END * i.amount_untaxed AS amount_untaxed,
       CASE WHEN i.move_type = 'out_refund' THEN -1 ELSE 1 END * i.amount_total AS amount_total,
       CASE WHEN i.move_type = 'out_refund' THEN -1 ELSE 1 END * i.amount_residual AS amount_residual,
       i.payment_state,
       (i.state = 'posted' AND i.amount_residual > 0 AND i.invoice_date_due < current_date) AS is_overdue
FROM {{ ref('stg_invoice_order') }} io
JOIN {{ ref('stg_invoice') }} i ON i.client_slug = io.client_slug AND i.env = io.env AND i.id = io.invoice_id
WHERE i.state <> 'cancel'
