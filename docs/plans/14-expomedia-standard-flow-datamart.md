# Plan 14 — Expomedia: alur standar Odoo (CRM → SPK → Invoice) + data mart + dashboard SPK

- Status: **STAGING LIVE 2026-09-29** (semua langkah di bawah terverifikasi). **PROD BELUM**: setiap perubahan pool-a /
  control-plane prod ditolak auto-mode ("Production Deploy") walau user sudah meminta. Langkah persisnya di §5.
- Terkait: plan 13 (tenant Expomedia, addons platform), fit-gap `docs/clients/expomedia-fitgap.md`, ADR 0015
  (addons platform), ADR 0016 (data mart), agen `.claude/agents/odoo-functional.md`.

## 1. Keputusan user (2026-09-29)

- Ikuti fungsi standar Odoo: CRM → Penawaran → **SPK = Sales Order** → Project/Task → Invoice → Payment.
  Absensi per SPK menempel ke SO. Tambah agen fungsional Odoo.
- Nomor `PNW/yyyy/mm/dd-XXXXXX` → `SPK/yyyy/mm/dd-XXXXXX`, counter tanpa reset. Menu Sales → **SPK**, hanya di DB
  Expomedia.
- Satu SPK = beberapa baris SO; satu baris = satu task per lokasi.
- **AE tanpa harga** (opsi B fit-gap); penawaran dibuat Owner/Finance.
- Data demo: 1 No QUOT = 1 SPK; nilai mockup.
- Dashboard: Next.js dari data mart Postgres. Owner/Finance melihat nilai; PM hanya status.
- "Jalankan hingga deployment, review di akhir."

## 2. Odoo (`expomedia_staging`)

| Item | Hasil / bukti |
|---|---|
| Agen fungsional + fit-gap | `.claude/agents/odoo-functional.md`, `docs/clients/expomedia-fitgap.md` (17 kebutuhan, gap G1–G7) |
| G2 penomoran (platform) | `custom_doc_numbering` 19.0.1.0.1: konfirmasi ulang tidak mengganti nomor; tanggal lokal. Platform v19.0.1.1.1. Tes 4/4 |
| `cl_expomedia_sale` (G1/G3/G5) | Grup AE (salinan ACL CRM, tanpa grup sales), sequence PNW/SPK, nama menu tetap setelah `-u sale` (terverifikasi), `x_giat_type/x_giat_slot` di timesheet. Tes 4/4 (AE AccessError ke SO, PNW → SPK, task per baris, timesheet → SO) |
| Konfigurasi standar | `odoo-data-expomedia/tools/configure_standard.py`: analytic, alamat kirim/tagih, template "Booth / Event" (Desain → Selesai, milestone), produk `JSA-PROYEK` (task_in_project + milestone), biaya per jam crew |
| Dipensiunkan | `cl_expomedia_spk` di-uninstall (tabel terhapus); impor lama (model SPK paralel) di-reset |
| Data (sheet SPK/GIAT 2026) | 742 lead → 742 SO (577 SPK + 165 penawaran), 825 task lokasi, milestone standar, 780 invoice (DP 50% + pelunasan; 506 lunas), 1.532 timesheet crew. 597 timesheet GIAT tanpa nomor SPK ada di proyek "GIAT belum terpetakan ke SPK". Harga = MOCKUP |
| Perbaikan impor | `tools/repair_import_2026-09-29.py`: tanggal nomor mengikuti QUOT, milestone ganda dihapus, tanggal tahap task. Total keuangan identik sebelum/sesudah (diff kosong) |

## 3. Data mart (ADR 0016)

- `datamart/ingest.sh` (COPY kolom eksplisit, satu transaksi) → dbt 1.12.5/1.11.0 (pylib ber-hash, python resmi,
  non-root) → `mart.mart_spk`, `mart_spk_location`, `mart_spk_activity` (RLS `app.client`) + `mart_user_access`
  (RLS `app.sub`, hak nilai = grup sales Odoo).
  - `dbt build`: PASS 17/17, ±25 detik.
  - Timer `datamart-refresh.timer` tiap 30 menit (role Ansible `datamart_refresh`).
- Postgres, tanpa restart:
  - network `db-datamart`;
  - role `datamart_reader` (limit 5) dan `datamart` 10 → 5, sehingga Σ tetap 196/200;
  - pg_hba +2 baris (db-cp, db-cp-stg), `pg_hba_file_rules` 19 baris tanpa error.

