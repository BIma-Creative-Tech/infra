-- plan 19: baris analitik biaya proyek SPK (biaya produksi & margin). SPK dari proyek baris (project_id, timesheet)
-- atau akun analitik proyek (account_id: konsumsi MO, permintaan barang, tagihan vendor). Pendapatan (category
-- 'invoice') tidak diambil — nilai SPK dari sale_order. Tanpa nama/keterangan baris (minimisasi data).
WITH spk_project AS (
  SELECT pp.id AS project_id, pp.account_id,
         coalesce((SELECT sol.order_id FROM sale_order_line sol WHERE sol.id = pp.sale_line_id),
                  (SELECT so.id FROM sale_order so WHERE so.project_id = pp.id ORDER BY so.id LIMIT 1)) AS so_id
  FROM project_project pp
)
SELECT a.id, coalesce(p1.so_id, p2.so_id), a.category, a.employee_id, a.date, a.unit_amount, a.amount, a.write_date
FROM account_analytic_line a
LEFT JOIN spk_project p1 ON p1.project_id = a.project_id
LEFT JOIN LATERAL (SELECT x.so_id FROM spk_project x WHERE x.account_id = a.account_id AND x.so_id IS NOT NULL
                   ORDER BY x.project_id LIMIT 1) p2 ON true
WHERE a.category IS DISTINCT FROM 'invoice' AND coalesce(p1.so_id, p2.so_id) IS NOT NULL
