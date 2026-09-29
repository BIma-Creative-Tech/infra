# Fit-Gap Odoo CE 19.0 — PT Expomedia Indo Karya (`expomedia`)

> Penyusun: agen `odoo-functional` · 2026-09-29 · Status: **DRAFT, menunggu persetujuan user**.
> Sumber: source `odoo-staging` (`/usr/lib/python3/dist-packages/odoo/addons`, disingkat `A/`), DB `expomedia_staging`
> (read-only), `/opt/src/odoo-addons-athera`, `/opt/src/odoo-addons-expomedia/cl_expomedia_spk`, dokumen requirement owner,
> sheet `spk-giat-2026-gsheet.xlsx`. Label: **[V]** = TERVERIFIKASI (path/field disebut), **[A]** = ASUMSI.
> Hanya gap yang disetujui di dokumen ini boleh menjadi kode custom (modul client `cl_expomedia_sale`).

> **Status 2026-09-29:** diimplementasikan di staging — plan 14 (G1, G2, G3, G5; G7 = dashboard control-plane dari data
> mart ADR 0016). G4/G6 ditunda.

## 1. Alur target & peran

```
AE ─ crm.lead/opportunity (CRM, tanpa harga)
        │  "New Quotation" (Owner/Finance)                          sale_crm
        ▼
sale.order draft "Penawaran" (harga, DP, termin)                    sale_management
        │ konfirmasi → nama diganti  SPK/2026/10/05-000123          custom_doc_numbering + sequence
        ▼
sale.order state=sale ("SPK")
   ├─ baris jasa per project/lokasi (task_in_project + template)    sale_project
   │     └─ project.project (1 per SO+template) → 1 task per baris = 1 lokasi
   │            stage: Desain → Produksi → Instalasi → Laporan → BAST → Selesai
   │            timesheet crew (GIAT) = "absensi per SPK" → so_line  sale_timesheet
   ├─ milestone (mis. Instalasi, BAST) + uang muka → invoice        sale_project / sale
   ├─ BAST dari SO                                                   custom_sale_bast
   └─ account.move → e-Faktur/Coretax, PPh → account.payment         account + custom_coretax*/custom_tax_id
hr.attendance (presensi/payroll) terpisah → custom_hr_payroll_id
```

| Peran | Grup standar (usulan) | Lihat harga/nilai? |
|---|---|---|
| AE | grup AE baru (CRM saja, **tanpa** `sales_team.group_sale_salesman`) — lihat §3.1 | Tidak (ditolak server) |
| Owner | `sales_team.group_sale_manager`, `account.group_account_manager`, `project.group_project_manager` | Ya |
| Finance | `sales_team.group_sale_salesman_all_leads`, `account.group_account_manager`/`_invoice` | Ya |
| PM | `project.group_project_user` + `hr_timesheet.group_hr_timesheet_approver`, tanpa grup sales, **bukan** `project.group_project_manager` | Tidak (status saja) |
| Supervisor/Mandor | `hr_timesheet.group_hr_timesheet_approver` (catat timesheet crew) | Tidak |

## 2. Kondisi saat ini (DB `expomedia_staging`, read-only) [V]

| Hal | Temuan |
|---|---|
| Modul standar | `crm, sale_crm, sale_management, sale_project, sale_timesheet, hr_timesheet, hr_hourly_cost, hr_attendance, sale_stock, project_stock, project_account, spreadsheet_dashboard_sale(_timesheet)` terpasang; 194 modul terpasang, 52 `custom_*`, 1 `cl_*` |
| Data alur standar | 0 `crm_lead`, 0 `sale_order`, 0 `hr_attendance`, 2 timesheet, 32 task |
| Data jalur paralel | 742 `custom_spk`, 744 `cl_expomedia_spk_project`, 734 `cl_expomedia_spk_activity`, 272 `custom_spk_delivery`, 716 `custom_spk_attendance`, 577 `project_project` |
| Fitur grup | `project.group_project_milestone`, `analytic.group_analytic_accounting`, `sale.group_delivery_invoice_address` **belum** di-imply ke `base.group_user` |
| Karyawan | 124 `hr_employee`, **0** dengan `hourly_cost > 0` (biaya tenaga kerja timesheet = 0) |
| Penomoran | `res_company.x_doc_code = 'EXP'`; sequence `sale.order` prefix `S` padding 5; sequence `tenant.sale_order` **tidak ada** |
| `custom_spk` | tidak punya field ke `sale.order`/`crm.lead` (grep `custom_spk*/models`: nihil) |
| Bahasa | `id_ID` & `en_US` aktif; 28 user `en_US`, 1 `id_ID`; nama menu `sale_menu_root` = `{"en_US": "Sales"}` |

