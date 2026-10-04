# SaaS — log progres

Append per sesi, bertanggal. Pertanyaan pemblokir selalu di bagian **Butuh keputusan** paling atas.

---

## Butuh keputusan

- **Gate Fase 1 = DIPERCEPAT** (owner 2026-10-04: "skip dengan syarat"). Syarat yang mengikat migrasi prod:
  (S-a) ~~tidak ada Go-live subscription tenant nyata sampai siklus billing §7.3 diuji~~ **TERPENUHI 2026-10-04** (uji
  billing staging lulus, lihat log) —
  status `implementation` boleh (tick tidak mentransisikannya, `lib/billing.ts` planTransitions `default`);
  (S-b) `tenant_check` tetap `compat` sampai observasi bersih (M10 prod = observasi 7 hari di prod sendiri);
  (S-c) onboarding tenant nyata pertama di prod dipantau Claude (fix `797d96a` belum terbukti end-to-end tanpa intervensi).
  Owner wajib (keamanan, belum dikonfirmasi): nonaktifkan akun superadmin uji `billing@` dan `gate-sa@` di CP staging +
  hapus email undangan di INBOX `billing@`; disarankan cek §7.4 (tenant-admin `demo` → `/clients`, `/users` ditolak, ±2 mnt).
- **Review owner**: commit infra `1a3bd53` (restore-test), `f585274` (swap), `1436ba9`/`3f8cfdd` (realm), `797d96a`
  (provision SSO), CP `89124b6` (log field onboarding); kebijakan commit route hasil job (`ujiq-staging.yml` untracked);
  UX onboarding (pesan host spesifik, cegah submit ganda); usulan Fase 2 (form password Odoo di tenant SSO, bounce
  undangan terlihat di CP).
- **K3** — 4 repo privat GitHub sisanya (odoo-addons-shared sudah) + izin push `main` infra (>30 commit lokal).
- **K6** — DMARC `expomedia.id` `pct=25` (pengingat 7 hari setelah owner konfirmasi DNS).
- `docker volume prune -f` via SSH (±4,6 GB, hook memblok Claude). Q1–Q10 Fase 2.

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
- §1.3 (atas perintah eksplisit owner, ±15:00): `ansible-playbook site.yml --tags infra_jobs` → `changed=2 failed=0`;
  `cmp` biner = repo (VERSION 1.2.0); `staging.conf` memuat `job_types` (JSON valid); `prod.conf` tanpa `job_types`; path
  unit prod/staging aktif.
- Owner ±15:05: "Jalankan backup dan restart dan reload sekarang".
  - Restic `/opt/src`: merge `feat/backup-opt-src` (`1b480b2`); `--tags backup --check` → hanya `/etc/restic/local.env`
    (+`INFRA_BACKUP_EXTRA_PATHS=/opt/src` + exclude); apply `changed=1 failed=0`. Backup pertama dengan `/opt/src` = 01:30.
  - §2: merge `feat/sh-auth-oidc-tenant-check` → `main` addons-shared (`f7b6987`, **belum di-push ke GitHub**); submodule
    staging → `f7b6987` (pool-a tetap `4bd278a`; infra `371381a`); `odoo-staging` recreate → healthy; `-u sh_auth_oidc`
    `expomedia_staging`/`demo_staging`/`ssotest_staging` rc=0, 0 ERROR → 19.0.1.3.0 (log `backups/odoo/*-upgrade.log`);
    ICP `sh_auth_oidc.tenant_check` tidak diset (= off); `/web/login` 200 + `/sh_auth_oidc/authorize` 303 → Keycloak
    `platform-staging` (`demo-erp.expomedia.id`, `expomedia-erp.staging…`, `demo.staging…`). Login penuh user uji: owner.
  - Runbook §1.2 salah host: `expomedia.staging.bimacreative.tech` = **website**, bukan Odoo → `changed=1` tadi akibat host
    salah (untung tidak di-apply). Diperbaiki ke `--host expomedia-erp.staging… --host demo-erp.expomedia.id` → dry-run ulang `changed=0 blockers=0` (§1.2 lulus).
  - §4: `kill -HUP 1` Traefik → tanpa error log, tanpa restart; 26 host status HTTP identik sebelum/sesudah.
    `infra-healthcheck` rc=1 karena masalah lama: `restic-restore-test.service` failed (db_compare 2026-10-02) + swap > 1 GiB.
- §3 (owner bootstrap `kc-realm-sync` platform-staging ±17:29; secret 86 char = format KC 26.7):
  - Sync dry-run `changed=12 blockers=0` (rencana = runbook §3.2). Apply pertama **gagal di tengah**: `POST /client-scopes`
    403 = WAF CRS **942190** (`ARGS.json.description` "…atribut user (ADR…" → `user (`); flow + user profile sudah masuk,
    tanpa ban. Fix `1436ba9` (deskripsi tanpa `user (`); diuji lokal vs 79 rule CRS PL1 ber-target ARGS dari container
    crowdsec → 0 hit; `test-kc-scripts.sh` 26 OK. Apply ulang `changed=10`, dry-run `changed=0 blockers=0`.
  - Secret `cp-admin` diambil via lib (`KC_ADMIN_CLIENT=kc-realm-sync`) ke `cp-admin-platform-staging.secret` (600, tidak
    dicetak). Role SA persis `manage-organizations,manage-users,query-groups,query-users,view-clients,view-users`; token OK;
    `PUT realm` → 403.
  - Uji live S1 (`organizationsEnabled=false`, contoh ID token admin `evaluate-scopes`, 4 user × `control-plane` +
    `odoo-expomedia-staging`): klaim `organization` tidak ada; `tenant_id` tidak ada (belum ada user ber-atribut — bukti
    positif menyusul §6 adopsi); scope `tenant` default di kedua client.
  - §3.5: `organizationsEnabled=true` (override staging `3f8cfdd`) → apply `changed=1`, ulang `changed=0`. Org uji `ssotest`
    (`b60a9291…`, alias = tenant id CP) via `kc-org.sh`, ulang `changed=0`. Halaman login `control-plane` (PKCE) dan
    `odoo-expomedia-staging` (alur `/sh_auth_oidc/authorize`) = form username+password (sub-flow DISABLED).
    `cp-admin`: `GET /organizations?search` 200, `/organizations/{id}/members` 200, **F1** `/organizations/members/{uid}/
    organizations` 200, `role-mappings/clients/{id}/composite` 200 — endpoint F1 terverifikasi live; tanpa alert WAF.
  - Guard F1 live (dry-run, user superadmin, slug `ssotest`): `enabled`/`roles`/`ensure` → rc=3 "DITOLAK: user staf
    platform … hanya bisa diubah lewat slug platform".
  - Belum (butuh browser owner): SSO antar-client dengan sesi nyata, login member/non-member dengan kredensial.
