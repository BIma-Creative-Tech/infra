# Plan 13 — Tenant Odoo Expomedia + modul platform Athera + form web → lead CRM

- Status: **STAGING LIVE 2026-09-29**; prod **BELUM** (ditahan: butuh persetujuan eksplisit deploy produksi, §6).
- Terkait: plan 07 (web + mail Expomedia; "Odoo tenant" di OUT), ADR 0015 (modul platform), ADR 0008 (SSO), ADR 0004
  (kapasitas); repo `/opt/src/odoo-addons-athera` (v19.0.1.1.0), `/opt/src/web-expomedia` branch `feat/contact-odoo-lead`
  (v0.4.0); requirement owner "Requirement Bisnis & Implementasi Odoo — Tenant `expomedia`" (2026-09-29).

## 1. Keputusan user (2026-09-29)

| # | Keputusan |
|---|---|
| 1 | Pool **bersama** (staging lalu pool-a), bukan dedicated |
| 2 | Cakupan: penawaran → SPK → absensi per proyek → produksi → penggajian → dashboard → finance/accounting; set modul **mengikuti 44 modul tenant `expomedia` di platform ATHERA**, tanpa `custom_athera_sso` (diganti `sh_auth_oidc`) |
| 3 | Mesin PPh withholding yang dikonfigurasi: **`custom_tax_id`** (`custom_pph_witholding` tetap terpasang sebagai dependensi) |
| 4 | Data tenant lama = data demo → **dibawa** nanti, dan **wajib direset sebelum go-live**; untuk sekarang DB bersih (akses dump belum ada) |
| 5 | Form kontak web → lead CRM Odoo: **ya** |

## 2. Modul (`addons/platform` @ v19.0.1.1.0, 52 modul)

Root (38): `custom_crm custom_sale_bast custom_doc_numbering custom_report_templates custom_spk custom_spk_estimation
custom_spk_survey custom_spk_change_order custom_spk_material custom_spk_costing custom_spk_delivery custom_spk_billing
custom_spk_shopfloor custom_project_portfolio custom_spk_workforce custom_attendance custom_hr_payroll_id custom_hr_leave_id
custom_expenses custom_petty_cash custom_dashboards l10n_id_psak_custom custom_accounting_menu custom_accounting_reports
custom_account_ee_features custom_coretax_export custom_pdp_masking custom_timesheet custom_planning custom_field_service
custom_documents custom_quality_full custom_product_barcode custom_barcode custom_wms_docs custom_adapter_framework
custom_object_storage custom_operating_unit` (+ dependensi: core, pdp, pdp_audit, ai_bridge, home_console, approval_engine,
bast, coretax, coretax_bupot, pph_witholding, tax_id, accounting_full/asset/recurring). Python: `httpx`, `xmlschema` via pylib.

Selisih dengan tenant lama: `custom_athera_sso` tidak dipasang; tambahan di luar dokumen owner yang tetap dipasang:
`custom_doc_numbering`, `custom_project_portfolio`, `custom_hr_leave_id`, `custom_petty_cash`, `custom_accounting_menu`
(+asset/recurring), `custom_account_ee_features`, `l10n_id_psak_custom`.

## 3. Staging (selesai)

| Item | Nilai / bukti |
|---|---|
| Pool | `odoo-staging` recreate (backup restic `RESULT status=ok dbs_ok=11` 07:01 WIB), healthy, `demo.staging…/web/login` 200 |
| DB | `expomedia_staging` (`provision-odoo-db.sh … --host expomedia-erp.staging.bimacreative.tech`) |
| Host | `expomedia-erp.staging.bimacreative.tech` — host default `expomedia.staging…` sudah dipakai website staging |
| Route | `traefik/dynamic/clients/expomedia-staging.yml`, TLS LE OK, `/web/login` 200 |
| SSO | client `odoo-expomedia-staging` realm `platform-staging`, provider id 4, smoke authorize 303 → Keycloak |
| Modul | 51 `custom_*` + `l10n_id_psak_custom` `installed`; install 2 m 42 s + 32 s; puncak memori cgroup pool 936 MiB / 1280 MiB |
| Company | PT Expomedia Indo Karya, ID/Banten, IDR, COA `id_psak` (60 akun, 5 pajak, income 41000 / expense 52000), `id_ID`, Asia/Jakarta |
| Konfigurasi | `custom_ai.enabled=False`; vertical PMO contoh retail diarsipkan → `BOOTH`, `EVENT`, `ACTIVATION` |
| User teknis | `website-leads` (Role/User + Sales own documents), API key `rpc` 365 hari → `staging/web-clients/expomedia/secrets/odoo_api_key.secret` |
| Web | `web-expomedia:dev-a173509` (v0.4.0 + fix), `--odoo-url https://expomedia-erp.staging.bimacreative.tech`; uji dari container web: `crm.lead/create` 200 (lead uji dihapus) |

