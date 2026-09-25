# Operasional — Control plane PROD (T16a) & STAGING (T16b)

- **Publik:** `https://cp.bimacreative.tech` (router `traefik/dynamic/platform/cp.yml`, sertifikat LE production `le-http`).
- **Stack:** `/opt/infra/web/control-plane/` (CLAUDE.md §3.1) · project compose `web-control-plane`.
- **Image:** lokal `control-plane:<short-sha>` dibangun dari repo `/opt/src/control-plane` commit `main`
  (saat ini **`control-plane:6d94d2b`** = kode `v0.2.0`, prod + staging sejak 2026-09-25 plan 05; label
  `org.opencontainers.image.revision`). **TEMPORARY:** image dibangun lokal di VPS, tidak ada registry — sama seperti image
  platform lain; GHCR + deploy CI menyusul (CLAUDE.md §3.7).
- **Jembatan job host:** `infra-job` (ADR 0009) — §Jembatan infra-job di bawah, `infra-jobs.md`.
- **Auth:** Auth.js OIDC → Keycloak realm `platform`, client `control-plane` (confidential, PKCE S256), callback
  `https://cp.bimacreative.tech/api/auth/callback/keycloak`.
- **Terkait:** repo control-plane `README.md` §Kebutuhan deploy T16, `keycloak.md`, `traefik.md`, `postgres.md`, ADR 0004.

## Isi stack

| Path / service | Isi | Git |
|---|---|---|
| `docker-compose.yml` | `migrate` (one-shot), `web` (container `control-plane`), `worker` (container `control-plane-worker`) | ya |
| `.env` | `DATABASE_URL`, `AUTH_SECRET`, `AUTH_URL`, `AUTH_KEYCLOAK_{ID,SECRET,ISSUER}`, `NODE_ENV`, `LOG_LEVEL` — **600 root** | **tidak** (`.gitignore` root: `.env`) |

| Service | Network | Limit (ADR 0004) | Healthcheck |
|---|---|---|---|
| `migrate` | `db` | 256m / 0.25 | — (one-shot, `restart: "no"`) |
| `web` → `control-plane:3000` | `db`, `proxy` (Traefik + egress ke `auth.bimacreative.tech`) | 384m / 0.5 | `GET /api/health` |
| `worker` | `db` saja | 256m / 0.25 | heartbeat file `/tmp/worker-heartbeat` (< 60 s) |

Hardening semua service: `user 1001:1001` (kecuali `worker` sejak plan 05: `950:950` prod / `951:951` staging — §Jembatan
infra-job), `read_only` + tmpfs, `cap_drop: [ALL]`, `no-new-privileges`, log 10m×3,
tanpa port publish. `web` & `worker` `depends_on: migrate (service_completed_successfully)` → setiap
`docker compose up -d` menjalankan migrasi drizzle dulu; migrasi gagal = container lama tetap jalan (tidak di-recreate).

## Jembatan infra-job (plan 05, ADR 0009)

Ops/superadmin menjalankan langkah runbook `odoo-sso-tenant.md` (DB, route, SSO, user SSO) dari UI sebagai job antrean. Control
plane menulis file job ke spool host; dispatcher root `infra-job` memvalidasi dan menjalankan skrip. Detail host (spool, unit,
kuota, kode error, keterbatasan): `infra-jobs.md`. Langkah UI: `docs/runbooks/odoo-sso-tenant.md` §Jalur control plane.

### Konfigurasi (compose, bukan `.env`)

| Env | Service | prod | staging |
|---|---|---|---|
| `INFRA_JOBS_INSTANCE` | `web` + `worker` | `prod` (env tenant `prod`/`demo`) | `staging` |
| `INFRA_JOBS_SPOOL_DIR` | `worker` | `/jobs/spool` | `/jobs/spool` |
| `INFRA_JOBS_RESULTS_DIR` | `worker` | `/jobs/results` | `/jobs/results` |
| `INFRA_JOBS_POLL_SECONDS` | `worker` | default 5 (tidak diset) | default 5 |
| `INFRA_JOBS_QUEUE_GRACE_SECONDS` | `worker` | default 900 (tidak diset) | default 900 |

