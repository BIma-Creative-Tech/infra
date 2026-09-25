# QA J5 — Plan 05 (control plane → infra-job) · staging · 2026-09-25

- **Penguji:** QA & Security (J5) · **Lingkungan:** staging saja (`cp.staging.bimacreative.tech`, realm `platform-staging`,
  DB `control_plane_staging`, `infra-job-staging.path`, pool `odoo-staging`). Prod tidak disentuh (bukti di §Cleanup).
- **Versi:** infra `main` 84f8246 (dispatcher `/usr/local/sbin/infra-job` 1.0.0) · control-plane image `control-plane:7b85a78`.
- **Acuan:** `docs/plans/05-control-plane-odoo-sso-jobs.md` §6 (STRIDE), §8.1 (AC-J*), ADR 0009, `docs/03-operations/infra-jobs.md`,
  `docs/runbooks/odoo-sso-tenant.md`.
- **Hasil ringkas:** AC-J1..J12 PASS (J13 tidak diuji di J5). 52 kasus negatif/keamanan live (30 dispatcher, 5 izin host/container, 17 control plane) → semua ditolak sesuai desain.
  **2 bug terbuka: BUG-J5-01 (High) resend_invite memulihkan akses user yang sudah dicabut; BUG-J5-02 (Medium) aktor CP
  = UUID acak per login (audit tidak bisa ditelusuri).** Sign-off J5: **BELUM** (ada High terbuka).

## Metode

- Identitas uji (Admin REST client `automation` via `:8443`, body tanpa `${`): `qa05-ops` (role CP `ops`), `qa05-super`
  (`superadmin`), `qa05-cadmin` (`client_admin`), `qa05-norole` (tanpa role). Password acak, file 600 di luar repo, dihapus.
- Klien HTTP: container sekali pakai `qa-j5-client` (`python:3.12.11-slim-bookworm`, network `proxy`, IP tetap `10.100.0.253`,
  `--read-only --cap-drop ALL no-new-privileges`, host → Traefik `10.100.0.7`). Login = alur Auth.js OIDC nyata
  (`/api/auth/csrf` → `POST /api/auth/signin/keycloak` → form Keycloak → callback). Mutasi = Server Action **tanpa JS**
  (multipart + `$ACTION_ID_<id>` dari HTML halaman, header `Origin` = AUTH_URL) — jalur yang sama dengan form UI.
  IP terpisah dipakai agar uji WAF tidak mem-ban `10.100.0.1` (hairpin back-channel Odoo).
- Pemantauan: `provision_jobs`/`environments`/`tenant_user_access`/`audit_logs` (psql read-only), `results/<id>.json`,
  `/var/log/infra-jobs/staging/<id>.log`, `journalctl -t infra-job`, efek nyata (Keycloak Admin REST, psql DB tenant, route, HTTP).
- Tenant uji: client CP `qajob` + environment `staging` (dibuat lewat form superadmin), DB `qajob_staging`,
  host `qajob.staging.bimacreative.tech` (wildcard DNS → 31.97.50.221).

## Alur CP nyata (semua lewat UI/Server Action, aktor `qa05-ops` kecuali disebut)