## 4. Dashboard (control-plane v0.3.0, branch `feat/lead-spk-dashboard` @ 98e823c)

- Halaman:
  - `/dashboard`: kartu client yang boleh dilihat user;
  - `/dashboard/spk`: KPI, bar tahap, nilai per klien, tabel SPK dengan filter, urutan, dan halaman;
  - `/dashboard/spk/[soId]`: lokasi, kegiatan dan kru, nilai.
- Kolom nilai tidak di-SELECT untuk user tanpa hak. Tampilan tanpa style inline (CSP tetap `style-src 'self' 'nonce'`).
- Staging `cp.staging.bimacreative.tech`: image `control-plane:98e823c`, `.env.datamart` (600) hanya untuk `web`.
  Backup `control_plane_staging-…-pre-98e823c.dump`.
- Tes: 320 unit, lint, dan typecheck lulus.
- E2E SSO sungguhan (realm `platform-staging`, 3 user uji):
  - Finance: 577 SPK, nilai tampil.
  - PM: 577 SPK, 0 angka Rp.
  - AE: 179 SPK miliknya, SPK AE lain 0.
  - Client lain → redirect `/forbidden`.
  - Detail 2607519: 12 lokasi, 15 kegiatan.
- User uji `uji-dash-{fin,pm,ae}@example.com` **masih ada** untuk review user. Password ada di scratchpad sesi (600),
  dan user Odoo mockup Maya/Agus/Yazinta tertaut ke sub-nya. Hapus setelah review (§6).

## 5. Prod (BELUM — butuh izin deploy produksi)

1. `systemctl start restic-backup.service` → `RESULT status=ok`.
2. Odoo pool-a: sama seperti staging (plan 13 §6).
   - Submodule `odoo/pool-a/addons/platform` @ `v19.0.1.1.1` dan `odoo/pool-a/addons/clients/expomedia` @ `v19.0.2.0.1`.
   - `addons_path` + `PYTHONPATH` + mount pylib (salin dari `staging/odoo`), lalu `addons/platform/tools/build-pylib.sh
     odoo/pool-a/pylib`, lalu `docker compose up -d --force-recreate` (jeda singkat `demo_demo`).
3. Tenant prod:
   - `provision-odoo-db.sh expomedia prod`, `render-client-route.sh expomedia prod`, `provision-odoo-sso.sh expomedia prod`;
   - install root plan 13 §2 + `cl_expomedia_sale`;
   - `tools/run-odoo-script.sh odoo-pool-a expomedia_prod tools/configure_standard.py`;
   - master data mockup (`run-import.sh`) + sheet (`run-import-spk.sh`, **sudah memakai importer yang diperbaiki**,
     tanpa repair). Tandai MOCKUP, reset sebelum go-live.
4. Data mart: tidak ada perubahan (tenant `expomedia:prod` sudah ada di `DATAMART_TENANTS`; ingest otomatis begitu DB
   ada).
5. Control-plane prod:
   - merge `feat/lead-spk-dashboard` → `main`, tag `v0.3.0`;
   - backup `control_plane`;
   - `web/control-plane/.env.datamart` (`DATAMART_ENV=prod`) + `env_file` web + tag `98e823c` (atau SHA main);
   - `docker compose up -d`.
6. Web expomedia prod: `--odoo-url https://expomedia.erp.bimacreative.tech` (plan 13 §6.6).
7. Rollback:
   - control-plane → tag `6d94d2b` + hapus `env_file` datamart;
   - pool-a → submodule/`addons_path` lama + recreate;
   - data mart → `datamart_refresh_state=absent`.

## 6. Terbuka

- Review user; hapus user uji Keycloak: `…/e2e/kc-users.sh delete` + kosongkan `oauth_uid` Maya/Agus/Yazinta.
- Pertanyaan fit-gap §10: DP %, milestone tagihan, upah crew, arti VM, jendela loading.
- 597 kegiatan GIAT tanpa nomor SPK: petakan manual oleh PM, atau wajibkan nomor SPK di kolom Lokasi.
- Build image lewat CI/GHCR (ADR 0004 §9) untuk control-plane (masih lokal, TEMPORARY).