Kosong `INFRA_JOBS_INSTANCE` = fitur job nonaktif. `SPOOL_DIR`/`RESULTS_DIR`/`INSTANCE` wajib diisi bersama (validasi Zod
`src/env.ts`). Sumber: repo control-plane `README.md` §Job Odoo/SSO, `.env.example`.

### Worker: uid dan mount

| | prod (`web/control-plane/docker-compose.yml`) | staging (`staging/control-plane/docker-compose.yml`) |
|---|---|---|
| `user:` worker | `"950:950"` (`cpjob-prod`) | `"951:951"` (`cpjob-staging`) |
| tmpfs `/tmp` | `uid=950,gid=950,mode=0700` | `uid=951,gid=951,mode=0700` |
| bind rw | `/var/lib/infra-jobs/prod/spool` → `/jobs/spool` | `/var/lib/infra-jobs/staging/spool` → `/jobs/spool` |
| bind ro | `/var/lib/infra-jobs/prod/results` → `/jobs/results` | `/var/lib/infra-jobs/staging/results` → `/jobs/results` |

Kedua bind `create_host_path: false` (direktori dibuat role Ansible `infra_jobs`; tanpa itu worker gagal start). uid worker
**bukan** 1001 (= user host `deploy`) agar `deploy` tidak bisa menulis job (QA J5 AC-J5). `web` tetap uid 1001 tanpa mount.
Network tidak berubah (worker hanya `db`).

### Status dan data

- `provision_jobs.status`: `queued` → `dispatched` (file di spool) → `running` → `succeeded` | `failed` (+ `cancelled`
  sebelum spool). `error_code`: kode dispatcher + tiga kode CP saja `no_result`, `spool_error`, `result_inconsistent`
  (`infra-jobs.md` §Kode error). Satu job aktif per (environment, type) — partial unique index `provision_jobs_one_active_uq`.
- `environments`: `host`, `db_status` (`absent|provisioned`), `route_status` (`absent|active|removed`), `sso_status`
  (`none|active|disabled`), `sso_client_id`, `sso_provider_id`, `last_job_id` — diisi **dari hasil job**, bukan input form.
- `tenant_user_access`: `pending|active|revoked|failed|inconsistent`; status diturunkan dari `RESULT action=` (grant → active,
  revoke → revoked, resend_invite → tidak berubah). "Kirim ulang" hanya untuk baris `active` (UI + server, `6d94d2b`).
- `audit_logs`: `job.enqueue.<type>` (success/rejected, email → `email_hash`), `job.finish` (`system:worker`),
  `job.result_inconsistent`. Aktor = `user:<sub Keycloak>` + `actor_user_id` sejak `6d94d2b` (BUG-J5-02); sebelum itu aktor = UUID
  acak per login (job/audit staging lama dari QA J5 tidak bisa ditelusuri).
- `users` di-upsert saat login (keycloak_sub, email, role cache, `last_login_at`).
- Mutasi dengan header `Origin` asing → `403` di `proxy.ts` (sejak `6d94d2b`; sebelumnya 500 dari Next.js).

### Versi, migrasi, backup

| Tag image | Commit repo control-plane | Isi | Migrasi | Dipakai |
|---|---|---|---|---|
| `6d94d2b` | `6d94d2b` (kode = tag lokal `v0.2.0` `31411f0`, yang hanya menambah CHANGELOG + versi) | jembatan + perbaikan QA J5 | 0001–0003 | staging `6845ea1`, prod `682e32b` (**sekarang**) |
| `7b85a78` | `7b85a78` | jembatan J2/J2b | 0001–0002 | staging `84f8246` (J4, digantikan) |
| `4fc3828` | `4fc3828` | sebelum plan 05 | 0000 | prod & staging sebelum plan 05 |

