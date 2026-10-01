-- Staging: gabungan raw_<slug>_<env>.invoice_order semua tenant (ADR 0016).
{{ union_tenants('invoice_order') }}