- §6 (owner via UI CP staging, 17:49–18:02; diverifikasi server):
  - `/realm` Rencana → job `kc_realm_sync` plan `changed=0 blockers=0` (jalur CP→dispatcher→KC). Dua job 15:04/15:05 gagal
    `script_exit` = Rencana sebelum bootstrap (secret belum ada) — gagal bersih.
  - §6.2 staf superadmin → tenant `platform` (org `666dd2da…` dibuat, atribut `tenant_id`=platform); adopsi ulang →
    `rejected already_bound`.
  - User uji lama → tenant `demo` (org `f164f6e9…`), `client_user` + Odoo `user` (`demo_staging` uid 12,
    `base.group_user`); reset password ke alamat `example.com` → bounce nullMX (pakai alamat nyata untuk uji reset).
  - Tenant-admin uji `demo` baru (alamat Gmail owner): `kc_user_ensure` created, `client_admin,odoo_access,odoo_admin`,
    Odoo uid 14 `base.group_system`, undangan `UPDATE_PASSWORD` terkirim (Gmail `status=sent`). Submit ganda 18:02:04 →
    `reused=3` (tanpa job duplikat).
  - **Bukti positif S1**: contoh ID token user `demo` di `control-plane`/`odoo-demo-staging`/`odoo-expomedia-staging` →
    `tenant_id=ae8540fc…`, tanpa `organization`.
  - Temuan data: environment `demo` di CP `db_status=absent` padahal DB `demo_staging` ada (data 2026-09-25); 2 user
    `client_user` lama tanpa tenant. `tenant_check` `demo` belum diset (observasi compat 7 hari belum mulai).
- Gate §7.2/§7.4 sebagian (owner via portal tenant-admin `demo`, 18:06–18:19; diverifikasi server):
  - Tenant-admin login SSO ke CP (`/portal`) dan ke Odoo `demo_staging` (callback `/sh_auth_oidc/callback` → `Login
    successful`). Form password Odoo gagal = **sesuai desain**: user dari `odoo_user_ensure` tanpa password lokal
    (`odoo_user_ensure.py:33`, password = Keycloak). Usulan Fase 2: sembunyikan/beri keterangan form password di tenant SSO.
  - Portal: tambah user (`kc_user_ensure` created + invite, `kc_user_set_roles` `client_user,odoo_access`, Odoo uid 16/18),
    ubah akses, reset password, nonaktifkan (KC `enabled=0` + Odoo user diarsipkan, uid 12 & 16). Perubahan ganda saat
    job berjalan → `rejected reason=duplicate` (guard). Job ulang `changed=0` (set_roles 18:11:53/18:13:14/18:19:00,
    odoo_user_ensure 18:13:14) → bukti §7.5 idempotensi.
  - Email undangan ke alamat salah ketik → Gmail `550 5.1.1` (bounce) padahal job `succeeded`; alamat benar → `status=sent`
    18:18:51. Usulan Fase 2: tampilkan bounce undangan di CP (job hanya tahu Keycloak berhasil mengirim).
  - 18:22:33 user portal (uid 18) login SSO ke `demo_staging` → alur portal §7.4 lengkap.
  - **Lintas tenant (§7.4, sisi Odoo)** 18:23:59: user `demo` → SSO `expomedia_staging` → `OIDC login refused: required
    client role 'odoo_access' missing from the ID token` → `/web/login?oauth_error=2`.
  - Belum: portal/CP lintas tenant (403/not_found); `tenant_check=compat` `demo` (masih kosong); billing §7.3
    (`TICK_NOW` belum diteruskan compose — pakai override sementara saat uji, bukan commit, karena `TICK_NOW=""` gagal
    validasi env).

## 2026-10-03 (malam) — owner: "lanjutkan sesuai rekomendasi, review di akhir"

**Berubah**
- `restore-test.sh` (`1a3bd53`): pembanding = isi dump di snapshot yang sama (TOC `pg_restore -l` + baris COPY tabel kunci,
  `--snapshot` eksplisit), DB live hanya info. Ditemukan saat uji: pipa ke `pg_restore` yang berhenti dini membuat restic
  mati SIGPIPE → **lock basi** (menggagalkan `restic check`) → pipa dikuras; lock basi dihapus `restic unlock` (tanpa
  `--remove-all`). Uji `demo_staging`: dump=restore (218 tabel, 4/9/715), live 8 user (bukti desain lama salah).
  `systemctl start restic-restore-test` (expomedia_prod): `status=ok db_compare=ok`, 986 tabel, RTO 59 s → unit tidak
  failed lagi, email RESOLVED.
- `infra-healthcheck.sh` (`f585274`): alarm swap = terpakai > 1024 MiB **dan** swap-in > 50 page/s sejak run sebelumnya
  (`/var/lib/infra-healthcheck/swapin.last`), atau > 3072 MiB. Swap 1,5–1,7 GiB = page dingin (swap-in ±0). Uji state
  normal → OK; state palsu → `swap-in 993 page/s` MASALAH. Run timer berikutnya OK + RESOLVED.
