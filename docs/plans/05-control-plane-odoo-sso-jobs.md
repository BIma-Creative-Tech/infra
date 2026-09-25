# Plan 05 — Control plane memicu job Odoo/SSO (DB, route, SSO tenant, user SSO) lewat jembatan root `infra-job`

- **Status:** **EXECUTED (2026-09-25)** — J1–J7 selesai, hasil di §9 (AC-J13 NOT VERIFIED, AC-P1 sebagian; open items §9.4).
  Sebelumnya: APPROVED GATE 1 (user, 2026-09-25): semua rekomendasi — 1 opsi (a) spool+dispatcher + CLAUDE.md §3/§3.4 & nextjs-developer.md diperbarui, 2 iterasi 1 ops/superadmin saja, 3 subdomain platform saja, 4 res.users manual, 5 kuota 60 job/jam · 3 DB/hari · 30 user-job/jam · 5 rotasi/hari + alert
- **Tanggal:** 2026-09-25 · **Penulis:** Analyst (FASE 0/1, read-only)
- **ADR:** `docs/adr/0009-control-plane-job-bridge.md` (accepted)
- **Asal:** task S9 plan 04 (`docs/plans/04-odoo-sso-prod-multitenant.md` §3.4 "Kontrak control plane", §9.3 open item 2)
- **Terkait:** CLAUDE.md §0, §1, §3 (tabel "Docker API akses"), §3.4, §3.6, §3.7; ADR 0008; `docs/runbooks/odoo-sso-tenant.md`;
  `docs/03-operations/control-plane.md`; `.claude/agents/nextjs-developer.md` §Orkestrasi; repo `/opt/src/control-plane` (`main` = `0030d68`,
  image live `control-plane:4fc3828`).

## 0. Tujuan

Ops/superadmin (dan kelak client_admin untuk tenant-nya sendiri) menjalankan dari control plane (`cp.bimacreative.tech` /
`cp.staging.bimacreative.tech`) langkah runbook `odoo-sso-tenant.md` A–E — provision DB, render route, aktifkan/nonaktifkan SSO,
undang/cabut user SSO — sebagai **job antrean** yang tercatat di `provision_jobs` + `audit_logs`, **tanpa** control plane pernah
membaca secret, memegang Docker API, atau mendapat root. Skrip root yang sudah ada tetap satu-satunya pelaksana.

## 1. Scope

**IN**
1. Jembatan eksekusi host: dispatcher root-owned `/usr/local/sbin/infra-job` + unit systemd `.path`/`.service` per instance
   control plane (prod, staging), spool direktori, allowlist job + regex argumen, lock, timeout, hasil tanpa secret (ADR 0009).
2. Kontrak job (§4): `odoo_db_provision`, `odoo_route` (render/remove), `odoo_sso_provision` (+ `rotate_secret`), `odoo_sso_disable`,
   `odoo_sso_user` (grant/revoke/resend_invite), semuanya dengan mode `dry_run`.
3. Control plane: migrasi skema (enum job, kolom hasil, tabel `tenant_user_access`, status environment), worker "bridge"
   (tulis spool, kumpulkan hasil, watchdog), UI/Server Action minimal untuk ops/superadmin, audit, upsert `users` saat login.
4. Compose worker prod + staging: uid khusus + 2 bind mount (spool rw, hasil ro). Tidak ada network/port baru.
5. Backfill data CP untuk tenant yang sudah ada (`demo_demo` prod; `demo_staging`, `ssotest_staging` staging).
6. QA (fungsional + threat model §6) dan docs (ADR, ops, runbook, CLAUDE.md §3/§3.4 bila disetujui, CHANGELOG).

**OUT** (plan/fase lain)
- `suspend`/`resume`/`terminate`/`backup_now`/`restore` (enum sudah ada di skema; kontraknya menyusul — jembatan yang sama dipakai).
- Domain client sendiri (verifikasi TXT + route multi-host) → iterasi 1 hanya subdomain platform (Q3).
- Pembuatan `res.users` oleh skrip (Q4), self-service client_admin (Q2 → iterasi 2, desain otorisasinya tetap ditulis di §5.2).
- Undangan akun portal control plane (client role `control-plane`) untuk client_admin — manual/ops dulu.
- Website Next.js client (`provision-web-client.sh`) — kandidat job berikutnya setelah jembatan terbukti.
- GHCR/CI deploy control plane (tetap build lokal, `docs/03-operations/control-plane.md`).

## 2. Discovery (fakta 2026-09-25, perintah read-only)

