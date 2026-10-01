-- Kegiatan lapangan per SPK: satu baris per (tanggal, waktu, jenis, lokasi) dengan daftar crew & jam.
SELECT ts.client_slug, ts.env, ts.order_id AS so_id, ts.task_id, ts.date, ts.giat_slot AS slot, ts.giat_type AS activity_type,
       max(ts.description) AS description, string_agg(DISTINCT e.name, ', ') AS crew, sum(ts.hours) AS hours,
       count(DISTINCT ts.employee_id) AS people
FROM {{ ref('stg_timesheet') }} ts
LEFT JOIN {{ ref('stg_employee') }} e ON e.client_slug = ts.client_slug AND e.env = ts.env AND e.id = ts.employee_id
WHERE ts.order_id IS NOT NULL
GROUP BY 1, 2, 3, 4, 5, 6, 7
