-- Pembayaran pelanggan per invoice (plan 15). Alokasi = account_partial_reconcile antara baris jurnal payment dan
-- baris piutang invoice. Payment tanpa jurnal (Odoo 18+: tanpa outstanding account) → relasi invoice_ids, jumlah
-- penuh payment. memo = referensi pembayaran (bukan data pribadi; nomor rekening tidak diambil).
SELECT p.id, inv.id, p.name, p.state, p.date, coalesce(j.name->>'id_ID', j.name->>'en_US'), p.memo, sum(apr.amount)
FROM account_payment p
JOIN account_journal j ON j.id = p.journal_id
JOIN account_move_line pl ON pl.move_id = p.move_id
JOIN account_partial_reconcile apr ON pl.id IN (apr.debit_move_id, apr.credit_move_id)
JOIN account_move_line il ON il.id = CASE WHEN apr.debit_move_id = pl.id THEN apr.credit_move_id ELSE apr.debit_move_id END
JOIN account_move inv ON inv.id = il.move_id AND inv.move_type IN ('out_invoice', 'out_refund')
WHERE p.partner_type = 'customer'
GROUP BY p.id, inv.id, p.name, p.state, p.date, j.name, p.memo
UNION ALL
SELECT p.id, rel.invoice_id, p.name, p.state, p.date, coalesce(j.name->>'id_ID', j.name->>'en_US'), p.memo, p.amount
FROM account_payment p
JOIN account_journal j ON j.id = p.journal_id
JOIN account_move__account_payment rel ON rel.payment_id = p.id
JOIN account_move inv ON inv.id = rel.invoice_id AND inv.move_type IN ('out_invoice', 'out_refund')
WHERE p.partner_type = 'customer' AND p.move_id IS NULL