Sheet client [V]: "SPK 2026" 746 baris; `No QUOT` = angka 7 digit `yyMMnnn` (mis. 2601002), **hampir 1 baris = 1 No QUOT**
(maks. 2 baris/No QUOT, 3 duplikat); 18 AE, VM terisi hanya ±75 baris, 45 GROUP, 163 BRAND. "GIAT 2026" 737 baris;
Kegiatan dominan Loading/Unloading/Maintenance/Installment (ejaan tidak konsisten: `Loading `, `loading`, `Maintennace`).
Lokasi = teks bebas (venue + kadang tanggal/No SPK). → pengelompokan "beberapa project per SPK" **tidak tampak** di sheet (Q1).

## 3. Keputusan kunci (analisis)

### 3.1 AE tanpa harga (keputusan 4) — **tidak bisa dengan grup standar saja**
Bukti [V]:
- Menu root CRM: `groups="sales_team.group_sale_salesman,sales_team.group_sale_manager"` (`A/crm/views/crm_menu_views.xml:9-14`);
  ACL `crm.lead` hanya untuk `group_sale_salesman`/`manager` (`A/crm/security/ir.model.access.csv:2-3`, 14 baris ACL CRM
  terikat `group_sale_salesman`).
- `group_sale_salesman` memberi `sale.order` r/w/c dan `sale.order.line` penuh (`A/sale/security/ir.model.access.csv:32,39`);
  rule personal `['|',('user_id','=',user.id),('user_id','=',False)]` (`A/sale/security/ir_rules.xml:44-48`).
- Quotation dari lead mewarisi `default_user_id = lead.user_id` (= AE) (`A/sale_crm/models/crm_lead.py:_prepare_opportunity_quotation_context`)
  → AE otomatis bisa membaca SO & harga.
- Form lead menampilkan `sale_amount_total` ("Sum of Orders") tanpa `groups` (`A/sale_crm/models/crm_lead.py:10`).
- Tidak ada grup standar CE untuk menyembunyikan harga penjualan.

| Opsi | Mekanisme | Fence server | Penilaian |
|---|---|---|---|
| A. Standar murni | AE = `group_sale_salesman`, Finance ganti Salesperson SO ke dirinya | Tidak (AE bisa create SO via RPC, SO `user_id=False` terlihat, default user_id = AE) | Ditolak |
| B. **AE tanpa grup sales (DIREKOMENDASIKAN)** | Modul client: grup `cl_expomedia_sale.group_ae` + salinan ACL CRM untuk grup ini + rule lead personal + tambahkan grup ke menu CRM; field `sale_amount_total/quotation_count/sale_order_count/order_ids` di `crm.lead` diberi `groups="sales_team.group_sale_salesman"`; tombol "New Quotation"/smart button diberi groups | **Ya** — AE tidak punya ACL `sale.order` → AccessError | Kode tipis (data + atribut field). Field bergrup otomatis dibuang dari view untuk user tanpa grup [V] `A/base/models/ir_ui_view.py:1659`. `SO.user_id` tetap boleh = AE (atribusi/komisi) karena domain grup hanya di UI [V] `A/sale/models/sale_order.py:208-216` |
| C. AE = salesman + rule diperketat | Override `sale.sale_order_personal_rule` & paksa `user_id` SO ≠ AE | Sebagian | Merusak atribusi AE di SO; tetap bisa create SO → ditolak |

