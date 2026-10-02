-- plan 19: biaya & margin konsisten (total = komponen, margin = nilai − total, material/jasa ≥ PO & terpakai/ditagih),
-- BAST: status dikenal, unik, dan hitungan di mart_spk = jumlah BAST tidak batal. Baris yang dikembalikan = gagal.
SELECT client_slug, env, so_id::text AS key, 'biaya/margin tidak konsisten' AS reason FROM {{ ref('mart_spk') }}
WHERE cost_total <> cost_material + cost_service + cost_labor + cost_other
   OR margin <> value - cost_total
   OR cost_material < greatest(material_used, po_goods) OR cost_service < greatest(service_billed, po_service)
   OR labor_hours_uncosted > labor_hours
UNION ALL
SELECT client_slug, env, bast_id::text, 'status BAST tidak dikenal' FROM {{ ref('mart_spk_bast') }}
WHERE state NOT IN ('draft', 'signed_one_side', 'completed', 'voided')
UNION ALL
SELECT client_slug, env, bast_id::text, 'BAST duplikat' FROM {{ ref('mart_spk_bast') }}
GROUP BY client_slug, env, bast_id HAVING count(*) > 1
UNION ALL
SELECT m.client_slug, m.env, m.so_id::text, 'bast_count tidak cocok'
FROM {{ ref('mart_spk') }} m
LEFT JOIN (SELECT client_slug, env, so_id, count(*) AS n FROM {{ ref('mart_spk_bast') }}
           WHERE state <> 'voided' GROUP BY 1, 2, 3) b
  ON b.client_slug = m.client_slug AND b.env = m.env AND b.so_id = m.so_id
WHERE m.bast_count <> coalesce(b.n, 0) OR m.bast_count <> m.bast_completed + m.bast_partial + m.bast_draft
