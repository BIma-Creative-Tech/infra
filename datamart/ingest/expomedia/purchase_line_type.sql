-- plan 19: jenis produk baris PO (barang vs jasa) untuk biaya PO per SPK. Tabel terpisah (bukan kolom baru di
-- purchase_line) agar ingest lama & baru tidak saling memecah COPY selama transisi. 'service' = jasa; selain itu barang.
SELECT pol.id, pt.type, coalesce(pt.is_storable, false)
FROM purchase_order_line pol
JOIN product_product pp ON pp.id = pol.product_id
JOIN product_template pt ON pt.id = pp.product_tmpl_id
WHERE pol.display_type IS NULL
