# Plan 19 — Expomedia: progres SPK, biaya produksi & margin, tanda tangan & GPS BAST

Status 2026-10-02: data mart **LIVE** (staging & prod tenant), control-plane v0.8.0 **STAGING** (prod belum), modul Odoo siap (tes lulus) — **belum di-deploy** (upgrade staging ditolak auto mode).
Pemicu: umpan balik uji user di staging (SPK uji `SPK/2026/10/02-001751`, so_id 2250):

1. progres SPK berhenti di 17 %;
2. biaya produksi (material + tenaga kerja) belum tampil;
3. margin = harga penawaran tanpa pajak − biaya produksi keseluruhan termasuk belanja PO ber-SPK;
4. Generate BAST: tanda tangan tidak bisa diinput, GPS tidak tertangkap;
5. dashboard tidak menunjukkan apakah BAST sudah ditandatangani.

Butir 1 & 4 (Odoo) dicatat di bagian Odoo; butir 2, 3, 5 di bagian Data mart & Dashboard.

## Odoo — progres SPK (butir 1)

Akar masalah: progres dashboard = urutan stage task (Desain 1/6 = 17 %), dan stage hanya diubah manual. SPK 001751
sudah punya MO selesai, surat jalan terkirim, invoice lunas — task tetap "Desain". Modul baru client
**`cl_expomedia_progress` 19.0.1.0.0** (addons `v19.0.2.7.0`, `e47e645`): stage task SPK **hanya maju** dari dokumen nyata,
dengan alasan di chatter task — Produksi (PO/MO SPK dikonfirmasi), Instalasi (surat jalan keluar selesai), Laporan (BAST
dibuat, menunggu TTD), BAST (BAST lengkap kedua pihak), Selesai (BAST lengkap + SPK lunas). Dokumen SPK = kunci Lacak
Dokumen `x_custom_trace_order_id` atau proyek SPK; BAST ber-lokasi hanya memajukan task lokasinya. Tanpa backfill otomatis
saat install (data mockup mengikuti gsheet): SPK lama lewat Aksi → **Perbarui progres dari dokumen**; importer bisa
memakai konteks `cl_expomedia_progress_skip`. Data mart tidak berubah (tetap membaca stage task).

## Odoo — tanda tangan & GPS BAST (butir 4)

Akar masalah tanda tangan (log Traefik 2026-10-02 09:30–09:32, IP kantor): membuka kotak tanda tangan memanggil
`/web/sign/get_fonts/` yang mengirim **semua** font tanda tangan (±1,3 MB); dialog lambat muncul → klik berulang → 100+
permintaan paralel ke pool staging (2 worker) → 502/504, tanda tangan tidak tersimpan. GPS: wizard hanya punya isian
angka manual, tidak ada pengambilan lokasi.

Platform **`custom_bast` 19.0.0.3.0** (`v19.0.1.3.0`, `9edf2ec`): wizard memakai `default_font` (satu font ±70 KB),
widget `bast_gps` mengambil lokasi browser otomatis saat wizard dibuka (+ tombol "Ambil lokasi", pesan bila izin ditolak /
bukan HTTPS; `Permissions-Policy: geolocation=(self)` sudah ada di Traefik), field `gps_accuracy`, `gps_captured_at`,
`gps_map_url` + tombol GPS (Google Maps) di form; wizard berbahasa Indonesia, pihak & nama penanda tangan terisi otomatis.
**`cl_expomedia_report` 19.0.1.2.0**: PDF BAST memuat waktu tanda tangan per pihak + lokasi GPS (±akurasi).

Bukti: Odoo sekali pakai terisolasi (Postgres + Odoo di network docker privat, DB baru, modul dari working copy):
**21/21 tes** (`/custom_bast` 7, `/cl_expomedia_progress` 8, `/cl_expomedia_report` 6; `test_pdf_renders` dikecualikan —
wkhtmltopdf timeout di container terisolasi, tidak terkait perubahan). Chromium headless (Playwright 1.55, geolocation
palsu): wizard → GPS `-6.225300, 106.799100 (±12 m)` otomatis, nama default, gambar tanda tangan → Adopt → Simpan → status
"Signed (one side)", tombol GPS muncul; `get_fonts` 1× / 71 KB; 0 error konsol. Konteks non-secure → pesan HTTPS tampil.

### Deploy Odoo staging (BELUM — upgrade ditolak auto mode)

```bash
f=/opt/infra/backups/odoo/expomedia_staging-$(date +%Y%m%d-%H%M%S)-pre-plan19.dump
(umask 077; docker exec postgres pg_dump -U postgres -Fc expomedia_staging > "$f")
cd /opt/infra
git -C staging/odoo/addons/platform checkout v19.0.1.3.0
git -C staging/odoo/addons/clients/expomedia checkout v19.0.2.7.0
docker exec odoo-staging odoo -c /etc/odoo/odoo.conf -d expomedia_staging -u custom_bast,cl_expomedia_report \
  -i cl_expomedia_progress --stop-after-init --no-http --workers=0 --max-cron-threads=0
docker restart odoo-staging
```

Lalu SPK 001751 (dan SPK uji lain): Sales → SPK → Aksi → Perbarui progres dari dokumen (atau `env['sale.order']
.browse(2250).action_cl_progress_sync()`), commit pin submodule staging. Prod: sama untuk `odoo/pool-a` + `expomedia_prod`.
Backup staging sudah dibuat: `expomedia_staging-20261002-171700-pre-plan19.dump`.

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
