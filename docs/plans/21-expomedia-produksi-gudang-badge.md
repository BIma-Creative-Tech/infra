# Plan 21 — Expomedia: produksi paralel WP + WAPR, gudang RS, stok awal, badge karyawan

Status 2026-11-17: **STAGING LIVE**; prod: modul `cl_expomedia_scm` 19.0.1.4.0 ter-upgrade di DB (restart `odoo-pool-a`,
impor master asli dan `configure_standard.py` dijalankan owner — diblokir hook/auto mode untuk agen).

## Keputusan user (2026-11-17)

| # | Keputusan |
|---|---|
| Produksi | GP → **WP** (rangka, panel, rakit akhir) & **WAPR** (komponen akrilik/printing) paralel; komponen WAPR dikirim ke WP |
| Material SPK | PO langsung diterima di WP/WAPR (default WP); GP1–GP4 = stok umum, dipindah manual |
| Reusable & sisa potong | Satu gudang **RS** "Gudang Reusable & Sisa Potong", lokasi `Properti Booth Reusable` & `Sisa Potong` |
| Stok awal | PO stok awal + Inventory Adjustment (training M0, UAT STK-01..05) |
| Badge | `EXPOH###` pekerja harian, `EXPOT###` pegawai tetap (Odoo: badge huruf+angka saja, tanpa tanda hubung) |

## Implementasi

- `odoo-data-expomedia` `main` `4775641` (merge `feat/d1711-gudang-tahap-badge`): `configure_standard.py` — SFG-AKRILIK-M2
  (biaya standar 0, kategori "Barang Setengah Jadi (SPK)") dibuat di WAPR, rute resupply WP←WAPR (urutan 3, aturan sumber
  `mts_else_mto`), BoM booth di WP; WP & WAPR `pbm`; gudang RS + operasi Pakai Barang Reuse SPK / Retur Dismantle dari Venue /
  Simpan Sisa Potong; Permintaan Barang SPK di WP & WAPR; SO/PO default WP; kiosk `barcode_manual`; SMS konfirmasi
  pengiriman nonaktif. Template 05_Karyawan kolom `badge`, importer → `hr.employee.barcode`, normalisasi mengisi otomatis.
- `odoo-addons-expomedia` `v19.0.3.3.0`: `cl_expomedia_scm` 19.0.1.4.0 — MO tanpa proyek mengambil proyek SPK dari kunci
  Lacak Dokumen (Odoo 19 tidak meneruskan `project_id` ke MO yang terbit lewat rute antar-gudang). Tes 8/8 (salinan DB staging).

## Temuan

- **Lokasi produksi gudang salah** (staging & prod): `stock.warehouse._get_production_location` = lokasi `usage=production`
  pertama urut `complete_name` → "Pemakaian SPK" (sebelum "Production") → aturan Pick Components/MTO semua gudang mengarah ke
  Pemakaian SPK, Pick Components & MO komponen tidak terbit. Perbaikan: Pemakaian SPK jadi sub-lokasi Production, aturan
  dibangun ulang (`configure_standard.py`).
- `stock_sms`: validasi transfer keluar pertama memunculkan dialog SMS berbayar → `stock_text_confirmation = False`.

## Bukti staging

Backup: `backups/odoo/expomedia_staging-20261117-004011-pre-gudang-tahap-badge.dump`, `…-005724-pre-v19.0.3.3.0.dump`.
Impor master 682 baris 0 error (48 badge, 25 tarif harian → `hourly_cost`). E2E (rollback): SPK 36 m² → MO WAPR + MO WP
ber-proyek SPK, transfer WAPR → transit → WP, surat jalan WP; analitik proyek = material kedua MO (Rp 400.000 uji), komponen
akrilik tidak dihitung ganda; aturan ke Pemakaian SPK = 0.

## Prod

Backup `backups/odoo/expomedia_prod-20261117-005950-pre-v19.0.3.3.0.{dump,filestore.tgz}`; pin pool-a `v19.0.3.3.0`;
`-u cl_expomedia_scm -d expomedia_prod` exit 0. Sisa (owner):
1. `docker restart odoo-pool-a`
2. `tools/run-import.sh odoo-pool-a expomedia_prod isian/master-asli-2026-11-17-norm.xlsx` (dry-run 688 baris, 0 error)
3. `tools/run-odoo-script.sh odoo-pool-a expomedia_prod tools/configure_standard.py` (dry-run dulu)

Rollback: pin `v19.0.3.2.1` + restore dump.
