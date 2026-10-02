-- optional-table: custom_doc_trace_issue
-- plan 18: isu link dokumen (modul custom_doc_trace). Tabel opsional: tenant/DB tanpa modul → ingest.sh melewati
-- COPY (raw kosong). Hanya isu terbuka + yang diperbaiki otomatis 30 hari terakhir. doc_no = nomor dokumen sumber.
SELECT i.id, i.rule_code, i.severity, i.res_model, i.res_id, i.sale_order_id, i.state, i.message,
       CASE i.res_model
         WHEN 'sale.order' THEN (SELECT x.name FROM sale_order x WHERE x.id = i.res_id)
         WHEN 'purchase.order' THEN (SELECT x.name FROM purchase_order x WHERE x.id = i.res_id)
         WHEN 'stock.picking' THEN (SELECT x.name FROM stock_picking x WHERE x.id = i.res_id)
         WHEN 'mrp.production' THEN (SELECT x.name FROM mrp_production x WHERE x.id = i.res_id)
         WHEN 'account.move' THEN (SELECT x.name FROM account_move x WHERE x.id = i.res_id)
         WHEN 'account.payment' THEN (SELECT x.name FROM account_payment x WHERE x.id = i.res_id)
         WHEN 'project.project' THEN (SELECT coalesce(x.name->>'id_ID', x.name->>'en_US') FROM project_project x WHERE x.id = i.res_id)
         WHEN 'project.task' THEN (SELECT x.name FROM project_task x WHERE x.id = i.res_id)
       END,
       i.first_seen, i.last_seen, i.fixed_at, i.write_date
FROM custom_doc_trace_issue i
WHERE i.state = 'open' OR (i.state = 'auto_fixed' AND coalesce(i.fixed_at, i.write_date) >= now() - interval '30 days')
