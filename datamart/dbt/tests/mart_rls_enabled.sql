-- depends_on: {{ ref("mart_spk") }} {{ ref("mart_spk_location") }} {{ ref("mart_spk_activity") }} {{ ref("mart_user_access") }}
-- Gagal bila ada tabel di schema mart tanpa RLS aktif atau tanpa policy client_isolation (ADR 0016 #3).
SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'mart' AND c.relkind = 'r'
  AND (NOT c.relrowsecurity OR NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = c.oid AND p.polname = 'client_isolation'))
UNION ALL
-- mart_user_access wajib berpolicy per sub (bukan per client)
SELECT 'mart_user_access:policy_bukan_sub' FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
WHERE c.relname = 'mart_user_access' AND pg_get_expr(p.polqual, p.polrelid) NOT LIKE '%app.sub%'
