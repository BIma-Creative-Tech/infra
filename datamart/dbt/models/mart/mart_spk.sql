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
  UNION ALL
  -- plan 16: dokumen supply chain selesai/terbit menjadi status terakhir SPK
  SELECT client_slug, env, so_id, doc_date,
         CASE kind WHEN 'po' THEN 'PO ' || doc_no || coalesce(' · ' || party, '')
                   WHEN 'receipt' THEN 'Material diterima ' || doc_no
                   WHEN 'mo' THEN 'Produksi ' || doc_no || CASE WHEN state = 'done' THEN ' selesai' ELSE ' berjalan' END
                   WHEN 'delivery' THEN 'Surat jalan ' || doc_no || CASE WHEN state = 'done' THEN ' terkirim' ELSE '' END
                   ELSE 'Tagihan vendor ' || doc_no END
  FROM {{ ref('mart_spk_scm') }} WHERE doc_date IS NOT NULL AND (kind IN ('po', 'bill') OR state = 'done')
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
), inv_detail AS (
  SELECT client_slug, env, so_id, count(*) FILTER (WHERE state = 'posted') AS invoice_count,
         min(invoice_date_due) FILTER (WHERE state = 'posted' AND amount_residual > 0) AS next_due_date,
         coalesce(sum(amount_residual) FILTER (WHERE is_overdue), 0) AS overdue
  FROM {{ ref('mart_spk_invoice') }} GROUP BY 1, 2, 3
), scm AS (
  SELECT client_slug, env, so_id,
         count(*) FILTER (WHERE kind = 'po') AS po_count,
         coalesce(sum(amount) FILTER (WHERE kind = 'po'), 0) AS po_amount,
         count(*) FILTER (WHERE kind = 'receipt') AS receipt_count,
         count(*) FILTER (WHERE kind = 'receipt' AND state = 'done') AS receipt_done,
         count(*) FILTER (WHERE kind = 'mo') AS mo_count,
         count(*) FILTER (WHERE kind = 'mo' AND state = 'done') AS mo_done,
         count(*) FILTER (WHERE kind = 'delivery') AS delivery_count,
         count(*) FILTER (WHERE kind = 'delivery' AND state = 'done') AS delivery_done,
         coalesce(sum(amount) FILTER (WHERE kind = 'bill' AND state = 'posted'), 0) AS bill_amount,
         coalesce(sum(amount_paid) FILTER (WHERE kind = 'bill' AND state = 'posted'), 0) AS bill_paid
  FROM {{ ref('mart_spk_scm') }} GROUP BY 1, 2, 3
), lead_first AS (
  SELECT client_slug, env, so_id, min(id) AS lead_id, min(create_date) AS lead_date
  FROM {{ ref('stg_crm_lead') }} WHERE so_id IS NOT NULL GROUP BY 1, 2, 3
), pay AS (
  SELECT client_slug, env, so_id, count(DISTINCT payment_id) AS payment_count, max(date) AS last_payment_date
  FROM {{ ref('mart_spk_payment') }} GROUP BY 1, 2, 3
)
SELECT so.client_slug, so.env, so.id AS so_id,
       so.name AS spk_no, so.quotation_name, so.legacy_ref,
       CASE so.state WHEN 'sale' THEN 'spk' WHEN 'cancel' THEN 'batal' ELSE 'penawaran' END AS status,
       -- Penawaran dibuat (draft) vs terkirim (sent: tombol Send / "Mark Quotation as Sent"); NULL untuk SPK/batal.
       -- Kolom tambahan — nilai `status` tetap agar control-plane v0.5.0 kompatibel.
       CASE so.state WHEN 'draft' THEN 'dibuat' WHEN 'sent' THEN 'terkirim' END AS quotation_state,
       so.date_order, grp.name AS customer, brand.name AS brand, ae.name AS ae, ae.login AS ae_login,
       coalesce(loc.locations, 0) AS locations, coalesce(sn.stage, 'Belum ada lokasi') AS stage,
       coalesce(loc.stage_min_seq, 0) AS stage_seq, coalesce(loc.progress_pct, 0) AS progress_pct,
       le.label AS last_status, le.at AS last_status_at,
       coalesce(loc.crew_hours, 0) AS crew_hours, coalesce(pp.crew_people, 0) AS crew_people,
       so.amount_untaxed AS value, coalesce(inv.invoiced, 0) AS invoiced, coalesce(inv.paid, 0) AS paid,
       coalesce(inv.due, 0) AS due, so.invoice_status,
       -- Quotation Tracker (plan 15): tahap terjauh alur Penawaran → SPK → Produksi → Ditagih → Lunas.
       CASE WHEN so.state = 'cancel' THEN 'batal'
            WHEN so.state <> 'sale' THEN 'penawaran'
            WHEN coalesce(inv.invoiced, 0) > 0 AND coalesce(inv.due, 0) <= 0 THEN 'lunas'
            WHEN coalesce(inv.invoiced, 0) > 0 THEN 'ditagih'
            WHEN coalesce(loc.progress_pct, 0) > 0 OR coalesce(loc.crew_hours, 0) > 0 THEN 'produksi'
            ELSE 'spk' END AS tracker_stage,
       coalesce(ivd.invoice_count, 0) AS invoice_count, ivd.next_due_date, coalesce(ivd.overdue, 0) AS overdue,
       coalesce(pay.payment_count, 0) AS payment_count, pay.last_payment_date,
       so.is_mockup, now() AS refreshed_at,
       -- plan 16: CRM + supply chain (biaya material = PO; nilai hanya dipilih app untuk grup sales)
       ld.lead_id, ld.lead_date,
       coalesce(scm.po_count, 0) AS po_count, coalesce(scm.po_amount, 0) AS material_cost,
       coalesce(scm.receipt_count, 0) AS receipt_count, coalesce(scm.receipt_done, 0) AS receipt_done,
       coalesce(scm.mo_count, 0) AS mo_count, coalesce(scm.mo_done, 0) AS mo_done,
       coalesce(scm.delivery_count, 0) AS delivery_count, coalesce(scm.delivery_done, 0) AS delivery_done,
       coalesce(scm.bill_amount, 0) AS vendor_billed, coalesce(scm.bill_paid, 0) AS vendor_paid
