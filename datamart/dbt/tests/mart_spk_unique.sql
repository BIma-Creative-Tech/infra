SELECT client_slug, env, so_id FROM {{ ref('mart_spk') }} GROUP BY 1, 2, 3 HAVING count(*) > 1
