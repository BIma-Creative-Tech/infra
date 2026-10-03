# SaaS — log progres

Append per sesi, bertanggal. Pertanyaan pemblokir selalu di bagian **Butuh keputusan** paling atas.

---

## Butuh keputusan

- **K3 (owner, HARI INI)** — buat 5 repo **private** kosong di `bctech-adm`: `web-expomedia`, `odoo-data-expomedia`,
  `odoo-addons-athera`, `odoo-addons-expomedia`, `web-tambang`; **nonaktifkan Actions** dulu (web-expomedia/web-tambang punya
  `ci.yml` yang langsung jalan saat push tag/branch); pasang deploy key **write** (public key di laporan sesi; file
  `~/.ssh/deploy_<repo>.pub` root di host). Setelah itu Claude menjalankan push semua branch + tag.
- **FREEZE DICABUT** (owner, 2026-10-03 ±14:27 WIB). Menunggu owner: (a) izin apply Ansible `infra_jobs` (runbook §1.3 —
  ditolak classifier izin otomatis, kategori *Protected-Scope IaC Apply*) dan `backup` (restic `/opt/src`); (b) jam untuk §2
  restart `odoo-staging` + §4 HUP Traefik (aturan runbook: di luar jam kerja client); (c) hadir ±10 mnt untuk bootstrap
  `kc-realm-sync` (§3.1, TOTP); (d) `docker volume prune` diblok hook `bash-policy.sh` — jalankan sendiri atau longgarkan hook.

## Keputusan owner (2026-10-02)

| # | Keputusan | Status pelaksanaan |
|---|---|---|
| K1 | `restic unlock` + ulang restore-test | **selesai** 23:03 — lock basi dihapus; `restic check` **ok**; `db_compare=failed` (lihat log sesi) |
| K2 | stop `ci-runner-supervisor` selama demo, start saat freeze dicabut | **selesai** — supervisor stop, container job idle ikut berhenti |
| K3 | repo privat GitHub + push semua branch/tag hari ini; `/opt/src` ke restic (apply setelah freeze) | sebagian — key/remote siap, menunggu repo dibuat owner; restic di branch belum di-merge |
| K4 | setelah freeze: hapus 21 image (**kecuali `axllent/mailpit:v1.31.2` — dipakai Mailpit staging Fase 1**) per `repo:tag` tanpa `-f` (pre-check daftar ID/tag, keluarkan yang dipakai container/compose/.env + 4 basis), `builder prune --filter until=72h`, `volume prune` anonim (lampirkan `volume ls -f dangling=true` sebelum/sesudah); §11.3 TIDAK; `docker-host-gc.timer` via Ansible dry-run dulu | menunggu freeze |
| K5 | tag ulang `42682f7f2d09` → `proyekkas-web:0.4.1`; pin `proyekkas-*:0.3.0` | menunggu freeze |
| K6 | owner ubah DMARC `expomedia.id` → `p=quarantine; pct=25` setelah demo; **ingatkan seminggu kemudian** untuk hapus `pct` | menunggu owner (pengingat: 7 hari setelah owner mengonfirmasi perubahan DNS) |
| K7–K10 | ADR 0009 tetap; client OIDC per tenant-env; role CP yang ada + label; domain/mailbox di gate Fase 2/4 | dimasukkan ke ADR 0017/0018/0009 |
| §13 | usulan 1–8 disetujui; #6 (mart bersama + RLS) diputuskan di plan Fase 3 | — |
| Q1 | Fase 1 tetap `<slug>.erp.bimacreative.tech` / `<slug>.staging.bimacreative.tech`; pola host = parameter inventory Fase 5 | — |
| Q2/Q3 | mail suspended = terima-saja (kirim mati); web suspended = tetap tayang | ADR 0018 D6 |
| Q4 | plan awal 7 kode, harga nullable | ADR 0018 D7 |
| Q5 | pengirim `noreply@bimacreative.tech`; penerima tenant-admin + billing internal; staging → Mailpit | ADR 0018 D8; mailbox `billing@bimacreative.tech` dibuat 2026-10-02 |
| Q6 | `ssotest_staging` hapus setelah Fase 1 lulus (dump dulu); `demo_staging` tenant uji; `demo_demo` dipertahankan | ADR 0018 D10 |
| K11 | upgrade Keycloak 26.7.4 → 26.7.5 sebelum Organizations di realm prod (menggantikan R1) — owner "y" 2026-10-03 | menunggu freeze dicabut (restart Keycloak di jendela perawatan) |
| Q11 | freeze berlaku sampai owner menulis "FREEZE DICABUT" | — |
| Lanjutan | owner: "lanjutkan sesuai rekomendasi" → `proyekkas-private` tidak di-push (restic saja); ADR 0017/0018 accepted (S1 tetap syarat) | selesai |
| Fase 1 | draft disetujui dengan syarat S1 → ADR 0017 sebelum W2#2, dan `users` prod kosong terjawab di W3 | W1 selesai (draft ADR) |

