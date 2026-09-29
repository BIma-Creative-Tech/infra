-- Satu baris per lokasi (task SO). Tahap = stage task; progres dari urutan stage template "Booth / Event"
-- (Desain=1 … Selesai=6; configure_standard.py). Nilai baris = subtotal baris SO (dibaca hanya bila can_see_value).
WITH ts AS (
  SELECT client_slug, env, task_id, sum(hours) AS hours, count(DISTINCT employee_id) AS people,
         max(date) AS last_date,
         (array_agg(description ORDER BY date DESC, write_date DESC))[1] AS last_desc
  FROM {{ ref('stg_timesheet') }} WHERE task_id IS NOT NULL GROUP BY 1, 2, 3
)
SELECT t.client_slug, t.env, t.sale_order_id AS so_id, t.id AS task_id,
       coalesce(nullif(split_part(t.name, ' — ', 2), ''), t.name) AS location, t.name AS task_name,
       st.name AS stage, coalesce(st.sequence, 0) AS stage_seq,
       round(100.0 * least(coalesce(st.sequence, 0), 6) / 6)::int AS progress_pct,
       t.date_deadline, t.date_last_stage_update AS stage_updated_at,
       coalesce(ts.hours, 0) AS crew_hours, coalesce(ts.people, 0) AS crew_people,
       ts.last_date AS last_activity_date, ts.last_desc AS last_activity,
       coalesce(l.price_subtotal, 0) AS value
FROM {{ ref('stg_project_task') }} t
LEFT JOIN {{ ref('stg_project_task_type') }} st ON st.client_slug = t.client_slug AND st.env = t.env AND st.id = t.stage_id
LEFT JOIN {{ ref('stg_sale_order_line') }} l ON l.client_slug = t.client_slug AND l.env = t.env AND l.id = t.sale_line_id
LEFT JOIN ts ON ts.client_slug = t.client_slug AND ts.env = t.env AND ts.task_id = t.id
