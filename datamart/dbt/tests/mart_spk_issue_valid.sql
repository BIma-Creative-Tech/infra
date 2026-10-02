-- plan 18: isu valid (severity & status dikenal, unik per client/env) dan issue_count di mart_spk = jumlah isu terbuka.
-- Baris yang dikembalikan = gagal.
SELECT client_slug, env, issue_id::text AS key, 'nilai tidak dikenal' AS reason FROM {{ ref('mart_spk_issue') }}
WHERE severity NOT IN ('info', 'warn', 'error') OR state NOT IN ('open', 'auto_fixed')
UNION ALL
SELECT client_slug, env, issue_id::text, 'duplikat' FROM {{ ref('mart_spk_issue') }}
GROUP BY client_slug, env, issue_id HAVING count(*) > 1
UNION ALL
SELECT m.client_slug, m.env, m.so_id::text, 'issue_count tidak cocok'
FROM {{ ref('mart_spk') }} m
LEFT JOIN (SELECT client_slug, env, so_id, count(*) AS n FROM {{ ref('mart_spk_issue') }}
           WHERE state = 'open' GROUP BY 1, 2, 3) i
  ON i.client_slug = m.client_slug AND i.env = m.env AND i.so_id = m.so_id
WHERE m.issue_count <> coalesce(i.n, 0)