---

## 2026-10-02 — Fase 0 (inventaris, read-only)

**Berubah**
- Repo infra: `docs/plans/saas-inventory.md`, `docs/plans/saas-phase-1.md`, `docs/plans/saas-progress.md`
  (branch `docs/saas-phase0`, merge ke `main`). Tidak ada perubahan konfigurasi/host/container.
- Sebelumnya di sesi yang sama (bukan bagian brief): kebijakan izin Claude Code `.claude/hooks/bash-policy.sh` +
  `.claude/settings.json` (commit `56e22b2`, `a4cc439`; merge `a479e2c`, `0050678`).

**Diperiksa / hasil**
- Inventaris §3.1 butir 1–9 selesai; asumsi A1–A9 dijawab (`saas-inventory.md` §12): A2/A3/A1 sebagian, A5 & A8
  salah (Organizations sudah tersedia; dump per DB sudah ada), A4/A6/A7/A9 benar.
- OOM 2026-09-28: container ci-runner-job (build APK Flutter, limit 4 GiB), sudah diperbaiki `1673916` (5 GiB).
- `vm.swappiness` sudah 10.
- Ditemukan: restore-test restic gagal (stale lock), repo tanpa remote/backup, image prod drms tanpa tag, tabel
  `users` prod kosong (penyebab belum terverifikasi), ADR 0014 usang (4g).

**Belum (menunggu freeze dicabut / keputusan)**
- Pekerjaan rumah §3.2 yang menghapus/mengubah (K1–K6).
- Gate Fase 0 "disk < 50 %" belum terpenuhi (62 %); proyeksi setelah K4 ≈ 46–48 %.
- Rencana Fase 1 menunggu persetujuan + K7–K10 + Q1/Q4/Q5.

## 2026-10-02 (malam) — keputusan owner Fase 0 → Fase 1

**Berubah**
- Host (disetujui K1/K2): `restic unlock` repo lokal (1 lock basi PID 435014 dihapus; tanpa `--remove-all`);
  `restic-restore-test.service` dijalankan ulang; `ci-runner-supervisor.service` di-stop (container `ci-runner-job` idle ikut
  berhenti; `ci-runner-supervisor.path` tetap aktif — hanya memicu bila `/etc/ci-runner/pat` berubah; unit `enabled` → akan
  hidup lagi bila host reboot).
- Host (K3 persiapan): 5 deploy key ed25519 `~/.ssh/deploy_<repo>` + alias `github-<repo>` di `~/.ssh/config` (backup
  `config.bak-*`), remote `origin` ditambahkan di 5 repo `/opt/src`. Belum ada push (repo GitHub belum ada).
- Repo infra: fix hook `bash-policy.sh` (deteksi push paksa per segmen, 89 kasus; merge `94c2c7e`); branch
  `feat/backup-opt-src` (`9a3ce82`, **belum di-merge**): `restic_extra_paths: [/opt/src]` + exclude build/dependensi
  (±200 MB); ADR 0017, ADR 0018, amandemen ADR 0009; status plan Fase 1.

**Diuji / hasil**
- `restic check --read-data-subset=1/5`: **no errors** (masalah lock selesai). Filestore restore sha256 ok, RTO 60 s.
- `db_compare=failed` untuk `expomedia_prod`: snapshot 01:30 vs DB **live**; sejak 01:30 ada **5 modul baru** + 368 baris
  `ir_module_module` ter-update (deploy plan 19 ke prod hari ini) → perbedaan jumlah tabel/modul **diharapkan**, bukan
  kerusakan backup. Kelemahan desain uji: membandingkan dengan DB live. Usulan (setelah freeze): simpan statistik DB
  (`db_stats`) saat backup sebagai snapshot kecil dan bandingkan restore dengan statistik itu. Uji ulang otomatis berikutnya
  2026-11-01; bisa dijalankan manual setelah backup 01:30 berikutnya bila owner mau bukti hijau sebelum itu.