| # | Fakta | Bukti | Implikasi |
|---|---|---|---|
| D1 | Worker `control-plane-worker` / `control-plane-staging-worker` hanya di network `db`; `user 1001:1001`, `read_only`, `cap_drop ALL`, tanpa mount host, tanpa socket. Web di `db`+`proxy`. | `web/control-plane/docker-compose.yml`, `staging/control-plane/docker-compose.yml`, `docker ps` | Tidak ada jalur ke host hari ini; jembatan harus ditambahkan. |
| D2 | **Tidak ada docker-socket-proxy yang berjalan** (hanya pernah untuk observability, dihapus H3). CLAUDE.md §3 tabel + §3.4 + `nextjs-developer.md` §Orkestrasi masih menyebut socket-proxy untuk control plane. | `docker ps -a \| grep sock` kosong; ADR 0001 riwayat H3; `observability.md` §Log | Desain baru menyimpang dari teks CLAUDE.md → butuh ADR 0009 + persetujuan user untuk edit CLAUDE.md/agent file. |
| D3 | **uid 1001 di container = user host `deploy`** (`deploy:x:1001`). | `getent passwd 1001` | File yang ditulis worker lewat bind mount akan milik `deploy` di host → `deploy` (CI) bisa ikut menyuntik job. Worker bridge harus uid khusus. |
| D4 | Pola root yang sudah ada: `deploy ALL=(root) NOPASSWD: /usr/local/sbin/infra-deploy` (wrapper root 755, regex whitelist, cek owner/perm, `logger`); unit systemd oneshot Ansible (`infra-healthcheck`, `restic-*`, `OnFailure=infra-unit-failure@%n`). | `/etc/sudoers.d/50-deploy-infra`, `/usr/local/sbin/infra-deploy`, `/etc/systemd/system/*.service`, role Ansible `users`, `healthcheck` | Dispatcher mengikuti pola yang sama (Ansible, root 755, validasi, logger, alert email). |
| D5 | systemd 255: `DirectoryNotEmpty=` (aktif selama dir berisi file, juga saat unit path diaktifkan) + `TriggerLimitIntervalSec/Burst`. | `man systemd.path` di host | Pemicu event-driven tanpa daemon/polling. File yang ditolak **harus** dipindah keluar inbox (kalau tidak → loop pemicu). |
| D6 | `fs.protected_hardlinks=1`, `protected_symlinks=1`, `protected_regular=2`; `/var/lib` dan `/opt` satu filesystem (`/dev/sda1`). | `sysctl`, `df` | Hardlink ke file root tidak bisa dibuat uid biasa; `rename` antar dir spool atomik (satu fs). |
| D7 | Skrip: semua wajib root, idempoten, `RESULT …` baris terakhir, exit ≠ 0 bila gagal, `--dry-run` (kecuali `provision-odoo-db.sh`, `render-client-route.sh`). Lock: `provision-odoo-db`/`provision-odoo-sso` `flock -n` `/run/lock/odoo-provision-<db>.lock`, `odoo-sso-user` `flock -w 60` lock yang sama, route `flock -n` `/run/lock/odoo-route-<slug>-<env>.lock`. | header skrip `scripts/*.sh` | Dispatcher cukup serial per instance; tabrakan lock = gagal cepat → status `failed` kode `locked`, boleh diulang. |
| D8 | Skrip membaca env opsional `INFRA_DIR`, `PG_CONTAINER`, `TRAEFIK_CONTAINER`, `KC_HOST`, `KC_ADMIN_PORT`, `KC_SECRETS_DIR`, `DRY`. | `scripts/lib/odoo-pools.sh`, `lib/keycloak-admin.sh`, `lib/odoo-exec.sh` | Dispatcher **wajib** menjalankan skrip dengan environment bersih (hanya `PATH`, `LANG`) — kalau tidak, pemanggil bisa membelokkan skrip ke direktori/host lain. |
| D9 | Validasi skrip: slug `^[a-z0-9-]{3,30}$`, env `prod|demo|staging`, FQDN regex, email `^[a-z0-9._%+-]+@…$` ≤ 254, login `^[A-Za-z0-9._@+-]{1,254}$`, nama `[[:alpha:]…]`. `odoo-sso-user.sh` menyisipkan `LOGIN`/`KC_UID` ke SQL/heredoc Python (aman karena regex tanpa kutip). | `scripts/lib/odoo-pools.sh`, `odoo-sso-user.sh` l.30–70, 187–220 | Dispatcher memvalidasi ulang dengan regex **sama atau lebih ketat** (pertahanan berlapis). Nama depan/belakang tidak dibawa di iterasi 1. |
| D10 | `odoo-sso-user.sh --create-kc` membuat user Keycloak + **mengirim undangan** sebelum menautkan `res.users`; bila `res.users` belum ada → exit ≠ 0 setelah undangan terkirim (setengah jadi, tetapi idempoten). | `odoo-sso-user.sh` l.115–160 vs l.187 | Dispatcher menjalankan **dry-run dulu** untuk `odoo_sso_user grant` & `odoo_sso_provision`; `blockers>0` → gagal tanpa mengubah apa pun. |
| D11 | Output skrip memuat email/login (baris `log`), path file secret (`secret_file=`, `secret=`), tidak memuat nilai secret; `RESULT` `odoo-sso-user` tanpa email. | header + `log` di skrip | Hasil ke CP: `RESULT` di-parse dengan allowlist kunci + `tail` terbatas + filter redaksi; log penuh hanya root di host. |
| D12 | `render-client-route.sh`: **satu host per tenant-env** (file `traefik/dynamic/clients/<slug>-<env>.yml`), DNS pre-check A = `31.97.50.221` tanpa AAAA, host unik antar file. | `render-client-route.sh`, `templates/traefik-client.yml` | Host SSO iterasi 1 = host route tenant itu; dispatcher mengambil/mencocokkan host dari file route (bukan percaya CP). |
| D13 | Waktu nyata `provision-odoo-sso.sh ssotest staging --dry-run` = **3,1 s**, `changed=0 blockers=0`. Durasi apply (install modul, `odoo -i base`) **belum diukur** di sesi ini. | `time …` | Timeout awal konservatif (§4.4), diukur ulang di J4. |
| D14 | CP: pg-boss 12.33.6 (`retryLimit`, `expireInSeconds` ada di `types.d.ts`), enum `job_type` {noop, provision, suspend, resume, terminate, backup_now, restore}, `job_status` {queued, running, succeeded, failed, cancelled}; `provision_jobs` (payload jsonb, log, actor, attempts, error); `audit_logs`; `environments(client_id, kind, odoo_instance, db_name, url)` unik `(client_id, kind)`. Worker hanya `noop`. | `src/db/schema.ts`, `src/worker/*.ts`, `node_modules/pg-boss/dist/types.d.ts` | Migrasi additive saja (rollback image aman, `control-plane.md` §Rollback). |
| D15 | CP otorisasi: role dari klaim `resource_access.control-plane.roles`; izin `jobs:enqueue` = superadmin, ops. **Sesi tidak membawa `client_id`**, tabel `users` tidak pernah diisi (0 baris), semua tabel CP kosong di prod & staging. | `src/lib/roles.ts`, `src/auth.ts`, `psql -d control_plane(_staging)` count | client_admin belum bisa dibatasi ke client-nya → butuh upsert `users` saat login + binding user↔client sebelum self-service (Q2). |
| D16 | Memori terukur: `control-plane-worker` 20 MiB / 256m, staging worker 23 MiB / 128m; host available ±11,5 GiB. | `docker stats --no-stream`, `free -m` | Kapasitas tidak jadi pembatas (§8). |

## 3. Keputusan 1 — Jembatan eksekusi worker → skrip root

### 3.1 Opsi