| # | Job | id | Status CP | Bukti hasil/efek |
|---|---|---|---|---|
| 1 | `odoo_db_provision` | 8075f053 | succeeded 28,0 s | `RESULT db=qajob_staging pool=staging created=yes changed=5`; DB owner `odoo_staging`, ACL `{odoo_staging=CTc/odoo_staging}`, `web.base.url=https://qajob.staging…` freeze; file admin-password `600 root:root` |
| 2 | `odoo_route` render | 263b5c1d | succeeded 6,7 s | file route `644 root:root` header render; `Host(qajob.staging…)`; dari 10.100.0.253: `/web/login` 200, `/web/database/selector` 403, `/web/database/manager` 403 |
| 3 | `odoo_sso_provision` | 12bc465c | succeeded 23,1 s | fase `dry_run` → `apply`; `changed=9`; client KC `odoo-qajob-staging` enabled, redirect `https://qajob.staging…/sh_auth_oidc/callback`, `fullScopeAllowed=false`; provider 4 `enabled=t sh_oidc_enabled=t source=file role=odoo_access`; secret `440 root:messagebus`, tanpa newline; smoke 303 ke realm |
| 4 | `odoo_sso_provision` ulang | b0cc98fa | succeeded `changed=0` | idempoten; root `provision-odoo-sso.sh qajob staging --host … --dry-run` → `changed=0 … blockers=0` |
| 5 | `odoo_sso_user` grant login tak ada | 1fe5827c | failed `blocked_dry_run` | `BLOKIR: res.users login=qaj5-nologin tidak ada`; KC `users?email=…nologin…` = 0 sebelum & sesudah; mail.log tanpa baris `qaj5-nologin` |
| 6 | `odoo_sso_user` grant (`res.users` id 5 dibuat dulu via `odoo shell`, login `qaj5-user`) | 6fa738e1 | succeeded | `kc_user=2a41979c… odoo_user=5 changed=4`; `tenant_user_access.status=active`, kc/odoo id terisi; `res_users.oauth_provider_id=4, oauth_uid=2a41979c…`; undangan terkirim (mail.log `status=sent … Saved`) |
|   | Login SSO E2E | — | — | (password uji diset via Admin REST) `authorize 303 → KC 200 → creds 302 → callback 303 /odoo`; `get_session_info` → `db=qajob_staging uid=5` |
| 7 | revoke | f33f60ae | succeeded | status `revoked`; login ulang → `callback 303 /web/login?oauth_error=2`; log Odoo `required client role 'odoo_access' missing` |
| 8 | resend_invite (user sudah revoked) | d95a301b | succeeded, `result.action=grant` | **BUG-J5-01**: role `odoo_access` diberikan lagi; login E2E berhasil lagi (`uid=5`); CP tetap `revoked` |
| 9 | resend_invite (required action tertunda) | 9a9af0fe | succeeded | `execute-actions-email ["UPDATE_PASSWORD"]` terkirim (mail.log: 2 email ke alamat uji) |
| 10 | revoke (pulihkan) | a361426b | succeeded | — |
| 11 | `odoo_sso_disable` (**superadmin**, confirm `qajob`) | d48a14b7 | succeeded | client KC `enabled=false`; provider 4 `enabled=f`; smoke "link provider tidak tampil"; `sso_status=disabled`; email alert terkirim 13:18 |
| — | konfirmasi slug salah | — | `?r=confirm`, tanpa job | — |

`environments` diperbarui dari hasil job saja: `absent/absent/none` → `provisioned/active/active` → `…/disabled` → akhir
`provisioned/removed/disabled`. `audit_logs`: `job.enqueue.*` (success + rejected) dan `job.finish` untuk setiap job (19 job → 19 `job.finish`, 0 job tanpa `job.enqueue.*` success; dicocokkan lewat `metadata.job_id`).

## Acceptance criteria

| AC | Status | Bukti |
|---|---|---|
| AC-J1 | PASS | `stat`: `/usr/local/sbin/infra-job root root 755`; `…/prod/spool/new root cpjob-prod 730`; `…/staging/spool/new root cpjob-staging 730` |
| AC-J2 | PASS (staging) | `infra-job-staging.path` enabled/active; prod `disabled/inactive` **sesuai rollout** (J6) |
| AC-J3 | PASS | `python3 -m unittest discover -s scripts/infra-job/tests` → `Ran 233 tests … OK (skipped=3)` |
| AC-J4 | PASS | worker `uid=951 gid=951`; `ls /jobs` → `results spool`; `touch /jobs/results/x` → `Read-only file system`; `/proc/mounts` spool rw, results ro |
| AC-J5 | PASS | `sudo -u deploy touch …/staging/spool/new/x` & `…/tmp/x` → Permission denied; `ls results` → denied; deploy groups=1001 saja |
| AC-J6 | PASS | tabel alur #1–#4 (+ rotate b943d505, disable, route remove): jalur apply di bawah hardening unit — `install` file secret/admin, `chown` 440 root:messagebus, rename route, `docker exec … odoo -i`/`odoo shell`, reload Traefik — tanpa error sandbox (`grep "Permission denied|Operation not permitted|Read-only file system"` di semua log job → 0; `systemctl --failed` kosong) |
| AC-J7 | PASS (dengan BUG-J5-01) | #5–#10. Grant/revoke/negatif sesuai AC; resend_invite pada user revoked = cacat keamanan (bug terpisah) |
| AC-J8 | PASS (fakta dicatat) | lihat §AC-J8 |
| AC-J9 | PASS | file `env=prod` (dan `env=demo`) ditulis uid 951 ke spool staging → `rejected_validation "env di luar instance ini (lintas instance)"`, journal hanya `REJECT`, 0 `START` di run itu; email alert terkirim (`alert-state` 5 email/jam, `suppressed=0`) |
| AC-J10 | PASS | 6 nilai secret (oidc qajob/demo/ssotest, admin-password qajob, `automation-platform-staging`, `platform-staging-control-plane`) dicari literal di `provision_jobs`, `audit_logs`, `tenant_user_access`, 44 `results/*.json`, semua log host job, journal → **0 hit**; pola `secret=/password=/"token":/PRIVATE KEY` di DB CP + results → 0; `audit_logs.metadata` tanpa `@` (pakai `email_hash`); journal tanpa email. Log host root memuat email (sesuai desain, 0600) |
| AC-J11 | PASS | 2 submit paralel `odoo_sso_provision` dry-run → `(303 ?r=queued&job=b9717ea7…)`, `(303 ?r=duplicate)`; 1 baris job; audit `rejected reason=duplicate` |
| AC-J12 | PASS | lihat §Negatif N-A* |
| AC-J13 | NOT TESTED | CI control-plane (lint/typecheck/vitest/Semgrep/Trivy) di luar tugas J5 ini |

