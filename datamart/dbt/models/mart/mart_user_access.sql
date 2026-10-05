{{ config(meta={'rls': 'sub'}) }}
-- Hak dashboard per Keycloak sub (= res_users.oauth_uid; login SSO sh_auth_oidc). Sumber tunggal: grup Odoo.
-- can_see_value = anggota efektif cl_expomedia_sale.group_price_viewer (Finance/Direksi; plan 20 #10), cadangan grup sales
-- di DB yang belum punya grup itu. Tanpa sub (belum SSO) diabaikan.
SELECT client_slug, env, keycloak_sub, login, name, can_see_value, is_project_user, is_ae
FROM {{ ref('stg_odoo_user') }}
WHERE active AND keycloak_sub IS NOT NULL AND keycloak_sub <> ''