| Opsi | Mekanisme | Apa yang bisa dilakukan control plane yang **tertembus** (web, worker, atau DB `control_plane`) | Kelebihan | Kekurangan |
|---|---|---|---|---|
| **(a) Spool + systemd path + dispatcher root** *(rekomendasi)* | Worker menulis file JSON job ke spool bind-mount; `infra-job-<inst>.path` (`DirectoryNotEmpty=`) memicu `infra-job@<inst>.service` (oneshot root) → `/usr/local/sbin/infra-job <inst>` memvalidasi (allowlist tipe, skema ketat, regex, binding instance→env, kuota) lalu `exec` skrip dengan argv tetap + env bersih; hasil JSON ke dir hasil (ro bagi worker). | Hanya menjalankan **tipe job yang di-allowlist** dengan argumen yang lolos regex, untuk env instance-nya saja (staging CP tidak bisa menyentuh prod), dalam batas kuota. Tidak bisa: shell, path, skrip lain, env var, DROP, membaca secret/log root. | Tidak ada kredensial baru di CP; tidak ada port/daemon jaringan; event-driven; pola sama dengan `infra-deploy`/unit Ansible; mudah dimatikan (`systemctl stop …path`). | Dispatcher = kode root baru (harus kecil + dites); izin/uid spool harus tepat (D3); hasil asinkron (collector). |
| (b) SSH forced-command | Worker punya private key; `ssh -p 2221 cpjob@<gw>` → `command="sudo /usr/local/sbin/infra-job"` di `authorized_keys` + sudoers. | Sama dengan (a) **plus** memegang private key (secret di CP), bisa memakai sshd sebagai permukaan (brute/DoS, CVE sshd), dan kunci bisa dibawa keluar bila ada egress (web punya egress via `proxy`). | Pola SSH sudah dikenal; sinkron (stdout langsung). | Worker butuh network ke host:2221 (sekarang `db` saja) + aturan ufw/sshd `Match` baru; fail2ban bisa mem-ban gateway docker; secret baru di CP; validasi argumen tetap sama beratnya. |
| (c) docker-socket-proxy exec / runner container | `tecnativa/docker-socket-proxy` dengan `CONTAINERS=1 POST=1 EXEC=1` (atau create container runner). | Proxy memfilter per **seksi API**, bukan per container/perintah → `docker exec` ke `postgres` (superuser), `keycloak`, pool Odoo; `POST /containers/create` dengan bind `/:/host` atau `privileged` → **root host**. | Sesuai teks lama CLAUDE.md §3.4. | **Ditolak**: setara grup `docker` = root (CLAUDE.md §3.7 threat model E; alasan yang sama dengan H3 observability). |
| (d) Host menarik dari DB (poller root) | Timer root tiap N detik membaca `provision_jobs` (role PG khusus, GRANT kolom) lalu menjalankan dispatcher yang sama; hasil ditulis balik ke DB. | Sama dengan (a) (data job tetap dikendalikan CP). | Tanpa bind mount; tanpa perubahan uid worker. | Root host memegang kredensial DB + butuh jalur host→Postgres (port tidak dipublish; `docker exec postgres psql` = superuser, atau pg_hba baru); polling (latensi/noise journal); root mem-parse baris DB. Cadangan bila (a) ditolak. |
| (e) Runner container root konsumen pg-boss dengan `docker.sock` | Container terpisah (bukan CP) memegang socket, konsumsi antrean. | Data job dari CP diproses oleh komponen yang **memegang root host** (socket) dan berada di network `db` → permukaan lebih besar dari (a). | Tidak ada unit host. | Socket di container jaringan; tidak lebih aman dari (a). Ditolak. |

**Rekomendasi: (a).** Batas keamanan sesungguhnya adalah dispatcher (bukan worker): apa pun yang terjadi di CP, yang sampai ke root
hanya "tipe job X dengan argumen tervalidasi untuk env instance ini". Detail desain di ADR 0009; ringkasnya:

### 3.2 Desain (a) — tata letak host (pseudo-config, final oleh infra-engineer)

```
/var/lib/infra-jobs/<inst>/            root:root 0755          inst ∈ {prod, staging}
  spool/                               root:cpjob-<inst> 0730  → bind mount rw ke worker: /jobs/spool
    tmp/                               cpjob-<inst> 0700       worker menulis .json di sini dulu
    new/                               cpjob-<inst> 0730       worker rename tmp/<id>.json → new/<id>.json (atomik, satu mount)
  work/                                root 0700               dispatcher rename new/<id>.json → work/ (sebelum dibaca)
  rejected/                            root 0700               file tidak valid (alert email)
  results/                             root:cpjob-<inst> 0750  → bind mount ro ke worker: /jobs/results; file 0640
/var/log/infra-jobs/<inst>/<id>.log    root 0600               stdout+stderr penuh (PII email) — retensi 30 hari
/etc/systemd/system/infra-job-<inst>.path     DirectoryNotEmpty=/var/lib/infra-jobs/<inst>/spool/new
/etc/systemd/system/infra-job@.service        Type=oneshot, ExecStart=/usr/local/sbin/infra-job %i, OnFailure=infra-unit-failure@%n
/usr/local/sbin/infra-job              root 0755, Python 3 stdlib (host python3 3.12.3), dikelola Ansible role baru `infra_jobs`
```
- User host `cpjob-prod` / `cpjob-staging`: system user, `nologin`, tanpa home, tanpa grup lain, uid tetap (dipilih infra-engineer,
  dicek bebas dengan `getent passwd`). Worker prod/staging berjalan sebagai uid masing-masing (`user:` di compose; file app di image
  milik root & world-readable — Dockerfile `COPY --chown=root:root`; J3 memverifikasi worker start dengan uid baru). **Web tidak
  mendapat mount** (dan tetap uid 1001).
- Dispatcher per file: `rename` ke `work/` → `open(O_NOFOLLOW)` → `fstat`: file reguler, `st_uid` = uid `cpjob-<inst>`, `st_nlink`=1,
  ukuran ≤ 8 KiB → JSON ketat (kunci tak dikenal = tolak) → validasi §4 → cek kuota → tulis `results/<id>.json` `state=running` →
  jalankan skrip dengan `subprocess` argv list (tanpa shell), `env={"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C.UTF-8"}`,
  `cwd=/opt/infra`, `stdin=DEVNULL`, grup proses sendiri, timeout per tipe → tulis hasil final atomik (tmp + rename) → hapus `work/<id>`.
- Serial per instance (`flock /run/lock/infra-job-<inst>.lock` di dispatcher); prod dan staging boleh paralel (pool berbeda).
- Kill switch: `systemctl disable --now infra-job-<inst>.path` atau file `/etc/infra-jobs/<inst>.disabled` (dispatcher menolak semua
  job dengan `error_code=disabled`).
- Jejak host (non-repudiation): `logger -t infra-job` satu baris per job **tanpa email** (`inst id type slug env actor exit dur sha256(payload)`),
  log penuh di `/var/log/infra-jobs`. auditd sudah ada (role `auditd`) — tambah watch `-w /usr/local/sbin/infra-job -p wa`.

## 4. Keputusan 2 — Kontrak job

### 4.1 Format file job (worker → dispatcher)

```json
{"v":1,"job_id":"<uuid>","type":"odoo_sso_user","slug":"acme-co","env":"prod","dry_run":false,
 "actor":"user:<keycloak sub>","requested_at":"2026-09-25T10:00:00Z","args":{"action":"grant","email":"a@b.co","admin":false}}
```
Umum: `v`=1; `job_id` = id `provision_jobs` (uuid, juga nama file); `type` ∈ allowlist; `slug` `^[a-z0-9-]{3,30}$`; `env` ∈ env
instance (**prod-inst → {prod, demo}; staging-inst → {staging}**); `dry_run` bool; `actor` `^(user|system):[A-Za-z0-9._@:-]{1,128}$`
(hanya untuk log host); `args` per tipe, `additionalProperties=false`. Tidak ada field path, perintah, env var, atau nama DB — nama
DB selalu diturunkan skrip dari slug+env.

### 4.2 Tipe job → skrip (argv tetap)

