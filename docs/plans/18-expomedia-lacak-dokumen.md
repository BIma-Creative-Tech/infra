# Plan 18 — Lacak Dokumen: link dokumen tidak pernah lepas (`custom_doc_trace`)

Status 2026-10-02: **STAGING & PROD SELESAI**. Rencana rinci: sesi Claude `/root/.claude/plans/ini-yang-selalu-saya-sleepy-steele.md`.

## Masalah
User berulang kali menemukan dokumen "terlepas mapping-nya" (contoh: tagihan `BILL/2026/10/0001` Rp 0 duplikat di PO
P02738). Riset Odoo 19: link tidak dihapus saat batal, tetapi **hilang/tidak dibuat** pada duplikasi (`copy=False`),
dokumen manual tanpa PO/SO (GR, tagihan, invoice), retur, PO dibuat ulang setelah batal (MTO→MTS), ganti BoM MO,
pembayaran tanpa rekonsiliasi; "Create Bill" pada PO tertagih penuh membuat tagihan 0.

## Solusi (modul platform, inert sampai diaktifkan per company)
1. **Kunci SPK** `x_custom_trace_order_id` di PO, picking, account.move, account.payment, proyek, MO (copy=True,
   terisi otomatis dari akar yang pasti) + `x_custom_trace_copied_from_id` pada duplikasi.
2. **Perbaikan perilaku**: duplikasi PO/MO/tagihan/invoice membawa link aman; PO pengganti mewarisi link; GR/tagihan/
   invoice manual tertaut bila tepat satu kandidat (ambigu → wizard); retur "Retur X · SPK"; ganti BoM tidak menghapus
   proyek; **blokir tagihan 0**; rekonsiliasi otomatis pembayaran manual (kandidat tunggal); wizard batal SPK.
3. **Lacak Dokumen** (tombol di SO/PO/picking/MO/tagihan/pembayaran/proyek) + **isu link** (12 aturan, auto-fix yang
   pasti, cron harian inkremental + penuh mingguan) + data mart (`mart_spk_issue`, `mart_spk.issue_count`, kunci SPK
   sebagai link utama, tagihan 0/batal tidak tampil) + badge/panel isu di Dashboard SPK.

## Rilis
| Komponen | Versi | Staging | Prod |
|---|---|---|---|
| platform `odoo-addons-athera` | `v19.0.1.2.1` (`f1d8034`): `custom_doc_trace` 19.0.1.0.1, `custom_doc_trace_mrp` 19.0.1.0.0 | ✔ aktif | ✔ aktif |
| data mart | infra `08b0bdd` | ✔ dbt 41/41 | ✔ |
| control-plane | `v0.7.0` image `8b0bf5e` | ✔ | ✔ (rollback `0def3c7`, tanpa migrasi) |
| `odoo-data-expomedia` | `e3b679d` (rapikan nama proyek semua bahasa) | ✔ | ✔ |

## Bukti
- Tes: 60 (`custom_doc_trace`) + 10 (`_mrp`) + regresi `cl_expomedia_*` = 67 lulus di salinan DB staging dengan
  `limit_memory_hard` 768 MB. Gabungan awal A+B: 13 MemoryError (scan penuh di tiap tes) → scan per batch 500 +
  inkremental; scan penuh staging 56–61 dtk, RSS ±198 MB.
- Staging scan pertama: 12.448 kunci SPK terisi (PO 2179/2180, picking 2423/2423, jurnal 4885/4885, payment 1926/1926,
  proyek 580/583, MO 455/455); auto-fix: bill 8579 dibatalkan, proyek 2912/2913 → nomor SPK; isu terbuka PO 2737
  (RFQ tanpa SPK); tanpa false positive 698 picking ber-proyek & 599 timesheet GIAT.
- Uji UI Chromium (Playwright, user uji sementara dengan grup user staging — dihapus): Lacak Dokumen dari SPK, PO,
  tagihan, pembayaran, picking, MO, proyek → alur 12 baris yang sama; daftar & form isu, Settings, 3 wizard perbaikan
  ter-render. **Bug ditemukan & diperbaiki**: `len()` di ekspresi view → OwlError (19.0.1.0.1).
- Prod (rollback, sequence dikembalikan): SPK→PO→tagihan berkunci SPK, Create Bill ke-2 ditolak, wizard 5 baris.
  `/web/login` prod 200 setelah recreate pool-a; cp prod & staging `/api/health` 200.
- Backup: `backups/odoo/expomedia_staging-20261002-145557-pre-doctrace.dump`,
  `expomedia_prod-20261002-151116-pre-plan18.{dump,filestore.tgz}`, `control_plane-20261002-151116-pre-v0.7.0.dump`.

## Catatan
- `configure_standard.py` sebelumnya hanya mengganti nama proyek di `en_US` (nama = jsonb terjemahan; `is_template`
  NULL pada proyek lama) → kini SQL di semua bahasa.
- Regresi pra-ada (bukan dari plan ini): `custom_accounting_full` tes `TestBillRefGuard` (guard menolak saat create,
  tes mengharapkan saat posting) dan setUpClass `project_project.billing_type` NOT NULL.
- Admin password di `staging/odoo/secrets/tenants/expomedia_staging.admin-password` tidak cocok dengan DB.
