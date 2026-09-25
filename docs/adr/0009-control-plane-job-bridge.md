# ADR 0009 — Jembatan job control plane → skrip root: spool + systemd path + dispatcher `infra-job`

- **Status:** accepted (GATE 1 plan 05, user 2026-09-25)
- **Tanggal:** 2026-09-25
- **Penulis:** Analyst (FASE 1 plan 05)
- **Terkait:** CLAUDE.md §3 (tabel "Docker API akses"), §3.4, §3.6, §3.7; ADR 0001 riwayat H3 (socket-proxy dihapus dari
  observability); ADR 0008 #5 (kontrak skrip SSO); `docs/plans/05-control-plane-odoo-sso-jobs.md`; `docs/plans/01-host-bootstrap.md` §4
  threat model E (grup docker = root).

## Context

Fakta (diverifikasi 2026-09-25, detail & perintah di plan 05 §2):

1. Aksi orkestrasi tenant (`provision-odoo-db.sh`, `render-client-route.sh`, `provision-odoo-sso.sh`, `odoo-sso-user.sh`) wajib root
   (`[[ $EUID -eq 0 ]]`), memakai `docker exec` ke `postgres`/pool Odoo/Traefik dan membaca secret platform (client `automation`
   Keycloak, file secret OIDC). Semuanya idempoten, baris terakhir `RESULT …`.
2. Worker control plane (`control-plane-worker`, `control-plane-staging-worker`) berjalan uid 1001, `read_only`, `cap_drop ALL`, hanya
   network `db`, tanpa mount host. **uid 1001 = user host `deploy`.**
3. CLAUDE.md §3/§3.4 dan `nextjs-developer.md` menyebut "docker-socket-proxy + skrip" untuk control plane, tetapi tidak ada socket-proxy
   yang berjalan; H3 menghapusnya dari observability karena akses Docker API = baca env/secret semua container dan proxy memegang socket.
   `tecnativa/docker-socket-proxy` memfilter per seksi API (mis. `CONTAINERS`, `EXEC`, `POST`), bukan per container/perintah.
4. Pola akses root yang sudah disetujui: wrapper root-owned tervalidasi (`/usr/local/sbin/infra-deploy` via sudoers user `deploy`) dan
   unit systemd oneshot dikelola Ansible dengan `OnFailure=infra-unit-failure@%n` (alert email).
5. systemd 255 di host mendukung `DirectoryNotEmpty=` dan `TriggerLimitIntervalSec=`/`TriggerLimitBurst=` pada unit `.path`
   (`man systemd.path`). `fs.protected_hardlinks=1`, `protected_symlinks=1`.

## Decision

1. Control plane **tidak** mendapat akses Docker API, SSH, sudo, atau secret platform. Satu-satunya jalur ke aksi root = **file job**
   di spool per instance (`/var/lib/infra-jobs/<prod|staging>/spool/new`), ditulis worker lewat bind mount.
2. `infra-job-<inst>.path` (`DirectoryNotEmpty=`) memicu `infra-job@<inst>.service` (oneshot root) yang menjalankan dispatcher
   `/usr/local/sbin/infra-job <inst>` (Python 3 stdlib, root 0755, dikelola role Ansible `infra_jobs`).
3. Dispatcher adalah batas keamanan: rename ke dir root → `O_NOFOLLOW`/`fstat` (reguler, uid `cpjob-<inst>`, nlink 1, ≤ 8 KiB) → JSON
   ketat → allowlist tipe → regex argumen (sama/lebih ketat dari skrip) → binding instance→env (prod: prod|demo; staging: staging) →
   aturan host (hanya subdomain platform; host SSO harus sudah ada di file route tenant) → kuota → `subprocess` argv list tanpa shell,
   environment bersih, timeout per tipe, serial per instance → hasil JSON (RESULT ter-allowlist + tail teredaksi) ke dir hasil (ro bagi
   worker). Log penuh hanya root.
4. Worker bridge berjalan sebagai uid khusus `cpjob-<inst>` (bukan 1001/`deploy`); web tidak mendapat mount.
5. Kill switch: `systemctl disable --now infra-job-<inst>.path` atau `/etc/infra-jobs/<inst>.disabled`.
6. Tipe job awal: `odoo_db_provision`, `odoo_route`, `odoo_sso_provision`, `odoo_sso_disable`, `odoo_sso_user` (kontrak plan 05 §4).
   Tipe baru (suspend/resume/backup/…) = perubahan dispatcher + ADR/plan, bukan konfigurasi CP.

Pseudo-config & tata letak: plan 05 §3.2 (bukan final; nama/uid final oleh infra-engineer). **UNVERIFIED**, diverifikasi di J4:
durasi nyata tiap job (timeout), dan apakah proses di dalam container ikut berhenti bila klien `docker exec` di-kill saat timeout.

## Alternatives

| Alternatif | Ditolak karena |
|---|---|
| docker-socket-proxy (EXEC/POST/CONTAINERS) atau runner container dengan socket | Filter per seksi API → exec ke container mana pun (postgres superuser, keycloak) dan create container dengan bind `/` → root host. Setara grup `docker` (plan 01 §4 E). Alasan yang sama dengan H3. |
| SSH forced-command + sudo wrapper | Private key = secret baru di CP; worker butuh jalur ke sshd host:2221 (network baru, fail2ban/ufw); validasi argumen tetap harus sama beratnya. Tidak lebih aman dari spool. |
| Host menarik job dari DB `control_plane` (timer root + role PG khusus) | Layak (cadangan). Root host memegang kredensial DB dan butuh jalur host→Postgres (port tidak dipublish); polling. Spool lebih sederhana dan tanpa kredensial. |
| Worker menjalankan skrip langsung (`child_process`) | Worker tidak root dan tidak boleh root; akan butuh socket Docker → sama dengan baris pertama. |

## Consequences

- (+) Tidak ada kredensial/akses baru di control plane; CP tertembus terbatas pada job allowlist untuk env instance-nya, dalam kuota.
- (+) Staging CP terisolasi dari tenant prod (binding di dispatcher + mount terpisah).
- (+) Skrip runbook tetap satu-satunya pelaksana → perilaku manual dan CP identik; tidak ada duplikasi logika.
- (−) Kode root baru (dispatcher) — harus kecil, stdlib saja, dites (≥ 40 kasus negatif), di-review QA, diawasi auditd.
- (−) Hasil asinkron: CP butuh collector + watchdog (`no_result`).
- (−) Mengubah teks CLAUDE.md §3/§3.4 dan `nextjs-developer.md` (butuh persetujuan user).

## Security implications

- STRIDE lengkap: plan 05 §6. Sisa risiko yang diterima: CP tertembus bisa menjalankan job allowlist untuk tenant mana pun di env
  instance-nya (mis. cabut akses, disable SSO, undang email ke tenant bila `res.users` login sudah ada); tidak bisa membaca secret/DB,
  menghapus data, atau keluar dari allowlist. Deteksi: alert email untuk disable/rotate/remove dan setiap job yang ditolak.
- Dispatcher menjalankan skrip dengan environment bersih (skrip membaca `INFRA_DIR`, `KC_HOST`, `KC_SECRETS_DIR`, dll. dari env).
- PII (email) ada di log penuh host (root 0600, retensi 30 hari) dan payload job CP; journal dan `audit_logs` tanpa email.

## Rollback

`systemctl disable --now infra-job-{prod,staging}.path`; compose worker kembali dari git (tanpa mount, uid 1001); image CP lama
(migrasi additive); role Ansible `infra_jobs` state absent (unit, sbin, user; spool/log dipertahankan untuk audit).
