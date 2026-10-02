-- quotation_state hanya untuk penawaran (dibuat/terkirim); SPK & batal = NULL. Baris yang dikembalikan = gagal.
SELECT client_slug, env, so_id, status, quotation_state
FROM {{ ref('mart_spk') }}
WHERE (status = 'penawaran') <> (quotation_state IS NOT NULL)
   OR quotation_state NOT IN ('dibuat', 'terkirim')