Migrasi `0001_infra_jobs`, `0002_error_code_spool_error`, `0003_j5_inconsistent` **additive** (ADD TYPE/VALUE/COLUMN/TABLE/INDEX,
CHECK yang diperlebar): image lama tetap berjalan di DB yang sudah dimigrasi (commit message `a727ddc`, `a0e8f09`). Image lokal
lain yang ada: `dev-6d94d2b`, `dev-7b85a78`, `dev-013de24` (build uji), `0.1.0-scaffold`.

Backup `pg_dump` sebelum migrasi (`/opt/infra/backups/control-plane/`, root 0700):
`control_plane_staging-20260925-130346-pre-7b85a78.dump`, `control_plane_staging-20260925-134933-pre-6d94d2b.dump`,
`control_plane-20260925-135715-pre-6d94d2b.dump`.

Deploy prod J6 (2026-09-25): migrasi 0001–0003, recreate web+worker, CP tidak tersedia ±4 s (13:57:18–13:57:22 WIB);
`odoo-pool-a`/`traefik`/`keycloak` tidak di-restart (StartedAt sebelum J6, dicek J7); `GET /` → 307 `/login`.

### Rollback jembatan

```bash
# 1) hentikan eksekusi host dulu (job baru tertahan → no_result)
systemctl disable --now infra-job-<prod|staging>.path
# 2) image lama (aman: migrasi additive). 6d94d2b → 7b85a78 (tanpa perbaikan J5, JANGAN untuk prod: BUG-J5-01/02)
#    atau → 4fc3828 (tanpa fitur job; kolom/enum baru diabaikan)
cd /opt/infra/web/control-plane        # staging: /opt/infra/staging/control-plane
CONTROL_PLANE_TAG=4fc3828 docker compose up -d
# 3) permanen: kembalikan compose dari git (tanpa uid 950/951 dan mount), commit di repo infra
git -C /opt/infra checkout 682e32b~1 -- web/control-plane/docker-compose.yml     # staging: 84f8246~1 -- staging/control-plane/
```
**Diuji di staging 2026-09-25 16:50 WIB:** `CONTROL_PLANE_TAG=4fc3828 docker compose up -d` dengan compose plan 05 (worker uid 951 +
mount + env `INFRA_JOBS_*`) → migrate no-op (4 migrasi tetap), web + worker healthy, `/login` 200, worker hanya queue `noop` (env
`INFRA_JOBS_*` diabaikan image lama); maju lagi ke `6d94d2b` → healthy, "jembatan infra-job aktif". Langkah 3 hanya bila langkah 2 gagal.
Pulihkan DB dari backup hanya bila data rusak (migrasi tidak perlu dibalik).

## Router Traefik (`dynamic/platform/cp.yml`)

| Router | Rule | Middleware |
|---|---|---|
| `cp-auth` (prio 100) | `Host(cp…) && (PathPrefix(/api/auth/signin) \|\| PathPrefix(/api/auth/callback))` | `crowdsec`, `security-headers`, **`ratelimit-login`** (10/menit/IP, burst 10) |
| `cp-login-action` (prio 90) | `Host(cp…) && Path(/login) && Method(POST)` | `crowdsec`, `security-headers`, **`ratelimit-login`** |
| `cp` (prio 1) | `Host(cp…)` — termasuk `/api/auth/{session,csrf,providers,signout}` | `crowdsec`, `security-headers`, `ratelimit-default` |

CSP **tidak** diset Traefik — aplikasi (`src/proxy.ts`) mengirim CSP dengan nonce per request. `security-headers`
hanya menambah HSTS (`max-age=604800`, 31536000 mulai 2026-10-09 — `traefik.md` §HSTS bertahap), nosniff, `X-Frame-Options: DENY`, referrer & permissions policy.