| `type` | `args` (tervalidasi) | argv yang dijalankan | Role CP (iterasi 1) | Dry-run dulu? |
|---|---|---|---|---|
| `odoo_db_provision` | `host?` (wajib untuk `demo`) | `scripts/provision-odoo-db.sh <slug> <env> [--host <h>]` | superadmin, ops | — (skrip tanpa `--dry-run`; `dry_run=true` ditolak) |
| `odoo_route` | `host?`, `remove` bool | `scripts/render-client-route.sh <slug> <env> [--host <h>]` / `… --remove` | superadmin, ops (`remove`: superadmin) | — (skrip tanpa `--dry-run`) |
| `odoo_sso_provision` | `hosts[]` 1..5, `rotate_secret` bool, `skip_smoke` bool | `scripts/provision-odoo-sso.sh <slug> <env> --host <h>… [--rotate-secret] [--skip-smoke]` | superadmin, ops (`rotate_secret`: superadmin) | ya: `blockers>0` → gagal tanpa apply |
| `odoo_sso_disable` | `hosts[]` 1..5 | `scripts/provision-odoo-sso.sh <slug> <env> --host <h>… --disable` | superadmin | ya |
| `odoo_sso_user` | `action` grant\|revoke\|resend_invite, `email`, `login?`, `admin` bool, `create_kc` bool (grant) | `scripts/odoo-sso-user.sh <slug> <env> --email <e> [--login <l>] [--create-kc] [--admin] --grant\|--revoke\|--resend-invite` | superadmin, ops (iterasi 2: client_admin untuk client sendiri, §5.2) | ya untuk grant |

Aturan host (iterasi 1, Q3): FQDN regex skrip; prod/demo `^[a-z0-9-]{1,63}\.erp\.bimacreative\.tech$`, staging
`^[a-z0-9-]{1,63}\.staging\.bimacreative\.tech$`. Untuk `odoo_sso_*`: setiap `hosts[]` **harus** sudah ada sebagai `Host(\`…\`)`
di file route tenant itu (`traefik/dynamic/clients/<slug>-<env>.yml`, root-owned) — kecuali `skip_smoke=true` (onboarding sebelum route,
runbook A2) yang hanya diizinkan untuk host default `<slug>.<erp|staging>.bimacreative.tech`. Mencegah CP tertembus menambah redirect
URI ke host asing. Email: regex skrip, huruf kecil, ≤ 254; login: regex skrip; field nama tidak didukung (user mengisi saat login pertama).

### 4.3 Status & transisi

```
queued ──(worker tulis spool)──▶ dispatched ──(results state=running)──▶ running ──▶ succeeded | failed
   │                                   │                                              ▲
   └─▶ cancelled (hanya sebelum spool) └──(tidak ada hasil > deadline)──▶ failed(error_code=no_result)
```
- `error_code` (baru): `rejected_validation`, `rejected_quota`, `disabled`, `blocked_dry_run`, `locked`, `timeout_state_unknown`,
  `script_exit`, `no_result`. `rejected_*` → alert email (indikasi bug/kompromi).
- `succeeded` = exit 0 **dan** baris `RESULT` terbaca. Exit 0 tanpa `RESULT` = `failed`.

### 4.4 Idempotensi, konkurensi, timeout, retry

- **Idempotensi:** skrip idempoten; dispatcher menolak `job_id` yang sudah punya hasil final (`results/` atau ledger `work/done.log`
  7 hari) → tidak dieksekusi dua kali walau worker menulis ulang file.
- **Konkurensi:** (1) CP: unique partial index satu job aktif (`queued|dispatched|running`) per `(environment_id, type)` →
  tombol ganda tidak menghasilkan dua job; (2) dispatcher serial per instance; (3) lock skrip per DB/route (D7).
- **Timeout awal (estimasi, diukur ulang di J4):** `odoo_db_provision` 900 s, `odoo_sso_provision` 300 s (+dry-run 60 s),
  `odoo_sso_user` 180 s, `odoo_sso_disable` 120 s, `odoo_route` 60 s. Timeout → SIGTERM grup proses, 30 s → SIGKILL, status
  `failed` `timeout_state_unknown`. **Perlu diverifikasi di staging (AC-J8):** apakah proses di dalam container (`docker exec … odoo`)
  ikut berhenti ketika klien `docker exec` di-kill — asumsi aman: **tidak**, sehingga ulangi hanya setelah dry-run/cek manual.
- **Retry:** tidak ada retry otomatis (pg-boss `retryLimit: 0` untuk antrean bridge). "Ulangi" di UI = job baru dengan
  `parent_job_id`; boleh langsung untuk `locked`/`blocked_dry_run`; `timeout_state_unknown` hanya superadmin.
- **Kuota dispatcher (per instance, Q5):** total 60 job/jam; `odoo_db_provision` 3/hari; `odoo_sso_user` 30/jam;
  `rotate_secret` 5/hari. Melebihi → `rejected_quota` + alert.

### 4.5 Hasil (dispatcher → worker)

`results/<id>.json` (0640 root:cpjob-<inst>):
```json
{"v":1,"job_id":"…","state":"succeeded","exit_code":0,"error_code":null,"started_at":"…","finished_at":"…","duration_ms":8123,
 "result":{"db":"acme_co_prod","realm":"platform","client":"odoo-acme-co-prod","provider":"7","hosts":"acme-co.erp.bimacreative.tech","changed":"3"},
 "tail":["[acme_co_prod] …", "…"]}
```
- `result` = baris `RESULT` terakhir di-parse `k=v`, **allowlist kunci** (`db realm client provider hosts changed kc_user odoo_user
  action mode blockers route host created pool`) dan nilai `^[A-Za-z0-9._,:@/=-]{0,512}$`; kunci `secret`, `secret_file` dibuang (path
  file secret tidak perlu di CP).
- `tail` = ≤ 40 baris terakhir stdout+stderr, ≤ 8 KiB, baris yang cocok `(?i)(secret|token|password|passwd|bearer|authorization)`
  diganti `[redacted]` (skrip tidak mencetak secret — ini pertahanan berlapis). Email boleh muncul (sudah dimiliki CP untuk job itu).
- Dispatcher memangkas `results/` > 7 hari; log penuh hanya di host (root).

## 5. Keputusan 3 — UI/API & otorisasi

### 5.1 Iterasi 1 (rekomendasi): ops/superadmin saja

- Halaman **Client → Environment** (baru): daftar environment client + status (`db`, `route`, `sso`), tombol aksi per status:
  "Provision DB" → "Render route" → "Aktifkan SSO" (dry-run dulu otomatis) → "Nonaktifkan SSO" / "Rotasi secret" (superadmin,
  dialog konfirmasi ketik slug).
- Tab **Pengguna SSO** per environment: daftar `tenant_user_access`, form undang (email, login Odoo opsional, admin tenant/TOTP),
  cabut, kirim ulang undangan. Pesan hasil generik (tidak membedakan "email sudah ada di realm" ke non-ops — anti enumerasi, relevan iterasi 2).
- Halaman **Jobs**: daftar `provision_jobs` (filter client/status/tipe), detail (payload tanpa email untuk non-superadmin? — tidak perlu
  di iterasi 1, semua ops), `result`, `tail`, tombol "Ulangi" (§4.4).
