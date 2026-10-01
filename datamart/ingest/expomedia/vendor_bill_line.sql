-- Baris tagihan vendor (2026-10-01, halaman detail dokumen): baris produk saja, dengan tautan ke baris PO.
SELECT aml.id, aml.move_id, aml.purchase_line_id, pp.default_code, coalesce(pt.name->>'id_ID', pt.name->>'en_US'),
       aml.name, aml.quantity, coalesce(u.name->>'id_ID', u.name->>'en_US'), aml.price_subtotal
FROM account_move_line aml
JOIN account_move m ON m.id = aml.move_id AND m.move_type IN ('in_invoice', 'in_refund')
LEFT JOIN product_product pp ON pp.id = aml.product_id
LEFT JOIN product_template pt ON pt.id = pp.product_tmpl_id
LEFT JOIN uom_uom u ON u.id = aml.product_uom_id
WHERE aml.display_type = 'product'