Log install: 1 ERROR upstream `pdp_field_classification_model_field_uniq` (19 pasangan duplikat di CSV `custom_pdp`,
1206/1225 baris termuat) — modul tetap terpasang.

## 3a. Data master: template + mockup (2026-09-29)

Keputusan user: pakai **data mockup** sampai data asli dari user masuk; template isian dari data perusahaan sampai master.
Repo `/opt/src/odoo-data-expomedia`: `dist/Template-Data-Master-Expomedia.xlsx` (dikirim ke user, 17 sheet + petunjuk,
kamus kolom, dropdown dari COA/satuan/termin Odoo), `dist/Mockup-Data-Master-Expomedia.xlsx` (fiktif, `@example.com`),
importer idempoten `tools/run-import.sh` (satu transaksi, `--dry-run`, `--reset-mockup`).
- `expomedia_staging`: mockup diimpor — 142 baris, 0 error (company, 2 rekening/jurnal, 8 departemen, 13 jabatan,
  15 karyawan, 9 user mockup, 7 pelanggan, 6 vendor, 5 venue, 8 kategori, 7 satuan, 23 produk, gudang WS + 3 lokasi,
  3 shift, 2 template estimasi, 5 akun). Siklus impor → reset → impor ulang diuji.
- **Go-live:** `run-import.sh <pool> <db> --reset-mockup` → impor file asli (dataset `asli` ditolak selama mockup ada).
  User mockup **tidak** diberi undangan SSO.

## 3b. Dashboard SPK + data operasional 2026 (2026-09-29)

- Modul client `cl_expomedia_spk` (repo `/opt/src/odoo-addons-expomedia` v19.0.1.0.0, submodule
  `staging/odoo/addons/clients/expomedia`; staging di-recreate untuk glob `clients/*`):
  - SPK multi-project dan multi-lokasi; kegiatan lapangan; absensi per SPK;
  - menu **Dashboard SPK**: Owner/Finance (`group_spk_price_viewer`) melihat nilai, PM/Supervisor status saja;
  - `group_spk_price_viewer` diberi baca semua SPK.
  Tes modul: 6/6 lulus.
- Sheet Google "SPK 2026 / GIAT 2026" (data operasional asli, tanpa nilai) diimpor ke `expomedia_staging` dengan
  `odoo-data-expomedia/tools/run-import-spk.sh`:
  - 742 SPK dan 744 project, dengan **nilai mockup**;
  - 734 kegiatan, 361 di antaranya tanpa nomor SPK;
  - 108 crew dan 716 absensi.
  Verifikasi per peran: Owner/Finance melihat nilai; PM/Supervisor ditolak baca `x_amount_total` (AccessError).
- Prod: modul client belum dipasang (ikut langkah §6 + submodule `odoo/pool-a/addons/clients/expomedia`).

## 4. User teknis & API key (per DB)

```python
# docker exec -i <pool> odoo shell -c /etc/odoo/odoo.conf -d <db> --no-http --workers=0 --max-cron-threads=0
import datetime
U = env['res.users'].with_context(no_reset_password=True)
u = U.search([('login', '=', 'website-leads')]) or U.create({'name': 'Website Leads (teknis)', 'login': 'website-leads',
    'group_ids': [(6, 0, [env.ref('base.group_user').id, env.ref('sales_team.group_sale_salesman').id])]})
key = env['res.users.apikeys'].with_user(u).sudo()._generate('rpc', 'web-expomedia <env>', datetime.datetime.now() + datetime.timedelta(days=365))
env.cr.commit(); print("KEY=" + key)   # alihkan stdout ke file, tulis ke secrets/odoo_api_key.secret tanpa newline
```
Kedaluwarsa key: **2027-09-29** (staging) — rotasi sesuai `web-client-onboarding.md` §3 langkah 7.