### AC-J8 — timeout (override Ansible sementara, sudah dikembalikan)

1. `ansible-playbook site.yml --tags infra_jobs --check --diff -e '{"infra_jobs_overrides":{"staging":{"timeouts":{"odoo_sso_provision":5}}}}'`
   → hanya `/etc/infra-jobs/staging.conf` berubah (`300 → 5`); apply `changed=1`. (Ditambah `odoo_db_provision: 5` pada run kedua
   karena job nyata selesai < 5 s: sso 4,8 s apply, db idempoten ~5 s, rotate ~4 s — batas bawah dispatcher 5 s.)
2. Agar apply pasti > 5 s tanpa mengubah unit: sesi psql menahan `LOCK TABLE ir_model_fields IN ACCESS EXCLUSIVE MODE` di
   `qajob_staging` (DB uji sendiri) 75 s → `odoo shell` apply tertahan saat memuat registry (dry-run hanya `SELECT` lain, lolos).
3. Job 5c2a1f3c (UI ops): dry-run exit 0 → apply 06:22:41 → `exit=-15 timeout=True` → CP `failed timeout_state_unknown`,
   `exit_code=-15`, `finished_at 06:22:46`, `duration_ms 8553`.
4. Fakta proses (monitor 1 Hz `ps` host + `docker top odoo-staging`): skrip bash + klien `docker exec -i` di host hilang
   ≤ 06:22:46,8 (SIGTERM grup cukup, SIGKILL tidak diperlukan). Proses **di dalam container**
   `/usr/bin/odoo shell … -d qajob_staging` (pid 3210669) **tetap hidup** setelah klien dibunuh — terlihat sampai 06:22:59,985,
   lalu berakhir karena statement-nya dibatalkan Postgres sendiri: `06:23:00.317 ERROR: canceling statement due to lock timeout`
   (`SELECT … FROM ir_model_fields WHERE state='manual'`). Kesimpulan: **proses odoo di container TIDAK ikut berhenti** saat
   dispatcher timeout (asumsi aman plan §4.4 benar) → catat di ADR 0009; `timeout_state_unknown` wajib dicek dry-run sebelum ulang.
   Setelah lock dilepas: `provision-odoo-sso.sh qajob staging … --dry-run` → `changed=0 blockers=0` (tidak ada state setengah jadi).
5. Kembalikan: `ansible-playbook site.yml --tags infra_jobs` (tanpa override) → `changed=1`; `diff staging.conf.before
   /etc/infra-jobs/staging.conf` → identik; sha256 `prod.conf`=`staging.conf`=`b7d8856f…` dan unit `infra-job@.service`
   `6986a53b…`, path `9191bdc8…`/`69514f99…` sama dengan sebelum uji; `--check` → `changed=0`.

## Negatif / keamanan (live)

### Dispatcher (file ditulis sebagai uid 951 `cpjob-staging` lewat `tmp/` → `rename` ke `new/`, kecuali disebut)

