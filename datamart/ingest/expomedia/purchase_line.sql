-- Baris PO (2026-10-01, halaman detail dokumen): produk, qty dipesan/diterima/ditagih, harga. Tanpa baris
-- section/note (display_type). Nama produk & satuan = jsonb terjemahan (id_ID, cadangan en_US).
SELECT pol.id, pol.order_id, pol.sequence, pp.default_code, coalesce(pt.name->>'id_ID', pt.name->>'en_US'), pol.name,
       pol.product_qty, pol.qty_received, pol.qty_invoiced, coalesce(u.name->>'id_ID', u.name->>'en_US'),
       pol.price_unit, pol.price_subtotal
FROM purchase_order_line pol
LEFT JOIN product_product pp ON pp.id = pol.product_id
LEFT JOIN product_template pt ON pt.id = pp.product_tmpl_id
LEFT JOIN uom_uom u ON u.id = pol.product_uom_id
WHERE pol.display_type IS NULL
