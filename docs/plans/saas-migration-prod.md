# SaaS — Rencana migrasi PROD ke control-plane (brief §6a, disesuaikan fakta 2026-10-03)

Status 2026-10-03: **DRAFT — menunggu (1) gate Fase 1 staging lulus (`saas-phase-1-deploy-staging.md` §7) dan (2)
persetujuan owner per langkah bertanda ⛔.** Tidak ada langkah yang dijalankan selama FREEZE. Prinsip brief §6a: adopsi,
bukan bangun ulang; tidak ada penghapusan sebelum pengganti terbukti; setiap langkah punya dry-run, cek, rollback.

## 0. Fakta prod (read-only, 2026-10-03)

| Item | Nilai | Sumber |
|---|---|---|
| Tenant di CP prod (`clients`) | **hanya `demo`** (env `demo`, DB `demo_demo`, host `demo.erp.bimacreative.tech`, db/route/sso aktif) | `SELECT` control_plane |
| Expomedia | **belum terdaftar di CP**: DB `expomedia_prod`, route `expomedia-prod.yml` (host `erp.expomedia.id`, dirender `render-client-route.sh` manual), client KC `odoo-expomedia-prod` | inventaris §3, A3 |
| User Odoo internal aktif (selain admin/system) | `expomedia_prod` **1** (tertaut SSO); `demo_demo` 1 (tidak tertaut) | `SELECT` res_users (jumlah saja) |
| User realm `platform` (non-SA) | **1** | `SELECT` keycloak |
| `users` CP prod | 0 baris (dihapus cleanup QA 09-25/26; FK SET NULL) | temuan W3 |
| Dispatcher prod | 1.0.0, 5 tipe; `prod.conf` tanpa `job_types` | inventaris §3 |
| Keycloak | 26.7.4, `organizationsEnabled=false`, sub-flow `Organization` ada di flow `browser` (migrasi 26.6.1) | ADR 0017 S1 |

Konsekuensi: migrasi data **kecil** (2 tenant Odoo, ≤ 3 user) — risiko utama ada di perubahan komponen bersama
(Keycloak, pool-a, Traefik, dispatcher), bukan di data.

## 1. Langkah (urut)

