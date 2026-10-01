{{ config(meta={'rls': 'sub'}) }}
-- Hak dashboard per Keycloak sub (= res_users.oauth_uid; login SSO sh_auth_oidc). Sumber tunggal: grup Odoo.
-- can_see_value = anggota efektif sales_team.group_sale_salesman (Owner/Finance). Tanpa sub (belum SSO) diabaikan.
SELECT client_slug, env, keycloak_sub, login, name, can_see_value, is_project_user, is_ae
FROM {{ ref('stg_odoo_user') }}
WHERE active AND keycloak_sub IS NOT NULL AND keycloak_sub <> ''
