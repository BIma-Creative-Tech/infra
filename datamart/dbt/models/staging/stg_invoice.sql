-- Staging: gabungan raw_<slug>_<env>.invoice semua tenant (ADR 0016).
{{ union_tenants('invoice') }}