| # | Langkah | Komponen prod | Jendela | Cek | Rollback |
|---|---|---|---|---|---|
| M1 | Snapshot: `restic-backup` manual + `pg_dump -Fc` `keycloak`, `control_plane`, `expomedia_prod`, `demo_demo`; tar `traefik/dynamic/clients`, `mail/data/config`; `kc_realm_sync --dry-run` keluaran disimpan sebagai "export" kondisi awal | read-only | kapan saja | `RESULT status=ok`, file dump ada | — |
| M2 | Gate Fase 1 staging **dipercepat** (keputusan owner 2026-10-04) dengan syarat S-a/S-b/S-c (`saas-progress.md` Butuh keputusan) + laporan ke owner | staging | — | bukti di `saas-progress.md` | — |
| M3 ⛔ | **Merge infra `feat/infra-saas-p1` → main** + role `infra_jobs` apply: dispatcher 1.2.0; `prod.conf` **tetap** 5 tipe (belum ada `job_types`) | `/usr/local/sbin/infra-job`, skrip | jam sepi | `cmp` dispatcher; job prod lama (`odoo_sso_user` dry-run `demo`) tetap jalan | role dari commit sebelumnya |
| M4 ⛔ | **K11: Keycloak 26.7.4 → 26.7.5** (pin digest baru di Containerfile, ADR 0001), rebuild `infra/keycloak:26.7.5-optimized`, recreate container | `keycloak` (± 1–2 menit login tidak tersedia) | **jendela perawatan** (di luar jam kerja expomedia & bct & drms) | login CP prod, `odoo-expomedia-prod`, `drms` web/mobile; `/health/ready` | image 26.7.4 lama (tag tetap ada) + recreate; DB tidak berubah oleh patch release (diverifikasi 2026-10-04: +1 changeset data `26.7.0-backfill-group-org-id`, 0 baris, tanpa skema — **SELESAI** `d89e121`) |
| M5 ⛔ | Realm `platform`: bootstrap client `kc-realm-sync` (console, sekali) → `kc_realm_sync` plan → apply dengan `approve` (sub-flow `Organization` DISABLED, scope `tenant`, `cp-admin`, `odoo_admin`) → plan kedua `changed=0` → override `organizationsEnabled: true` → plan/apply | realm `platform` (tanpa restart) | jam sepi | login semua client `platform` tetap form biasa; token berisi `tenant_id` (kosong dulu); drms realm tidak tersentuh | override `organizationsEnabled: false` + sync; desired-state lama |
| M6 ⛔ | **Deploy CP prod** `feat/saas-p1` (merge control-plane → main, build `control-plane:<sha7>`, migrasi 0004–0005 aditif + seed plan + tenant `platform`) dengan `INFRA_JOBS_TYPES` **kosong** (perilaku prod = hanya baca untuk fitur baru) | `control-plane`, `control-plane-worker` (restart ± 30 s) | jam sepi | health, `/dashboard` SPK expomedia (dibaca datamart) normal, `/users` & `/clients` terbuka read-only | `CONTROL_PLANE_TAG=3d4aa7c` (kolom/enum baru diabaikan kode lama) |
| M7 ⛔ | Aktifkan tipe job baru di prod: `prod.conf job_types` = 5 lama + `kc_*`, `odoo_user_ensure`, `odoo_tenant_config`, `tenant_suspend`, `tenant_resume` (tanpa `kc_realm_sync` apply dari UI kecuali owner setuju) + `INFRA_JOBS_TYPES` sama di compose prod | dispatcher prod, CP prod | jam sepi | job `kc_user_*` dry-run sukses | hapus `job_types` dari prod.conf |
| M8 ⛔ | **Backfill** dari CP (tanpa terminal): (a) adopsi user staf realm `platform` (1 user) → tenant `platform` (`adopt`); (b) **daftarkan tenant `expomedia`** (form "Tenant baru" TIDAK dipakai — DB sudah ada) lewat aksi backfill: baris `clients` + environment `prod` (db `expomedia_prod`, host `erp.expomedia.id`, status db/route/sso diisi dari kondisi nyata, `route` = **manual** sampai Fase 2 karena host milik client); `kc_org_ensure`; (c) `demo` → `kc_org_ensure`; (d) user Odoo expomedia (1) → `kc_user_ensure adopt` ke tenant expomedia + role sesuai; (e) subscription `expomedia` = `implementation` (**JANGAN Go-live** sampai billing §7.3 diuji — syarat S-a); `bct` = tenant tanpa layanan Odoo (web Fase 4) — **bct = pemilik platform** (owner 2026-10-04) → tenant `platform`, bukan tenant klien | control_plane, Keycloak (atribut/org) | jam sepi | `/clients/expomedia` lengkap; `tenant_id` terisi; tidak ada user `platform` tanpa `tenant_id` | baris CP: `terminated`; org/atribut KC dibiarkan (tidak dipakai) |
| M9 ⛔ | **`sh_auth_oidc` 19.0.1.3.0 di pool-a**: bump submodule `odoo/pool-a/addons/shared`, restart `odoo-pool-a`, `-u sh_auth_oidc` di `expomedia_prod` & `demo_demo`; `odoo_tenant_config compat` per env dari CP | `odoo-pool-a` (± 1 menit) | **jendela perawatan** | login SSO expomedia & demo; log `tenant_check=compat` tanpa mismatch | submodule `4bd278a` + restart |
| M10 ⛔ | **DIBLOKIR** sampai `sh_auth_oidc` menerima `tenant_id` staf platform (strict mengunci staf dari Odoo tenant — progres 2026-10-04). 7 hari compat bersih (syarat S-b: tanpa ini TETAP compat) → `odoo_tenant_config strict` per env (tanpa restart; ICP) | ICP DB tenant | kapan saja | login tetap jalan; mismatch = 0 | `compat` |
| M11 | **Cut-over administrasi** (tanggal dari owner): semua user/tenant/billing lewat CP; akses console Keycloak = insiden (catat); bukti: 1 user uji dibuat lewat CP prod → login Odoo expomedia | — | — | `audit_logs` | — |
| M12 | Pensiun manual (setelah 2 minggu normal): skrip/alias manual user (`odoo-sso-user.sh` langsung), SA `automation` (ganti `cp-admin`), dokumen operasi menunjuk CP; route/mail adopsi = **Fase 2/4** (generator domain kustom & mail job) | repo | — | ADR penutup migrasi | — |

## 2. Yang berbeda dari brief §6a
- **R1 (restart Keycloak untuk feature `organization`) tidak perlu** — fitur sudah aktif; diganti **M4 upgrade 26.7.5** (K11, fix
  #52309) yang tetap butuh satu restart.
- **M7 brief (adopsi router Traefik)** dan **M8 brief (adopsi mail)** dipindah ke Fase 2/4 (K10): `erp.expomedia.id` adalah host
  milik client; dispatcher Fase 1 hanya mengizinkan `*.erp.bimacreative.tech`.
- Backfill tenant (M8) kecil dan dilakukan dari UI CP (aksi superadmin), bukan skrip `import-tenants.ts` — volume 2 tenant Odoo.

## 3. Pertanyaan untuk owner
1. Jendela perawatan untuk M4 (restart Keycloak: memengaruhi login semua aplikasi termasuk drms) dan M9 (restart pool-a): tanggal/jam?
2. Status kontrak `bct` (tenant website): perlu subscription sekarang atau setelah web profile Fase 4?
3. Tanggal cut-over administrasi (M11) dan apakah `kc_realm_sync` apply prod boleh dari UI CP (dengan approve) atau hanya dari terminal oleh Lead.
4. Tenant `demo` (DB `demo_demo`, dipertahankan Q6): diperlakukan sebagai tenant internal tanpa subscription?
