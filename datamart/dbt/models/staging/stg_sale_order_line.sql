-- Staging: gabungan raw_<slug>_<env>.sale_order_line semua tenant (ADR 0016).
{{ union_tenants('sale_order_line') }}