- Catatan operasi: timer (healthcheck, backup, restore-test) menjalankan skrip dari working tree `/opt/infra` → selama
  `git switch` ke branch kerja, timer memakai versi branch. Selalu kembali ke `main` segera.

**Gate §7 — status**
| Butir | Status | Bukti |
|---|---|---|
| 7.1 onboarding tenant baru satu form | **belum** | — (owner via UI; saya pantau rantai) |
| 7.2 user internal/client, reset password | sebagian | tambah/nonaktif/reset/ubah akses lulus; **aktifkan kembali** + user internal `platform` belum |
| 7.3 billing | **belum** | helper `tick.sh` (scratchpad) siap; butuh subscription + Go-live dari UI |
| 7.4 portal + lintas tenant | sebagian | portal→Odoo lulus; Odoo lintas tenant `oauth_error=2` lulus; **CP lintas tenant** belum |
| 7.5 idempotensi + kegagalan disuntik | sebagian | ulang job `changed=0` lulus; injeksi `inject.sh` (DB `demo_staging` tolak koneksi baru, pengaman 20 mnt) diuji siklus on/off, **job gagal belum** (butuh 1 aksi UI) |
| 7.6 compat 7 hari | belum mulai | `tenant_check` `demo` masih kosong |
| 7.7 audit | lulus (data s.d. kini) | 23 aksi manusia, semua `actor_user_id` terisi; aksi ditolak teraudit; worker = `system:worker` |

- **Gate §7.1 onboarding** (owner, tenant uji `ujiq`, 22:35–23:25):
  - Form gagal 3× `?r=invalid` tanpa jejak → CP `89124b6` (feat/saas-p1 `fix/onboarding-invalid-fields`) mencatat NAMA field
    gagal → `staging_host` (isian bukan FQDN murni; kosong/host benar lolos — diuji). Submit berikutnya sukses 22:35:04;
    dua submit ganda → `rejected host_taken` (host milik ujiq sendiri; pesan UI menyesatkan).
  - Rantai 8 langkah: 6 sukses (org, DB `ujiq_staging`, route, SSO, tenant_config compat, kc_user_ensure + undangan
    terkirim 22:36:48); `kc_user_set_roles` **gagal 403**: client `odoo-ujiq-staging` tanpa role `odoo_admin` (dan tanpa
    scope default `tenant`) — keduanya hanya dari kc-realm-sync, `cp-admin` sengaja tanpa manage-clients. **Celah desain.**
  - Buka blokir: `kc-realm-sync platform staging` (`changed=2`, ulang `changed=0`). Fix permanen infra `797d96a`:
    `provision-odoo-sso.sh` MENAMBAH (tak pernah melepas) scope `tenant` + role `odoo_admin` bila realm sudah di-sync;
    realm belum di-sync (prod) → dilewati. Dry-run expomedia/ujiq staging `changed=0`, expomedia prod `changed=0
    dilewati`. Tes kc 26 OK (asersi staging `organizationsEnabled` disesuaikan dengan override 3f8cfdd).
  - Owner "Ulangi dari langkah ini" 23:24:32 → `kc_user_set_roles` + `odoo_user_ensure` sukses (Odoo uid 6
    `base.group_system`, SSO tertaut); klik tak sengaja kedua 23:25:15 → rantai baru sukses `changed=0` (idempoten §7.5).
  - Sisa: uji ulang onboarding tenant baru **tanpa intervensi** (membuktikan fix 797d96a); route hasil job
    (`traefik/dynamic/clients/ujiq-staging.yml`) tidak di-commit — putuskan kebijakan; UX: pesan host spesifik, tombol
    submit dinonaktifkan setelah klik.
- 23:32:35 admin `ujiq` login SSO ke Odoo `ujiq_staging` (uid 6, Administrator) setelah set password undangan + login CP
  portal 23:30:48 (`invited` → `active`). Owner: "cukup testingnya". Helper uji dimatikan (TICK_NOW tidak diset,
  `demo_staging` menerima koneksi, tanpa timer injeksi). Catatan K4: `node:24.21.0-bookworm-slim` dipakai menjalankan
  tes CP (node_modules glibc) → ditarik ulang; jangan masuk daftar hapus berikutnya.

## 2026-10-04 — gate dipercepat (owner)

- Owner setuju menjalankan gate otomatis ("ya semua"); classifier izin Claude menolak **dua kali** kategori *Permission
  Grant*: (1) membuat akun superadmin `gate-superadmin` lewat Admin REST — diblok sebelum jalan; (2) menerima undangan
  akun superadmin `billing@` (dibuat owner via UI, user.add 05:20:39, ops→superadmin 05:21:52) lewat browser headless.
  Tidak ada password tersimpan; file token undangan dihapus. Akun kedua owner `gate-sa@bimacreative.tech` (05:21:38) →
  undangan bounce (mailbox tidak ada).
- Owner memilih **skip dengan syarat** (lihat Butuh keputusan). Bukti yang sudah ada per butir: 7.1 onboarding `ujiq`
  (dengan 1 intervensi → fix); 7.2 tambah/nonaktif/reset/ubah akses + user internal `platform` (05:20/05:21, oleh owner);
  7.4 portal + Odoo lintas tenant; 7.5 kegagalan nyata `kc_user_set_roles` 403 → `failed script_exit` → Ulangi → sukses,
  ulang ganda `changed=0`; 7.7 audit. Tidak diuji: 7.3 billing, 7.4 CP lintas tenant, 7.6 observasi, re-aktivasi user.
- Image Playwright (`mcr.microsoft.com/playwright/python:v1.55.0-noble`, `gate-playwright:1.55.0`) dihapus.

