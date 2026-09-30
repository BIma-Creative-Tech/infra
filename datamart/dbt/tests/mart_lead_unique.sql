SELECT client_slug, env, lead_id FROM {{ ref('mart_lead') }} GROUP BY 1, 2, 3 HAVING count(*) > 1