- gitleaks seluruh history 5 repo yang akan dipush: **no leaks found**.

**Belum**
- Push K3 (menunggu repo + deploy key dari owner).
- Spike S1, W0, W2–W8 (menunggu "FREEZE DICABUT").

## 2026-10-02 (larut) — billing@ + tindak lanjut rekomendasi

**Berubah**
- Mailserver (permintaan eksplisit owner, walau dalam freeze; tanpa restart — changedetector DMS): mailbox
  `billing@bimacreative.tech` kuota 2G lewat `mail/scripts/mailbox-add.sh` (password acak → `mail/secrets/…password`, 600 root,
  tidak dicetak). Verifikasi: `setup email list` memuat akun, `doveadm user` → home `/var/mail/bimacreative.tech/billing/home`.
- Repo infra: ADR 0017/0018 → accepted; ADR 0018 D8 alamat billing; `mail.md` daftar akun; hook `bash-policy.sh` pola
  baca-secret per segmen (false-deny `grep …; ls …/secrets/…`), 91 kasus.

**Belum**
- Password `billing@` perlu diserahkan ke owner lewat kanal aman (file secret di host; tidak dikirim lewat chat).
- K3 push menunggu repo GitHub dari owner; sisanya menunggu "FREEZE DICABUT".

## 2026-10-03 — Fase 1 dimulai (kode di branch, freeze tetap)

**Berubah**
- Kontrak Fase 1 `docs/plans/saas-phase-1-contract.md` (merge `3f67537`), urutan "Users dulu".
- Spike S1 terjawab dari dokumen + kode Keycloak 26.7.4 → ADR 0017 (D3 scope `organization` tidak default, D6 role
  `manage-organizations`, D7 sub-flow `Organization` DISABLED); uji live menyusul setelah freeze. K11 baru.
- Pengerjaan paralel di branch (belum merge/deploy): infra `feat/infra-saas-p1-dispatcher`, `feat/infra-saas-p1-scripts`,
  `feat/infra-saas-p1-odoo-user`; odoo-addons-shared `feat/sh-auth-oidc-tenant-check`; control-plane `feat/saas-p1-users`.

## 2026-10-03 — Fase 1 kode selesai di branch (menunggu QA + "FREEZE DICABUT")

**Berubah (branch, belum di-merge ke main / belum deploy)**
- infra `feat/infra-saas-p1` (integrasi `c2868eb`; gabungan `feat/infra-saas-p1-dispatcher` 3f75141,
  `feat/infra-saas-p1-scripts` 5f6f358, `feat/infra-saas-p1-odoo-user` 445ac51): dispatcher 1.1.0 (10 tipe baru, allowlist
  per instance), skrip `kc-org`/`kc-user`/`kc-realm-sync`/`tenant-state`/`odoo-user`/`odoo-tenant-config`, desired-state realm,
  middleware `tenant-suspended`, role Ansible `infra_jobs` (`job_types`), helper `odoo_user_ensure.py`, kontrak v1.1.
- control-plane `feat/saas-p1-users` (5c93ac7): migrasi 0004, kontrak TS 10 tipe, rantai job, rekonsiliasi `users`, halaman
  `/users`, izin `users:view|manage|manage_own`, `realm:sync`, tenant `platform`.
- odoo-addons-shared `feat/sh-auth-oidc-tenant-check` (5ba6ef9): `sh_auth_oidc` 19.0.1.3.0 `tenant_check`.
- Alasan belum merge infra ke `main`: checkout `/opt/infra` dipakai job prod — branch mengubah `keycloak-admin.sh`,
  `odoo_sso_kc.py`, template route, dan menambah file middleware Traefik (komponen freeze).

**Diuji (container sekali pakai, tanpa menyentuh layanan berjalan)**
- Dispatcher 372 OK; skrip kc 18 OK (mock) + uji end-to-end ke **Keycloak 26.7.4 dan Traefik v3.7.13 sekali pakai**
  (sync plan/apply/apply-kedua changed=0, flow `Organization` DISABLED, klaim `tenant_id` ada, `organization` tidak);
  `odoo_user_ensure` 62 ok (Odoo 19 + Postgres sekali pakai); `sh_auth_oidc` 151 tes 3 modul 0 gagal; control-plane lint/typecheck,
  486 unit + 20 integrasi (migrasi 0000–0004, rantai, lintas tenant), build OK.
