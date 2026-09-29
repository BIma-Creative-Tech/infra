{#
  SELECT dari raw_<slug>_<env>.<table> untuk setiap tenant di var `tenants` yang schema-nya ada,
  ditambah kolom client_slug & env. Tidak ada tenant → hasil kosong dengan kolom yang benar tidak dijamin, jadi
  minimal satu tenant harus sudah di-ingest (ingest.sh) sebelum dbt build.
#}
{% macro union_tenants(table) -%}
  {%- if not execute -%}
    {#- fase parse: belum ada koneksi DB; isi sebenarnya dikompilasi saat eksekusi -#}
    SELECT NULL::text AS client_slug, NULL::text AS env
  {%- else -%}
  {%- set parts = [] -%}
  {%- for t in var('tenants') -%}
    {%- set rel = adapter.get_relation(database=target.database, schema='raw_' ~ t[0] ~ '_' ~ t[1], identifier=table) -%}
    {%- if rel is not none -%}
      {%- do parts.append("SELECT '" ~ t[0] ~ "'::text AS client_slug, '" ~ t[1] ~ "'::text AS env, r.* FROM " ~ rel ~ " r") -%}
    {%- endif -%}
  {%- endfor -%}
  {%- if parts | length == 0 -%}
    {{ exceptions.raise_compiler_error("Tidak ada schema raw untuk tabel " ~ table ~ " — jalankan ingest.sh dulu") }}
  {%- endif -%}
  {{ parts | join('\nUNION ALL\n') }}
  {%- endif -%}
{%- endmacro %}
