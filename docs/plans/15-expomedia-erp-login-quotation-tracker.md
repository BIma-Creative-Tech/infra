# Plan 15 — Expomedia: erp.expomedia.id, login bermerek Demo/Production, Quotation Tracker

Status 2026-09-30: **Demo (`demo-erp.expomedia.id` → staging) dan Production (`erp.expomedia.id`) AKTIF**.
Kelanjutan plan 13/14 (alur standar CRM → PNW → SPK = sale.order → task → timesheet → invoice → payment).

## 1. Keputusan user (2026-09-30)

- **Demo** = staging yang ada (`expomedia_staging`, data mockup). **Production** = DB baru `expomedia_prod` (pool-a) di
  `https://erp.expomedia.id`, dimulai **tanpa** transaksi mockup.
- Login = halaman `/web/login` Odoo bermerek + toggle Demo/Production (link antar host, DB tetap per host) +
  username/password + tombol SSO. Login via SSO = satu sesi Keycloak untuk Odoo dan dashboard.
- Dashboard Quotation Tracker di **control-plane** (data mart), bukan di Odoo.
- Menu: hanya level aplikasi (kartu bergambar home console).
- User `am.ademaryadi@gmail.com` = admin semua modul, di demo dan prod.
- DNS `expomedia.id` (NS mysrsx / Digital Registra) ditambahkan user sendiri.

## 2. Selesai (staging)

| Bagian | Isi |
|---|---|
| Odoo | `cl_expomedia_web` 19.0.1.0.0 (repo odoo-addons-expomedia tag `v19.0.2.1.0`; submodule `staging/odoo/addons/clients/expomedia`). Login bermerek, `/expomedia/landing` → `cl_expomedia_web.dashboard_url` untuk grup **Dashboard Quotation Tracker**, kartu app Expomedia + grup "Alur Kerja Expomedia", navbar grafit. 4 tes HttpCase lulus (config uji `proxy_mode = False`). Backup sebelum install: dump `expomedia_staging` di scratchpad sesi (600). |
| Data mart | ingest `payment` (account_partial_reconcile → alokasi per invoice; payment tanpa jurnal → `account_move__account_payment`), `invoice.invoice_date_due` (ALTER ADD COLUMN, kolom di akhir). dbt: `stg_payment`, `mart_spk_invoice`, `mart_spk_payment`, kolom `mart_spk.tracker_stage/invoice_count/next_due_date/overdue/payment_count/last_payment_date`, tes `mart_spk_payment_within_invoice`. 21/21 PASS; total alokasi = total dibayar invoice (Rp 12.251.347.500 staging). |
| control-plane | v0.4.0 branch `feat/quotation-tracker` (`5e7cafc` + fix `eb5ab2d`), image `control-plane:eb5ab2d` di `cp.staging`. `/dashboard/quotation` + detail Penagihan/Pembayaran; env `DASHBOARD_ODOO_URLS`. E2E SSO `uji-dash-fin` (nilai) / `uji-dash-pm` (tanpa Rp) lulus. Rollback: tag `98e823c`. |
| User | `am.ademaryadi@gmail.com` di `expomedia_staging` (id 99, **sudah ada sejak 2026-09-29**, tertaut Keycloak `platform-staging`, role control-plane `superadmin`): ditambah grup admin semua privilege + SPK PM/price viewer + PMO admin + Dashboard; `sh_oidc_password_exempt` (admin boleh password lokal). Password Keycloak tidak diubah; password lokal Odoo baru diserahkan ke user. Login lokal → `/expomedia/landing` → `cp.staging/dashboard/quotation` (diuji). |

## 3. DNS + alias Demo (SELESAI 2026-09-30)

Di panel DNS `expomedia.id`, tanpa AAAA:

| Tipe | Nama | Nilai |
|---|---|---|
| A | `erp` | `31.97.50.221` |
| A | `demo-erp` | `31.97.50.221` |

Setelah `dns_precheck` lulus (1.1.1.1 & 8.8.8.8):
1. Demo alias: router manual `traefik/dynamic/clients/expomedia-staging-alias.yml` (salin 6 router
   `expomedia-staging.yml`, Host `demo-erp.expomedia.id`, header DB sama, `/web/database` ditolak);
   `provision-odoo-sso.sh expomedia staging --host expomedia-erp.staging.bimacreative.tech --host demo-erp.expomedia.id`;
   `web.base.url` → `https://demo-erp.expomedia.id`; `DASHBOARD_ODOO_URLS` staging → `demo-erp`.
   **Jangan** buat router sebelum DNS resolve (ACME HTTP-01 gagal berulang → rate limit LE).
   File di `dynamic/clients/` tidak di-watch → setelah menaruh file manual: `docker exec traefik kill -HUP 1`.

