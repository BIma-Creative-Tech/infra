-- Staging: gabungan raw_<slug>_<env>.payment semua tenant (ADR 0016; plan 15).
{{ union_tenants('payment') }}
