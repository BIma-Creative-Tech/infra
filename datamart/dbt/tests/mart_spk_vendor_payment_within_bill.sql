-- Alokasi pembayaran vendor per tagihan tidak boleh melebihi total tagihan (2026-10-01; cek join reconcile).
-- Distinct dulu: mart & stg_vendor_bill satu baris per (tagihan, PO).
SELECT p.client_slug, p.env, p.bill_id
FROM (SELECT DISTINCT client_slug, env, bill_id, payment_id, amount FROM {{ ref('mart_spk_vendor_payment') }}) p
JOIN (SELECT DISTINCT client_slug, env, id, amount_total FROM {{ ref('stg_vendor_bill') }}) b
  ON b.client_slug = p.client_slug AND b.env = p.env AND b.id = p.bill_id
GROUP BY p.client_slug, p.env, p.bill_id, b.amount_total
HAVING sum(p.amount) > abs(b.amount_total) + 0.01