Risiko opsi B [A]: fitur CRM lain yang memeriksa `group_sale_salesman` di kode (mis. assignment tim, `crm.team.member`) — wajib
diuji per layar (pipeline, activity, lost reason, convert lead, merge). `expected_revenue` pada lead tetap terlihat AE (nilai
perkiraan yang diisi AE sendiri) — konfirmasi ke client (Q9).

### 3.2 Absensi per SPK "menempel di Sales Order" (keputusan 5) — **standar: timesheet di task SO**
- `account.analytic.line.so_line` dihitung dari `task_id.sale_line_id` (`A/sale_timesheet/models/hr_timesheet.py:80-82,117+`) [V].
- Baris dengan produk `service_type='milestones'` → `timesheet_invoice_type='billable_milestones'`: **tidak menambah qty tertagih**
  (tagihan tetap dari milestone) [V] `hr_timesheet.py:54-69` (sale_timesheet).
- SO punya smart button jam tercatat: `timesheet_count` via `order_id` analytic line (`A/sale_timesheet/models/sale_order.py:14,20-33`) [V].
- Biaya: `amount = -unit_amount × employee.hourly_cost` (`A/hr_timesheet/models/hr_timesheet.py:459-478`, `hr_hourly_cost`) [V];
  input bisa dalam **hari** (`company.timesheet_encode_uom_id`) → cocok slot pagi/malam (0,5 hari) [V] `hr_timesheet.py:129,174`.
- `hr.attendance` tidak punya field project/task/SO (grep field `A/hr_attendance/models/hr_attendance.py`) [V] → tetap untuk
  presensi/payroll (`custom_attendance` + `custom_hr_payroll_id`), **bukan** alat biaya per SPK.

Rekomendasi: 1 baris GIAT → 1 timesheet per anggota TIM di task lokasi (tanggal, 0,5 hari/slot, deskripsi "Loading – pagi").
Gap kecil: jenis kegiatan terstruktur (Loading/Unloading/…) → field selection `x_giat_type` pada `account.analytic.line` (G5).
`custom.spk.attendance` & `cl.expomedia.spk.activity` tidak dipakai lagi untuk biaya.

### 3.3 Penomoran `SPK/yyyy/mm/dd-XXXXXX` (keputusan 2)
- `ir.sequence` mendukung `%(year)s %(month)s %(day)s` (`A/base/models/ir_sequence.py:219`) [V].
- `custom_doc_numbering` mengganti nama saat `action_confirm` via `next_by_code('tenant.sale_order', sequence_date=date_order)`,
  aktif jika `company.x_doc_code` terisi; nama draft disimpan di `x_quotation_name`
  (`/opt/src/odoo-addons-athera/custom_doc_numbering/models/sale_order.py`) [V]. `date_order` di-set `now()` saat konfirmasi
  (`A/sale/models/sale_order.py:1228-1231`) [V] → tanggal di nomor = tanggal konfirmasi.
- Cukup data: sequence `code='tenant.sale_order'`, `company_id=EXP`, `prefix='SPK/%(year)s/%(month)s/%(day)s-'`, `padding=6`,
  `use_date_range=False` (tanpa reset, sesuai asumsi) — **tanpa kode baru**, kecuali 2 temuan:
  - **Bug guard** [V]: pengecekan `order.name.startswith("SO/")` → SO yang dibatalkan lalu dikonfirmasi ulang mendapat nomor
    SPK baru. Perbaikan: lewati bila `x_quotation_name` sudah terisi (fix di modul platform, G2).
  - **Zona waktu** [V/A]: `date_order` disimpan UTC naif dan diinterpolasi tanpa konversi → konfirmasi 00:00–06:59 WIB
    tercetak tanggal kemarin. Perlu konteks `ir_sequence_date` dalam TZ user (G2) atau diterima.
- Efek samping sudah aktif [V]: `x_doc_code='EXP'` membuat invoice pelanggan bernomor `INV/EXP/YYYY/MM/NNN` reset bulanan
  (`custom_doc_numbering/models/account_move.py:8-24`). Konfirmasi ke client (Q2).