- Mutasi = **Server Action** (bukan route `/api/*` — sesuai pengecualian WAF H6 `controlplane-crs-exclusions`; body JSON), Zod
  `.strict()` dengan regex yang sama dengan dispatcher (satu modul `src/lib/job-contract.ts`), `requirePermission` baru:
  `jobs:odoo` (superadmin, ops), `jobs:odoo_admin` (superadmin: `remove`, `disable`, `rotate_secret`, ulang `timeout_state_unknown`).
- Setiap enqueue: `audit_logs` (`action=job.enqueue.<type>`, actor, client_id, target environment, ip, request id, metadata tanpa
  email → `email_hash`), dan saat final: `action=job.finish` (actor `system:worker`, state, error_code).

### 5.2 Iterasi 2 (desain saja, tidak diimplementasi di plan ini): client_admin

- Prasyarat: upsert `users` saat login (J2 sudah mengisi: `keycloak_sub`, email, role cache, `last_login_at`) + superadmin mengikat
  `users.client_id` (UI kecil). Otorisasi dari DB, bukan klaim: `session.sub → users.client_id` **=** `environments.client_id`.
- Hanya `odoo_sso_user` grant/revoke/resend untuk environment client sendiri, env `prod`/`demo`; `create_kc` selalu true; tidak bisa
  menautkan `base.user_admin` (skrip sudah menolak); kuota per client (mis. 20 undangan/hari, `plans.max_users`); IDOR diuji QA.

## 6. Threat model (STRIDE) — opsi (a)

| STRIDE | Ancaman | Mitigasi (wajib) | Verifikasi QA |
|---|---|---|---|
| S | Proses lain (mis. user `deploy`, uid 1001) menaruh file job | uid khusus `cpjob-<inst>`; dispatcher cek `st_uid`, dir `new/` 0730 root:cpjob; `deploy` bukan anggota grup | `sudo -u deploy touch /var/lib/infra-jobs/prod/spool/new/x` → Permission denied; file milik uid lain → `rejected_validation` |
| S | Staging CP (lebih lemah) memicu job prod | Binding instance→env di dispatcher (hard-coded, bukan dari file); mount terpisah | file job `env=prod` di spool staging → `rejected_validation` |
| T | Injeksi argumen/opsi (`--host=…`, `-x`, spasi, `$()`, newline, unicode) | Skema ketat + regex `fullmatch`; argv list tanpa shell; nilai tidak boleh diawali `-` (regex sudah) | matriks negatif unit test dispatcher + 1 E2E per tipe |
| T | Symlink/hardlink/TOCTOU di spool | `rename` ke `work/` root 0700 lalu `O_NOFOLLOW`+`fstat`, `st_nlink=1`; `protected_hardlinks=1` | symlink ke `/etc/shadow`, hardlink, FIFO → ditolak, tidak dibaca |
| T | Env var membelokkan skrip (`INFRA_DIR`, `KC_HOST`, …) | `env` bersih di `subprocess` | unit test: env dispatcher tidak diteruskan (`/proc/<pid>/environ` skrip uji) |
| T | Host asing di redirect URI Keycloak | `hosts[]` ⊆ Host di file route root-owned tenant itu (§4.2) | `hosts=["evil.example"]` → rejected; redirectUris client tidak berubah |
| R | Siapa memicu apa | `audit_logs` (CP) + `logger -t infra-job` (host, hash payload) + log penuh root; event admin Keycloak ON | cocokkan job_id di CP ↔ `journalctl -t infra-job` |
| I | Secret/PII bocor ke CP/UI | Skrip tak mencetak secret; parse `RESULT` allowlist; buang `secret*`; redaksi `tail`; log penuh root 0600; journal tanpa email | grep hasil job & `provision_jobs.log` untuk isi file secret (hash) → 0 kecocokan |
| I | Worker membaca hasil instance lain / file host | Mount hanya `results/` instance sendiri, ro | `docker exec control-plane-staging-worker ls /jobs` hanya spool+results staging |
| D | Banjir job / DB baru tanpa batas (disk, RAM pool) | Kuota §4.4, ukuran file ≤ 8 KiB, maks 100 file per run, `TriggerLimit*`, serial per instance | 70 job dalam 1 jam → ke-61 `rejected_quota` + alert |
| D | Job macet mengunci antrean | Timeout per tipe + watchdog CP `no_result` | skrip uji `sleep` (hanya di unit test) → `timeout_state_unknown` |
| E | Eskalasi ke root lewat dispatcher | Dispatcher kecil, stdlib saja, root 0755, Ansible, auditd watch, code review QA + Semgrep/bandit | review + `stat -c '%U %a' /usr/local/sbin/infra-job` = `root 755` |
| E | client_admin → tenant lain (iterasi 2) | otorisasi dari `users.client_id` DB, bukan input form | IDOR test (iterasi 2) |

Sisa risiko yang diterima: CP tertembus (termasuk web) **dapat** menjalankan job yang di-allowlist untuk tenant mana pun di env
instance-nya — mis. mencabut akses user, menonaktifkan SSO tenant (superadmin-only di UI, tetapi dispatcher tidak tahu role), atau
mengundang email penyerang ke tenant (grant + create_kc), tetapi tautan `res.users` hanya ke login yang **sudah ada**; tidak bisa membaca
secret, DB tenant, atau menghapus data. Mitigasi deteksi: alert email untuk setiap `odoo_sso_disable`, `rotate_secret`, `odoo_route remove`
dan semua `rejected_*` (dispatcher → `scripts/lib/infra_alert_mail.py`).

## 7. Keputusan 4 — Model data (migrasi Drizzle, additive)

| Perubahan | Detail |
|---|---|
| enum `job_type` + nilai | `odoo_db_provision`, `odoo_route`, `odoo_sso_provision`, `odoo_sso_disable`, `odoo_sso_user` (`ALTER TYPE … ADD VALUE`; nilai lama tetap) |
| enum `job_status` + nilai | `dispatched` |
| `provision_jobs` kolom baru | `environment_id` uuid FK (set null), `env` `environment_kind`, `dry_run` bool, `exit_code` int, `error_code` text (CHECK daftar §4.3), `result` jsonb, `parent_job_id` uuid FK self, `dispatched_at`, `deadline_at`; partial unique index `(environment_id, type) WHERE status IN ('queued','dispatched','running')` |
| `environments` kolom baru | `host` text (FQDN route, CHECK regex), `db_status` enum `absent|provisioned`, `route_status` `absent|active|removed`, `sso_status` `none|active|disabled`, `sso_client_id` text, `sso_provider_id` int, `last_job_id` uuid — diisi **dari hasil job** (bukan input), CHECK `db_name` = turunan slug+kind di app (Zod) |
| tabel baru `tenant_user_access` | `id`, `environment_id` FK, `email` (lower, CHECK regex skrip, ≤ 254), `odoo_login` (CHECK regex skrip), `is_tenant_admin` bool, `status` enum `pending|active|revoked|failed`, `kc_user_id` uuid (dari `RESULT kc_user`), `odoo_user_id` int (dari `RESULT odoo_user`), `invited_by` FK users, `last_job_id`, timestamps; unique `(environment_id, email)`, index email |
| `users` | tidak berubah skemanya; **mulai diisi** saat login (upsert by `keycloak_sub`) — prasyarat audit `actor_user_id` dan iterasi 2 |