| ID | Kasus | Hasil |
|---|---|---|
| H01 | `env=prod` (lintas instance) | `rejected_validation` "env di luar instance ini" |
| H02 | `env=demo` + host `.erp.` | `rejected_validation` (lintas instance) |
| H03 | slug `qa$(id)` | `rejected_validation` slug |
| H04 | slug `--host` | `rejected_validation` slug |
| H05 | `hosts=["--disable"]` | `rejected_validation` host |
| H06 | host `evil.staging…` (tidak di file route) | `rejected_validation` "host tidak ada di file route tenant" |
| H07 | kunci top-level `cmd` | `rejected_validation` kunci tak dikenal |
| H08 | `args.script` | `rejected_validation` |
| H09 | email dengan `\n--admin` | `rejected_validation` email |
| H10 | email huruf besar | `rejected_validation` email |
| H11 | login `x --admin` | `rejected_validation` login |
| H12 | `type=shell` | `rejected_validation` type |
| H13 | 9 000 byte | `rejected_validation` "> 8192 byte" |
| H14 | kunci JSON duplikat | `rejected_validation` |
| H15 | `v=1.0` | `rejected_validation` pecahan |
| H16 | byte non-ASCII | `rejected_validation` |
| H17 | mode 0666 | `rejected_validation` mode |
| H18 | symlink → `/etc/shadow` | `rejected_validation` "bukan file reguler" (tidak dibaca) |
| H19 | FIFO | `rejected_validation` "bukan file reguler" (dispatcher tidak hang) |
| H20 | hardlink (nlink=2) | `rejected_validation` "nlink ≠ 1" |
| H21 | route `remove=true` + host | `rejected_validation` |
| H22 | `odoo_db_provision dry_run=true` | `rejected_validation` |
| H23 | revoke + admin | `rejected_validation` |
| H24 | nama file bukan UUID | dipindah `rejected/badname.*`, tanpa hasil, email |
| H25 | file kosong | `rejected_validation` |
| H26 | job_id duplikat (8075f053) | `rejected/…duplicate…`, hasil lama `sha256sum -c` OK |
| H27 | `odoo_db_provision` ke-4 dalam 24 j (langsung ke spool) | `rejected_quota` "kuota odoo_db_provision/24 jam habis" |
| H28 | uid 951 `ln /etc/shadow new/<uuid>.json` | `Operation not permitted` (protected_hardlinks) |
| H29 | uid 951 hardlink ke `results/*.json` | `Operation not permitted` |
| H30 | file pemilik uid 65534 di `new/` (ditaruh root) | `rejected_validation` "pemilik file bukan user job instance ini" |

H01–H30: 0 baris `START` di journal untuk semua kasus ini (tidak ada eksekusi skrip). Worker CP mengabaikan hasil dengan
job_id yang tidak ada di DB (tidak ada log/perubahan).

### Izin host / container

| ID | Kasus | Hasil |
|---|---|---|
| P1 | `deploy` tulis `spool/new`, `spool/tmp`, baca `results` | denied ×3 |
| P2 | `cpjob-prod` (950) tulis spool staging | Permission denied |
| P3 | worker `ls /jobs/spool/new` | `Permission denied` |
| P4 | worker `ls /var/log/infra-jobs` | tidak ada di container |
| P5 | uid 951 di host: `ls /var/log/infra-jobs/staging`, `…/staging/work`, `…/prod/results` | denied ×3 |

### Control plane (Server Action, 0 baris `provision_jobs` baru untuk semua kasus: 10 → 10)

| ID | Kasus | Hasil |
|---|---|---|
| N-A1 | ops → `ssoDisable` / `ssoRotate` / `routeRemove` (action id dari halaman superadmin) | 303 `/forbidden` ×3 |
| N-A2 | ops → `createClient` | 303 `/forbidden`; form create client tidak dirender untuk ops |
| N-A3 | client_admin → `ssoProvision` dry-run / `ssoUser` grant | 303 `/forbidden` ×2 |
| N-A4 | tanpa role → sama | 303 `/forbidden` ×2 |
| N-A5 | tanpa sesi → sama | 303 `/login` ×2 |
| N-A6 | client_admin / tanpa role: GET `/clients`, `/clients/qajob`, `/environments/<id>`, `/jobs`, `/jobs/<id>` | 307 `/forbidden` (client_admin `/dashboard` 200 tanpa form ops); anonim → 307 `/login` |
| N-C1 | Origin `https://evil.example` | 500 (Next.js "Invalid Server Actions request"), tanpa job — lihat OBS-J5-02 |
| N-C2 | tanpa header Origin | 303 `?r=origin` |
| N-C3 | Origin `https://cp.bimacreative.tech` (instance lain) | 500 (x-forwarded-host ≠ origin), tanpa job |
| N-C4 | Origin benar + `Sec-Fetch-Site: cross-site` | 303 `?r=origin` |
| N-I1 | email `a$(id)@x.co` | 403 WAF (CrowdSec AppSec rce), tanpa ban IP (hanya alert) |
| N-I2 | email `--revoke@x.co`, login `a --admin`, login `-x`, action `delete` | 303 `?r=invalid` ×4 |
| N-I3 | field ekstra `hosts=evil.example` | 303 `?r=invalid` (Zod strict) |
| N-I4 | host `evil.example.com` / `qajob.erp.bimacreative.tech` pada env staging | 303 `?r=invalid` ×2 (audit `issue=host_env`) |
| N-I5 | `environmentId=' OR 1=1--` | 403 WAF (sqli) |
| N-I6 | superadmin buat environment `kind=prod` di CP staging / host asing | 303 `?r=invalid`, jumlah environment tetap 1 |
| N-Q1 | `odoo_db_provision` ke-4 lewat UI | 303 `?r=quota`, audit `violation=db_provision_day` |