## 5. Tes upstream (DB sementara `expomediatest_staging`, sudah di-drop)

`--test-enable --test-tags /<52 modul>`: **669 tes, 9 gagal, 23 error**. Tidak ada kegagalan di modul SPK/BAST.
- 5 kelas `setUpClass` gagal (`custom_account_ee_features.test_admin_fee`, `custom_accounting_recurring.test_recurring`,
  `custom_coretax_export.test_{item_jenis,pemotong_guard,zero_rate_vat}`): `AccessError` field `standard_price` pada
  `product.product` — **dugaan** (belum diverifikasi): price fence `custom_spk` menyembunyikan harga pokok dari user uji.
- `custom_tax_id`: 13 error `CheckViolation account_move_line_check_accountable_required_fields` — **dugaan**: DB uji tanpa
  COA terpasang saat tes berjalan (modul diuji saat install).
- FAIL lain: `custom_pdp.test_no_installed_column_is_unclassified`, `custom_hr_leave_id.test_overlap_two_holidays`,
  `custom_doc_numbering.test_quotation_then_sales_order_renumber`, `custom_dashboards.test_tile_compute_formula`,
  `custom_crm.test_score_clamped_*`, `custom_attendance.{test_overtime_work_entry_creation,test_long_shift_requires_approval}`,
  `custom_adapter_framework.test_call_log_appended` (+1 error), `custom_project_portfolio.test_payload_carries_vertical_and_url`;
  error `custom_timesheet.test_overtime` ×2, `custom_accounting_full.test_bill_ref_guard` ×2.
Ditindaklanjuti di repo modul (owner); bukan pemblokir staging.

## 6. Prod (BELUM — langkah untuk dijalankan setelah persetujuan)

1. `systemctl start restic-backup.service` → `RESULT status=ok`.
2. `git -c protocol.file.allow=always submodule add /opt/src/odoo-addons-athera odoo/pool-a/addons/platform` →
   checkout `v19.0.1.1.0`; salin perubahan `odoo.conf` (`addons_path`) & `docker-compose.yml` (`PYTHONPATH`, mount pylib) dari
   `staging/odoo` (commit `13a0a69`); `odoo/pool-a/addons/platform/tools/build-pylib.sh /opt/infra/odoo/pool-a/pylib`.
3. `cd odoo/pool-a && docker compose config -q && docker compose up -d --force-recreate` (jeda singkat `demo_demo`); cek
   healthy, `python3 -c "import httpx, xmlschema"` di container, `demo.erp…/web/login` 200.
4. `provision-odoo-db.sh expomedia prod` (host default `expomedia.erp.bimacreative.tech`, DNS wildcard OK) →
   `render-client-route.sh expomedia prod` → `provision-odoo-sso.sh expomedia prod --dry-run` lalu tanpa `--dry-run`.
5. Install root §2 (`-i … --without-demo --stop-after-init --no-http --workers=0 --max-cron-threads=0`), konfigurasi §3
   (company, `try_loading('id_psak')`, set `country_id` lewat partner, `custom_ai.enabled=False`, vertical).
6. User teknis §4 → `web/clients/expomedia/secrets/odoo_api_key.secret`; provision ulang web prod dengan argumen saat ini +
   `--image web-expomedia:<tag v0.4.0> --odoo-url https://expomedia.erp.bimacreative.tech`.
7. Rollback: `provision-web-client.sh` tanpa `--odoo-url`; submodule dihapus / `addons_path` lama + recreate; restore DB.

## 7. Terbuka

- Migrasi data demo dari DB `expomedia` platform ATHERA (butuh akses dump + filestore) → restore ke `expomedia_staging`,
  uninstall `custom_athera_sso` + dependensi control-plane, lalu **reset sebelum go-live**.
- Repo GitHub untuk `odoo-addons-athera` (owner) → `git submodule set-url`.
- Merge `feat/contact-odoo-lead` web-expomedia + tag `v0.4.0` (image GHCR) — sekarang image lokal `dev-a173509`.
- Data pajak (NPWP, sertifikat elektronik Coretax), karyawan/payroll, user SSO Expomedia (`res.users` + `odoo-sso-user.sh`).
- Tindak lanjut tes gagal §5 di repo modul.
