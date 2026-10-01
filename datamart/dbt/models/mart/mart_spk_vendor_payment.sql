-- Satu baris per (SPK, PO, tagihan vendor, pembayaran) — kolom Pembayaran di detail SPK (2026-10-01). amount = alokasi
-- pembayaran ke tagihan tsb (account_partial_reconcile), bukan total payment; tagihan yang mencakup >1 PO muncul per PO.
SELECT DISTINCT s.client_slug, s.env, s.so_id, s.po_id, s.doc_id AS bill_id, s.doc_no AS bill_no, p.payment_id,
       p.name AS payment_no, p.state, p.date, p.journal, p.memo, p.amount
FROM {{ ref('stg_vendor_payment') }} p
JOIN {{ ref('mart_spk_scm') }} s ON s.client_slug = p.client_slug AND s.env = p.env AND s.kind = 'bill' AND s.doc_id = p.bill_id
WHERE p.state NOT IN ('draft', 'canceled', 'rejected')