Di mana email/role user tenant hidup: **sumber kebenaran akses** tetap Keycloak (role `odoo_access` pada client tenant) + Odoo
(tautan `oauth_uid`); `tenant_user_access` = *desired state* + cache hasil job, direkonsiliasi dari `RESULT`. Role bisnis Odoo (grup
akses `res.users`) **tidak** dikelola CP di plan ini. Email = PII: hanya di `tenant_user_access`, `provision_jobs.payload` (perlu untuk
dispatch) dan log host root (retensi 30 hari); `audit_logs.metadata` memakai hash.

## 8. Keputusan 5 — Acceptance criteria, task, rollout, kapasitas

### 8.1 Acceptance criteria (dijalankan di staging dulu; prod subset AC-P*)

```
AC-J1  stat -c '%U %G %a' /usr/local/sbin/infra-job /var/lib/infra-jobs/{prod,staging}/spool/new → root root 755 / root cpjob-<inst> 730
AC-J2  systemctl is-enabled infra-job-prod.path infra-job-staging.path → enabled; systemctl is-active … → active
AC-J3  python3 -m unittest (tests dispatcher, di repo infra) → OK; matriks negatif ≥ 40 kasus (tipe, kunci ekstra, regex, env lintas
       instance, symlink, hardlink, FIFO, >8 KiB, uid salah, job_id duplikat, kuota, disabled)
AC-J4  docker exec control-plane-staging-worker id -u → uid cpjob-staging; ls /jobs → spool results; touch /jobs/results/x → Read-only
AC-J5  sudo -u deploy touch /var/lib/infra-jobs/staging/spool/new/x → Permission denied
AC-J6  UI staging (ops): tenant uji `cpjob` staging: Provision DB → Render route → Aktifkan SSO → status succeeded; RESULT changed>0;
       ulangi Aktifkan SSO → changed=0 (idempoten); provision-odoo-sso.sh cpjob staging --dry-run (root) → blockers=0 changed=0
AC-J7  UI: undang user uji (res.users dibuat dulu di Odoo) → succeeded, tenant_user_access.status=active, kc_user/odoo_user terisi;
       login SSO E2E berhasil; cabut → login ditolak oauth_error=2; undang login yang tidak ada → failed blocked_dry_run, **tanpa**
       user Keycloak baru / email undangan (cek Admin REST users?username=…)
AC-J8  job dengan timeout uji kecil (hanya staging, override konfigurasi) → failed timeout_state_unknown; catat apakah proses odoo di
       container masih hidup (docker top odoo-staging) → hasil dicatat di ADR 0009
AC-J9  file job env=prod di spool staging → rejected_validation + email alert; tidak ada eksekusi (journalctl -t infra-job)
AC-J10 grep nilai secret (sha256 file secret oidc vs isi provision_jobs.log/result/tail, /var/log/infra-jobs) → 0 kecocokan pada
       provision_jobs; audit_logs memuat job.enqueue.* dan job.finish untuk setiap job
AC-J11 double-click (2 enqueue paralel sama environment+type) → 1 job dibuat, 1 ditolak (unique index)
AC-J12 non-ops (client_admin/client_user uji) → /clients/* dan Server Action job → forbidden (403/redirect), tidak ada baris job
AC-J13 CI control-plane: lint, typecheck, vitest (skema Zod job-contract = regex dispatcher, fixture bersama), Semgrep, Trivy image
       tanpa CRITICAL/HIGH baru; Semgrep python pada infra-job
AC-P1  prod: backfill client demo + environment demo (db demo_demo, host demo.erp…); job odoo_sso_provision dry_run → succeeded
       blockers=0 changed=0; odoo_sso_user grant user uji → login E2E demo.erp → revoke → user uji dihapus (pola QA S7)
AC-P2  prod: tidak ada restart odoo-pool-a/traefik/keycloak (docker inspect StartedAt tidak berubah); cp.bimacreative.tech 307 → /login
```

### 8.2 Task & dependency

| ID | Task | Agent | depends_on | File/dir disentuh | Paralel dengan |
|---|---|---|---|---|---|
| J1 | Dispatcher `infra-job` (Python stdlib) + unit test + role Ansible `infra_jobs` (user cpjob-*, dir, unit path/service, tmpfiles/logrotate, auditd watch, alert) — **tidak di-apply** | infra-engineer | GATE 1 | `ansible/roles/infra_jobs/**`, `ansible/site.yml` (role + tag `infra_jobs`), `ansible/roles/auditd/templates/50-infra.rules.j2` (watch), `scripts/infra-job/` (sumber + tests), `docs/03-operations/infra-jobs.md` (draft) | J2 |
| J2 | Migrasi skema §7, `src/lib/job-contract.ts` (Zod = regex dispatcher; fixture JSON bersama dari J1), worker bridge (spool writer, collector outbox, watchdog, `retryLimit:0`), upsert `users`, UI §5.1, audit, test | nextjs-developer | GATE 1 (fixture kontrak dari J1 boleh menyusul, disepakati di §4) | repo `control-plane` (`src/**`, `drizzle/**`, `tests/**`) | J1 |
| J3 | Compose worker prod+staging: `user: <uid cpjob>`, tmpfs uid, 2 bind mount, env `JOBS_DIR=/jobs`; tag image baru | infra-engineer | J1 (uid), J2 (tag image) | `web/control-plane/docker-compose.yml`, `staging/control-plane/docker-compose.yml` | — |
| J4 | Live staging: `ansible-playbook --tags infra_jobs` (check → apply), build image, `docker compose up -d` staging CP, backfill staging (demo, ssotest), ukur durasi job nyata, AC-J1..J9 fungsional | Lead + infra-engineer | J1, J2, J3 | host `/var/lib/infra-jobs`, `/etc/systemd/system`, DB `control_plane_staging` | — |
| J5 | QA staging: AC-J1..J13 + STRIDE §6 (termasuk file jahat di spool, IDOR role, redaksi) | qa-security | J4 | `docs/qa/2026-09-XX-plan05-staging.md` | — |
| J6 | Live prod: compose prod CP (tag sama), path unit prod aktif, backfill demo, AC-P1/P2 | Lead + infra-engineer | J5 PASS | `web/control-plane/docker-compose.yml`, DB `control_plane` | — |
| J7 | Docs: ADR 0009 accepted + hasil, `control-plane.md`, `infra-jobs.md`, runbook `odoo-sso-tenant.md` (jalur CP), CLAUDE.md §3 tabel + §3.4 + `nextjs-developer.md` §Orkestrasi (bila Q1 disetujui), CHANGELOG, tag control-plane | docs-versioning | J6 | `docs/**`, `CLAUDE.md`, `.claude/agents/nextjs-developer.md`, `CHANGELOG.md` | draft paralel J5 |

