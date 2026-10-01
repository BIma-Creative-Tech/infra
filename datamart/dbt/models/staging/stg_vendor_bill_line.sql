-- Staging: gabungan raw_<slug>_<env>.vendor_bill_line semua tenant (ADR 0016; detail dokumen SCM 2026-10-01).
{{ union_tenants('vendor_bill_line') }}
