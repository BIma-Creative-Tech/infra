-- Isu link dokumen (plan 18, modul Odoo custom_doc_trace): satu baris per isu terbuka atau yang diperbaiki otomatis
-- 30 hari terakhir (filter di ingest). so_id NULL = dokumen yatim (belum tertaut SPK mana pun) — tetap per client.
SELECT client_slug, env, so_id, id AS issue_id, rule_code, severity, res_model, res_id, doc_no, state, message,
       first_seen, last_seen, fixed_at
FROM {{ ref('stg_doc_trace_issue') }}