Gelombang: [J1 ‖ J2] → J3 → J4 → J5 → J6 → J7.

### 8.3 Rollout, downtime, rollback

- **Rollout:** staging dulu (instance `staging` saja aktif), prod setelah QA PASS. Path unit prod baru di-enable di J6.
- **Downtime:** tenant Odoo **nol** (tidak ada recreate pool/Traefik/Keycloak; route job hanya HUP Traefik saat dijalankan).
  Control plane: recreate web+worker saat ganti image ± 5–10 s per instance (`control-plane.md`).
- **Rollback:** (1) matikan jembatan: `systemctl disable --now infra-job-<inst>.path` (job CP tertahan `dispatched` → `no_result`);
  (2) image CP lama: `CONTROL_PLANE_TAG=4fc3828 docker compose up -d` — aman karena migrasi additive (kolom/enum baru diabaikan kode
  lama); (3) compose worker kembali dari git (hapus mount/uid); (4) Ansible: role `infra_jobs` state absent (unit, sbin, user; dir
  `/var/lib/infra-jobs` + log dipertahankan untuk audit). Perubahan tenant yang dibuat job di-rollback per runbook `odoo-sso-tenant.md`
  (C/E) — sama seperti operasi manual.

### 8.4 Kapasitas

| Komponen | RAM | Disk | Catatan |
|---|---|---|---|
| Dispatcher Python (saat job) | ±20–30 MiB transien (estimasi) | — | proses oneshot, tidak resident |
| Beban skrip | sama dengan runbook manual: one-off `odoo`/`odoo shell` di dalam container pool (dalam `mem_limit` pool) | — | serial per instance membatasi one-off bersamaan |
| Worker CP | tidak berubah (±20–23 MiB terukur) | — | collector interval 5 s |
| Spool/hasil/log | — | < 10 KiB per job; 30 hari × ≤ 60 job/jam ≪ 100 MiB | tmpfiles.d/logrotate |
| DB `control_plane` | — | trivial | |

Tidak ada container baru; anggaran ADR 0004 tidak berubah.

## 9. Pertanyaan GATE 1 (untuk user)

