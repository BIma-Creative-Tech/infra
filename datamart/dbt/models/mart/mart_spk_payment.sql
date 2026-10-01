-- Satu baris per (SPK, pembayaran, invoice) — detail pembayaran Quotation Tracker (plan 15). amount = alokasi ke
-- invoice tsb (account_partial_reconcile), bukan total payment.
SELECT io.client_slug, io.env, io.order_id AS so_id, p.payment_id, p.name AS payment_no, p.state, p.date,
       p.journal, p.memo, p.invoice_id, i.name AS invoice_no, p.amount
FROM {{ ref('stg_payment') }} p
JOIN {{ ref('stg_invoice_order') }} io ON io.client_slug = p.client_slug AND io.env = p.env AND io.invoice_id = p.invoice_id
JOIN {{ ref('stg_invoice') }} i ON i.client_slug = p.client_slug AND i.env = p.env AND i.id = p.invoice_id
WHERE p.state NOT IN ('draft', 'canceled', 'rejected')
