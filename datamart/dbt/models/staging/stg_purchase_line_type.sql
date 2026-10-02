-- Staging: gabungan raw_<slug>_<env>.purchase_line_type semua tenant (plan 19, barang vs jasa baris PO).
{{ union_tenants('purchase_line_type') }}
