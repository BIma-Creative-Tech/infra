-- Setiap dokumen SCM di mart harus tertaut ke SPK yang ada di mart_spk (plan 16).
SELECT s.client_slug, s.env, s.kind, s.doc_no FROM {{ ref('mart_spk_scm') }} s
LEFT JOIN {{ ref('mart_spk') }} m ON m.client_slug = s.client_slug AND m.env = s.env AND m.so_id = s.so_id
WHERE m.so_id IS NULL