- Nomor penawaran: saat ini `S00001` (`sale.order`, padding 5). Format penawaran → Q2.

### 3.4 Ganti nama menu "Sales" → "SPK" hanya di DB Expomedia
- Nama menu = kolom jsonb `ir_ui_menu.name` per DB [V] → DB lain tidak terpengaruh selama modulnya hanya di-install di `expomedia_*`.
- Mengubah lewat UI **tidak aman**: menu didefinisikan `<menuitem>` di `A/sale/views/sale_menus.xml:4` (`sale_menu_root`),
  tanpa `noupdate` → `-u sale` menulis ulang nama. [V]
- Cara benar: record override di modul client (`<record id="sale.sale_menu_root" model="ir.ui.menu"><field name="name">SPK</field>`,
  plus `sale.sale_order_menu`, `sale.menu_sale_quotations` → "Penawaran", `sale.menu_sale_order` → "SPK") dengan terjemahan
  `id_ID` di `i18n/id.po`. Upgrade `sale` otomatis ikut meng-upgrade modul dependen (`button_upgrade`,
  `A/base/models/ir_module.py:704-735`) sehingga override dimuat ulang **setelah** `sale` [V]. Nama action/window title
  ("Quotations", "Sales Orders") juga di-override bila perlu [A].

## 4. Tabel fit-gap

