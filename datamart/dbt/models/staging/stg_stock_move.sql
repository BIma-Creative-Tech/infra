-- Staging: gabungan raw_<slug>_<env>.stock_move semua tenant (ADR 0016; detail dokumen SCM 2026-10-01).
{{ union_tenants('stock_move') }}