FROM {{ ref('stg_sale_order') }} so
LEFT JOIN {{ ref('stg_partner') }} grp ON grp.client_slug = so.client_slug AND grp.env = so.env AND grp.id = so.partner_invoice_id
LEFT JOIN {{ ref('stg_partner') }} brand ON brand.client_slug = so.client_slug AND brand.env = so.env AND brand.id = so.partner_id
LEFT JOIN {{ ref('stg_odoo_user') }} ae ON ae.client_slug = so.client_slug AND ae.env = so.env AND ae.id = so.user_id
LEFT JOIN loc ON loc.client_slug = so.client_slug AND loc.env = so.env AND loc.so_id = so.id
LEFT JOIN stage_name sn ON sn.client_slug = so.client_slug AND sn.env = so.env AND sn.so_id = so.id AND sn.stage_seq = loc.stage_min_seq
LEFT JOIN last_event le ON le.client_slug = so.client_slug AND le.env = so.env AND le.so_id = so.id
LEFT JOIN people pp ON pp.client_slug = so.client_slug AND pp.env = so.env AND pp.so_id = so.id
LEFT JOIN inv ON inv.client_slug = so.client_slug AND inv.env = so.env AND inv.so_id = so.id
LEFT JOIN inv_detail ivd ON ivd.client_slug = so.client_slug AND ivd.env = so.env AND ivd.so_id = so.id
LEFT JOIN scm ON scm.client_slug = so.client_slug AND scm.env = so.env AND scm.so_id = so.id
LEFT JOIN lead_first ld ON ld.client_slug = so.client_slug AND ld.env = so.env AND ld.so_id = so.id
LEFT JOIN pay ON pay.client_slug = so.client_slug AND pay.env = so.env AND pay.so_id = so.id