| # | Kebutuhan (bahasa client) | Fitur standar CE | Konfigurasi | Gap | Usulan | Keputusan |
|---|---|---|---|---|---|---|
| 1 | Pipeline AE, follow-up | `crm.lead`, aktivitas, stage | Tim sales, stage pipeline | AE harus tanpa grup sales (§3.1) | G1 grup AE (opsi B) | [V] menunggu user |
| 2 | Penawaran dibuat Owner/Finance dari lead | `sale_crm` `action_sale_quotations_new` (`A/sale_crm/models/crm_lead.py:29`) | Template quotation, termin | – | – | [V] |
| 3 | SPK = SO, nomor `SPK/yyyy/mm/dd-XXXXXX` | `ir.sequence` + `custom_doc_numbering` | Sequence §3.3 | Guard konfirmasi ulang, TZ | G2 (fix platform) | [V] |
| 4 | Menu "SPK" | `ir.ui.menu` | – | Tidak bisa via UI secara tahan-upgrade | Data override di modul client (G3, bukan logika) | [V] |
| 5 | 1 SPK banyak project/lokasi | `service_tracking='task_in_project'` + `project_template_id`: **1 project per SO+template, 1 task per baris** (`A/sale_project/models/sale_order_line.py:336-430`) | Produk jasa + template "Booth/Event" | Venue terstruktur per baris: task `partner_id` = pelanggan SO (`sale_order_line.py:272`), picking = `partner_shipping_id` SO (`A/sale_stock/models/sale_order_line.py:302`) | Nama lokasi di deskripsi baris → judul task (standar). Bila perlu venue partner: G4 `x_venue_partner_id` baris → task | [V] |
| 6 | Tahap Desain→Produksi→Instalasi→Laporan→BAST | Stage task dari template (`is_template`, `action_create_from_template`, `A/project/models/project_project.py:183`) | Template + stage | – | – | [V] |
| 7 | Tagihan bertahap (DP, pelunasan) | Uang muka `sale.advance.payment.inv` (`percentage`/`fixed`) [V]; `service_policy='delivered_milestones'` (butuh `project.group_project_milestone`, `A/sale_project/models/product_template.py:18`), `project.milestone.sale_line_id/quantity_percentage` [V] | Aktifkan milestone; produk kebijakan milestone | – | `custom_spk_billing` tidak dipakai | [V] |
| 8 | Absensi/tenaga kerja per SPK | Timesheet task → `so_line` (§3.2) | `hourly_cost` crew, UoM hari | Jenis kegiatan GIAT | G5 `x_giat_type` (opsional) | [V] |
| 9 | Presensi, lembur, payroll PPh21 TER, BPJS | `hr.attendance` + `custom_attendance`, `custom_hr_payroll_id` | – | – | Tetap (platform) | terpasang [V], fungsi [A] |
| 10 | Jadwal loading/dismantle per venue | Task `date_deadline` saja (tanpa tanggal mulai) [V] `A/project/models/project_task.py:183`; `planning`/`industry_fsm` EE tidak ada [V] | Subtask per kegiatan (Loading, Dismantle) dg deadline | Jendela waktu muat/bongkar | Subtask dulu; bila kurang → evaluasi jembatan `custom_spk_delivery.task_id` (G6, ditunda) | [A] |
| 11 | BAST serah terima | `custom_sale_bast.action_generate_bast` di SO [V] | – | – | Tetap | [V] |
| 12 | Owner/Finance lihat nilai; PM status saja | SO list/pivot (`amount_untaxed` tersimpan; `amount_invoiced`/`amount_to_invoice` non-stored, tidak bisa di-pivot [V] `A/sale/models/sale_order.py:236-237`); profitabilitas proyek hanya `project.group_project_manager` [V] `A/project/models/project_project.py:1132-1134` | PM = `group_project_user` tanpa sales | – | – | [V] |
| 13 | Dashboard: No SPK klik → detail & status terakhir | Task list/kanban group by `sale_order_id` (nama SO tampil via `sudo().display_name` walau tanpa ACL [V] `odoo/orm/fields_relational.py:373`); `project.update` status (`A/project/models/project_update.py:45`); Dashboards spreadsheet sale terpasang | Filter tersimpan + favorit | "Tahap paling tertinggal per SPK" & ringkasan 1 baris/SPK | Mulai dengan view standar; dashboard kecil (G7) hanya jika user menolak view standar. Fence nilai = ACL (bukan view) | [V]/[A] |
| 14 | Estimasi BoQ, margin | `sale.order` line + `sale_pdf_quote_builder`; biaya produk | – | BoQ internal (waste, margin) | `custom_spk_estimation` sementara tanpa jembatan (keputusan terpisah) | [A] |
| 15 | Material per SPK | `project_stock`/`sale_stock`, analitik proyek [V terpasang] | Lokasi/rute | Approval & offcut | `custom_spk_material` di-hold | [A] |
| 16 | Coretax/e-Faktur, PPh potong | `account` + `custom_coretax*`, `custom_tax_id` | NSFP, pajak | Dua mesin PPh (`custom_pph_witholding` & `custom_tax_id`) terpasang berdampingan | Pakai `custom_tax_id`; nonaktifkan yang lain setelah verifikasi | terpasang [V], fungsi [A] |
| 17 | Brand & Group klien | `res.partner` perusahaan (Group) + kontak anak (Brand); SO `partner_id`=Brand, invoice ke `commercial_partner_id` | Impor partner | – | Ganti `cl.expomedia.brand` | [A] (Q5) |

## 5. Konfigurasi (tanpa kode, `expomedia_staging`)

1. Settings → Project: aktifkan **Milestones**; Accounting: **Analytic Accounting**; Sales: **Customer Addresses** (invoice/delivery).
2. Settings → Timesheets: encoding **Days** (bila disetujui, Q6); isi `hourly_cost` karyawan crew (upah harian ÷ jam kerja kalender).
3. Project → template **"Booth / Event"** (`is_template`): stage Desain, Produksi, Instalasi, Laporan, BAST, Selesai; milestone
   default Instalasi & BAST.
4. Produk jasa (mis. Produksi Booth, Instalasi, Dismantle, Desain): `type=service`, `service_tracking=task_in_project`,
   `project_template_id`=template, `service_policy=delivered_milestones`.
5. Termin pembayaran (DP x% + pelunasan) — nilai Q3.
6. Sequence `tenant.sale_order` (§3.3) untuk company EXP.
7. User & grup sesuai tabel §1; PM **tidak** diberi `project.group_project_manager` (profitabilitas) maupun grup sales.
8. `custom_timesheet`: jangan pakai tombol "Invoice timesheet" di SO (§6).

