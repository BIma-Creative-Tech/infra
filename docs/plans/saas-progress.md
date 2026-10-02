# SaaS — log progres

Append per sesi, bertanggal. Pertanyaan pemblokir selalu di bagian **Butuh keputusan** paling atas.

---

## Butuh keputusan

- **K3 (owner, HARI INI)** — buat 5 repo **private** kosong di `bctech-adm`: `web-expomedia`, `odoo-data-expomedia`,
  `odoo-addons-athera`, `odoo-addons-expomedia`, `web-tambang`; **nonaktifkan Actions** dulu (web-expomedia/web-tambang punya
  `ci.yml` yang langsung jalan saat push tag/branch); pasang deploy key **write** (public key di laporan sesi; file
  `~/.ssh/deploy_<repo>.pub` root di host). Setelah itu Claude menjalankan push semua branch + tag.
- **FREEZE** — berlaku sampai owner menulis "FREEZE DICABUT". Setelah itu: K2 start ulang CI runner, K4–K5, apply K3 restic,
  W0–W8.

## Keputusan owner (2026-10-02)

| # | Keputusan | Status pelaksanaan |
|---|---|---|
| K1 | `restic unlock` + ulang restore-test | **selesai** 23:03 — lock basi dihapus; `restic check` **ok**; `db_compare=failed` (lihat log sesi) |
| K2 | stop `ci-runner-supervisor` selama demo, start saat freeze dicabut | **selesai** — supervisor stop, container job idle ikut berhenti |
| K3 | repo privat GitHub + push semua branch/tag hari ini; `/opt/src` ke restic (apply setelah freeze) | sebagian — key/remote siap, menunggu repo dibuat owner; restic di branch belum di-merge |
| K4 | setelah freeze: hapus 21 image per `repo:tag` tanpa `-f` (pre-check daftar ID/tag, keluarkan yang dipakai container/compose/.env + 4 basis), `builder prune --filter until=72h`, `volume prune` anonim (lampirkan `volume ls -f dangling=true` sebelum/sesudah); §11.3 TIDAK; `docker-host-gc.timer` via Ansible dry-run dulu | menunggu freeze |
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
