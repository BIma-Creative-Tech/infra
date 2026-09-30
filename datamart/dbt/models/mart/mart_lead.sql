-- Satu baris per lead/opportunity CRM (plan 16) — langkah "Lead" Quotation Tracker. Partner lead = brand (kontak di
-- bawah group) seperti SO; customer = group. AE murni hanya melihat miliknya (filter ae_login di aplikasi).
SELECT l.client_slug, l.env, l.id AS lead_id, l.name, l.type, l.stage, l.status,
       ae.name AS ae, ae.login AS ae_login,
       coalesce(grp.name, brand.name) AS customer, brand.name AS brand,
       l.expected_revenue, l.create_date, l.date_closed, l.so_id, (l.so_id IS NOT NULL) AS has_quotation,
       l.is_mockup, now() AS refreshed_at
FROM {{ ref('stg_crm_lead') }} l
LEFT JOIN {{ ref('stg_partner') }} brand ON brand.client_slug = l.client_slug AND brand.env = l.env AND brand.id = l.partner_id
LEFT JOIN {{ ref('stg_partner') }} grp ON grp.client_slug = l.client_slug AND grp.env = l.env AND grp.id = brand.parent_id
LEFT JOIN {{ ref('stg_odoo_user') }} ae ON ae.client_slug = l.client_slug AND ae.env = l.env AND ae.id = l.user_id
WHERE l.status <> 'archived'