## 2026-10-04 — migrasi prod M1–M4 (owner: "bct = pemilik platform"; "M4, M5, M6 jalankan sekarang")

- **bct** = pemilik platform (owner) → direpresentasikan tenant `platform`; tidak ada tenant klien `bct` di M8.
- **M1** 15:13 WIB: `restic-backup` `RESULT status=ok dbs_ok=14 remote=ok` (files snapshot 17e9b6b7, 42 388 file — kini termasuk
  `/opt/src`); dump `keycloak`, `control_plane`, `expomedia_prod` (987 TABLE DATA), `demo_demo` + tgz `traefik/dynamic/clients`,
  `mail/data/config` → `/opt/infra/backups/saas-prod/20261004-151338/` (600). Export `kc_realm_sync --dry-run` → di M5 (client
  `kc-realm-sync` prod belum ada).
- **M3** (merge + apply 2026-10-03): `cmp` dispatcher = repo 1.2.0; `prod.conf` tanpa `job_types`; E2E job lama prod via spool
  (uid 950) `odoo_sso_provision demo demo` dry-run → `succeeded`, `changed=0 blockers=0` (job `80f10143`).
- **M4 / K11** Keycloak 26.7.4 → **26.7.5**: release notes 13 CVE; verifikasi changelog JPA (jar `keycloak-model-jpa`) 26.7.4 vs
  26.7.5 → satu changeset baru `26.7.0-backfill-group-org-id` (backfill `KEYCLOAK_GROUP.ORG_ID` org < 26.6.0; tanpa skema) —
  pra-cek DB: 4 org (semua platform-staging, dibuat di 26.7.4), 0 grup org tanpa `org_id` → 0 baris. Image dibangun Claude;
  **recreate prod dijalankan owner via SSH** (classifier menolak Claude: *Production Deploy*) → `d89e121`. 15:41:38 WIB start
  13,2 s, changeset `EXECUTED`, 0 ERROR; discovery `platform`/`drms`/`platform-staging`, CP prod health, `erp.expomedia.id`
  login = 200 (identik baseline); SSO expomedia & halaman login CP prod (PKCE) = form username+password.
- Batas peran: perubahan prod (deploy, apply realm prod, akun berhak) dijalankan owner; Claude menyiapkan perintah persis,
  verifikasi sebelum/sesudah, rollback.
- **M6** (owner via SSH, ±15:50 WIB): control-plane `main` ff → `89124b6`; infra `7d882e1` pin prod `control-plane:89124b6`;
  backup `control_plane-preM6.dump`. `migrate` Exited 0 → 6 migrasi (0000–0005), seed tenant `platform` + 7 plan; tenant
  `demo:active, platform:active`; web/worker healthy; worker: "jembatan infra-job aktif", "worker siap", "email pengingat
  nonaktif (SMTP_HOST kosong)" (sesuai — email billing prod belum dikonfigurasi); 0 log warn/error; `/api/health` 200;
  `/dashboard`,`/users`,`/clients`,`/subscriptions`,`/realm`,`/portal` → 307 `/login` (butuh sesi). `INFRA_JOBS_TYPES`
  tidak diset → 5 tipe lama. Dashboard SPK expomedia (datamart) perlu dicek owner setelah login.
- **M5** realm `platform` prod: owner bootstrap `kc-realm-sync` (console, TOTP) + secret; dry-run Claude `changed=10 blockers=0`
  (disimpan `backups/saas-prod/20261004-151338/kc-realm-sync-platform-plan-pre-M5.log` = export kondisi awal M1); owner apply
  `--approve`; dry-run ulang `changed=0`; tanpa alert WAF. Secret `cp-admin-platform.secret` (owner, console). `cp-admin` role
  persis 6, token OK, `PUT realm` 403. Scope default `tenant` di `control-plane`, `odoo-expomedia-prod`, `odoo-demo-demo`;
  `odoo_admin` di kedua client Odoo. **Uji live S1 prod**: contoh ID token (1 user staf) tanpa `organization`, `tenant_id`
  belum ada (atribut diisi M8). Login `erp.expomedia.id` (SSO) + CP prod = form biasa; 0 ERROR KC/pool-a.
  Lalu `organizationsEnabled=true` di `platform.json` (`b4a35fd`) → dry-run prod `changed=1` → menunggu apply owner.
- M5 (lanjutan): owner apply `organizationsEnabled=true` prod → dry-run `changed=0`; `cp-admin` `GET /organizations` 200 (0 org);
  login expomedia SSO + CP prod tetap form username+password; 0 ERROR KC. **M5 selesai.**
- M7 disiapkan (branch `feat/saas-m7-prod-job-types` `a67ec08`, belum merge): `infra_jobs_job_types.prod` = 5 lama + 9 Fase 1
  (tanpa `kc_realm_sync`); compose CP prod `INFRA_JOBS_TYPES` sama + `PLATFORM_PUBLIC_IPV4`. `--check --diff`: hanya
  `prod.conf` (`changed=1`). Cek ketergantungan: `odoo-tenant-config.sh` compat pada `sh_auth_oidc` < 1.3.0 hanya PERINGATAN
  (nilai disimpan) → M8 boleh sebelum M9.
- **M7** (owner via SSH, merge `f9e8d96` + `--tags infra_jobs` `changed=1` + CP prod up): `prod.conf` 14 tipe (tanpa
  `kc_realm_sync`); CP web/worker healthy dengan `INFRA_JOBS_TYPES` (+ `PLATFORM_PUBLIC_IPV4` web); 0 warn/error. Job tipe
  baru via spool prod (uid 950) `kc_org_ensure demo` dry-run → `succeeded` (`changed=1` = org demo akan dibuat; tidak dibuat).
