-- Plan 19: BAST (custom_bast) per SPK — satu baris per dokumen. status_label: draft = belum ditandatangani,
-- signed_one_side = baru satu pihak, completed = lengkap (kedua pihak), voided = dibatalkan (tidak dihitung di mart_spk).
-- GPS 0/NULL = tidak terekam (ingest mengubah 0 → NULL).
SELECT client_slug, env, so_id, id AS bast_id, name AS bast_no, kind, state,
       CASE state WHEN 'completed' THEN 'Lengkap' WHEN 'signed_one_side' THEN 'TTD satu pihak'
                  WHEN 'voided' THEN 'Dibatalkan' ELSE 'Belum TTD' END AS status_label,
       location, date_handover, party_from, party_to, from_signed_at, from_signed_by, to_signed_at, to_signed_by,
       gps_latitude, gps_longitude, gps_accuracy,
       nullif(greatest(coalesce(from_signed_at, '-infinity'), coalesce(to_signed_at, '-infinity')), '-infinity') AS last_signed_at
FROM {{ ref('stg_bast') }}
WHERE so_id IS NOT NULL