- **Syarat owner #2 terjawab**: `users` prod kosong karena baris dihapus cleanup QA 2026-09-25 & 09-26 (dokumen
  `docs/qa/2026-09-25-plan05-prod-backfill.md:75`, `2026-09-26-plan06-prod.md:165`; `pg_stat` ins=2 del=2; FK `ON DELETE SET
  NULL`); sejak 09-26 tidak ada sign-in CP prod. Bukan bug kode. Perbaikan: baris `users` dibuat dari RESULT `kc_user_ensure`,
  tidak pernah di-DELETE (nonaktif = `status=disabled`); usulan FK `RESTRICT` di migrasi 0005.

**Belum**
- Review QA/security (berjalan).
- Deploy staging (W2–W5), uji live S1, gate — menunggu "FREEZE DICABUT". Urutan: kontrak v1.1 §4.
- Fase 1 sisa: W6 portal client, W7 subscription/invoice/tick, rekonsiliasi `tenant_suspend|resume`, UI `kc_realm_sync`.

## 2026-10-03 — QA/security Fase 1 + perbaikan

**Review QA** (read-only, 3 branch): staging GO bersyarat, prod NO-GO sampai F1 diperbaiki. Temuan: **F1 High** — tenant-admin
bisa "mengadopsi" user Keycloak lama tanpa `tenant_id` (termasuk superadmin) lalu mencabut role/menonaktifkan (dibuktikan uji
negatif); F2 Medium — aturan satu tenant-admin tidak atomik; F3–F5, F7 Low (secret di mode uji, strict dengan alias kosong, email
di log, auto-link admin lokal Odoo); F6 Low (ICP tenant_check bisa diubah admin tenant — risiko diterima); F8 Info.

**Perbaikan (semua di branch, belum merge/deploy)**
- infra `feat/infra-saas-p1` (`437d5a6`, `0fa2bad`, `cb1cfad`, `447c801`, `6355383`): kontrak **v1.2** — arg `adopt` pada
  `kc_user_ensure` (alert saat apply); skrip menolak user lama tanpa `tenant_id` kecuali `--adopt`, dan menolak mengubah user
  ber-role superadmin/ops (efektif/composite) dari slug tenant; mode uji wajib `KC_SECRETS_DIR` di `/tmp`; `strict` diblok bila
  alias org kosong; log email → `email#<hash8>`; auto-link admin lokal Odoo ditolak; dispatcher VERSION 1.2.0.
- control-plane `feat/saas-p1-users` (`aabbc45`, `2cc4a93`, `666d12b`): `adopt` hanya superadmin (enqueue + guard worker);
  aturan email (tanpa tenant / staf / tenant lain → tolak); `users:manage_own` dimatikan sampai portal W6; alur "Ikat ke
  tenant…" untuk baris lama (backfill F8); satu tenant-admin dengan advisory lock per tenant saat enqueue.

**Diuji**: uji QA pembukti F1 kini **gagal sesuai harapan** (exit 3) dan dijadikan regresi `T07Adopt`; dispatcher 379 OK;
skrip kc 25 OK; `odoo_user_ensure` 75 ok; control-plane 527 unit (227 kasus kontrak) + 28 integrasi (termasuk uji konkurensi F2:
tanpa lock gagal 3/3, dengan lock lulus 3/3); lint/typecheck/build OK.

**Belum**: endpoint Keycloak baru di perbaikan F1 (`/organizations/members/{id}/organizations`, role composite) diverifikasi dari
kode sumber 26.7.4, belum live (permintaan pengecualian hook untuk menyalin secret uji **ditolak** Lead) → konfirmasi saat deploy
W2 staging. Langkah pertama setelah `kc_realm_sync` pertama: adopsi staf ke tenant `platform` dari CP.

## 2026-10-03 — lanjutan Fase 1 (owner: "y lanjut")

- K11 disetujui (eksekusi setelah freeze). Freeze tetap berlaku (belum ada "FREEZE DICABUT"). K3: repo GitHub belum ada (cek
  `ls-remote` gagal akses) — push menunggu owner.
- Dikerjakan di branch control-plane (bercabang dari `feat/saas-p1-users`): `feat/saas-p1-billing` (migrasi 0005, langganan/
  invoice/plan, tick harian, email pengingat, halaman `/suspended`, rekonsiliasi status tenant) dan `feat/saas-p1-tenants`
  (onboarding tenant satu form, detail tenant + suspend/resume, halaman Audit, UI sync realm, pintasan adopsi staf).

