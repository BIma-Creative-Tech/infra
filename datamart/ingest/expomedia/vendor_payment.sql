-- Pembayaran ke vendor per tagihan (2026-10-01, kolom Pembayaran di detail SPK): pola = payment.sql, tetapi
-- partner_type 'supplier' dan tagihan in_invoice/in_refund. Alokasi = account_partial_reconcile; payment tanpa
-- jurnal (move_id NULL) → relasi invoice_ids, jumlah penuh. memo = referensi (nomor rekening tidak diambil).
SELECT p.id, bill.id, p.name, p.state, p.date, coalesce(j.name->>'id_ID', j.name->>'en_US'), p.memo, sum(apr.amount)
FROM account_payment p
JOIN account_journal j ON j.id = p.journal_id
JOIN account_move_line pl ON pl.move_id = p.move_id
JOIN account_partial_reconcile apr ON pl.id IN (apr.debit_move_id, apr.credit_move_id)
JOIN account_move_line bl ON bl.id = CASE WHEN apr.debit_move_id = pl.id THEN apr.credit_move_id ELSE apr.debit_move_id END
JOIN account_move bill ON bill.id = bl.move_id AND bill.move_type IN ('in_invoice', 'in_refund')
WHERE p.partner_type = 'supplier'
GROUP BY p.id, bill.id, p.name, p.state, p.date, j.name, p.memo
UNION ALL
SELECT p.id, rel.invoice_id, p.name, p.state, p.date, coalesce(j.name->>'id_ID', j.name->>'en_US'), p.memo, p.amount
FROM account_payment p
JOIN account_journal j ON j.id = p.journal_id
JOIN account_move__account_payment rel ON rel.payment_id = p.id
JOIN account_move bill ON bill.id = rel.invoice_id AND bill.move_type IN ('in_invoice', 'in_refund')
WHERE p.partner_type = 'supplier' AND p.move_id IS NULL
