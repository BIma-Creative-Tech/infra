# Plan 16 — Expomedia: modul tak terpakai dicabut, supply chain per SPK, dashboard real-time, PDF bermerek

Status 2026-09-30: **STAGING & PROD SELESAI** (§6, §7). Kelanjutan plan 13/14/15.

## 1. Permintaan user (2026-09-30)

1. Modul PMO terbawa di penerapan Expomedia — seharusnya tidak dipasang. Tambahan: Point of Sale juga tidak dipakai;
   kebutuhan "workshop center yang terbagi" bukan operating unit/cabang.
2. Data harus masuk ke tiap modul (SCM → invoice) dan terlihat di dashboard; di `expomedia_staging` Purchase, Inventory
   dan Manufacturing masih kosong.
3. Setiap pergerakan CRM → penawaran → SPK → invoice → pembayaran klien meng-update dashboard.
4. Output PDF disesuaikan dengan alur yang sudah dibuat (PNW/SPK) dan memakai logo.

## 2. Modul dicabut

| Modul | Alasan | Staging | Prod |
|---|---|---|---|
| `custom_project_portfolio` (PMO) | Tidak dipakai; stage/SLA bentrok dengan template Booth/Event | uninstall ✔ | uninstall ✔ |
| `point_of_sale` + `pos_hr pos_mrp pos_sale pos_online_payment spreadsheet_dashboard_pos_hr` | Tidak dipakai (0 POS order) | uninstall ✔ | uninstall ✔ |
| `custom_operating_unit` | Depends wajib ke `point_of_sale`; 0 operating unit. Workshop = `stock.warehouse` (mis. `Workshop Benda`/WS) | uninstall ✔ | uninstall ✔ |

Backup sebelum uninstall: `pg_dump -Fc` di scratchpad sesi (600).

## 3. Supply chain per SPK (standar Odoo, data MOCKUP di Demo)

Importer `odoo-data-expomedia/tools/import_sheet_standard.py` tahap `supply_chain()` (SPK ≥ Produksi):
PO material per vendor + PO truk (`project_id` = proyek SPK → analitik/profitabilitas proyek, `origin` = No. SPK) →
Receipt di gudang WS → Vendor Bill (+ pembayaran vendor SPK Jan–Jun) → MO `FG-BOOTH` 1 unit/lokasi (komponen =
material diterima, `project_id`) → ≥ Instalasi: MO selesai + Surat Jalan per lokasi (`sale_id` SPK, `project_id`).
`configure_standard.py`: pricelist → IDR (staging "Default" USD → semua SO/invoice tercetak "$"), produk `FG-BOOTH`.
Reset `--keep-master` (transaksi saja); reset kini juga menghapus proyek buatan SO (bug urutan lama).

## 4. Dashboard (data mart + control-plane)

- Ingest baru: `crm_lead`, `purchase_order`, `stock_picking`, `mrp_production`, `vendor_bill`; `partner` + partner lead.
- dbt: `mart_lead`, `mart_spk_scm` (dokumen PO/receipt/MO/surat jalan/bill per SPK), `mart_spk` + `lead_id`,
  `po_count`, `material_cost`, `mo_*`, `delivery_*`, `vendor_billed/paid`; status terakhir SPK ikut dokumen SCM.
  Tes: `mart_lead_unique`, `mart_spk_scm_linked`, RLS mencakup mart baru.
- Refresh berbasis perubahan: timer tiap 2 menit (`RandomizedDelaySec=20s`); `datamart-refresh.sh` menghitung sidik jari
  `pg_stat_user_tables` (ins+upd+del tabel alur) per tenant → skip bila sama dan < 30 menit sejak run sukses.
  State: `StateDirectory=datamart-refresh`. Jeda aksi Odoo → dashboard ≈ 2–3 menit.
- control-plane (branch `feat/tracker-crm-scm`): funnel Lead CRM → Penawaran → SPK → Pengadaan (PO) → Produksi →
  Terkirim → Absensi → Ditagih → Lunas; kartu nilai + pipeline lead, biaya material, hutang vendor; kolom "Pengadaan &
  kirim"; daftar lead terbaru tanpa penawaran (tautan Odoo CRM); detail SPK seksi "Pengadaan, produksi & pengiriman".
  Nilai tetap hanya dipilih untuk `canSeeValue`.