1. **Jembatan = opsi (a) spool + systemd path + dispatcher root `infra-job`**, dan teks CLAUDE.md §3 (baris "Docker API akses:
   docker-socket-proxy — hanya control-plane") + §3.4 + `nextjs-developer.md` diubah menjadi "control plane tanpa akses Docker API;
   orkestrasi lewat `infra-job` (ADR 0009)"? — **Rekomendasi: ya.** (Cadangan: (d) poller DB.)
2. **Iterasi 1 hanya ops/superadmin**; client_admin mengundang/mencabut user tenant sendiri di iterasi 2 (setelah binding user↔client
   dan kuota)? — **Rekomendasi: ya.**
3. **Host iterasi 1 hanya subdomain platform** (`*.erp.bimacreative.tech`, `*.staging.bimacreative.tech`); domain client sendiri tetap
   lewat runbook manual sampai alur verifikasi TXT + route multi-host dirancang? — **Rekomendasi: ya.**
4. **`res.users` tetap dibuat manual** (admin tenant/ops di Odoo) sebelum undangan; CP menampilkan blocker "login belum ada"? Alternatif:
   perluas `odoo-sso-user.sh --create-odoo-user` (grup "Internal User" minimal). — **Rekomendasi: manual dulu**, perluasan skrip
   sebagai plan kecil berikutnya bila ops merasa lambat.
5. **Kuota dispatcher per instance**: 60 job/jam, `odoo_db_provision` 3/hari, `odoo_sso_user` 30/jam, `rotate_secret` 5/hari; lewat
   batas → ditolak + email alert; alert juga untuk setiap disable/rotate/remove. — **Rekomendasi: setujui angka ini** (bisa dinaikkan
   lewat konfigurasi root tanpa ubah CP).

## 9. Hasil eksekusi (2026-09-25)

Sumber: git log `main` infra sejak `2317d19` (s.d. `682e32b`), repo control-plane `main` `0030d68` → `6d94d2b`, QA
`docs/qa/2026-09-25-plan05-staging.md` (J5 + regresi J5R), fakta Lead (J4/J6), cek read-only J7. Waktu WIB kecuali disebut UTC.

### 9.1 Task

| ID | Hasil | Commit / bukti |
|---|---|---|
| J1 | Dispatcher `/usr/local/sbin/infra-job` 1.0.0 (Python stdlib) + 233 test; role Ansible `infra_jobs` (user `cpjob-prod` 950 / `cpjob-staging` 951, spool/results/log, `infra-job@.service` hardened, `infra-job-<inst>.path`, tmpfiles, conf kuota/timeout, kill switch, `state=absent`); watch auditd; draft `infra-jobs.md` | infra `8340a4d`, `c63201b`, `1bcfe0a`, merge `ad4143f` |
| J2 | CP: migrasi `0001` (additive), `src/lib/job-contract.ts`, worker bridge (spool writer, collector, watchdog, pg-boss `retryLimit 0`), UI `/clients/<slug>`, `/environments/<id>`, `/jobs`, audit, upsert `users`; J2b menyelaraskan regex dengan dispatcher + `spool_error` (migrasi `0002`) | CP `a727ddc`, `1c61472`, `013de24`, `7b85a78` |
| J3/J4 | Staging: role `infra_jobs`+`auditd` diterapkan ±13:00 (run ulang idempoten; path staging enabled, prod disabled); compose worker uid 951 + spool rw/results ro; CP staging `7b85a78` (migrasi 0001/0002); E2E dry-run `ssotest` via spool → succeeded | infra `84f8246`; backup `control_plane_staging-20260925-130346-pre-7b85a78.dump` |
| J5 | QA staging: AC-J1..J12 PASS, 52 negatif live ditolak; BUG-J5-01 (High), BUG-J5-02 (Medium), OBS-J5-01/02 | `f96df2f`, merge `5fff6c6` |
| J5 fix | BUG-J5-01 skrip (`--resend-invite` aksi tersendiri) + CP; BUG-J5-02 CP; OBS-J5-01 `RESULT invite=`; OBS-J5-02 Origin asing → 403; migrasi `0003` (`inconsistent`, `result_inconsistent`); staging CP `6d94d2b` | infra `3ca5501`/merge `7611e5e`, `8226b7b`, `6845ea1`; CP `a0e8f09`, `6d94d2b`; backup `control_plane_staging-20260925-134933-pre-6d94d2b.dump` |
| J5R | Regresi R1–R13 PASS; sign-off J6 | `785d682`, merge `fc7c7d4` |
| J6 | Prod: backup `control_plane-20260925-135715-pre-6d94d2b.dump`, migrasi 0001–0003, CP `6d94d2b`, worker uid 950 + mount, `infra-job-prod.path` enabled; CP tidak tersedia ±4 s (13:57:18–13:57:22); E2E dry-run `odoo_sso_provision demo demo` via spool → succeeded 3 438 ms (`changed=0 blockers=0`, job `7f5cdba0`) | infra `682e32b` |
| J7 | Docs: `infra-jobs.md` final, `control-plane.md` §Jembatan infra-job, runbook §CP, plan/ADR hasil, CHANGELOG infra; CP `CHANGELOG.md` + `package.json` 0.2.0 + tag lokal `v0.2.0` | branch infra `docs/docs-versioning-plan05`; CP `docs/docs-versioning-v0.2.0` `31411f0` (tag `v0.2.0`, belum merge ke `main`) |

CLAUDE.md §3/§3.4 dan `nextjs-developer.md` §Orkestrasi sudah diperbarui saat GATE 1 (`2317d19`); tidak diubah lagi di J7.

### 9.2 Acceptance

| AC | Hasil | Bukti |
|---|---|---|
| AC-J1 | PASS | QA J5 §AC-J1 (`infra-job root root 755`; `spool/new root cpjob-<inst> 730`) |
| AC-J2 | PASS | QA J5: staging enabled/active; prod enabled/active sejak J6 (`682e32b`; `systemctl is-enabled/is-active` dicek J7) |
| AC-J3 | PASS | QA J5 `Ran 233 tests … OK (skipped=3)`; matriks negatif 106 kontrak + 40 CP (commit `8340a4d`) |
| AC-J4 | PASS | staging QA J5 (uid 951, `results spool`, `Read-only file system`); prod dicek J7: `uid=950`, `touch /jobs/results/x` → `Read-only file system`, web uid 1001 tanpa mount |
| AC-J5 | PASS | QA J5 §AC-J5, P1–P5 |
| AC-J6 | PASS | QA J5 alur #1–#4 (tenant uji `qajob`, bukan `cpjob`): DB 28,0 s, route 6,7 s, SSO `changed=9` lalu `changed=0`; jalur apply di bawah hardening tanpa error sandbox |
| AC-J7 | PASS | QA J5 #5–#10 + J5R R3–R9 (run pertama menemukan BUG-J5-01; setelah fix resend tidak memulihkan akses) |
| AC-J8 | PASS (fakta dicatat) | QA J5 §AC-J8: `timeout_state_unknown`; proses `odoo shell` di container tetap hidup ±14 s setelah klien `docker exec` dibunuh → keterbatasan di ADR 0009 §Hasil, `infra-jobs.md` §Keterbatasan |
| AC-J9 | PASS | QA J5 §AC-J9, J5R R12 |
| AC-J10 | PASS | QA J5 §AC-J10 (6 secret, 0 hit), J5R R13 |
| AC-J11 | PASS | QA J5 §AC-J11 (`?r=duplicate`, 1 baris job) |
| AC-J12 | PASS | QA J5 N-A1..N-A6 |
| AC-J13 | **NOT VERIFIED** | CI control-plane (lint/typecheck/vitest/Semgrep/Trivy) dan Semgrep python dispatcher tidak dijalankan/diperiksa di J5/J6/J7; workflow `security.yml` ada (CP `0030d68`), hasil run tidak dilihat |
| AC-P1 | SEBAGIAN | dry-run `odoo_sso_provision demo demo` via spool (aktor `system:lead-j6-smoke`) → succeeded 3 438 ms, `blockers=0 changed=0`. **Belum:** backfill client/environment `demo` di CP prod (CP prod 0 client, 0 environment — dicek J7), job lewat UI, grant/login E2E/revoke user uji prod |
| AC-P2 | PASS | dicek J7: `odoo-pool-a` StartedAt 05:18:44Z, `traefik` 2026-09-23, `keycloak` 2026-09-24 (sebelum J6 06:57Z); `cp.bimacreative.tech` → 307 `/login` |

### 9.3 Bug & temuan

| ID | Sev | Ringkas | Status |
|---|---|---|---|
| BUG-J5-01 | High | `odoo_sso_user resend_invite` memberi ulang role `odoo_access` ke user yang sudah dicabut; CP tetap menampilkan `revoked` | FIXED: skrip `3ca5501` (aksi tersendiri, blocker untuk user tanpa role/tautan), CP `6d94d2b` (tombol hanya `active`, server `precondition`, status dari `RESULT action`, `result_inconsistent`); J5R R4–R9 PASS |
| BUG-J5-02 | Medium | aktor CP = UUID acak per login (Auth.js `token.sub`), `actor_user_id` NULL | FIXED CP `6d94d2b` (`sub` Keycloak, `actor_user_id` terisi); J5R R1–R2 PASS. Job/audit staging sebelum fix tetap beraktor acak |
| OBS-J5-01 | Low | redaksi `tail` menyembunyikan sinyal undangan | FIXED `8226b7b` (`RESULT invite=sent\|none`) + CP `6d94d2b`; J5R R11 |
| OBS-J5-02 | Low | Origin asing → 500 | FIXED CP `6d94d2b` (403 di `proxy.ts`); J5R R10 |
| OBS-J5-03 | Info | kuota DB staging habis oleh uji; durasi nyata | dicatat `infra-jobs.md` |
| OBS-J5R-01 | Low | CRS `rce` FP pada nama client bertanda baca (`;`, kurung) → 403 | terbuka (§9.4 #2) |

### 9.4 Open items

| # | Item | Pemilik |
|---|---|---|
| 1 | Backfill data CP tenant lama (§1.5): prod `demo`/`demo` (belum ada client/environment di CP prod); staging `demo`/`staging` (belum ada); staging `ssotest`/`staging` (dibuat QA J5R, kolom status masih default `absent/absent/none`). Selesaikan juga AC-P1 (job via UI + grant/login/revoke user uji prod) | Lead |
| 2 | OBS-J5R-01: tuning `controlplane-crs-exclusions` untuk nama client bertanda baca — hanya bila dibutuhkan | Lead / infra-engineer |
| 3 | AC-J13: jalankan/periksa CI control-plane (lint, typecheck, vitest, Semgrep, Trivy) dan Semgrep python dispatcher | Lead / qa-security |
| 4 | Backlog: `resend_invite` yang `blocked_dry_run` pada baris `active` (akses di Keycloak/Odoo sudah tidak cocok dengan CP) → tandai baris `inconsistent`? | nextjs-developer (backlog) |
| 5 | Backlog: perketat CHECK DB `tenant_user_access.email` / slug ke regex dispatcher (migrasi non-additive → perlu backup + rencana rollback) | nextjs-developer (backlog) |
| 6 | Client CP staging `qajob` dibiarkan sebagai jejak uji TERMINATED (baris job/audit/tenant_user_access dipertahankan) | — (info) |
| 7 | Image control plane masih dibangun lokal di VPS (TEMPORARY, sama dengan image platform lain); GHCR + deploy CI menyusul | Lead |
| 8 | Jalur `result_inconsistent` hanya diuji unit/integrasi, belum live (QA J5R) | qa-security (opsional) |

