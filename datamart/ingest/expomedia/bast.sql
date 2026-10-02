-- optional-table: custom_bast_document
-- plan 19: BAST (custom_bast) per SPK — status tanda tangan untuk dashboard. SPK dari reference 'sale.order,<id>',
-- surat jalan 'stock.picking,<id>' (sale_id), atau kunci custom_doc_trace bila ada. gps_accuracy (kolom opsional
-- versi modul berikutnya) lewat to_jsonb agar query jalan di modul lama. Nama penanda tangan = nama yang diketik di BAST.
SELECT b.id, b.name, b.kind, b.state,
       coalesce((to_jsonb(b) ->> 'x_custom_trace_order_id')::int,
                CASE split_part(b.reference, ',', 1)
                  WHEN 'sale.order' THEN nullif(split_part(b.reference, ',', 2), '')::int
                  WHEN 'stock.picking' THEN (SELECT sp.sale_id FROM stock_picking sp
                                             WHERE sp.id = nullif(split_part(b.reference, ',', 2), '')::int)
                END),
       left(b.location_text, 200), b.date_handover, pf.name, pt.name,
       b.party_from_signed_at, left(b.party_from_signed_by, 120), b.party_to_signed_at, left(b.party_to_signed_by, 120),
       nullif(b.gps_latitude, 0), nullif(b.gps_longitude, 0), (to_jsonb(b) ->> 'gps_accuracy')::numeric, b.write_date
FROM custom_bast_document b
LEFT JOIN res_partner pf ON pf.id = b.party_from_id
LEFT JOIN res_partner pt ON pt.id = b.party_to_id