Hasil: zona serial `2026093001`; `demo-erp` LE (YE1, s/d 2026-12-29), `/web/login` 200, `/web/database` 403; SSO
`odoo-expomedia-staging` redirect URI dua host; `web.base.url` staging = `https://demo-erp.expomedia.id`.

## 4. Prod (SELESAI 2026-09-30, izin user eksplisit)

Plan 14 §5 dengan host **erp.expomedia.id** dan modul `cl_expomedia_web`:
1. `restic-backup.service`.
2. Pool-a: submodule `platform` @ v19.0.1.1.1, `clients/expomedia` @ **v19.0.2.1.0**, addons_path/PYTHONPATH/pylib, recreate.
3. `provision-odoo-db.sh expomedia prod --host erp.expomedia.id`, `render-client-route.sh … --host erp.expomedia.id`,
   `provision-odoo-sso.sh … --host erp.expomedia.id`; install root plan 13 §2 + `cl_expomedia_sale` + `cl_expomedia_web`
   (hook: env=production, dashboard_url=`https://cp.bimacreative.tech/dashboard/quotation`); `configure_standard.py`.
   Tanpa `run-import-spk.sh` (mockup hanya di Demo).
4. User: Keycloak realm `platform` (belum ada) + `odoo-sso-user.sh expomedia prod --email am.ademaryadi@gmail.com --admin --grant`
   (res.users dibuat dulu dengan skrip grup admin yang sama), role control-plane prod.
5. control-plane prod: merge `feat/quotation-tracker` (berisi `feat/lead-spk-dashboard`) → main, tag v0.4.0, backup
   `control_plane`, `.env.datamart` (`DATAMART_ENV=prod`), `DASHBOARD_ODOO_URLS=expomedia=https://erp.expomedia.id`.
6. Rollback: plan 14 §5.7 (+ uninstall `cl_expomedia_web` bila perlu; hook tidak menghapus logo company).

### Hasil prod

| Langkah | Bukti |
|---|---|
| Backup | restic 2026-09-30 14:55 WIB, semua DB ok, snapshot `f392a23e`; dump `control_plane` pra-v0.4.0 di scratchpad sesi |
| Pool-a | submodule `platform` v19.0.1.1.1 + `clients/expomedia` v19.0.2.1.0, `addons_path`/`PYTHONPATH`/pylib (6 paket); recreate → healthy, `demo.erp…/web/login` 200 |
| Tenant | `expomedia_prod` (`provision-odoo-db.sh --host erp.expomedia.id`, admin secret `odoo/pool-a/secrets/tenants/expomedia_prod.admin-password`); route `expomedia-prod.yml` LE s/d 2026-12-29; SSO provider 4 realm `platform` (Odoo.com off, signup b2b) |
| Modul | 195 = set staging (0 selisih); ERROR tunggal = bug `custom_pdp` duplikat klasifikasi (dikenal, non-fatal) |
| Konfigurasi | company PT Expomedia Indo Karya (Kota Tangerang, BT, IDR, id_ID), COA `id_psak` (60 akun, 5 pajak, income 41000; generic_coa diganti — belum ada jurnal), `custom_ai.enabled=False`, vertical BOOTH/EVENT/ACTIVATION, `configure_standard.py`. **NPWP tidak diisi** (staging memakai placeholder). Tanpa data mockup. |
| User | Keycloak `platform` SUDAH ADA: username `ademaryadi` (Stefanus Ade Maryadi, OTP aktif, control-plane `superadmin`) → + role `odoo_access`; res.users 5 `am.ademaryadi@gmail.com` admin semua modul + Dashboard, tertaut (oauth_uid = id Keycloak), `sh_oidc_password_exempt`. `odoo-sso-user.sh` tidak dipakai (mencari username = email). |
| control-plane | main `c4c1051` (merge `feat/quotation-tracker`), tag v0.4.0 (lokal, belum di-push), `.env.datamart` DATAMART_ENV=prod, `DASHBOARD_ODOO_URLS=expomedia=https://erp.expomedia.id`; healthy |
| Data mart | `raw_expomedia_prod` ter-ingest, 21/21 PASS, `mart_user_access` prod berisi user ini (nilai=ya) |
| E2E | login lokal prod → `/expomedia/landing` → `https://cp.bimacreative.tech/dashboard/quotation`; Demo → cp.staging |

## 5. Catatan

- `cl_expomedia_sale` tests di DB kosong gagal 2 (butuh `custom_spk` + konfigurasi penomoran dari `configure_standard.py`)
  — bukan regresi modul baru; jalankan di salinan DB staging.
- Tombol "Use a Passkey" (auth_passkey) dan "Reset Password" tetap tampil di login (fitur standar).
