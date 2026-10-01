-- Staging: gabungan raw_<slug>_<env>.purchase_line semua tenant (ADR 0016; detail dokumen SCM 2026-10-01).
{{ union_tenants('purchase_line') }}