## Bug & temuan

### BUG-J5-01 · High · `odoo_sso_user resend_invite` memulihkan akses user yang sudah dicabut
- **Komponen:** kontrak dispatcher (`build_argv`: `resend_invite` → `odoo-sso-user.sh … --resend-invite` tanpa `--grant`/aksi
  terpisah) + `scripts/odoo-sso-user.sh` (`ACTION` default `grant`; `--resend-invite` hanya flag tambahan) + UI CP
  (`src/app/environments/[id]/page.tsx` menampilkan tombol "resend_invite" pada baris berstatus `revoked`) + rekonsiliasi CP
  (status tidak diperbarui dari `RESULT action=grant`).
- **Langkah:** grant user (6fa738e1) → revoke (f33f60ae, login → `oauth_error=2`) → klik resend_invite pada baris revoked (d95a301b).
- **Aktual:** job `succeeded`, `result.action=grant changed=1`, log `UBAH: role odoo_access … → user …`; login SSO E2E berhasil lagi
  (`uid=5`); `tenant_user_access.status` tetap `revoked` (CP menampilkan akses dicabut padahal aktif).
- **Diharapkan:** resend_invite hanya mengirim ulang `execute-actions-email` (tanpa mengubah role/tautan); ditolak untuk
  user `revoked`; CP merekonsiliasi status dari `RESULT action`.
- **Dampak:** kontrol keamanan "cabut akses" bisa dibatalkan diam-diam oleh ops (atau CP tertembus) dan tidak terlihat di CP.
- **Rekomendasi:** (1) skrip: `--resend-invite` menjadi aksi tersendiri yang tidak memanggil assign role/tautan, atau dispatcher
  menambahkan guard (mis. dry-run pendahulu menolak bila role belum ada → blocker); (2) CP: sembunyikan/ tolak resend untuk
  status `revoked|failed`, dan set status dari `result.action`; (3) test unit + E2E ulang. **Agent:** infra-engineer (skrip/dispatcher)
  + nextjs-developer (UI/rekonsiliasi).