**Ratelimit login dipersempit (H3, 2026-09-23).** Sebelumnya `ratelimit-login` berlaku untuk seluruh `/api/auth/*`,
termasuk `/api/auth/session` yang dipanggil klien saat navigasi/refresh sesi. Sekarang hanya:
- `/api/auth/signin*` — memulai alur OIDC (cookie state/PKCE/nonce + redirect ke Keycloak);
- `/api/auth/callback*` — menukar authorization code → token (request keluar ke Keycloak = amplifikasi);
- `POST /login` — tombol "Masuk" adalah Server Action (`src/app/actions.ts` `loginAction` → `signIn()` di server),
  **tidak** lewat `/api/auth/signin`; tanpa router ini alur login nyata hanya kena `ratelimit-default`.

`/api/auth/csrf` **tidak** diberi `ratelimit-login`: hanya token HMAC tanpa state server; provider satu-satunya
Keycloak OIDC (tidak ada Credentials provider) → tidak ada permukaan brute-force password di control plane.
Brute-force password ditangani Keycloak (`ratelimit-login` pada `/login-actions` + brute force detection realm).
Bucket rate limit per router: `cp-auth` (signin + callback bersama) dan `cp-login-action` terpisah.

Verifikasi (container uji `--network proxy --ip 10.100.0.250`, `--resolve cp.bimacreative.tech:443:<ip traefik>`):
15× `GET /api/auth/session` → 15× 200; 15× `GET /api/auth/csrf` → 15× 200; 15× `GET /api/auth/signin/keycloak` →
10× 302 lalu 5× 429; `GET /api/auth/callback/keycloak` berikutnya → 429 (bucket sama); 12× `POST /login` → 10× 200
lalu 2× 429; 15× `GET /login` → 15× 200.

## Server Action & WAF (H6, 2026-09-23)

Tombol "Masuk" (`loginAction`) dan "Keluar" (`logoutAction` di `Nav`) adalah **Server Action** Next.js: browser mengirim
`POST <URL halaman>` (`/login`, `/dashboard`, `/clients`, …) dengan header `Next-Action: <id hex>` dan
`Content-Type: text/plain;charset=UTF-8` (body JSON, mis. `[]`). CRS 920420 menolak `text/plain` → sebelum H6 tombol login
= 403 dan IP pengguna di-ban AppSec (insiden 2026-09-23 20:23 WIB, termasuk SSH saat itu).
- Pengecualian sempit: `security/crowdsec/appsec-configs/controlplane-crs-exclusions.yaml` (hanya 920420, host cp/cp.staging,
  POST, `Next-Action` hex 40–64, `text/plain`, bukan `/api/*`/`/_next/*`) + `appsec-rules/controlplane-server-action.yaml`
  (body diparse sebagai JSON → XSS/SQLi di argumen Server Action tetap 403; body non-JSON → 403). Detail & uji:
  `crowdsec.md` §Pengecualian CRS 920420.
- Hasil: `POST /login` dengan id dari HTML → `200` + `x-action-redirect: https://auth.bimacreative.tech/realms/platform/…;push`.
- **Untuk nextjs-developer:** Server Action baru tidak butuh perubahan WAF selama body text/plain = JSON (bawaan React) dan
  dipanggil dari halaman di luar `/api/*`. Argumen berisi HTML/SQL-like string akan diperiksa CRS (bisa 403) — validasi di app
  tetap wajib (Zod), false positive dilaporkan ke infra dengan `cscli alerts inspect -d`. Upgrade Next.js: pastikan format
  id `$ACTION_ID_` masih hex 40–64 (uji `qa/edge-external.ps1` §7).
- Ban dari AppSec sejak H6 hanya berlaku di HTTP (bouncer Traefik), tidak di firewall host.

## Deploy / upgrade

