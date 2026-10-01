-- Baris dokumen supply chain per SPK (2026-10-01, halaman detail dokumen): PO (qty pesan/terima/tagih), penerimaan &
-- surat jalan (qty rencana/selesai), MO (hasil + komponen), tagihan vendor. amount hanya PO & tagihan (nilai → app).
WITH docs AS (
  SELECT DISTINCT client_slug, env, so_id, kind, doc_id FROM {{ ref('mart_spk_scm') }}
)
SELECT d.client_slug, d.env, d.so_id, d.kind, d.doc_id, l.id AS line_id, NULL::text AS role, l.sequence,
       l.default_code, l.product, l.description, l.qty, l.qty_received AS qty_done, l.qty_invoiced AS qty_billed, l.uom,
       l.price_subtotal AS amount
FROM docs d JOIN {{ ref('stg_purchase_line') }} l ON l.client_slug = d.client_slug AND l.env = d.env AND l.order_id = d.doc_id
WHERE d.kind = 'po'
UNION ALL
SELECT d.client_slug, d.env, d.so_id, d.kind, d.doc_id, m.id, NULL, m.sequence, m.default_code, m.product, NULL, m.qty,
       m.qty_done, NULL, m.uom, NULL
FROM docs d JOIN {{ ref('stg_stock_move') }} m ON m.client_slug = d.client_slug AND m.env = d.env AND m.picking_id = d.doc_id
WHERE d.kind IN ('receipt', 'delivery')
UNION ALL
SELECT d.client_slug, d.env, d.so_id, d.kind, d.doc_id, m.id, 'hasil', m.sequence, m.default_code, m.product, NULL, m.qty,
       m.qty_done, NULL, m.uom, NULL
FROM docs d JOIN {{ ref('stg_stock_move') }} m ON m.client_slug = d.client_slug AND m.env = d.env AND m.production_id = d.doc_id
WHERE d.kind = 'mo'
UNION ALL
SELECT d.client_slug, d.env, d.so_id, d.kind, d.doc_id, m.id, 'komponen', m.sequence, m.default_code, m.product, NULL,
       m.qty, m.qty_done, NULL, m.uom, NULL
FROM docs d JOIN {{ ref('stg_stock_move') }} m ON m.client_slug = d.client_slug AND m.env = d.env
  AND m.raw_material_production_id = d.doc_id
WHERE d.kind = 'mo'
UNION ALL
SELECT d.client_slug, d.env, d.so_id, d.kind, d.doc_id, l.id, NULL, NULL, l.default_code, l.product, l.description,
       l.qty, NULL, NULL, l.uom, l.price_subtotal
FROM docs d JOIN {{ ref('stg_vendor_bill_line') }} l ON l.client_slug = d.client_slug AND l.env = d.env AND l.move_id = d.doc_id
WHERE d.kind = 'bill'
