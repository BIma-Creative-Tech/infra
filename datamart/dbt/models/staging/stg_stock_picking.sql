-- Staging: gabungan raw_<slug>_<env>.stock_picking semua tenant (ADR 0016, plan 16).
{{ union_tenants('stock_picking') }}