```bash
# 1) build tag baru dari commit main repo control-plane (context = git archive → tanpa file lokal/.env)
cd /opt/src/control-plane && git fetch && git checkout main && git pull --ff-only
TAG=$(git rev-parse --short=7 main)
git archive --format=tar main | docker build -t control-plane:$TAG \
  --label org.opencontainers.image.revision=$(git rev-parse main) -
# 2) pin tag baru di compose (default ${CONTROL_PLANE_TAG:-<tag>}) → commit di repo infra
cd /opt/infra/web/control-plane && sed -i "s/CONTROL_PLANE_TAG:-[0-9a-f]\{7\}/CONTROL_PLANE_TAG:-$TAG/" docker-compose.yml
docker compose config -q
# 3) migrasi (opsional terpisah — `up -d` juga menjalankannya) lalu recreate web+worker
docker compose run --rm --no-deps migrate
docker compose up -d
docker compose ps                # control-plane & control-plane-worker (healthy)
# 4) smoke
curl -sI https://cp.bimacreative.tech/ | grep -i -E '^HTTP|^location|content-security-policy'   # 307 → /login + CSP nonce
curl -s  https://cp.bimacreative.tech/api/auth/providers                                          # 200 JSON keycloak
```
Downtime saat recreate ± 5–10 s (satu replika). Perubahan `.env` → `docker compose up -d` (recreate).

## Rollback

Migrasi drizzle hanya maju — rollback image aman **selama migrasi baru bersifat additive** (cek `drizzle/` diff
sebelum upgrade; migrasi destruktif butuh backup DB `control_plane` dulu: `sudo systemctl start restic-backup.service`).
```bash
cd /opt/infra/web/control-plane
docker images control-plane                        # tag yang tersedia lokal
CONTROL_PLANE_TAG=<tag-lama> docker compose up -d  # cepat (sementara)
# permanen: kembalikan docker-compose.yml dari git (git checkout <rev> -- web/control-plane/) → docker compose up -d
```
Tag sebelumnya di host: `control-plane:0.1.0-scaffold` (build T12 dari `/opt/src`, image id `743e0032be51`). Jangan
`docker image prune` tag yang masih menjadi target rollback.

## Riwayat cutover T16a (2026-09-23)

- Sebelumnya container berjalan dari `/opt/src/control-plane/docker-compose.yml` (project `control-plane`, image
  `control-plane:0.1.0-scaffold`, internal saja). `.env` disalin (`install -m 600`, isi identik — `cmp`) ke
  `/opt/infra/web/control-plane/.env`.
- Urutan: `docker compose run --rm migrate` (stack baru, sukses) → stop+rm `web`/`worker` lama → `up -d` stack baru.
  Nama container sama (`control-plane`, `control-plane-worker`) sehingga target Traefik tidak berubah. Downtime internal
  ± 8 s (belum ada router publik saat itu). Stack lama: `docker compose ps -a` di `/opt/src/control-plane` kosong.
- **Jangan** menjalankan `docker compose up` di `/opt/src/control-plane` lagi — nama container bentrok (gagal) dan
  memakai `.env` lama. Compose di repo itu hanya untuk pengembangan lokal.
- Sertifikat: `le-http-staging` dulu (issuer `(STAGING)`), 307/200 terverifikasi, entri `cp` dihapus dari
  `acme-staging.json` (backup `acme-staging.json.bak-t16a-*`), resolver → `le-http`, restart Traefik → issuer
  `Let's Encrypt YE1`, `Verify return code: 0`.

## Verifikasi (2026-09-23)

