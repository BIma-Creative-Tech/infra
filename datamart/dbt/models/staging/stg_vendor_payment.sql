-- Staging: gabungan raw_<slug>_<env>.vendor_payment semua tenant (ADR 0016; detail dokumen SCM 2026-10-01).
{{ union_tenants('vendor_payment') }}