## 6. Modul custom: pertahankan / jembatani / pensiunkan

| Modul | Status | Alasan (bukti) |
|---|---|---|
| `custom_doc_numbering` | **Pertahankan** + fix G2 | Mekanisme rename cocok [V] |
| `custom_sale_bast`, `custom_bast` | **Pertahankan** | Sudah di `sale.order` [V] |
| `custom_coretax*`, `custom_tax_id`, `custom_hr_payroll_id`, `custom_attendance`, `custom_accounting_*` | **Pertahankan** (platform) | Kepatuhan ID; di luar alur SPK |
| `custom_pph_witholding` | Evaluasi → nonaktif | Duplikasi mesin PPh (doc owner §3.2) |
| `custom_timesheet` | Pertahankan (validasi/OT), **jangan pakai wizard invoice** | Wizard membuat `account.move` sendiri dengan `x_billing_rate` + `sale_line_ids` (`custom_timesheet/wizards/custom_timesheet_invoice_wizard.py:75-120`) → tagihan ganda vs milestone [V] |
| `custom_crm` | Pertahankan | Hanya menambah menu di bawah `crm.crm_menu_root` [V] |
| `custom_spk` (+ `group_spk_*`) | **Hold, tidak dipakai untuk alur komersial** | Tidak ada link ke SO/lead [V]; state draft/sent menduplikasi quotation. Tidak di-uninstall sekarang (9 satelit bergantung) |
| `custom_spk_billing` | **Pensiun (tidak dipakai)** | Mencocokkan invoice via teks `invoice_origin like spk.name` (`custom_spk_billing/models/custom_spk_billing_plan.py:144-147`) [V]; digantikan milestone+DP |
| `custom_spk_workforce` (`custom.spk.attendance`, `work.log`, alokasi) | **Pensiun untuk biaya SPK** | Model paralel timesheet; alokasi tenaga tetap bulanan [A] bisa dievaluasi nanti |
| `custom_spk_delivery` | Hold; kandidat jembatan G6 | Punya loading/instalasi/dismantle/BAST per venue (`custom_spk_delivery/models/custom_spk_delivery.py:48-91`) yang CE tidak punya, tetapi terikat `custom.spk` |
| `custom_spk_estimation`, `_costing`, `_material`, `_change_order`, `_survey`, `_shopfloor` | Hold (fase berikut) | Semua terikat `custom.spk`, bukan SO [V] |
| `custom_project_portfolio` | Tidak dipakai untuk Expomedia [A] | Stage/SLA sendiri di `project.task.type` bisa bentrok dengan template |
| `custom_field_service` | Tidak dipakai | `fsm.work.order` paralel, tanpa link task/SO [V] |
| `custom_planning` | Tidak dipakai (sekarang) | `planning.slot` tanpa link project/task [V] |
| `custom_dashboards` | Opsional | Tile KPI generik; fence tetap dari ACL |
| `cl_expomedia_spk` | **Pensiunkan** | `cl.expomedia.spk.project` (paralel `project.task`), `cl.expomedia.spk.activity` (paralel timesheet), `cl.expomedia.brand` (→ partner) [V] |

## 7. Cakupan kode custom yang diusulkan (`cl_expomedia_sale`, hanya DB Expomedia)

| ID | Isi | Jenis |
|---|---|---|
| G1 | Grup AE + ACL/rule CRM + groups pada field/tombol `sale_crm` di `crm.lead` | Security data + atribut field |
| G2 | Guard rename (pakai `x_quotation_name`) + TZ tanggal nomor | Fix di `custom_doc_numbering` (platform) |
| G3 | Override nama menu + `i18n/id.po`; sequence SPK | Data |
| G4 | (opsional) `sale.order.line.x_venue_partner_id` → `project.task.partner_id` | Field + 1 override prepare values |
| G5 | (opsional) `account.analytic.line.x_giat_type` | Field + view |
| G6 | (ditunda) jembatan `custom_spk_delivery.task_id` | – |
| G7 | (bila view standar ditolak) dashboard SPK berbasis `sale.order`/task, nilai hanya grup sales | View/OWL |
| Tes | Per peran: AE `sale.order.read` → AccessError; PM tidak menerima `amount_*`; nomor SPK; menu `demo_staging` tetap "Sales" | Python |