## 5. PDF (`cl_expomedia_report`, addons expomedia)

Penawaran Harga / SPK, Invoice (DP, LUNAS, terbilang), Kuitansi, PO/RFQ, Surat Jalan / Penerimaan Barang, Perintah
Produksi — Bahasa Indonesia, logo company, aksen grafit. Tombol Print standar diarahkan lewat fungsi yang dipanggil
setiap install/upgrade; `uninstall_hook` memulihkan template `custom_report_templates`/standar.

## 6. Hasil & bukti (staging)

| Bagian | Bukti |
|---|---|
| Modul | staging 188 modul terpasang; uninstall PMO lalu POS/OU tepat 1 + 7 modul, `/web/login` 200, log tanpa ERROR |
| Mata uang | 742 SO, 4.882 jurnal, 2.178 PO semuanya IDR |
| Data | 742 lead → 742 penawaran (577 SPK), 825 task, 779 invoice (506 lunas), 1.527 timesheet; SCM 2.178 PO, 2.178 tagihan vendor, 1.419 pembayaran vendor, 1.724 penerimaan, 454 MO, 698 surat jalan |
| Idempoten | sinkron ulang dry-run: 0 dokumen baru; reset dry-run `--keep-master` 12.783 record (quant dikembalikan) |
| Kinerja | satu transaksi ±6–7 PO/menit (≈6 jam) → commit tiap 10–20 SPK ≈ 40–50 PO/menit (SCM ±35 menit) |
| Perbaikan | surat jalan ber-`sale_id` membuat sale_stock menambah baris FG-BOOTH qty 0 ke SPK → tautan via proyek + origin, 450 baris dibersihkan; tanggal MO selesai di-flush sebelum backdate |
| PDF | `cl_expomedia_report` 19.0.1.0.0 (addons tag `v19.0.2.3.0`), 6/6 tes di salinan DB `rpttest_staging`; 8 action Print terarah; sampel SPK/PNW/Invoice/Kuitansi/PO/Surat Jalan/Penerimaan/Perintah Produksi dicek visual |
| Data mart | ingest + dbt 30/30 PASS (timer 20:05, 20:35, 21:05); mart: 454 SPK berpengadaan, 450 terkirim, biaya material Rp 7,0 M, hutang vendor Rp 2,4 M |
| control-plane | `feat/tracker-crm-scm` `cb5e8a1`: 328 unit test, tsc, eslint lulus; image `control-plane:cb5e8a1` di cp.staging (healthy; rollback `eb5ab2d`, tanpa migrasi) |

| BAST | importer `handover()`: 540 BAST draft per lokasi (tahap BAST); PDF BAST Expomedia (`cl_expomedia_report` 19.0.1.1.0, addons `v19.0.2.4.0`), 7/7 tes |
| Real-time | timer tiap 2 menit diterapkan (Ansible); run `skip` bila sidik jari sama. Uji: lead baru di CRM staging → muncul di `mart.mart_lead` **41 detik** kemudian (lead uji dihapus) |

DB uji `rpttest_staging` sudah di-drop.

## 7. Prod (SELESAI 2026-09-30, setelah user keluar dari auto mode)

| Langkah | Bukti |
|---|---|
| Backup | `pg_dump` `expomedia_prod` pra-uninstall PMO & pra-uninstall POS, `control_plane` pra-v0.5.0 (scratchpad sesi, 600) |
| Modul | PMO lalu POS + OU (7 modul) di-uninstall; 187 modul → + `cl_expomedia_report`; `/web/login` 200 |
| Addons | submodule `odoo/pool-a/addons/clients/expomedia` → `v19.0.2.4.0`; `-i cl_expomedia_report -u cl_expomedia_web`; 9 action Print terarah |
| Konfigurasi | `configure_standard.py`: FG-BOOTH dibuat, pricelist sudah IDR. Uji render Penawaran dalam transaksi rollback: judul Indonesia, Rp, logo; counter PNW dikembalikan ke 1 (sequence standar tidak ikut rollback) |
| control-plane | main `4309281` (merge `feat/tracker-crm-scm` + rilis), tag annotated **v0.5.0**, image `control-plane:4309281` di prod & staging (healthy; rollback prod `c4c1051`, staging `eb5ab2d`, tanpa migrasi) |
| Data mart | tenant `expomedia:prod` ter-ingest dengan tabel baru; dbt PASS |