## 2026-10-03 — Fase 1 kode LENGKAP (W3–W7) di branch, QA ronde 2 lulus; menunggu "FREEZE DICABUT"

**Branch final (belum merge ke main / belum deploy)**
- control-plane `feat/saas-p1` (worktree `/opt/src/wt/cp-p1`, HEAD `8c50916`) = Users + billing + tenants + portal + domain:
  migrasi 0004–0005, onboarding tenant satu form (rantai 14 langkah, opsional plan → subscription `implementation`),
  detail tenant + suspend/resume, Users + adopsi staf, subscriptions/invoices (Go-live, invoice `INV/YYYY/MM/NNNN`, tandai
  lunas, override harga), tick harian 00:15 WIB + email pengingat (staging → Mailpit), `/suspended`, portal client
  (`/portal`, `/portal/users`, `/portal/domains`; client_user tetap mendarat di `/dashboard`), domain + checklist DNS,
  `/audit`, `/realm`. Uji: 740 unit, 82 integrasi, lint/typecheck/build OK.
- infra `feat/infra-saas-p1` (worktree `/opt/infra-wt/p1-int`, HEAD `8db6578`): + compose CP staging (allowlist job,
  SMTP→Mailpit, `PLATFORM_PUBLIC_IPV4`) dan **runbook deploy staging** `docs/plans/saas-phase-1-deploy-staging.md`.
- odoo-addons-shared `feat/sh-auth-oidc-tenant-check` (`5ba6ef9`); infra `feat/backup-opt-src` (`9a3ce82`).

**QA ronde 2** (billing/onboarding/portal/domain/compose): staging GO, tanpa High; tidak ada IDOR/kebocoran lintas
tenant; F1–F8 tidak regresi. Diperbaiki: N1 retry apply sync realm melewati gerbang (Medium), N2 aksi billing tanpa cek
aktor nonaktif (Medium), N3 retry suspend/resume, N4 invoice/harga 0, N5 portal hanya akses Odoo `none|user`, N6 portal
cek role DB, N7 `blockers` wajib ada, N8 tick cek job lawan + lewati tenant terminated, N10; N9 → runbook (`users`
tidak pernah di-DELETE).

**Keputusan Lead (dicatat)**: urutan invoice global; jatuh tempo = akhir periode; email "tenant tanpa admin" hanya saat
daftar berubah; DNS wildcard `*.erp|staging.bimacreative.tech` sudah ada (smoke SSO onboarding aman); domain di bawah
`bimacreative.tech` ditolak sebagai domain tenant.

**Berikutnya** (setelah "FREEZE DICABUT"): jalankan runbook deploy staging §0–§6 → gate §7 → plan migrasi prod (M3–M10,
K11 upgrade Keycloak 26.7.5) → owner approval.

## 2026-10-03 — lanjutan tanpa freeze: rencana migrasi prod, draft Fase 2, perbaikan suspend, registrasi tenant lama

- **K3**: repo GitHub masih belum ada (cek `ls-remote` gagal) — menunggu owner.
- **Rencana migrasi prod** `docs/plans/saas-migration-prod.md` (M1–M12, draft; `506a9dd`). Fakta prod: CP prod hanya tenant
  `demo`; Expomedia (`expomedia_prod`, `erp.expomedia.id`) belum terdaftar di CP; user Odoo internal aktif expomedia 1 (sudah
  SSO), demo 1; realm `platform` 1 user. Migrasi data kecil; risiko di komponen bersama (Keycloak, pool-a, Traefik, dispatcher).
- **Draft Fase 2** `docs/plans/saas-phase-2.md` (`f11a14e`) + Q1–Q10 untuk owner. Temuan: Σ CONNECTION LIMIT role Postgres 196
  dari 197 slot non-superuser (pemakaian nyata 31) — bukan ancaman langsung, tetapi tidak ada ruang role baru (W0 Fase 2).
- **Perbaikan Fase 1** infra `9078ee2`: render ulang route (mis. job `odoo_route`) **mempertahankan status suspended** kecuali
  `--resume` eksplisit (sebelumnya membuka tenant ditangguhkan diam-diam); uji regresi `T05 test_3`.
- **Fitur CP** `020bc2f`: "Daftarkan tenant yang sudah ada" (untuk M8 Expomedia) — baris tenant/environment dari kondisi nyata,
  host kustom = route manual (job DB/route/SSO diblok sampai Fase 2), rantai `kc_org_ensure` + `odoo_tenant_config compat`.
  757 unit + 87 integrasi OK.