### BUG-J5-02 · Medium · Aktor CP = UUID acak per login, bukan `sub` Keycloak
- **Komponen:** `src/auth.ts` callback `jwt`/`session` + `src/server/context.ts actorFromSession`. Auth.js 5 men-set
  `token.sub = user.id = crypto.randomUUID()` (`@auth/core/lib/actions/callback/oauth/callback.js` l.224: "user's id is
  intentionally not set based on the profile id"), sedangkan `upsertUserOnLogin` memakai `profile.sub` yang benar.
- **Bukti:** sesi `qa05-ops` → `session.user.id=16bef5ca-…` / `36196936-…` (berubah tiap login) vs Keycloak id `bf06fc2d-…`;
  `users.keycloak_sub=bf06fc2d-…` (benar); semua 19 `provision_jobs` dan semua `audit_logs` aksi user: `actor=user:<uuid acak>`,
  `actor_user_id` **NULL**; journal host `actor=user:36196936-…` (tidak bisa dicocokkan ke Keycloak).
- **Dampak:** non-repudiation (STRIDE R) gagal — "siapa memicu apa" tidak dapat ditelusuri ke identitas; rate limit per aktor
  (10/menit) direset dengan login ulang; dasar otorisasi iterasi 2 (`session.sub → users.client_id`) akan salah.
- **Diharapkan:** `session.user.id` / aktor = klaim `sub` Keycloak; `actor_user_id` terisi.
- **Rekomendasi:** di callback `jwt` saat sign-in set `token.sub = profile.sub` (atau simpan `token.kcSub`) dan pakai itu di
  `actorFromSession`; test unit + cek `actor_user_id` tidak null. **Agent:** nextjs-developer.

### OBS-J5-01 · Low · Redaksi `tail` terlalu lebar
Baris seperti `PLAN/UBAH: execute-actions-email ["UPDATE_PASSWORD"] …`, `user Keycloak … dibuat (required actions UPDATE_PASSWORD)`,
`secret file: isi sesuai` menjadi `[redacted]` → ops di CP tidak bisa melihat bahwa undangan terkirim. Aman (bukan kebocoran);
pertimbangkan pola redaksi yang tidak mengenai `UPDATE_PASSWORD`/`secret file:` (infra-engineer, opsional).

### OBS-J5-02 · Low · Origin asing → HTTP 500
Next.js membatalkan Server Action (`x-forwarded-host … does not match origin`) dengan 500, bukan 403. Tidak ada efek (tanpa job,
tanpa audit); hanya kebisingan log/monitor. Informasi.

### OBS-J5-03 · Info
- Kuota `odoo_db_provision` staging (3/24 j, jendela bergulir) **habis** oleh uji ini (8075f053 06:10, 685b3a7d 06:21,
  9b3dae00 06:27 UTC; dua terakhir idempoten tanpa DB baru) → job DB staging berikutnya ditolak sampai ± 2026-09-26 06:10 UTC.
- Durasi nyata (staging): DB baru 28 s; DB idempoten ~5 s; route 6,7 s; SSO pertama (install modul) 23 s; SSO idempoten 8–15 s
  (dry-run ~3 s); sso_user ~2–5 s; disable ~8 s. Timeout default (900/60/300/180/120) longgar.
- CrowdSec AppSec mencatat alert WAF untuk IP uji 10.100.0.253 (rce/sqli), tanpa keputusan ban.

## Cleanup (bukti)

| Item | Tindakan | Verifikasi |
|---|---|---|
| SSO qajob | job CP `odoo_sso_disable` 89518667 (superadmin) | succeeded |
| Route | job CP `odoo_route remove` 2f61e0b5 (superadmin, confirm) | file `qajob-staging.yml` hilang; `https://qajob.staging…/web/login` → 404 |
| Client KC `odoo-qajob-staging` | Admin REST `DELETE /clients/8d59af05-…` | `clients?clientId=odoo-qajob-staging` → 0 |
| User KC | `DELETE` `postmaster+qaj5-user@…`, `qa05-ops`, `qa05-super`, `qa05-cadmin`, `qa05-norole` | `users/count` realm platform-staging = 0 (sama dengan awal) |
| DB | `odoo.md` §Rollback: route sudah `--remove` → nama dicek persis `qajob_staging` → `docker exec postgres dropdb --force -U postgres qajob_staging` (2 koneksi pool) | `pg_database` count 0 |
| Filestore / secret | `rm -rf /var/lib/odoo/filestore/qajob_staging` (container), `rm` `staging/odoo/secrets/oidc/qajob_staging`, `…/tenants/qajob_staging.admin-password` | tinggal `demo_staging`, `ssotest_staging` |
| CP | client `qajob` **ditandai**: `terminated_at` di-set, nama `QA J5 plan05 TEST (hapus) — TERMINATED 2026-09-25 cleanup` (baris client/environment/job/tenant_user_access/audit **dipertahankan** sebagai jejak uji); baris `users` 4 akun `qa05-*` dihapus | `UPDATE 1`, `DELETE 4` |
| Host | container `qa-j5-client` dihapus; sisa hardlink `spool/tmp/5fb45353….json` dihapus; `spool/new` & `spool/tmp` kosong; file password/uji di scratchpad dihapus | `ls -A` kosong |
| Tidak disentuh | `demo_staging`/`ssotest_staging`: provider 1–4 identik dengan baseline, secret `440 root:messagebus` mtime sama, route sha256 sama, dry-run keduanya `changed=0 blockers=0`; `odoo-staging` healthy | — |
| Prod | `odoo-pool-a`/`traefik`/`keycloak`/`control-plane(-worker)` StartedAt sama dengan baseline; `infra-job-prod.path` disabled; `prod/results` kosong; `cp.bimacreative.tech` 307 `/login` | — |

Sisa yang sengaja dibiarkan: `results/*.json` uji (dipangkas 7 hari), `rejected/*` (forensik, 30 hari), `/var/log/infra-jobs/staging/*.log`
(30 hari, memuat alamat uji `postmaster+qaj5-*`), 2 email undangan di mailbox `postmaster` lokal, `work/ledger` (kuota).
