-- Baris logistik & produksi (2026-10-01, halaman detail dokumen): move penerimaan/surat jalan (picking_id),
-- hasil MO (production_id) dan komponen MO (raw_material_production_id); qty rencana vs selesai. Tanpa yang batal.
SELECT sm.id, sm.picking_id, sm.production_id, sm.raw_material_production_id, sm.sequence, pp.default_code,
       coalesce(pt.name->>'id_ID', pt.name->>'en_US'), sm.product_uom_qty, sm.quantity,
       coalesce(u.name->>'id_ID', u.name->>'en_US'), sm.state
FROM stock_move sm
LEFT JOIN product_product pp ON pp.id = sm.product_id
LEFT JOIN product_template pt ON pt.id = pp.product_tmpl_id
LEFT JOIN uom_uom u ON u.id = sm.product_uom
WHERE sm.state <> 'cancel'
  AND (sm.picking_id IS NOT NULL OR sm.production_id IS NOT NULL OR sm.raw_material_production_id IS NOT NULL)
