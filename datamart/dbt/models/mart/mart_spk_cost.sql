-- Plan 19: biaya produksi & margin per SPK (satu baris per SPK yang punya biaya). Sumber:
--  * analitik proyek SPK (stg_analytic_line): konsumsi MO & permintaan barang (picking_entry) = material terpakai,
--    tagihan vendor (jasa/sewa/subkon; barang di PO ber-proyek tidak beranalitik sejak plan 17) = jasa ditagih,
--    timesheet (employee_id; kiosk ½/1 hari) = tenaga kerja, sisa baris negatif = lain-lain;
--  * PO terkonfirmasi ber-SPK (stg_purchase_order/line/line_type): barang vs jasa, tanpa pajak.
-- Keputusan user (2026-10-02): belanja PO ikut biaya → material = MAX(terpakai, PO barang) dan jasa = MAX(ditagih,
-- PO jasa): PO yang belum terpakai/ditagih dihitung sebagai komitmen biaya, tanpa menghitung ganda saat sudah terpakai.
-- plan 20 #8: satu proyek bisa dipakai beberapa SPK (SPK per lokasi). Baris analitik ber-SPK pasti (so_exact: task SPK,
-- SPK timesheet, kunci Lacak Dokumen jurnal/MO) masuk ke SPK itu; baris proyek tanpa SPK pasti di proyek ber-SPK > 1
-- dibagi pro-rata nilai SPK (tanpa pajak; rata bila semua 0) agar biaya & margin per SPK lokasi tidak menumpuk di SPK
-- pertama. Baris lama tanpa kolom so_exact (NULL) = pasti (perilaku plan 19).
-- plan 20 #5: baris jurnal Expense / Petty Cash (is_expense) = biaya lain-lain (kategori 'expense'), tidak ikut
-- "jasa ditagih" yang dibandingkan dengan PO jasa (greatest) — kalau ikut, expense bisa tertutup nilai PO.
WITH spk AS (
  SELECT client_slug, env, id AS so_id, project_id, greatest(coalesce(amount_untaxed, 0), 0) AS value
  FROM {{ ref('stg_sale_order') }} WHERE state = 'sale' AND project_id IS NOT NULL
), shared AS (
  SELECT client_slug, env, project_id, count(*) AS spk_count, sum(value) AS total
  FROM spk GROUP BY 1, 2, 3 HAVING count(*) > 1
), line AS (
  SELECT l.client_slug, l.env, coalesce(s.so_id, l.so_id) AS so_id,
         CASE WHEN coalesce(l.is_expense, false) THEN 'expense' ELSE l.category END AS category, l.employee_id,
         l.hours * w.share AS hours, l.amount * w.share AS amount
  FROM {{ ref('stg_analytic_line') }} l
  LEFT JOIN shared p ON NOT coalesce(l.so_exact, true) AND p.client_slug = l.client_slug AND p.env = l.env
                    AND p.project_id = l.project_id
  LEFT JOIN spk s ON s.client_slug = p.client_slug AND s.env = p.env AND s.project_id = p.project_id
  CROSS JOIN LATERAL (SELECT CASE WHEN p.project_id IS NULL THEN 1.0
                                  WHEN p.total > 0 THEN s.value / p.total
                                  ELSE 1.0 / p.spk_count END AS share) w
), al AS (
  SELECT client_slug, env, so_id,
         coalesce(-sum(amount) FILTER (WHERE category IN ('manufacturing_order', 'picking_entry')), 0) AS material_used,
         coalesce(-sum(amount) FILTER (WHERE category = 'vendor_bill'), 0) AS service_billed,
         coalesce(-sum(amount) FILTER (WHERE employee_id IS NOT NULL
                                         AND category NOT IN ('manufacturing_order', 'picking_entry', 'vendor_bill')), 0) AS labor,
         coalesce(sum(hours) FILTER (WHERE employee_id IS NOT NULL
                                       AND category NOT IN ('manufacturing_order', 'picking_entry', 'vendor_bill')), 0) AS labor_hours,
         coalesce(sum(hours) FILTER (WHERE employee_id IS NOT NULL AND amount = 0
                                       AND category NOT IN ('manufacturing_order', 'picking_entry', 'vendor_bill')), 0) AS labor_hours_uncosted,
         coalesce(-sum(amount) FILTER (WHERE employee_id IS NULL
                                         AND category NOT IN ('manufacturing_order', 'picking_entry', 'vendor_bill')), 0) AS other
  FROM line GROUP BY 1, 2, 3
), po AS (
  SELECT po.client_slug, po.env, po.so_id,
         coalesce(sum(pl.price_subtotal) FILTER (WHERE coalesce(t.product_type, 'consu') <> 'service'), 0) AS po_goods,
         coalesce(sum(pl.price_subtotal) FILTER (WHERE t.product_type = 'service'), 0) AS po_service
  FROM {{ ref('stg_purchase_order') }} po
  JOIN {{ ref('stg_purchase_line') }} pl ON pl.client_slug = po.client_slug AND pl.env = po.env AND pl.order_id = po.id
  LEFT JOIN {{ ref('stg_purchase_line_type') }} t ON t.client_slug = pl.client_slug AND t.env = pl.env AND t.id = pl.id
  WHERE po.so_id IS NOT NULL AND po.state IN ('purchase', 'done') GROUP BY 1, 2, 3
), k AS (
  SELECT coalesce(al.client_slug, po.client_slug) AS client_slug, coalesce(al.env, po.env) AS env,
         coalesce(al.so_id, po.so_id) AS so_id,
         coalesce(al.material_used, 0) AS material_used, coalesce(po.po_goods, 0) AS po_goods,
         coalesce(al.service_billed, 0) AS service_billed, coalesce(po.po_service, 0) AS po_service,
         coalesce(al.labor, 0) AS cost_labor, coalesce(al.labor_hours, 0) AS labor_hours,
         coalesce(al.labor_hours_uncosted, 0) AS labor_hours_uncosted, coalesce(al.other, 0) AS cost_other
  FROM al FULL JOIN po ON po.client_slug = al.client_slug AND po.env = al.env AND po.so_id = al.so_id
)
SELECT k.*,
       greatest(material_used, po_goods) AS cost_material,
       greatest(service_billed, po_service) AS cost_service,
       greatest(material_used, po_goods) + greatest(service_billed, po_service) + cost_labor + cost_other AS cost_total
FROM k
