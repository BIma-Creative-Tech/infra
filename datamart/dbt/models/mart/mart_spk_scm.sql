-- Satu baris per dokumen supply chain SPK (plan 16): PO material/jasa, penerimaan barang, perintah produksi (MO),
-- surat jalan ke venue, tagihan vendor. amount/amount_paid hanya untuk PO & tagihan (nilai → hanya grup sales di app).
WITH po AS (
  SELECT * FROM {{ ref('stg_purchase_order') }} WHERE so_id IS NOT NULL
)
SELECT client_slug, env, so_id, 'po' AS kind, id AS doc_id, name AS doc_no, state,
       coalesce(date_approve, date_planned) AS doc_date, vendor AS party, amount_untaxed AS amount,
       NULL::numeric AS amount_paid, receipt_status AS detail
FROM po WHERE state <> 'cancel'
UNION ALL
SELECT sp.client_slug, sp.env, sp.so_id, CASE sp.picking_type WHEN 'incoming' THEN 'receipt' ELSE 'delivery' END,
       sp.id, sp.name, sp.state, coalesce(sp.date_done, sp.scheduled_date), po.vendor, NULL, NULL, sp.origin
FROM {{ ref('stg_stock_picking') }} sp
LEFT JOIN po ON po.client_slug = sp.client_slug AND po.env = sp.env AND po.id = sp.purchase_id
WHERE sp.so_id IS NOT NULL AND sp.picking_type IN ('incoming', 'outgoing') AND sp.state <> 'cancel'
UNION ALL
SELECT client_slug, env, so_id, 'mo', id, name, state, coalesce(date_finished, date_start), NULL, NULL, NULL,
       trim(to_char(product_qty, 'FM999990.##')) || ' unit'
FROM {{ ref('stg_mrp_production') }} WHERE so_id IS NOT NULL AND state <> 'cancel'
UNION ALL
SELECT b.client_slug, b.env, po.so_id, 'bill', b.id, b.name, b.state, b.invoice_date::timestamp, po.vendor,
       CASE WHEN b.move_type = 'in_refund' THEN -1 ELSE 1 END * b.amount_untaxed,
       CASE WHEN b.move_type = 'in_refund' THEN -1 ELSE 1 END * (b.amount_total - b.amount_residual),
       b.payment_state
FROM {{ ref('stg_vendor_bill') }} b
JOIN po ON po.client_slug = b.client_slug AND po.env = b.env AND po.id = b.purchase_id
WHERE b.state <> 'cancel'