## 2026-10-03 — DITAHAN sampai demo expomedia selesai (owner)

Owner: demo ke client hari ini; pekerjaan dilanjutkan setelah demo. **Freeze tetap berlaku** sampai owner menulis
"FREEZE DICABUT". Estimasi waktu setelah freeze dicabut (disetujui owner sebagai estimasi, bukan pencabutan freeze):

| Tahap | Kerja aktif | Kalender | Dampak client |
|---|---|---|---|
| Deploy staging (runbook `saas-phase-1-deploy-staging.md` §0–§6) | ±4–5 jam | hari yang sama | nol |
| Gate Fase 1 (§7 butir 1–5, 7) | ±1 hari | hari ke-1–2 | nol |
| Observasi `tenant_check=compat` (§7 butir 6) | pasif | 7 hari | nol |
| Tertunda: start CI runner (K2), K4, K5, restic `/opt/src` | ±1–1,5 jam | hari ke-0/1 | nol |
| Migrasi prod M3–M9 (`saas-migration-prod.md`) | ±1 hari kerja, 2 jendela perawatan | — | Keycloak ±1–2 mnt, pool-a ±1 mnt, CP ±30 dtk |

Prod cut-over: ±1 minggu (gate dipercepat, observasi paralel) atau ±2,5 minggu (gate penuh). Ketergantungan owner: kalimat
"FREEZE DICABUT"; ±10 menit ×2 untuk bootstrap `kc-realm-sync` di console Keycloak (TOTP admin; staging lalu prod); pilihan
skenario gate; dua jendela perawatan prod + tanggal cut-over. Tetap terbuka: K3 (repo GitHub), K6 (DMARC), Q1–Q10 Fase 2.

## 2026-10-03 (sore) — FREEZE DICABUT; runbook staging §0, §1.1–1.2, §5 + K2/K4/K5

**Berubah**
- §0: backup manual `RESULT status=ok dbs_ok=13 remote=ok` (14:29); dump `control_plane_staging` + `keycloak` + salinan
  `traefik/dynamic/clients` di `/opt/infra/backups/saas-p1/20261003-143042/` (700/600 root).
- §1.1: merge `feat/infra-saas-p1` → `main` (`1b117d8`; sebelum `e2341c7`). §1.2: `provision-odoo-sso.sh expomedia staging
  --dry-run` exit 0 `blockers=0`; `changed=1` (redirectUris/rootUrl client `odoo-expomedia-staging`) = drift lama — skrip
  sebelum merge memberi rencana identik; tidak diterapkan. §1.3 `--check --diff`: `changed=2` (`infra-job` 1.2.0 +
  `staging.conf` `job_types`), `prod.conf` tidak berubah. **Apply belum** (izin ditolak) → dispatcher host masih versi lama;
  tipe job Fase 1 belum di-allowlist (CP staging akan ditolak fail-closed, bukan dieksekusi).
- §5: image `control-plane:020bc2f` (commit `feat/saas-p1`, berisi `main` 3d4aa7c); pin compose staging (`28df9e3`); migrasi
  0004–0005 + seed tenant `platform` + 7 plan; web/worker/mailpit healthy; `/api/health` 200. Prod CP tetap `3d4aa7c`.
- K2: `ci-runner-supervisor` ternyata sudah aktif sejak 06:40 WIB (start manual, pemicu tidak tercatat; bukan sesi ini).
- K5: tag `42682f7f2d09` → `ghcr.io/bctech-adm/proyekkas-web:0.4.1`, dan `139ab67a1e2f` → `proyekkas-migrate:0.4.1`
  (label versi 0.4.1, revisi `7141e4c` = container `drms-pk-migrate`). `:0.3.0` tetap ada (tidak dihapus).
- K4: `docker rmi` 22 tag / 20 image §11.1 tanpa `-f` (mailpit dikecualikan), `builder prune --filter until=72h` 2,28 GB.
  `/` 64 % → **59 %**. `zricethezav/gitleaks` ternyata dipakai pre-commit hook infra → ditarik ulang otomatis (digest pin).
  `volume prune` **diblok hook**: 34 volume anonim (32 PGDATA container Postgres uji 09-27…10-03 + 2 kosong, ±4,6 GB).

**Belum**: §1.3 apply, §2 (addons-shared + restart odoo-staging), §3 (KC, butuh owner), §4 (Traefik HUP), §6–§7; restic
`/opt/src` (`feat/backup-opt-src` merge bersih, apply via role `backup`).
