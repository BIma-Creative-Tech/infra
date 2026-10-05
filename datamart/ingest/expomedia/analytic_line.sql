-- plan 19: baris analitik biaya proyek SPK (biaya produksi & margin). SPK dari proyek baris (project_id, timesheet)
-- atau akun analitik proyek (account_id: konsumsi MO, permintaan barang, tagihan vendor). Pendapatan (category
-- 'invoice') tidak diambil — nilai SPK dari sale_order. Tanpa nama/keterangan baris (minimisasi data).
-- plan 20 #8: satu proyek bisa dipakai beberapa SPK (SPK per lokasi) → so_exact = SPK pasti dari dokumen (task SPK,
-- SPK timesheet, kunci Lacak Dokumen jurnal / MO); bila tidak ada, so_id = SPK pertama proyek (so_exact false) dan
-- mart membagi biaya itu pro-rata ke SPK-SPK proyek. Kunci dibaca lewat to_jsonb (NULL di DB tanpa modul).
-- is_expense: jurnal Expense / Petty Cash (custom_doc_trace_expense) → biaya lain-lain, bukan "jasa ditagih".
WITH spk_project AS (
  SELECT pp.id AS project_id, pp.account_id,
         coalesce((SELECT sol.order_id FROM sale_order_line sol WHERE sol.id = pp.sale_line_id),
                  (SELECT so.id FROM sale_order so WHERE so.project_id = pp.id ORDER BY so.id LIMIT 1)) AS so_id
  FROM project_project pp
), base AS (
  SELECT a.*, coalesce(p1.project_id, p2.project_id) AS spk_project_id, coalesce(p1.so_id, p2.so_id) AS root_so_id,
         coalesce(t.sale_order_id, a.order_id, (to_jsonb(am) ->> 'x_custom_trace_order_id')::int,
                  (SELECT (to_jsonb(mo) ->> 'x_custom_trace_order_id')::int FROM mrp_production mo
                    WHERE a.category = 'manufacturing_order' AND mo.name = a.name AND mo.company_id = a.company_id
                    LIMIT 1)) AS exact_so_id,
         (am.id IS NOT NULL AND ((to_jsonb(am) ->> 'petty_cash_request_id') IS NOT NULL
                                 OR EXISTS (SELECT 1 FROM hr_expense e WHERE e.account_move_id = am.id))) AS is_expense
  FROM account_analytic_line a
  LEFT JOIN spk_project p1 ON p1.project_id = a.project_id
  LEFT JOIN LATERAL (SELECT x.project_id, x.so_id FROM spk_project x WHERE x.account_id = a.account_id
                       AND x.so_id IS NOT NULL ORDER BY x.project_id LIMIT 1) p2 ON true
  LEFT JOIN project_task t ON t.id = a.task_id
  LEFT JOIN account_move_line aml ON aml.id = a.move_line_id
  LEFT JOIN account_move am ON am.id = aml.move_id
  WHERE a.category IS DISTINCT FROM 'invoice'
)
SELECT id, coalesce(exact_so_id, root_so_id), category, employee_id, date, unit_amount, amount, write_date,
       spk_project_id, exact_so_id IS NOT NULL, is_expense
FROM base WHERE coalesce(exact_so_id, root_so_id) IS NOT NULL
