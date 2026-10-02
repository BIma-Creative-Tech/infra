# Plan 17 — Expomedia: biaya & margin per SPK (produksi, PO, permintaan barang, kiosk tukang)

Status 2026-10-02: **STAGING & PROD SELESAI**. Kelanjutan plan 16. Pemicu: umpan balik uji user di staging
(SPK uji `SPK/2026/10/02-001750`). Tujuan user: semua biaya produksi & tenaga kerja terukur per SPK → margin
(= Project → Profitabilitas standar, akun analitik proyek SPK).

## 1. Permintaan & keputusan

| # | Permintaan | Keputusan / solusi |
|---|---|---|
| 1 | Status penawaran terkirim | Standar `sale.order.state = sent` (Send email / tombol **Tandai Terkirim**); data mart `mart_spk.quotation_state`, dashboard "Penawaran dibuat/terkirim" |
| 2 | JSA-BOOTH-M2 tidak membuat MO | Jasa tidak pernah memicu procurement → baris barang `PRD-BOOTH-M2` (m², MTO + Manufacture + BoM). Penagihan semua produk SPK **Prepaid/Fixed Price** (keputusan user: bisa tagih penuh / DP / bertahap tanpa menunggu milestone) |
| 3 | Shortcut PO ber-No. SPK | `cl_expomedia_scm`: tombol Buat PO + smart button PO di SPK, origin = No. SPK, pencarian No. SPK |
| 4 | Permintaan barang Ops per SPK | Standar: Workshop 2 langkah (Pick Components dari MO) + operasi **Permintaan Barang SPK** (`analytic_costs`, lokasi Pemakaian SPK) |
| 5 | Kiosk absensi + SPK | `cl_expomedia_kiosk`: setelah scan pilih SPK/lokasi → check-out membuat timesheet ½/1 hari di task SPK (biaya = upah harian). Tukang borongan = PO jasa `JSA-SUBKON-TKG` ber-proyek |

## 2. Temuan & perbaikan

- **Nomor PNW di proyek/MO/picking**: `custom_doc_numbering` mengganti nomor setelah `action_confirm` → kini sebelum
  (platform `v19.0.1.1.2`, modul 19.0.1.0.2, tes regresi). Proyek bernama `<SPK> - Booth / Event` (template diganti nama,
  579 proyek staging dirapikan).
- **Biaya barang terhitung ganda** (tagihan vendor PO ber-proyek + konsumsi MO): barang (storable & habis pakai) di PO
  ber-proyek tidak lagi diberi analitik proyek; jasa tetap. Data demo staging diperbaiki
  (`odoo-data-expomedia/tools/repair_double_count_2026-10-02.py`): analitik tagihan vendor Rp 7,01 M → Rp 1,05 M (truk).
- **Prod tanpa `x_doc_code`** → SPK di prod tidak pernah dinomori ulang. Diset `EXP` (sama dengan staging; invoice pelanggan
  `INV/EXP/YYYY/MM/NNN`, prod belum punya SO/invoice).

## 3. Rilis

| Komponen | Versi | Staging | Prod |
|---|---|---|---|
| platform (`odoo-addons-athera`) | `v19.0.1.1.2` (`11c931a`) | ✔ `-u custom_doc_numbering` | ✔ |
| client (`odoo-addons-expomedia`) | `v19.0.2.6.0` (`277b047`): `cl_expomedia_scm` 19.0.1.0.0, `cl_expomedia_kiosk` 19.0.1.0.0, `cl_expomedia_sale` 19.0.1.1.0 | ✔ | ✔ |
| konfigurasi (`odoo-data-expomedia` `feat/booth-mto-prepaid`) | `configure_standard.py` §3, §7–9 | ✔ (gudang WS, BoM per m² MOCKUP) | ✔ (gudang utama `WH`, BoM tanpa komponen — diisi per MO) |
| data mart | infra `501a934` (`quotation_state`) | ✔ dbt 38/38 | ✔ |
| control-plane | `v0.6.0` image `0def3c7` (redesign + pengadaan per PO + penawaran terkirim) | ✔ | ✔ (rollback `4309281`, tanpa migrasi) |

## 4. Bukti

- Tes: `custom_doc_numbering` 5, `cl_expomedia_scm` 5 + `cl_expomedia_sale` 5, `cl_expomedia_kiosk` 11 — semua lulus di
  salinan DB staging (container sekali pakai, `proxy_mode = False`), salinan di-drop.
- E2E staging (rollback): SPK JSA-DES + 36 m² booth → MO `WS/MO` 36 m² ber-proyek, Pick Components, surat jalan WS; DP 30 % +
  pelunasan = total; biaya proyek: komponen MO Rp 13,26 jt, Permintaan Barang Rp 605 rb. Salinan DB: proyek, MO origin dan
  picking bernomor SPK.
- Kiosk staging di Chromium headless (Playwright, locale `id-ID` — locale POSIX membuat luxon gagal): scan → pemilih SPK
  (30 SPK, cari "SPK/2026/10" → 3) → check-in → check-out → timesheet ½ hari Rp 277.456 di task SPK. Data uji dihapus.
- Prod (rollback, sequence dikembalikan): `PNW/2026/10/02-000001 → SPK/2026/10/02-000001`, MO `WH/MO/00001` origin SPK +
  proyek, `invoice_status = to invoice`. `/web/login` prod 200 setelah recreate; `cp` prod & staging `/api/health` 200.
- Backup pra-deploy (600): `backups/odoo/expomedia_staging-20261002-102106-pre-scm.dump`,
  `expomedia_prod-20261002-104926-pre-plan17.{dump,filestore.tgz}`, `control_plane-20261002-104926-pre-v0.6.0.dump`.

## 5. Sisa / catatan

- Prod: gudang masih bernama "My Company" (`WH`) dan belum ada master material → BoM `PRD-BOOTH-M2` kosong; isi master
  gudang Workshop & material sebelum produksi nyata. Karyawan prod perlu `hourly_cost` (upah harian ÷ 8) dan badge.
- Kiosk: hanya kiosk `hr_attendance` (`/hr_attendance/<token>`) yang meminta SPK; kiosk PIN `custom_attendance` tidak.
- Importer demo: produk SPK prepaid → milestone tidak lagi dibuat otomatis; pick components divalidasi sebelum MO selesai.
- `odoo-data-expomedia` di-merge ke `main` (`feat/booth-mto-prepaid`).
