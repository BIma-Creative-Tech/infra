# Plan 20 — Expomedia: masukan pertemuan klien 2026-10-05

Status 2026-10-06: gelombang A, B, C + harga katalog **LIVE STAGING & PROD** (platform `v19.0.1.4.2`, client `v19.0.3.2.1`);
prod: restart `odoo-pool-a` oleh owner; website menunggu URL akun Instagram + unggahan company profile. Sumber: catatan pertemuan klien (poin 1–3,
5–10; poin 4 tidak ada di catatan). Fit-gap = gerbang wajib sebelum kode custom (standar Odoo dulu).

Kondisi sekarang (dicek 2026-10-05, staging + prod): client addons `v19.0.2.7.0`, platform `v19.0.1.3.3`; website v0.5.0
(Next.js, **tanpa CMS** — ADR 0007, konten di `src/config/*.ts`, ganti konten = rebuild image).

## Ringkasan per poin

| # | Permintaan | Yang sudah ada | Gap | Ukuran | Butuh keputusan |
|---|---|---|---|---|---|
| 1 | Instagram: tombol mengambang di samping WhatsApp + di footer | Tombol WA `whatsapp-button.tsx` (server component, warna Onyx) | Belum ada data sosmed sama sekali (`brand.ts` tanpa `social`), footer tanpa ikon sosmed | Kecil | URL/handle Instagram |
| 2 | Tombol unduh company profile, file dikelola di CMS | — | Website tidak punya CMS/upload; rootfs read-only, tanpa volume | Kecil–sedang | Di mana file dikelola |
| 3 | Invoice ke klien memuat nama project, nomor PO, SPK | PDF invoice `cl_expomedia_report`: NO. SPK (`invoice_origin`), REF. KLIEN (`ref` = no. quotation lama) | Tidak ada field **No. PO klien**; nama project belum dicetak (nama proyek sekarang `"<SPK> - Booth / Event"`, tidak bermakna) | Kecil | — (lihat #6: nama event) |
| 5 | Petty cash & expense terhubung ke SPK + smart button | `hr_expense` + `sale_expense` (tautan re-invoice saja), `project_hr_expense` (analitik proyek), `custom_petty_cash` 0.4.0 | Petty cash tanpa SPK/proyek; expense biaya (bukan re-invoice) tanpa tombol di SPK; Lacak Dokumen tidak mencakup keduanya | Sedang | — |
| 6 | Kalender SPK: tanggal event, lokasi, instalasi, produksi → kebutuhan MPP per tanggal | Kiosk mencatat kru **aktual** per SPK; `custom_planning` (tanpa tautan SPK) | Tidak ada field tanggal/lokasi terstruktur di SPK; tidak ada kalender/rencana MPP | Sedang–besar | Bentuk jadwal (lihat di bawah) |
| 7 | AE membuat SPK tanpa melihat harga satuan & diskon; managerial melihat | AE saat ini **tidak punya akses SPK sama sekali** (keputusan 2026-09-29, CRM saja); diskon per baris belum aktif | ACL SPK untuk AE + penyembunyian harga di form/list/PDF/portal/email | Sedang | Membalik keputusan 2026-09-29 |
| 8 | 1 project → beberapa invoice, sesuai SPK per lokasi | 1 SPK = 1 proyek, lokasi = task per baris (teks); invoice per SPK (DP + pelunasan) | Tidak bisa menagih per lokasi | Besar (menyentuh mart, Lacak Dokumen, progres, BAST) | Model data (lihat di bawah) |
| 9 | Estimasi vs realisasi produksi; boleh pakai barang recycle dari project lama | Realisasi: profitabilitas proyek + `mart_spk_cost` (plan 17/19); lokasi stok `Properti Booth Reusable`, `Sisa Potong` | Tidak ada estimasi tersimpan per SPK; tidak ada alur pakai barang reuse + aturan nilainya | Besar | Nilai barang recycle |
| 10 | Hanya akses tertentu (finance, direktur) melihat harga project | Harga jual hanya untuk grup sales; profitabilitas hanya project manager | **PM bisa melihat harga PO/vendor & nilai stok** (punya purchase/stock user); tidak ada grup "lihat harga" | Sedang–besar | Daftar peran yang boleh |

## Rancangan per poin

### 1. Instagram (website)
`brand.social.instagram` di `src/config/brand.ts`; komponen tombol mengambang bertumpuk di atas WA (gaya sama, ikon Simple
Icons CC0 inline seperti WA); ikon Instagram di kolom Kontak footer. Tes unit brand. Rilis 0.6.0 → staging → prod (atas
permintaan).

### 2. Company profile
Usulan: **file dikelola di Odoo** (sistem yang sudah dipakai klien; tanpa CMS baru):
`cl_expomedia_web` menambah unggahan "Company Profile" di Pengaturan perusahaan + rute publik tetap
`https://erp.expomedia.id/expomedia/company-profile` (unduh PDF, nama file tetap, cache pendek). Website hanya menautkan URL
itu (tombol di hero sebagai tombol ketiga + di halaman Kontak/footer). Ganti file = unggah ulang di Odoo, tanpa rebuild.
Alternatif: (b) PDF statis di `public/` (ganti = rebuild oleh kita); (c) CMS Payload untuk website (ADR baru, DB + volume
media, perubahan template infra) — berlebihan untuk satu file.

### 3. Invoice
Field `x_client_po` (No. PO klien) di SPK → disalin ke invoice (termasuk DP); PDF invoice: NO. SPK dari kunci Lacak Dokumen
(bukan teks `invoice_origin`), NO. PO, NAMA PROJECT. Nama project = field **Nama event/project** di SPK (dibuat di #6) dan
dipakai juga untuk nama proyek (`<SPK> - <nama event>`). REF. KLIEN (no. quotation lama) tetap.

### 5. Petty cash & expense per SPK
- `petty.cash.request` + baris realisasi: field SPK (`x_custom_trace_order_id`) → analitik proyek SPK ikut di jurnal
  realisasi (biaya masuk profitabilitas & `mart_spk_cost`).
- `hr.expense`: field SPK terpisah dari `sale_order_id` (re-invoice) → analitik proyek terisi otomatis.
- Smart button "Petty Cash" & "Expense" di SPK (pola tombol PO `cl_expomedia_scm`), tombol buat baru dengan SPK terisi.
- Lacak Dokumen: tambah expense & petty cash sebagai anchor (modul platform `custom_doc_trace` → generik, bukan client).
Penempatan: penautan petty cash/expense ↔ SO bersifat generik → **platform** (`custom_petty_cash`/`custom_expenses`), smart
button & label Expomedia di client.

### 6. Jadwal SPK & kebutuhan MPP
Usulan: model baris **Jadwal SPK** (`x.spk.schedule`): SPK, lokasi/task, fase (Produksi / Loading-in & Instalasi / Event /
Dismantle), tanggal mulai–selesai, **MPP dibutuhkan** (orang/hari), catatan. Satu SPK punya beberapa baris (fase berupa
rentang tanggal, bukan satu tanggal). Tampilan: kalender (warna per fase), list, pivot/grafik **total MPP per tanggal** →
PM melihat hari yang kekurangan orang dan menambah MPP. Header SPK: Nama event, venue, periode event (ringkasan).
Realisasi MPP dari kiosk (`hr.attendance.x_sale_order_id`) dibandingkan rencana di pivot yang sama (fase 2).
Alternatif lebih ringan: 4 pasang field tanggal di header SPK + kalender per field — tidak bisa per lokasi dan tidak bisa
menjumlah MPP per hari.

### 7 + 10. Visibilitas harga (dikerjakan bersama)
- Grup baru **"Expomedia / Lihat Harga"** (Finance, Direksi, + peran yang owner tetapkan). Tanpa grup ini: harga satuan,
  diskon, subtotal, total, pajak disembunyikan di SPK (form/list/PDF/portal/email), PO & tagihan vendor, nilai stok,
  analitik & profitabilitas, dashboard (`mart_user_access.can_see_value` mengikuti grup ini).
- AE: boleh membuat & mengubah SPK **miliknya** saat draft (produk, qty, deskripsi, lokasi, jadwal); harga terisi dari
  pricelist di server dan ditetapkan/diubah oleh pemegang grup; AE tidak bisa konfirmasi. Persetujuan harga oleh manager
  sebelum dikirim ke klien.
- PM/purchasing/gudang: tetap bisa membuat PO/penerimaan tetapi harga disembunyikan → **perlu dipastikan**: siapa yang
  mengisi harga PO bila purchasing tidak boleh melihat harga.
- Diuji per peran (tes ACL + uji UI), karena penyembunyian di view saja tidak cukup (field tetap terbaca lewat RPC → pakai
  `groups=` di field + aturan baca).

### 8. Beberapa invoice per lokasi
Usulan (standar Odoo): **1 Project = beberapa SPK, 1 SPK per lokasi** — SPK lokasi menunjuk proyek bersama
(`sale.order.project_id`, task masuk proyek itu), invoice/DP/BAST per SPK seperti sekarang. Tombol "Tambah SPK lokasi"
dari proyek/SPK pertama (menyalin klien, PO, nama event). Dampak: data mart (asumsi 1 SPK = 1 proyek), progres, Lacak
Dokumen (kunci tetap SPK — aman), dashboard butuh agregasi per proyek.
Alternatif: 1 SPK multi-lokasi + wizard "invoice per lokasi" (pilih baris) — lebih sedikit dokumen, tetapi DP/BAST/progres
per lokasi jadi custom dan menyimpang dari standar.

### 9. Estimasi vs realisasi produksi
Bergantung #8 dan #10. Usulan: baris **Estimasi biaya** per SPK (material, jasa/subkon, tenaga, lain-lain; boleh dari BoM)
dibekukan saat SPK dikonfirmasi; realisasi dari sumber yang sudah ada (MO, permintaan barang SPK, PO jasa, timesheet,
expense & petty cash dari #5); laporan selisih per SPK/proyek di Odoo + dashboard. Barang recycle: operasi "Pakai Barang
Reuse" dari lokasi `Properti Booth Reusable` ke SPK; nilai biaya mengikuti keputusan owner (0 / nilai sisa / % harga baru),
sehingga estimasi yang memakai barang baru vs realisasi yang memakai barang reuse terlihat sebagai penghematan.

## Urutan usulan

- **Gelombang A** (kecil, tanpa keputusan struktur): #1, #2, #3, #5.
- **Gelombang B** (struktur, setelah keputusan): #8 → #6 → #7+#10.
- **Gelombang C**: #9 (memakai hasil #5, #6, #8, #10).

Semua: staging dulu → uji user → prod atas permintaan; tes modul di Odoo sekali pakai terisolasi + uji UI per peran.

## Keputusan owner (2026-10-05)
- #2: company profile **dikelola di Odoo** (unggah di Pengaturan, URL publik tetap).
- #8: **SPK per lokasi** di bawah satu proyek bersama.
- #7/#10: **harga SPK/project (harga jual, nilai invoice klien, pendapatan & margin) hanya Finance dan Direksi**. Harga
  material & biaya yang timbul (PO, tagihan vendor, nilai stok, biaya) **boleh dilihat peran lain** → cakupan #10 hanya sisi
  jual; tidak perlu memagari PO/purchasing.
- #9: barang recycle dibebankan **nol** ke SPK baru.

## Gelombang A — implementasi (2026-10-05, belum dirilis)

| # | Repo / branch | Isi |
|---|---|---|
| 1, 2 (web) | `web-expomedia` `feat/instagram-company-profile` | `brand.social.instagram` + `brand.companyProfileUrl` (kosong = tidak dirender); `FloatingContacts` (Instagram di atas WhatsApp, gaya Onyx, Simple Icons CC0) menggantikan `whatsapp-button.tsx`; Instagram + unduh company profile di footer; tautan unduh di hero dan kartu di halaman Kontak. |
| 2 (Odoo) | `odoo-addons-expomedia` `feat/klien-2026-10-05-a` | `cl_expomedia_web` 19.0.1.3.0: `res.company.x_company_profile` (PDF ≤ 25 MB, divalidasi `%PDF-`), tab **Website** di form perusahaan, rute publik `GET /expomedia/company-profile` (unduh `Company-Profile-Expomedia.pdf`, cache 5 menit, 404 bila kosong). |
| 3 | idem | `cl_expomedia_sale` 19.0.1.2.0: SPK `x_event_name` (Nama Project / Event) + `x_client_po` (No. PO Klien) → disalin ke invoice (`x_project_name`, `x_client_po`; DP & pelunasan; invoice gabungan = digabung koma). `cl_expomedia_report` 19.0.1.3.0: PDF invoice NO. SPK (kunci Lacak Dokumen, fallback `invoice_origin`), NAMA PROJECT, NO. PO KLIEN; PDF SPK/penawaran juga. |
| 5 | `odoo-addons-athera` `feat/doc-trace-expense` + client | Platform **`custom_doc_trace_expense` 19.0.1.0.0**: kunci SPK di `hr.expense` & `petty.cash.request` (dipilih pembuat dokumen selama terbuka; pemilih SPK lewat sudo untuk karyawan tanpa akses Sales — hanya nomor SPK), analitik proyek SPK otomatis (expense) / di setiap baris realisasi (petty cash, di samping OU + Employee), jurnal ikut berakar ke SPK, node Expense/Petty cash di Lacak Dokumen, tombol **Expense** & **Petty Cash** di SPK (menggantikan tombol standar sale_expense). `cl_expomedia_scm` 19.0.1.1.0 bergantung padanya. |

Perbaikan yang ditemukan saat uji UI staging (masalah lama, bukan dari gelombang A):
- **Karyawan tidak bisa membuat expense** — modul lama `custom_spk` (on hold) memagari `standard_price` produk dengan grup
  *SPK / Cost Visibility*; onchange kategori expense → AccessError. `cl_expomedia_scm` 19.0.1.2.0 (client `v19.0.2.8.1`):
  `base.group_user` ⊃ Cost Visibility (sesuai keputusan #10: biaya boleh dilihat peran lain; harga jual tidak tersentuh).
- **Form invoice AccessError bagi user akuntansi tanpa grup PPh** (`custom_tax_id`; di prod belum ada satu pun user dengan
  grup PPh → akan kena saat go-live). Platform `v19.0.1.4.1` (`custom_tax_id` 19.0.0.6.2): Billing/Read-only = PPh User,
  Manajer akuntansi = PPh / DPP Admin; tab PPh hanya untuk grup PPh. `odoo-data-expomedia` `tools/schema.py`: peran
  Direksi/Finance mendapat grup PPh.

### Tes & deploy staging (2026-10-05)

- Odoo terisolasi: `custom_doc_trace_expense` 5/5; `cl_expomedia_report` (+ tes invoice baru) 6/6 di luar `test_pdf_renders`;
  `cl_expomedia_web` 5/5 (+ unduhan company profile); `cl_expomedia_scm` 6/6; `custom_tax_id:TestInvoiceAccess` 1/1.
  Gagal yang **sudah ada di main** (lingkungan DB kosong, bukan regresi): `cl_expomedia_sale` 3 (nomor SPK/menu
  `custom_spk`), `custom_doc_trace` 2 (picking type tanpa lokasi), `custom_tax_id` 13 (tanpa CoA/jurnal penjualan).
- Website: lint, typecheck, 120/120 tes; pratinjau Playwright desktop + mobile (hero, footer, kontak) dengan nilai sementara.
- Staging: backup `backups/odoo/expomedia_staging-20261005-185355-pre-plan20a.dump`; `-u cl_expomedia_sale,
  cl_expomedia_report,cl_expomedia_web,cl_expomedia_scm` (memasang `custom_doc_trace_expense`), lalu `-u cl_expomedia_scm`,
  `-u custom_tax_id`; semua exit 0, `odoo-staging` healthy.
- Uji UI Playwright (user uji sementara Finance + Karyawan, sudah diarsipkan; expense uji dihapus): field SPK & tombol
  Expense/Petty Cash, tombol standar sale_expense tersembunyi, tab Website perusahaan, field invoice, karyawan memilih SPK
  tanpa akses Sales dan menyimpan expense, Finance tanpa grup PPh langsung membuka invoice.

Prod (belum, atas permintaan owner): backup → pin `odoo/pool-a/addons/{platform v19.0.1.4.1, clients/expomedia v19.0.2.8.1}`
→ `-u cl_expomedia_sale,cl_expomedia_report,cl_expomedia_web,cl_expomedia_scm,custom_tax_id -d expomedia_prod` → restart
`odoo-pool-a` (cek `demo_demo` tidak memasang modul client) → unggah company profile di prod → isi `companyProfileUrl` +
handle Instagram → rilis website 0.6.0 staging → prod.

Catatan lanjutan:
- Data mart `mart_spk_cost`: baris analitik tagihan pihak ketiga petty cash & expense (move `in_invoice`) masuk kategori
  `vendor_bill` → dihitung di `service_billed` lalu `greatest(service_billed, po_service)` — bisa tertutup PO jasa. Perlu
  ember sendiri (expense/petty cash) — dikerjakan bersama #9 (estimasi vs realisasi butuh realisasi akurat).
- Petty cash Expomedia belum dikonfigurasi (akun Uang Muka, jurnal Bank-Out/Payment) — perlu sebelum dipakai.
- Website: tombol company profile baru tampil setelah file diunggah di Odoo prod lalu `companyProfileUrl` diisi + rilis.

## Gelombang B & C — implementasi (2026-10-06, LIVE STAGING)

| # | Isi |
|---|---|
| 8 | `cl_expomedia_sale` 19.0.1.3.0: **Lokasi / Venue** di SPK + invoice + PDF; tombol **Tambah SPK Lokasi** (penawaran baru: klien, nama event, PO klien, **proyek yang sama**); baris jasa SPK yang menunjuk proyek tidak membuat proyek baru (Odoo 19 selalu membuat proyek per SPK → override `_timesheet_service_generation`); nama proyek = nama event; stat **SPK Lokasi**. `cl_expomedia_scm`: PO per SPK lewat kunci SPK (tombol Buat PO mengisi kunci). `cl_expomedia_progress`: dokumen berkunci SPK lain tidak memajukan progres. Platform `custom_doc_trace` 19.0.1.0.2: alur Lacak Dokumen tidak memuat dokumen/task SPK lain di proyek bersama. Data mart: baris analitik → SPK pasti (task SPK, SPK timesheet, kunci jurnal/MO) atau dibagi **pro-rata nilai SPK** di proyek bersama; `mart_spk` + `project_id`, `event_name`, `location`, `project_spk_count`; expense/petty cash = biaya lain-lain (catatan #5). Validasi: mart biaya baru = mart lama (456 SPK, 0 selisih; belum ada proyek bersama). |
| 6 | Modul baru **`cl_expomedia_schedule`** 19.0.1.0.0: jadwal per SPK/lokasi (Produksi, Loading-in & Instalasi, Event, Dismantle; tanggal mulai–selesai; **MPP/hari**), tab **Jadwal & MPP** di SPK, menu Project/Sales → **Jadwal SPK** (kalender per fase), Project → Laporan → **Kebutuhan MPP** (grafik/pivot per tanggal: rencana vs **aktual kiosk**), ringkasan Event mulai/selesai di daftar SPK. PM tanpa akses Sales memilih SPK lewat pemilih SPK. |
| 7+10 | `cl_expomedia_sale` 19.0.2.0.0 (client `v19.0.3.0.0`): grup **Lihat Harga Jual SPK** (otomatis Sales Manager = Finance/Direksi + user akuntansi; diskon per baris aktif untuk grup ini). Field harga SPK & baris dipagari: hilang dari semua view, ditolak lewat API (read/search_read/web_read/export/read_group) dan tulis; perhitungan server tetap jalan (override `_has_field_access` — Odoo 19 juga memeriksa grup field saat atribut dibaca). Konfirmasi, kirim/pratinjau ke klien, update harga = grup ini. **AE = sales (milik sendiri)**: membuat Penawaran/SPK tanpa harga (harga dari pricelist). PDF penawaran/SPK yang dicetak AE tanpa harga & total. CRM nilai penawaran = grup harga. Dashboard: `can_see_value` = grup harga (cadangan grup sales di DB lama). Biaya/material tidak dibatasi. |
| 9 | Modul baru **`cl_expomedia_estimate`** 19.0.1.0.1: tab **Estimasi Biaya** di SPK (material, jasa/subkon, tenaga, lain-lain; asal **Baru / Recycle** — recycle Rp 0 ke SPK, nilai baru = penghematan), laporan **Estimasi vs Realisasi** per SPK × kategori (pivot/daftar, merah = melebihi estimasi) dengan realisasi = aturan `mart_spk_cost` (total staging sama persis dengan mart: Rp 7.180.818.350; view 90 ms). `odoo-data-expomedia` `configure_standard.py`: operasi **Pakai Barang Reuse SPK** (WS/Stock/Properti Booth Reusable → Pemakaian SPK, **tanpa** biaya analitik) — dijalankan di staging. |

Tes terisolasi: semua tes baru lulus (sale 6 baru, scm 7, schedule 3, estimate 2, report 8, doc_trace shared project 1); gagal
bawaan `cl_expomedia_sale` 2 (nomor SPK di DB kosong) tetap. Uji UI staging per peran (user uji sementara, diarsipkan; data uji
dihapus): AE tanpa kolom/total harga & tanpa tombol konfirmasi/kirim, Finance melihat harga & konfirmasi; SPK lokasi dari
tombol; jadwal + kalender + grafik MPP; estimasi + laporan. Backup staging: `…-pre-plan20b8.dump`, `…-pre-plan20b10.dump`.

Catatan lanjutan:
- AE masih bisa melihat **harga katalog produk** (menu Products / tombol Catalog = list price produk, bukan harga SPK) —
  pagari bila owner menganggapnya harga jual.
- Dashboard control-plane belum menampilkan proyek bersama / estimasi (data sudah di mart: `project_id`, `project_spk_count`).
- Prod butuh: `configure_standard.py` (operasi reuse — prod belum punya gudang WS/lokasi reusable), grup PPh untuk Finance.

## Harga katalog & deploy prod (2026-10-06)

Permintaan owner 2026-10-06: harga katalog disembunyikan dari sales/AE; AE hanya memasukkan produk jual di CRM/SPK.
`cl_expomedia_sale` 19.0.2.1.1 (client `v19.0.3.2.1`): `list_price`/`lst_price`/`price_extra` + harga pricelist dipagari
(baca hanya grup Lihat Harga Jual; pembuat produk tanpa grup tetap bisa membuat produk), tombol **Catalog** di SPK
disembunyikan & dijaga server, label "Price:" kanban ikut tersembunyi. Produk di baris SPK = standar `sale_ok` (produk
jual). Uji UI staging: AE tanpa harga di kanban/form produk & tanpa Catalog.

Prod: backup `backups/odoo/expomedia_prod-20261006-074725-pre-plan20.{dump,filestore.tgz}` → pin `odoo/pool-a/addons`
platform `v19.0.1.4.2`, clients/expomedia `v19.0.3.2.1` → `-u custom_tax_id,custom_doc_trace,custom_doc_trace_mrp,
cl_expomedia_sale,cl_expomedia_report,cl_expomedia_web,cl_expomedia_scm,cl_expomedia_progress -i cl_expomedia_schedule,
cl_expomedia_estimate -d expomedia_prod` exit 0 (`demo_demo` tidak memasang modul terkait). Verifikasi shell (rollback):
AE tanpa harga/konfirmasi/Catalog, Finance & admin = grup harga + PPh, model jadwal/estimasi ada. Restart `odoo-pool-a`
diblokir hook → owner. Operasi "Pakai Barang Reuse SPK" belum di prod (prod hanya gudang WH; jalankan
`configure_standard.py` setelah gudang WS + lokasi Properti Booth Reusable dibuat).

## Keputusan yang masih dibutuhkan
1. URL akun Instagram Expomedia (tombol & tautan sudah dibuat, tampil otomatis setelah URL diisi).
2. Poin 4 catatan pertemuan (tidak ada di catatan).