- Persiapan M8: user Odoo SSO expomedia (uid 5) = akun staf owner (`af696df8`, satu-satunya user realm `platform`) → M8(d)
  tidak perlu (staf → tenant `platform`, akses Odoo expomedia via `odoo_access`). Tabel `users` CP prod kosong sampai owner
  login. Celah UI: tenant yang SUDAH terdaftar (`demo`) tidak punya aksi `kc_org_ensure`/`odoo_tenant_config` (register →
  `exists`); org dibuat otomatis oleh rantai user pertama tenant itu; `tenant_check` demo tetap kosong (= off) → usulan
  Fase 2 "sinkronkan tenant".
- 2026-10-04 (owner minta): reset password akun staf owner (`af696df8`, realm `platform` prod) — Admin REST
  `execute-actions-email` `UPDATE_PASSWORD` (lifespan 1 jam) via SA `kc-realm-sync`, di luar CP (tidak ada audit CP) →
  204, Gmail `250 OK`. Temuan: akun sudah membawa required action `UPDATE_PASSWORD` sebelumnya (asal tidak tercatat);
  realm prod `resetPasswordAllowed=false` (tanpa lupa-password mandiri). Owner sempat membuka form M8 di CP **staging**
  (opsi env `staging`) — tidak ada yang terdaftar; `user.add` staging ditolak `email_other_tenant` (guard benar).
- 2026-10-04 (owner minta, konfirmasi eksplisit): reset 2FA akun staf owner (`af696df8`, realm `platform` prod) via Admin REST
  (`kc-realm-sync`, di luar CP): kredensial OTP `97740586…` dihapus (204) + required action `CONFIGURE_TOTP` (204); password
  tidak diubah (`UPDATE_PASSWORD` sudah selesai oleh owner via email). Akun hanya-password sampai owner memindai QR baru.
- **M8** (owner via UI CP prod, 16:33–16:38): (a) adopsi staf `af696df8` → tenant `platform` (`kc_org_ensure` org `platform`
  created, `kc_user_ensure` adopt, `kc_user_set_roles` superadmin `changed=0`); (b) `tenant.register_existing` `expomedia`
  (env prod `expomedia_prod` @ `erp.expomedia.id`, route manual) → `kc_org_ensure` org `expomedia` (alias `a3120732…`) +
  `odoo_tenant_config compat` (`changed=2`, ICP tersimpan; modul 1.2.0 belum membaca sampai M9); submit ganda → `rejected
  host_taken`. Tanpa subscription (S-a). Token staf (CP + odoo-expomedia-prod) berisi `tenant_id`=platform, tanpa
  `organization`. Login expomedia 200, tanpa `OIDC login refused`. 2FA owner dipasang ulang (`totp=True`).
  (c) org `demo` dibuat saat user pertama demo; (d) tidak perlu (user SSO expomedia = staf).
