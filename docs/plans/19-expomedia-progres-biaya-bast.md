# Plan 19 — Expomedia: progres SPK, biaya produksi & margin, tanda tangan & GPS BAST

Status 2026-10-02: data mart **LIVE** (staging & prod tenant), control-plane v0.8.0 **STAGING** (prod belum).
Pemicu: umpan balik uji user di staging (SPK uji `SPK/2026/10/02-001751`, so_id 2250):

1. progres SPK berhenti di 17 %;
2. biaya produksi (material + tenaga kerja) belum tampil;
3. margin = harga penawaran tanpa pajak − biaya produksi keseluruhan termasuk belanja PO ber-SPK;
4. Generate BAST: tanda tangan tidak bisa diinput, GPS tidak tertangkap;
5. dashboard tidak menunjukkan apakah BAST sudah ditandatangani.

Butir 1 & 4 (Odoo) dicatat di bagian Odoo; butir 2, 3, 5 di bagian Data mart & Dashboard.

## Data mart

Commit infra `16652bd` (di `main`, working tree live). Ingest baru (`datamart/ingest/expomedia/`):

| Raw | Isi | Catatan |
|---|---|---|
| `analytic_line` | baris analitik proyek SPK tanpa pendapatan (`category <> 'invoice'`): id, so_id, category, employee_id, date, hours (`unit_amount`), amount | SPK dari `project_id` (timesheet) atau `account_id` proyek (konsumsi MO, permintaan barang `picking_entry`, tagihan vendor); tanpa nama baris |
| `purchase_line_type` | jenis produk baris PO (`service` vs barang) | tabel terpisah (bukan kolom baru `purchase_line`) agar ingest lama/baru tidak memecah COPY selama transisi |
| `bast` | `custom_bast_document` (tabel opsional): status, SPK (`reference` `sale.order,<id>` / `stock.picking` → `sale_id` / kunci doc_trace), lokasi, pihak, penanda tangan + waktu, GPS (0 → NULL), `gps_accuracy` lewat `to_jsonb` (kolom modul berikutnya) | |

Model: `mart_spk_cost` (biaya per SPK), `mart_spk_bast` (satu baris per BAST) + kolom baru di **akhir** `mart_spk`
(`material_cost` lama tetap = total PO, untuk v0.7.0):

- `material_used` = −Σ analitik `manufacturing_order` + `picking_entry`; `po_goods` = Σ baris PO barang (PO `purchase`/`done`
  ber-SPK, tanpa pajak) → **`cost_material` = MAX(keduanya)**.
- `service_billed` = −Σ analitik `vendor_bill`; `po_service` = Σ baris PO jasa → **`cost_service` = MAX(keduanya)**.
- `cost_labor` = −Σ timesheet (employee_id), `labor_hours`, `labor_hours_uncosted` (jam beramount 0 = tarif karyawan kosong);
  `cost_other` = sisa baris negatif.
- `cost_total`, `value_tax` (= amount_total − amount_untaxed), **`margin` = amount_untaxed − cost_total**, `margin_pct`.
- `bast_count` / `bast_completed` / `bast_partial` / `bast_draft` (tanpa voided), `bast_last_signed_at`.

Alasan MAX: plan 17 membebankan barang saat dipakai (barang di PO ber-proyek tanpa analitik), sedangkan user minta belanja
PO ikut biaya. MAX menghitung PO yang belum terpakai/ditagih sebagai komitmen biaya tanpa hitung ganda setelah terpakai
(material yang diambil dari stok di luar PO SPK tetap masuk lewat konsumsi).

Fingerprint refresh menambah `custom_bast_document`, `product_template`. Test dbt `mart_spk_cost_bast_valid` (total =
komponen, margin = nilai − total, MAX, jam tanpa tarif ≤ jam; BAST status dikenal, unik, hitungan cocok). Validasi di
schema `preview_*` (ingest ke `preview_raw_*`, dbt 47/47), lalu live: `datamart-refresh` 47/47 PASS, schema preview di-DROP.

Angka SPK 2250 (staging): nilai tanpa PPN Rp 8.500.000, PPN Rp 935.000; material terpakai Rp 368.350 (MO WS/MO/00557),
PO barang 0 → material Rp 368.350; tagihan vendor truk Rp 1.500.000 = PO jasa P02738 → jasa Rp 1.500.000; tenaga kerja
Rp 0 dari 8 jam (**8 jam tanpa tarif** — karyawan admin `hourly_cost` 0); total Rp 1.868.350; **margin Rp 6.631.650
(78,0 %)**. BAST/2026/01081: draft → `signed_one_side` setelah TTD pertama.

Staging seluruhnya (mockup): 580 SPK, rata-rata margin 60,3 %, 24 SPK margin negatif, 75 SPK PO barang > material terpakai.

## Dashboard

control-plane **v0.8.0** (`main` `3d4aa7c`, merge `feat/spk-cost-bast` `240afd2`, tag lokal `v0.8.0`), image
`control-plane:3d4aa7c`; staging compose dipin (`04bfb6f`, rollback `8b0bf5e`, tanpa migrasi baru).

- Detail SPK: panel **Biaya produksi & margin** (hanya hak nilai; nilai tanpa PPN, PPN, material terpakai vs PO barang,
  jasa vs PO jasa, tenaga kerja + peringatan "n jam belum bertarif", total, margin Rp & % berwarna, bar komposisi) dan panel
  **BAST** (semua peran: jenis, lokasi, status Belum TTD / TTD satu pihak / Lengkap, penanda tangan + waktu kedua pihak,
  tautan Google Maps + akurasi bila GPS terekam). Badge BAST di header.
- Daftar Dashboard SPK: kolom **BAST** (semua peran) dan **Margin** (hak nilai); KPI **BAST ditandatangani** (+ SPK
  menunggu TTD).
- Kolom plan 19 dibaca lewat `to_jsonb` (`src/server/mart-spk.ts`), tabel `mart_spk_bast` dicek `to_regclass` → image
  aman di atas mart lama. Nilai (`cost_sum`, `margin_*`, `j`) hanya DIPILIH bila canSeeValue.
- Bukti: lint 0 warning, typecheck, vitest 351/351 (baru `tests/unit/spk-cost-bast.test.ts`), `next build` (docker build);
  staging `/api/health` 200, kedua container healthy; query halaman dijalankan di container staging sebagai
  `datamart_reader` + RLS `app.client=expomedia` → angka SPK 2250 di atas; client lain → 0 baris `mart_spk_bast`/`mart_spk_cost`.
  UI login Keycloak tidak diuji (tanpa user uji — pembuatan user ditolak auto mode).

### Sisa untuk prod

- Pin `web/control-plane/docker-compose.yml` ke `3d4aa7c` lalu `docker compose up -d` (aksi prod — keluar dari auto mode).
- Data mart prod sudah membawa kolom/tabel baru (tenant `expomedia:prod` kosong SO).
- Isi `hourly_cost` karyawan (staging admin & prod) agar biaya tenaga kerja kiosk tidak Rp 0.