- `GET /` → `307 location: /login`, header `content-security-policy: … 'nonce-…' 'strict-dynamic' …` (satu CSP, dari app).
- `GET /login` → 200, atribut `nonce="…"` di `<script>` cocok dengan header CSP.
- `GET /api/auth/providers` → 200 `{"keycloak":{…,"callbackUrl":"https://cp.bimacreative.tech/api/auth/callback/keycloak"}}`.
- `GET /api/auth/csrf` (cookie jar) → token 64 char; `POST /api/auth/signin/keycloak` (csrfToken + callbackUrl) →
  `302` ke `https://auth.bimacreative.tech/realms/platform/protocol/openid-connect/auth?response_type=code&client_id=control-plane&redirect_uri=…&code_challenge_method=S256&state=…&nonce=…`;
  cookie `__Host-authjs.csrf-token`, `__Secure-authjs.{state,nonce,pkce.code_verifier,callback-url}`.
- Halaman login Keycloak (URL di atas) → 200, `<title>Sign in to platform`.
- **NOT TESTABLE:** login end-to-end (callback → sesi → `/dashboard`) — belum ada user di realm `platform`
  (pembuatan user/role = keputusan user/Lead, di luar T16a).

## Staging — `cp.staging.bimacreative.tech` (T16b, 2026-09-23)

- **Publik:** `https://cp.staging.bimacreative.tech` (router `traefik/dynamic/platform/cp-staging.yml`, LE production `le-http`;
  dicakup DNS wildcard `*.staging` — pre-check A = `31.97.50.221` @apollo/@athena.dns-parking.com, @1.1.1.1, @8.8.8.8, tanpa AAAA).
- **Stack:** `/opt/infra/staging/control-plane/` · project compose `staging-control-plane` · image **sama** dengan prod
  (`control-plane:6d94d2b` sejak 2026-09-25, default `${CONTROL_PLANE_TAG:-…}`) — upgrade staging dulu, baru prod (ganti tag di kedua compose).
- **Auth:** realm `platform-staging`, client `control-plane` (issuer `https://auth.bimacreative.tech/realms/platform-staging`).
- **DB:** `control_plane_staging` (role sama, `CONNECTION LIMIT 10`) — lihat `postgres.md`.

| Service | Container | Network | Limit (ADR 0004: staging web+worker 320 MiB / 0.25) | Healthcheck |
|---|---|---|---|---|
| `migrate` | `staging-control-plane-migrate-1` (one-shot) | `db` | 192m / 0.25 (transien) | — |
| `web` | `control-plane-staging:3000` | `db`, `proxy` | 192m / 0.15 | `GET /api/health` |
| `worker` | `control-plane-staging-worker` | `db` | 128m / 0.10 | heartbeat `/tmp/worker-heartbeat` |

Hardening identik prod (uid 1001; worker 951 sejak plan 05, `read_only` + tmpfs, `cap_drop: [ALL]`, `no-new-privileges`, log 10m×3, tanpa port publish).
Terukur setelah start: web ±55 MiB, worker ±24 MiB.

`.env` (600 root, di-ignore git): `NODE_ENV`, `LOG_LEVEL`, `DATABASE_URL=postgresql://control_plane_staging:<PG_CONTROL_PLANE_STAGING_PASSWORD>@postgres:5432/control_plane_staging`,
`AUTH_SECRET` (acak baru, `openssl rand -base64 48`, berbeda dari prod), `AUTH_URL=https://cp.staging.bimacreative.tech`,
`AUTH_KEYCLOAK_ID=control-plane`, `AUTH_KEYCLOAK_ISSUER=…/realms/platform-staging`, `AUTH_KEYCLOAK_SECRET` (= isi
`identity/keycloak/secrets/platform-staging-control-plane.secret`, 600, tanpa newline).

### Client Keycloak `control-plane` (realm `platform-staging`)

Dibuat lewat Admin REST dengan service account `automation` (realm `platform-staging`, role `manage-clients`), tanpa
kredensial admin baru. Konfigurasi = client prod (realm `platform`) dengan host staging: confidential (`client-secret`),
standard flow saja (implicit/direct grants/service account/device/CIBA off), `pkce.code.challenge.method=S256`,
redirect `https://cp.staging.bimacreative.tech/api/auth/callback/keycloak`, `post.logout.redirect.uris=…/login`, web origin
`https://cp.staging.bimacreative.tech`, `fullScopeAllowed=false`, client role `superadmin|ops|client_admin|client_user`,
mapper `oidc-usermodel-client-role-mapper` (ID/access/userinfo/introspection, multivalued).