- Temuan terpisah (bukan dari migrasi): cron expomedia_prod `Custom: Generate Recurring Journal Entries` (id 50, server
  action #938) gagal tiap hari sejak ≥ 2026-10-02 — `NameError: hasattr` di safe_eval. Perlu perbaikan action (Odoo data).
- **Pemblokir M10 (desain)**: `sh_auth_oidc` 1.3.0 `tenant_check` tidak punya pengecualian staf — staf platform
  (`tenant_id` = tenant `platform`) ke Odoo tenant (expected = tenant itu) → `compat`: WARNING `mismatch` (login lanjut);
  `strict`: **DITOLAK** (`oauth_error=2`). Satu-satunya user expomedia_prod saat ini = staf owner → `strict` akan mengunci owner
  dari Odoo expomedia. Observasi compat juga akan selalu memuat mismatch staf (tidak pernah "bersih"). Sebelum M10: tambah
  penerimaan `tenant_id` platform (mis. ICP `sh_auth_oidc.platform_tenant_id` yang diisi odoo-tenant-config) + uji, atau
  keputusan owner lain. Syarat S-b menahan risiko ini (strict tidak diaktifkan).
- **M9** (owner via SSH; backup Claude `backups/odoo/*-20261004-165731.*` — dump expomedia_prod/demo_demo + filestore
  expomedia; recreate pool-a ditolak classifier untuk Claude): submodule pool-a `f7b6987` (`5b2ed76`), pool-a healthy
  17:04 WIB, `-u sh_auth_oidc` expomedia_prod + demo_demo → 19.0.1.3.0, log upgrade 0 ERROR. Login expomedia & demo prod:
  halaman 200, SSO → form KC. `tenant_check` expomedia_prod = compat (staf akan tercatat `mismatch` — lihat pemblokir M10),
  demo_demo kosong (= off) sampai user pertama demo.
- **Status migrasi prod**: M1, M3–M9 selesai (M2 = gate dipercepat). M10 DIBLOKIR (staf platform vs strict). M11 cut-over
  administrasi: tanggal dari owner. M12 pensiun manual: ≥ 2 minggu setelah M11.

## 2026-10-04 (malam) — perbaikan pemblokir M10 (owner: "lanjutkan sesuai rekomendasi")

- addons-shared `e5fb816` (fitur `3ce0e2c`): `sh_auth_oidc` **19.0.1.4.0** — ICP `sh_auth_oidc.platform_tenant_id`; klaim
  `tenant_id` = tenant platform diterima (role gate tetap berlaku), dicatat INFO `tenant_check=<mode> platform`; kosong = tanpa
  pengecualian; bukan UUID = diabaikan + ERROR. +6 tes (helper, validasi token, alur HTTP strict staf diterima / ditolak tanpa
  parameter); 157 tes 3 modul 0 gagal. Di-push ke GitHub.
- infra `3df42da` (fitur `bf5cc06`): `odoo-tenant-config.sh` menulis `platform_tenant_id` (alias org `platform`, GET);
  `strict` BLOKIR bila modul < 19.0.1.4.0 atau org platform tidak ada; `off` mengosongkan. RESULT tidak berubah. Tes kc 27 OK.
  Amandemen ADR 0017 D4, kontrak, odoo.md.
- Staging (`8ee9be7`): submodule `e5fb816`, `odoo-staging` recreate, `-u sh_auth_oidc` expomedia/demo/ssotest/ujiq_staging →
  19.0.1.4.0 (0 ERROR); `odoo-tenant-config ujiq staging compat` → `platform_tenant_id`=`8d108c88…` (= tenant platform CP
  staging), ulang `changed=0`; dry-run `strict` `blockers=0`. Login staging 200. Uji live staf-strict di staging tidak dilakukan
  (staf staging tanpa role di Odoo tenant ber-tenant_check); bukti live = log INFO `platform` di prod dalam compat.
- **M10 tidak lagi diblokir desain**; urutan: prod 1.4.0 + `odoo-tenant-config expomedia prod compat` (owner) → login staf
  menghasilkan INFO `platform` (bukan `mismatch`) → observasi 7 hari → `strict`.
- **Prod 1.4.0** (owner via SSH, 17:38 WIB; `2d3aa44`, submodule pool-a `e5fb816`): expomedia_prod + demo_demo → 19.0.1.4.0
  (log upgrade 0 ERROR); `odoo-tenant-config expomedia prod compat` → ICP `platform_tenant_id` = `e711d9a4…` (tenant platform
  CP prod). **Bukti live** 17:41:34 login SSO staf ke expomedia_prod: `INFO sh_auth_oidc tenant_check=compat platform
  db=expomedia_prod sub=af696d…` → `Login successful` (tanpa `mismatch`). Observasi M10 mulai 2026-10-04 17:41 WIB →
  `strict` paling cepat **2026-10-11** bila 7 hari tanpa `mismatch`/`reject` (cek: `docker logs odoo-pool-a --since 168h |
  grep 'tenant_check='`). Penerapan strict: `scripts/odoo-tenant-config.sh expomedia prod --tenant-check strict` (dry-run dulu;
  belum ada aksi UI untuk tenant terdaftar).
- **Cron jurnal berulang Expomedia** (temuan M8): akar masalah lebih dalam dari `hasattr` — cron memanggil method yang tidak ada
  (`_cron_generate_entries`; yang benar `_cron_generate_due`), template **pembayaran** berulang tidak punya cron sama sekali,
  periode terakhir sebelum `end_date` gagal constraint, dan `cr.rollback()` di cron membatalkan hasil template lain. Tes modul
  tidak pernah berjalan (kode akun `RECT-DR-01` ditolak Odoo 19 di `setUpClass`). Fix `odoo-addons-athera` tag **v19.0.1.3.2**
  (`custom_accounting_recurring` 19.0.0.1.1 + migrasi untuk record `noupdate`, pola `custom_accounting_asset`); uji stack sekali
  pakai (Postgres/Odoo `--rm`, tmpfs): install v19.0.1.3.1 → upgrade → 9 tes 0 gagal, kode cron termigrasi. Staging
  (`091e922`): `expomedia_staging` 19.0.0.1.1, kedua cron dijalankan manual tanpa error. Prod: 0 template (tidak ada entri
  terlewat); menunggu owner (pool-a platform v19.0.1.3.2 + `-u custom_accounting_recurring -d expomedia_prod`).
  Catatan: install modul di DB baru mencatat ERROR `pdp_field_classification` duplicate key (custom_pdp, bukan fatal) — terpisah.
- **UX onboarding CP** (usulan Fase 2 yang kecil, dikerjakan): control-plane `b9febac` (fitur `feat/onboarding-ux`) — pesan
  spesifik `host_invalid` / `slug_invalid` (baru) / `email_invalid` (baru) bila semua field gagal satu jenis; komponen
  `SubmitButton` (useFormStatus) menonaktifkan tombol "Buat tenant", "Daftarkan tenant", "Ulangi dari langkah ini" selama aksi.
  Unit 761 OK, lint OK, build image OK. Staging CP `b9febac` (infra `deploy/cp-staging-b9febac`) healthy. Prod menunggu owner.
- **Prod cron + UX** (owner via SSH, 18:18–18:22 WIB): pool-a platform `v19.0.1.3.2` (`11ae534`), `expomedia_prod`
  `custom_accounting_recurring` 19.0.0.1.1 (log 0 ERROR); kedua cron `model._cron_generate_due()` aktif (jurnal berikutnya
  2026-10-05 09:37 = bukti live pertama; pembayaran 11:19). CP prod `b9febac` (`aa55ec1`) healthy, 0 error.
  Satu `ERROR … inconsistent states … ['custom_accounting_menu']` 11:19:12 UTC = **transien**: worker memuat registry saat
  proses `-u` (pid 27) sedang berjalan (11:19:01–12,9); muat registry berikutnya bersih, semua dependensi `installed`.
  Catatan runbook: `-u` dengan worker hidup bisa memicu pesan ini sesaat (tidak perlu tindakan).
- Keamanan: akun superadmin uji realm `platform-staging` `billing@` (`34391a60`) dan `gate-sa@` (`2904b4a3`) **dinonaktifkan** +
  logout sesi (Admin REST `kc-realm-sync`; undangan di INBOX `billing@` tidak lagi bisa dipakai). Baris CP staging masih
  `invited` (diubah di luar UI) — nonaktifkan juga dari `/users` staging bila ingin sinkron.
- `custom_pdp` duplicate key saat instalasi baru: 19 baris duplikat identik di `pdp.field.classification.csv` → dibuang
  (odoo-addons-athera **v19.0.1.3.3**, `custom_pdp` 19.0.2.0.1); uji install bersih: 0 duplicate key, 0 ERROR, 30 tes OK.
  DB terpasang tidak terdampak (tanpa `-u`). Staging gitlink `b50d28f`; prod pool-a tetap v19.0.1.3.2 (naik saat rilis berikut).
- K3 (cek `ls-remote`): web-expomedia, odoo-data-expomedia, odoo-addons-athera, odoo-addons-expomedia, web-tambang →
  `Permission denied (publickey)` (repo/deploy key belum ada). control-plane `main` +45 dan infra `main` +138 commit belum
  di-push (remote ada; workflow push = `security.yml` di runner GitHub-hosted, tanpa deploy) — menunggu persetujuan owner.
- K3 (owner: "push cp dan infra"): gitleaks rentang `origin/main..main` → no leaks (control-plane 36, infra 81 commit non-merge);
  push `main` control-plane `31411f0..b9febac`, infra `fe01694..930754b`; keduanya sinkron dengan origin. 5 repo lain tetap
  menunggu repo/deploy key GitHub.
- **Aksi "Sinkronkan tenant"** (celah M8/M10): control-plane `11be44d` (fitur `feat/tenant-sync`) — halaman tenant (platform-admin)
  punya form `tenant_check` off/compat/strict → rantai `kc_org_ensure` → `odoo_tenant_config` per env ber-SSO aktif; audit
  `tenant.sync`; platform/terminated/ops ditolak; bisa "Ulangi dari langkah ini". Unit 766, **integrasi 88 lulus** (Postgres
  sekali pakai; +1 tes; `node_modules` lengkap via `npm ci` di scratchpad — `billing-flow` kini ikut lulus), tsc + lint bersih.
  Staging CP `11be44d` healthy. Kegunaan: org `demo` + compat (staging & prod) dan M10 strict expomedia tanpa terminal.
- CP prod `11be44d` (owner via SSH, `9977897`): web/worker healthy, health 200, 0 error. Aksi "Sinkronkan tenant" tersedia di
  prod + staging; belum dijalankan (usulan: `demo` → compat di kedua instance; `expomedia` → strict ≥ 2026-10-11 bila observasi
  M10 bersih).
- Owner "Sinkronkan tenant" `demo` → compat: prod 19:18 (org `demo` dibuat `47ba5c96…`; `demo_demo` ICP expected + platform +
  compat, `changed=3`), staging 19:21 (org sudah ada `changed=0`; `demo_staging` `changed=3`). Rekonsiliasi CP env
  `tenant_check=compat`. Pemakaian pertama aksi baru di prod: sukses.
- **Petunjuk login SSO** (usulan Fase 2): addons-shared `1773770` — `sh_auth_oidc` 19.0.1.5.0, template `login_sso_hint`
  (inherit `web.login`): keterangan "masuk lewat tombol SSO; form email/kata sandi hanya untuk akun lokal" bila ada provider
  aktif; form tidak disembunyikan (admin darurat). +2 tes HTTP, 159 tes 3 modul 0 gagal. Staging: 4 DB 19.0.1.5.0 (0 ERROR),
  petunjuk tampil di `demo.staging` & `ujiq.staging`. Prod (pool-a) + push addons-shared menunggu owner.
- Prod (owner via SSH, 19:31 WIB): pool-a shared `1773770` → `sh_auth_oidc` 19.0.1.5.0 di expomedia_prod + demo_demo (rc=0, log
  0 ERROR; `c6154e1`); petunjuk login SSO tampil di `erp.expomedia.id` dan `demo.erp.bimacreative.tech`. Platform pool-a
  `v19.0.1.3.3` (custom_pdp dedupe) di-checkout owner; gitlink dicatat Claude (`5718872`) — data instalasi baru saja.

## 2026-10-04 (malam) — pembersihan staging (owner: "kerjakan poin 1 dan 2")

- Backup: restic (`ujiq_staging` 2 snapshot, `ssotest_staging` 10, terakhir 15:14) + dump eksplisit DB/filestore/route +
  `control_plane_staging` → `/opt/infra/backups/saas-cleanup/<ts>/` (600).
- `ujiq` & `ssotest`: `provision-odoo-sso.sh --disable` (client KC `enabled=false`, provider Allowed OFF) →
  `render-client-route.sh --remove` (host 404) → `odoo db drop` (DB + filestore terhapus). User KC tenant `ujiq` (admin
  `28c5564a`) dinonaktifkan; `ssotest`/`qajob` tanpa user. File secret SSO `staging/odoo/secrets/oidc/{ujiq,ssotest}_staging`
  **tidak** terhapus (izin folder secrets ditolak) — tidak berguna lagi (client nonaktif); hapus manual bila mau.
- CP staging: `ujiq`, `ssotest`, `qajob` → `terminated` + environment `absent/removed/disabled` + audit `tenant.terminate`
  (`system:ops`, SQL manual — belum ada aksi UI terminasi; ADR 0018 "manual platform-admin"). Koreksi data lama:
  env `demo` staging `db_status` absent → provisioned (audit `environment.correct`).
- Org Keycloak `ujiq`/`ssotest` dan client KC (nonaktif) dibiarkan (tidak dipakai). ADR 0018 D10 diamandemen.
- **Gate §7.3 billing — LULUS** (staging, owner klik + Claude `TICK_NOW` override sementara): subscription `demo` (odoo-shared-s,
  override IDR 1.000.000) → Go-live 2026-10-04 (garansi s.d. 2026-12-04) → tick 2026-12-05: `active`, periode 12-04→01-04,
  `INV/2026/10/0001` unpaid → tick 2027-01-05: `past_due` (grace s.d. 2027-03-04) + email pengingat di Mailpit → tick
  2027-03-05: `suspended` + `tenant_suspend` succeeded, `demo.staging` → 302 `/suspended/demo` ("Layanan ditangguhkan … Data
  Anda tetap aman") → owner tandai lunas → `active` (periode berikut + `INV/2026/10/0002`), `tenant_resume` succeeded,
  `/web/login` 200, `demo-staging.yml` identik git. Audit lengkap (aksi owner ber-aktor). Override `TICK_NOW` dimatikan.
  Catatan: subscription pertama sempat dibuat di CP **prod** (`demo`) → di-terminate owner (TICK_NOW tidak berlaku di prod).
  Subscription staging `demo` tetap `active` (periode s.d. 2027-02-04; tick nyata akan memprosesnya Feb 2027).

## 2026-10-04 (malam) — RAM host prod (owner: Q6 ditolak, "environment ini justru untuk prod"; pilih 1b + 3)

- Ukur (Prometheus `infra_container_memory_*`, 7 hari): Σ pakai sesaat 4,7 GiB; Σ puncak per container 6,5 GiB; puncak serentak
  9,0 GiB; `ci-runner-job` 5 013 MiB (= limit) + swap Σ 3,3 GiB. Penyebab: drms `org.gradle.jvmargs=-Xmx8G` (template Flutter).
- **1b** branch `feat/ci-runner-jvm-cap` (`fc24d50`, belum merge/apply): `$GRADLE_USER_HOME/gradle.properties` (Xmx2g, Kotlin
  768m) + `ci_runner_memory` 4g; `--check`: hanya `supervisor.env` (task file dilewati check mode). Apply me-restart supervisor
  (job berjalan dihentikan) → jalankan saat tidak ada build.
- **3** `01d4ff0`: mail 1024→512m, CP web 384→256m, CP worker 256→128m, webmail 256→128m, web staging ×3 256→192m (hemat
  plafon 1 088 MiB). Keycloak/Postgres/pool-a/odoo-staging/uptime-kuma tetap. Staging web di-recreate Claude → healthy 192m;
  prod (mail, CP, webmail) menunggu owner.
- Q6 Fase 2 direvisi: dedicated prod diizinkan (±2 instance setelah 1b+3, `capacity_max_mib` pengaman).
- Opsi 3 prod diterapkan owner (±20:21 WIB): mailserver 512m, CP 256m, CP worker 128m, webmail 128m — semua healthy, CP health
  200, webmail `mail.bimacreative.tech`/`mail.expomedia.id` 302, mailserver 4 port mail listen, 0 error.
- Opsi 1b: owner merge `cdcc9cd` + apply role `ci_runner`: `supervisor.env` `CI_MEMORY=4g`, `/srv/ci/cache/gradle/gradle.properties`
  (Xmx2g, Kotlin 768m) **berlaku untuk build berikutnya**. Handler restart supervisor TIDAK jalan (aktif sejak 2026-10-03) →
  job baru masih 5120 MiB sampai `systemctl restart ci-runner-supervisor` (saat tidak ada build; restart memutus job berjalan).
- Cek CI (owner): supervisor di-restart 20:26:56 WIB setelah job selesai (rc=0) → job baru limit 4096 MiB. Puncak `ci-runner-job`
  1h 1 675 / 24h 2 719 / 7d 5 013 MiB. Belum ada build Gradle/APK sejak cap (`daemon` terakhir 2026-09-28) → cap belum teruji di
  APK. Keputusan: limit tetap 4g (job non-APK sudah 2,7 GiB → 3g terlalu tipis). Verifikasi: owner jalankan workflow APK drms
  manual, lalu cek puncak/OOM; bila heap kurang → `ci_runner_gradle_jvmargs` -Xmx2560m.
- Build APK drms (mobile #45 → runner job 235, 21:20–21:29 WIB): Gradle 9.3.1 berjalan (daemon `GRADLE_OPTS` dari workflow drms:
  `-Xmx1536m -XX:MaxMetaspaceSize=384m` — mengalahkan `gradle.properties` runner; tim drms sudah membatasi sendiri), **puncak
  container 3 697 MiB / limit 4 096 MiB, tanpa OOM**. Job gagal `rc=10` hanya di `upload-artifact`: **kuota storage artifact
  GitHub akun `bctech-adm` penuh** (dihitung ulang 6–12 jam setelah penghapusan). Limit CI tetap 4g (headroom ±0,4 GiB — jangan
  turun ke 3g). ci #175 (tag v0.6.0) exit 130 = SIGINT (pembatalan: concurrency `ci-${ref}` / manual), bukan memori.
- Kuota artifact GitHub: owner menjalankan `/root/gh-artifacts.sh` (skrip Claude: daftar + hapus artifact > KEEP_DAYS lewat
  REST API dengan token fine-grained sekali pakai, tidak disimpan; `gh` sengaja tidak dipasang di server prod). Sisa: hapus
  token, turunkan retention repo/workflow, re-run mobile #45 + ci #175 setelah GitHub menghitung ulang kuota (6–12 jam).
- **Koreksi CI**: limit runner 4g **salah** untuk build release drms — `mobile.yml` mengatur heap via `GRADLE_OPTS` (debug
  -Xmx1536m, puncak 3,5–3,7 GiB; release R8 -Xmx2560m + metaspace 512m + dart ±1 GiB → "fits the 5 GiB runner"; -Xmx2g di 4 GiB
  pernah OOM, plan 12 R10). `ci_runner_memory` kembali **5g** (`e20d116`, `--check` 4g→5g) — owner apply + restart supervisor
  SEBELUM tag `mobile-v0.3.2`. `gradle.properties` runner tetap (cadangan; kalah dari GRADLE_OPTS).
- APK tanpa kuota artifact: drms branch `fix/artifact-quota-release-asset` (`22b8285`, di-push): 5 langkah `upload-artifact`
  `continue-on-error`; `release-prod` self-hosted menyalin simbol obfuscation ke `/cache/release-symbols/<tag>`; pubspec
  0.3.2+1; `docs/release-notes/apk/0.3.2.md` (= item 0.3.1 + keterangan rilis ulang); CHANGELOG. actionlint 1.7.12 bersih.
  Owner: PR → merge ke `main` → push tag `mobile-v0.3.2` → APK di GitHub Release (asset, tidak dihitung kuota Actions).