## 8. Data demo / migrasi (sheet → objek standar)

| Sumber | Target | Catatan |
|---|---|---|
| GROUP / BRAND | `res.partner` company / kontak anak | Normalisasi spasi (`Luxasia` vs `Luxasia `) |
| AE | `res.users` (grup AE) → `crm.lead.user_id`, `sale.order.user_id` | 18 nama |
| VM | Kontak PIC klien (`partner_id` child) atau catatan | Arti VM = Q7 |
| No QUOT (`yyMMnnn`) | `crm.lead` (won) → `sale.order`; nomor lama di `client_order_ref` (bisa dicari) | Pengelompokan project→SPK = Q1 |
| PROJECT (per baris) | `sale.order.line` (produk jasa, deskripsi = nama project+lokasi) → task | Harga **mockup**, ditandai (mis. tag SO "MOCKUP" [A]) |
| Centang Quot/Produksi/Instalment/Laporan/BAST | Stage task tertinggi yang tercentang; BAST → milestone tercapai | – |
| Keterangan | `note` / chatter task | – |
| GIAT (Tgl, Hari, Kegiatan, Lokasi, Project, TIM) | Timesheet per anggota TIM di task yang cocok (No SPK di Lokasi, atau fuzzy nama project) | Nama crew → `hr.employee`; baris tak cocok → laporan rekonsiliasi |
| Keuangan demo | DP untuk SPK ≥ Produksi, invoice pelunasan saat BAST, payment Jan–Jun | Semua mockup, bisa di-reset |

Data lama `custom_spk`/`cl_expomedia_*` (impor `gs_*`) dihapus lewat importer `--reset` sebelum impor ulang (setelah disetujui).

## 9. Risiko

- Opsi B (G1) menyentuh ACL CRM: harus diuji per layar; upgrade `crm`/`sale_crm` bisa menambah ACL baru yang tidak tersalin.
- `x_doc_code='EXP'` sudah mengubah pola nomor invoice (reset bulanan) — cek dengan Finance sebelum invoice pertama.
- PM tidak punya ACL `sale.order`: klik SO dari task → AccessError (disengaja); navigasi PM lewat Project/Task.
- 577 `project_project` lama (dari jalur `custom_spk`) perlu dibersihkan/diarsipkan agar tidak tercampur dengan proyek dari SO.

## 10. Pertanyaan terbuka untuk client

1. Bagaimana beberapa project dikelompokkan menjadi satu SPK? Di sheet hampir setiap baris punya No QUOT sendiri.
2. Format nomor penawaran (tetap `S00001`, `PNW/…`, atau `yyMMnnn` seperti sekarang)? Counter SPK: berjalan terus atau reset (tahunan/bulanan/harian)? Setuju nomor invoice `INV/EXP/YYYY/MM/NNN`?
3. Persentase DP dan milestone penagihan (mis. DP 50% – Instalasi – BAST)? Termin hari?
4. Crew lapangan: karyawan tetap, harian, atau vendor/subkon? Upah harian per orang (untuk `hourly_cost`)?
5. Brand = kontak di bawah Group, dan invoice ke Group? Atau ada brand yang ditagih langsung?
6. Timesheet crew dicatat per hari/slot (pagi/malam = 0,5 hari) — cocok?
7. Arti kolom VM (Visual Merchandiser klien atau staf internal)?
8. Apakah jadwal muat/bongkar perlu jam (window) atau cukup tanggal per kegiatan?
9. Boleh AE melihat "Expected Revenue" di lead (nilai perkiraan yang ia isi sendiri)?
10. Siapa yang mengonfirmasi SPK (Owner saja atau Finance juga)? Siapa yang mencatat GIAT/timesheet (PM/Mandor)?