- **Beda satu-satunya dengan prod:** `claim.name` mapper ditulis literal **`resource_access.control-plane.roles`**, bukan
  `resource_access.${client_id}.roles`. Body JSON berisi `${…}` diblokir CrowdSec AppSec (`anomaly score block: rce`, 403 di
  router `auth-admin`). Hasil klaim identik (`${client_id}` = `control-plane`).
- Ambil ulang secret (tanpa menampilkan): `GET /admin/realms/platform-staging/clients/<id>/client-secret` → tulis `value`
  dengan `printf '%s'`/`sys.stdout.write` ke file 600. Rotasi: `POST …/client-secret` → perbarui file + `.env` → `docker compose up -d`.
- **Realm export belum diperbarui:** `partial-export` butuh `manage-realm` (akun `automation` → 403) dan file
  `realm-export/platform-staging.json` sedang dipakai T15. Export ulang (tanpa secret) oleh admin setelah T15 merge.

### Deploy / upgrade staging

```bash
cd /opt/infra/staging/control-plane
docker compose config -q
docker compose run --rm --no-deps migrate     # migrasi ke control_plane_staging (up -d juga menjalankannya)
docker compose up -d && docker compose ps     # control-plane-staging & -worker (healthy)
curl -sI https://cp.staging.bimacreative.tech/ | grep -i -E '^HTTP|^location'   # 307 → /login
```
Rollback sama dengan prod (`CONTROL_PLANE_TAG=<tag-lama> docker compose up -d`). Monitor Uptime Kuma:
`Control plane staging (cp.staging)` (`observability/scripts/uptime-kuma-provision.js`, idempoten).

### Verifikasi (2026-09-23)

- Sertifikat: `le-http-staging` dulu (issuer `(STAGING) Baloney Bulgur YE2`, `GET /` 307) → entri `cp.staging` dihapus dari
  `acme-staging.json` (backup `acme-staging.json.bak-t16b-*`, entri `drms-kas.staging` tetap) → `le-http` → restart Traefik →
  issuer `Let's Encrypt YE1`, `Verify return code: 0`.
- `GET /` → `307 location: /login`; `GET /login` → 200; `/api/auth/providers` → callbackUrl `https://cp.staging…/api/auth/callback/keycloak`.
- `POST /api/auth/signin/keycloak` (csrf) → 302 `https://auth.bimacreative.tech/realms/platform-staging/protocol/openid-connect/auth?response_type=code&client_id=control-plane&redirect_uri=https%3A%2F%2Fcp.staging…&code_challenge=…&code_challenge_method=S256&nonce=…`;
  router `cp-staging-auth`. Halaman login Keycloak → 200 `<title>Sign in to platform-staging`. `POST /login` → router `cp-staging-login-action`.
- Prod tidak berubah: `cp.bimacreative.tech` → 307, signin → `realms/platform`.
- **NOT TESTABLE:** login end-to-end (callback → sesi → klaim role) — belum ada user di realm `platform-staging`.

## Belum / berikutnya

- ~~Staging `cp.staging.bimacreative.tech`~~ — selesai T16b (§Staging).
- Realm export `platform-staging` (dan `platform`) memuat client `control-plane` — butuh admin (`manage-realm`).
- Image di registry (GHCR) + `infra-deploy` wrapper untuk user `deploy` (CLAUDE.md §3.7) — image masih build lokal (TEMPORARY).
- Plan 05 open items (backfill status environment tenant lama, CI AC-J13, dll.): `docs/plans/05-control-plane-odoo-sso-jobs.md` §9.4.
