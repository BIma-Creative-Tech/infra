-- Staging: gabungan raw_<slug>_<env>.purchase_order semua tenant (ADR 0016, plan 16).
{{ union_tenants('purchase_order') }}
