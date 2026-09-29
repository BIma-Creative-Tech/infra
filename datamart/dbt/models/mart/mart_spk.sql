-- Satu baris per Penawaran/SPK (sale.order). Tahap SPK = lokasi paling tertinggal; status terakhir = kegiatan
-- (timesheet) atau perubahan tahap paling baru. Nilai/tagihan/pembayaran dari invoice pelanggan yang terkait baris SO.
WITH loc AS (
  SELECT client_slug, env, so_id, count(*) AS locations, min(stage_seq) AS stage_min_seq,
         round(avg(progress_pct))::int AS progress_pct, sum(crew_hours) AS crew_hours
  FROM {{ ref('mart_spk_location') }} GROUP BY 1, 2, 3
), stage_name AS (
  SELECT DISTINCT ON (client_slug, env, so_id, stage_seq) client_slug, env, so_id, stage_seq, stage
  FROM {{ ref('mart_spk_location') }}
), events AS (
  SELECT client_slug, env, order_id AS so_id, date::timestamp + interval '12 hours' AS at, description AS label
  FROM {{ ref('stg_timesheet') }} WHERE order_id IS NOT NULL
  UNION ALL
  SELECT client_slug, env, so_id, stage_updated_at, 'Tahap ' || stage || ': ' || location
  FROM {{ ref('mart_spk_location') }} WHERE stage_updated_at IS NOT NULL
), last_event AS (
  SELECT DISTINCT ON (client_slug, env, so_id) client_slug, env, so_id, at, label
  FROM events ORDER BY client_slug, env, so_id, at DESC
), people AS (
  SELECT client_slug, env, order_id AS so_id, count(DISTINCT employee_id) AS crew_people
  FROM {{ ref('stg_timesheet') }} WHERE order_id IS NOT NULL GROUP BY 1, 2, 3
), inv AS (
  SELECT io.client_slug, io.env, io.order_id AS so_id,
         sum(CASE WHEN i.move_type = 'out_refund' THEN -1 ELSE 1 END * i.amount_untaxed) AS invoiced,
         sum(CASE WHEN i.move_type = 'out_refund' THEN -1 ELSE 1 END * (i.amount_total - i.amount_residual)) AS paid,
         sum(CASE WHEN i.move_type = 'out_refund' THEN -1 ELSE 1 END * i.amount_residual) AS due
  FROM {{ ref('stg_invoice_order') }} io
  JOIN {{ ref('stg_invoice') }} i ON i.client_slug = io.client_slug AND i.env = io.env AND i.id = io.invoice_id
  WHERE i.state = 'posted' GROUP BY 1, 2, 3
)
SELECT so.client_slug, so.env, so.id AS so_id,
       so.name AS spk_no, so.quotation_name, so.legacy_ref,
       CASE so.state WHEN 'sale' THEN 'spk' WHEN 'cancel' THEN 'batal' ELSE 'penawaran' END AS status,
       so.date_order, grp.name AS customer, brand.name AS brand, ae.name AS ae,
       coalesce(loc.locations, 0) AS locations, coalesce(sn.stage, 'Belum ada lokasi') AS stage,
       coalesce(loc.stage_min_seq, 0) AS stage_seq, coalesce(loc.progress_pct, 0) AS progress_pct,
       le.label AS last_status, le.at AS last_status_at,
       coalesce(loc.crew_hours, 0) AS crew_hours, coalesce(pp.crew_people, 0) AS crew_people,
       so.amount_untaxed AS value, coalesce(inv.invoiced, 0) AS invoiced, coalesce(inv.paid, 0) AS paid,
       coalesce(inv.due, 0) AS due, so.invoice_status, so.is_mockup, now() AS refreshed_at
FROM {{ ref('stg_sale_order') }} so
LEFT JOIN {{ ref('stg_partner') }} grp ON grp.client_slug = so.client_slug AND grp.env = so.env AND grp.id = so.partner_invoice_id
LEFT JOIN {{ ref('stg_partner') }} brand ON brand.client_slug = so.client_slug AND brand.env = so.env AND brand.id = so.partner_id
LEFT JOIN {{ ref('stg_odoo_user') }} ae ON ae.client_slug = so.client_slug AND ae.env = so.env AND ae.id = so.user_id
LEFT JOIN loc ON loc.client_slug = so.client_slug AND loc.env = so.env AND loc.so_id = so.id
LEFT JOIN stage_name sn ON sn.client_slug = so.client_slug AND sn.env = so.env AND sn.so_id = so.id AND sn.stage_seq = loc.stage_min_seq
LEFT JOIN last_event le ON le.client_slug = so.client_slug AND le.env = so.env AND le.so_id = so.id
LEFT JOIN people pp ON pp.client_slug = so.client_slug AND pp.env = so.env AND pp.so_id = so.id
LEFT JOIN inv ON inv.client_slug = so.client_slug AND inv.env = so.env AND inv.so_id = so.id
