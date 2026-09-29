{#
  ADR 0016 #3: setiap tabel mart dibuat ulang tiap run → RLS + GRANT dipasang ulang (post-hook).
  Pembaca (datamart_reader, NOBYPASSRLS, bukan owner) hanya melihat baris sesuai setting transaksi yang di-SET LOCAL
  aplikasi: mode 'client' → client_slug = app.client; mode 'sub' → keycloak_sub = app.sub (daftar client milik user
  yang login, dipakai sebelum app.client diketahui). Mode dari config model `meta.rls` (default 'client'). Owner (dbt) tidak terkena policy (tanpa FORCE) agar test dbt jalan.
#}
{% macro secure_mart() -%}
  {%- set meta = config.get('meta') -%}
  {%- set mode = meta.get('rls', 'client') if meta is mapping else 'client' -%}
  ALTER TABLE {{ this }} ENABLE ROW LEVEL SECURITY;
  DROP POLICY IF EXISTS client_isolation ON {{ this }};
  CREATE POLICY client_isolation ON {{ this }} FOR SELECT TO datamart_reader
    USING (
    {%- if mode == 'sub' %} keycloak_sub = current_setting('app.sub', true)
    {%- else %} client_slug = current_setting('app.client', true)
    {%- endif %});
  REVOKE ALL ON {{ this }} FROM PUBLIC;
  GRANT SELECT ON {{ this }} TO datamart_reader
{%- endmacro %}
