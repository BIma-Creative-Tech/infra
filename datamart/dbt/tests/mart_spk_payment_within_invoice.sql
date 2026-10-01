-- Alokasi pembayaran per invoice tidak boleh melebihi total invoice (plan 15; cek join reconcile).
SELECT p.client_slug, p.env, p.so_id, p.invoice_id
FROM {{ ref('mart_spk_payment') }} p
JOIN {{ ref('mart_spk_invoice') }} i USING (client_slug, env, so_id, invoice_id)
GROUP BY 1, 2, 3, 4, i.amount_total HAVING sum(p.amount) > abs(i.amount_total) + 0.01
