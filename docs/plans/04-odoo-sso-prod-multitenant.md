# Plan 04 — SSO Odoo prod multi-tenant (`odoo-pool-a`, Keycloak realm `platform`, `sh_auth_oidc`)

- Status: **APPROVED GATE 1 (user, 2026-09-25): semua rekomendasi §8** — 1 satu realm, 2 file per DB (B), 3 onboarding ops+undangan+TOTP admin tenant+Forgot password+admin break-glass, 4 role `odoo_access`, 5 recreate kapan saja setelah QA staging lulus; CLAUDE.md §3.2 diperbarui.
- Tanggal: 2026-09-25 · Penulis: Analyst · ADR: `docs/adr/0008-odoo-sso-multitenant.md` (proposed)
- Terkait: CLAUDE.md §3.2 (Login, dbfilter header), §3.4 (control plane), §3.6; ADR 0003 D1/D2; T15 (`docs/03-operations/odoo.md`
  §SSO); `docs/03-operations/keycloak.md`; `docs/03-operations/crowdsec.md`; repo `odoo-addons-shared` (`/opt/src/odoo-addons-shared`).

## 0. Tujuan

Tenant produksi di pool `odoo-pool-a` (DB `<slug>_prod`, `<slug>_demo`) bisa login lewat Keycloak SSO memakai `sh_auth_oidc`,
aman untuk banyak client: user client A tidak bisa masuk Odoo client B, onboarding tenant/rotasi secret **tanpa** restart pool,
dan dapat diotomasi (skrip → nanti control plane).

## 1. Scope

**IN**
1. Modul `sh_auth_oidc` **19.0.1.2.0**: sumber secret per DB dari file platform (ADR 0008 #4); opsional role gate (Q4).
2. Skrip infra: `scripts/provision-odoo-sso.sh` (client Keycloak + secret file + modul/parameter/provider Odoo, idempoten)
   dan `scripts/odoo-sso-user.sh` (buat/undang user Keycloak + tautkan `res.users`); lib `scripts/lib/keycloak-admin.sh`.
3. Pool (prod + staging): mount ro direktori secret OIDC + env `SH_OIDC_SECRET_DIR`, `SH_OIDC_TRUSTED_ISSUERS`
   (prod: `https://auth.bimacreative.tech/realms/platform`) — satu kali recreate per pool.
4. Edge: router token back-channel realm `platform`/`platform-staging` untuk hairpin `10.100.0.1` dengan limit sendiri;
   `/sh_auth_oidc/` tenant di router + rate-limit tersendiri (template `templates/traefik-client.yml`, render ulang
   `demo-demo`, `demo-staging`).
5. Upgrade submodule `odoo/pool-a/addons/shared` `18f6bcf` → commit modul baru (setelah QA staging); staging juga.
6. Migrasi `demo_staging` dari secret env ke file; tenant uji kedua staging `ssotest_staging` untuk uji lintas-tenant.
7. Aktivasi SSO prod untuk `demo_demo` (host `demo.erp.bimacreative.tech`, client `odoo-demo-demo`, realm `platform`).
8. QA (lintas tenant, WAF, rate-limit) + docs/runbook/CHANGELOG.

**OUT**: integrasi control plane (job `odoo_sso_provision`/UI tautan user — plan terpisah, hanya kontrak antarmuka di §6),
RP-initiated logout / back-channel logout, realm per client, Keycloak Organizations, pool dedicated, MFA wajib realm-wide,
client `<slug>_prod` nyata (belum ada — hanya `demo_demo` di pool prod).

## 2. Discovery (fakta 2026-09-25, perintah read-only)

| # | Fakta | Bukti |
|---|---|---|
| F1 | Prod pool submodule `18f6bcf`, staging `5fa8b70`; addons `main` = `14ff8dd` (hanya CI/ruff setelah `5fa8b70`). Diff `18f6bcf..5fa8b70`: hanya `sh_auth_oidc` (password policy) + githook; **`sh_dbfilter_header` tidak berubah**. | `git submodule status`; `git diff --stat 18f6bcf 5fa8b70`, `5fa8b70 main` |
| F2 | `demo_demo`: `auth_oauth`, `auth_signup`, `sh_auth_oidc` **uninstalled**; `sh_dbfilter_header`, `auth_totp`, `auth_passkey` installed. Satu-satunya DB prod-pool. | `psql -d demo_demo … ir_module_module`; `pg_database` |
| F3 | `demo_staging`: provider id 4 `Keycloak (platform-staging)` enabled, `sh_oidc_client_secret_env=SH_OIDC_ODOO_DEMO_STAGING_SECRET`, signup off; Odoo.com (id 1) disabled; Google/Facebook tidak enabled; ICP `auth_signup.invitation_scope=b2b`, `auth_oauth.authorization_header=True`; 0 user tertaut (user uji dihapus). | `psql -d demo_staging` |
| F4 | Env pool: staging `.env` memuat `SH_OIDC_ODOO_DEMO_STAGING_SECRET`, `SH_OIDC_TRUSTED_ISSUERS`; prod `.env` hanya `PG*`, `ODOO_ADMIN_PASSWD`. | `cut -d= -f1 .env` |
| F5 | **Klaim H4 "provision-odoo-db menambah invitation_scope b2b + disable Odoo.com" TIDAK terbukti**: `scripts/provision-odoo-db.sh` tidak berubah sejak T10 (`e2a320f`), `grep invitation_scope\|odoo.com\|oauth scripts/` kosong. Setelan b2b/Odoo.com di `demo_staging` dibuat manual di T15. | `git log -- scripts/provision-odoo-db.sh`; `grep -rn` |
| F6 | Modul: config per DB di `auth.oauth.provider`; `redirect_uri = request.httprequest.url_root + 'sh_auth_oidc/callback'`; tidak ada hardcode host/DB/tenant. Secret: env bernama bebas (dipilih record provider) + `SH_OIDC_TRUSTED_ISSUERS`, atau ICP `sh_auth_oidc.client_secret.<id>`. **Celah env-name mapping:** env global per pool, tidak terikat DB, perlu recreate pool per tenant/rotasi. | `models/auth_oauth_provider.py` `_sh_oidc_client_secret`; `controllers/main.py` `sh_oidc_authorize` |
| F7 | Signup core: `_auth_oauth_signin` → `signup()` → `_signup_create_user` menolak bila `invitation_scope != 'b2c'`; user signup dari `base.template_portal_user_id` (portal). | `auth_oauth/models/res_users.py:105`, `auth_signup/models/res_users.py:92` (image `odoo:19.0-20260908`) |
| F8 | Session Odoo: bila `session.db` tidak lolos `db_filter` (header per host) → `session.logout()` ("Logged into database … dbfilter rejects it"). | `odoo/http.py:1829-1848` |
| F9 | Traefik: `X-Forwarded-*` klien tidak dipercaya (tanpa `forwardedHeaders.trustedIPs`); router tenant `Host()` eksplisit + `X-Sh-Odoo-Db` eksak + hapus `X-Odoo-Database`. `/sh_auth_oidc/*` saat ini lewat router utama (`ratelimit-default` 50/s), **bukan** `ratelimit-login`. | `traefik/traefik.yml:40`; `templates/traefik-client.yml` |
| F10 | Token back-channel dari container tiba sebagai **10.100.0.1** di router `auth-login` (`ratelimit-login` 10/menit burst 10, per IP) → satu bucket untuk semua tenant + control plane. | access log 2026-09-23..25: 25× `/realms/platform-staging/…/token` 10.100.0.1 → 200 |
| F11 | Keycloak `automation` (realm `platform`) roles `view-realm, manage-users, manage-clients` (tanpa `manage-realm`). Realm `platform`: 1 user, clients `automation`, `control-plane` (+ bawaan); `resetPasswordAllowed=false`, `verifyEmail=false`, SMTP aktif, brute force 5×/900 s, `organizationsEnabled=false`. Authenticator tersedia termasuk `conditional-user-role`, `deny-access-authenticator`, `organization`. | Admin REST GET (token `automation`, :8443) |
| F12 | Client `odoo-demo-staging` (export `platform-staging.json`): confidential, standard flow saja, PKCE S256, RS256, `fullScopeAllowed=false`, default scopes `acr profile basic email`, web origins kosong, `post.logout.redirect.uris` `/web/login`. ID token contoh `aud`=`azp`=`odoo-demo-staging` (T15). | realm export |
| F13 | CrowdSec AppSec: tidak ada alert untuk `/sh_auth_oidc`/`auth_oauth` (0 dari 189 alert); access log hanya 2× authorize + 2× callback (303) di staging → sampel FP **sangat kecil**. Exclusion Odoo yang ada hanya `attack-xss` untuk endpoint editor. | `cscli alerts list`; access log |
| F14 | Pool prod start: log "HTTP service running" ±0,4 s setelah proses mulai (2026-09-23 06:37:39→40); `mem` pool-a 197 MiB / 2560m; host available 11,9 GiB. | `docker logs --timestamps`, `docker stats`, `free -m` |
| F15 | Control plane: `users.keycloak_sub` unik + satu `client_id`; `environments(db_name, url, odoo_instance)`; worker masih scaffold (`noop`, belum memanggil skrip host). | `/opt/src/control-plane/src/db/schema.ts`, `src/worker/jobs.ts` |

## 3. Jawaban pertanyaan desain

### 3.1 Model realm (Q1)
**Rekomendasi: satu realm `platform` untuk semua tenant prod/demo** (staging: `platform-staging`). Isolasi user antar client
dijamin di **Odoo** (hanya user tertaut `oauth_provider_id`+`oauth_uid`=`sub` di DB tenant itu; tanpa signup) + `aud`/`azp`
per client, opsional role gate klaim (Q4). Token: `iss` = realm, `aud`=`azp`=`odoo-<slug>-<env>`, `sub` = id user Keycloak;
`fullScopeAllowed=false` + default scopes `basic profile email acr` → tidak ada role client lain (mis. role control plane) bocor ke token Odoo.
Delegasi admin: client **tidak** diberi akses console Keycloak (realm berisi user semua client); kelola user lewat skrip
sekarang, control plane nanti (validasi `client_admin` hanya untuk client-nya). Trade-off realm per client: lihat ADR 0008 Alternatives.

### 3.2 Model client Keycloak + konfigurasi per DB (Q2)
- Client `odoo-<slug>-<env>` per tenant-env, representasi = F12, redirect URI eksak untuk **setiap** host tenant-env
  (`<slug>.erp.bimacreative.tech` untuk prod, host `--host` untuk demo, + domain client terverifikasi). Domain client baru →
  jalankan ulang skrip dengan daftar host lengkap (idempoten, PUT `redirectUris`).
- Odoo per DB: satu provider `Keycloak (platform)` (dicari berdasarkan `client_id`), `sh_oidc_enabled`, issuer + auth/token/JWKS/userinfo
  endpoint realm, `sh_oidc_allow_signup=False`, sumber secret **file platform** (ADR 0008 #4).
- Yang single-tenant/hardcoded hari ini (bukan di kode modul, tetapi di operasi): env `SH_OIDC_<CLIENT>_SECRET` global pool (F6),
  provider + ICP dibuat manual (F3/F5), tidak ada skrip. Plan ini menutup ketiganya.

### 3.3 Otorisasi tenant & provisioning user (Q3)
- **Tanpa auto-signup** (F7: signup menghasilkan user portal dan butuh b2c publik). Provider `sh_oidc_allow_signup=False`,
  `auth_signup.invitation_scope=b2b`, provider Odoo.com/Google/Facebook disabled — di-set oleh `provision-odoo-sso.sh` (menutup F5).
- **Pre-provisioning** (`odoo-sso-user.sh <slug> <env> --email <e> [--login <odoo login>] [--create-kc] [--admin]`):
  cari/buat user Keycloak (username = email, `emailVerified` sesuai input, required actions `UPDATE_PASSWORD`
  [+ `CONFIGURE_TOTP` untuk admin tenant]) → `execute-actions-email` (SMTP realm sudah jalan) → tautkan `res.users` existing
  (`oauth_provider_id`, `oauth_uid`=id Keycloak). Pembuatan `res.users` + hak akses tetap oleh admin tenant/ops (bisnis), bukan skrip.
  Jika Q4 disetujui: assign client role `odoo_access`.
- **Offboarding:** disable user Keycloak (semua tenant sekaligus) atau hapus role/tautan untuk satu tenant; arsipkan `res.users`.
- **Break-glass:** `admin` tenant (`base.user_admin`, password acak di `<pool>/secrets/tenants/<db>.admin-password`) **tidak ditautkan**
  → tetap password lokal, hanya dipakai ops platform. Admin milik client = SSO saja (password lokal ditolak, `sh_auth_oidc` T15).
  `sh_oidc_password_exempt` tidak dipakai untuk user client. Keycloak down → per DB `sh_auth_oidc.password_login_policy=allow` (runbook).

### 3.4 Otomasi & secret (Q4)
`scripts/provision-odoo-sso.sh <slug> <prod|demo|staging> [--host <fqdn>]... [--disable]` (pseudo-langkah, bukan final):
1. Validasi via `lib/odoo-pools.sh` (`validate_slug_env`, `validate_host`); realm: prod/demo → `platform`, staging → `platform-staging`;
   lock `flock` per DB; DB harus sudah ada (hasil `provision-odoo-db.sh`).
2. Token `automation` (secret `identity/keycloak/secrets/automation-<realm>.secret`) → Admin REST `https://auth.bimacreative.tech:8443`
   `--resolve …:8443:127.0.0.1` (H5). `GET /clients?clientId=odoo-<slug>-<env>` → `POST` bila tidak ada, `PUT` bila berbeda
   (redirectUris, attributes). **Body tanpa `${…}`** (CRS 932130). Nama mapper literal.
3. `GET /clients/<uuid>/client-secret` → tulis `<pool>/secrets/oidc/<db>` hanya bila berbeda (`printf '%s'`, `0440 root:101`,
   tanpa menampilkan nilai). Rotasi: `--rotate-secret` → `POST …/client-secret` → tulis file (efektif tanpa restart).
4. Odoo (`odoo shell`/one-off `-i`, pola `provision-odoo-db.sh`): install `auth_oauth,sh_auth_oidc` bila belum; ICP
   `auth_signup.invitation_scope=b2b`, `auth_oauth.authorization_header=True`; disable provider non-platform; create/update provider;
   hapus ICP `sh_auth_oidc.client_secret.<id>` bila ada.
5. Smoke: `curl https://<host>/web/login` memuat `/sh_auth_oidc/authorize?provider=<id>`; `authorize` → 303 ke realm dengan `client_id` benar.
6. Output: `RESULT db=<db> realm=<r> client=<clientId> provider=<id> hosts=<h,…> changed=<n> secret_file=<path>`.
`--disable`: provider Allowed OFF + client Keycloak `enabled=false` (tidak menghapus apa pun).
Kontrak control plane (nanti): job `odoo_sso_provision {slug, env, hosts[]}` / `odoo_sso_user {slug, env, email, role}` memanggil skrip
lewat wrapper root (pola `infra-deploy`), mencatat `RESULT` ke `provision_jobs.log`. Control plane tidak membaca secret.

### 3.5 Upgrade addons prod `18f6bcf` → baru (Q5)
- Staging dulu (S4). Prod: backup `demo_demo` (dump + filestore, `odoo.md` §Upgrade 2) → checkout submodule ke commit modul
  19.0.1.2.0 → recreate pool (sekaligus mount + env) → `-u` **tidak diperlukan** untuk `demo_demo` (F1: `sh_dbfilter_header`
  tidak berubah; `sh_auth_oidc` belum ter-install, F2) → `provision-odoo-sso.sh demo demo --host demo.erp.bimacreative.tech`.
- Untuk tenant prod masa depan yang sudah punya `sh_auth_oidc`: `-u sh_auth_oidc` per DB (satu proses one-off, `--no-http`)
  setelah backup; urutan DB demi DB; gagal → restore DB tersebut (prosedur `odoo.md` §Rollback).
- Test modul di image yang di-pin: `/opt/src/odoo-addons-shared/test/run-tests.sh sh_auth_oidc` + `sh_dbfilter_header`.

### 3.6 Keamanan/QA — lihat §5 (threat model) dan AC-Q*.
WAF: callback membawa `iss=https%3A%2F%2Fauth…` + `code` panjang di query — sampel staging hanya 2 (F13) → QA wajib ≥ 20 login
+ cek `cscli alerts`. Tidak ada exclusion baru direncanakan; bila FP muncul → exclusion sempit terpisah (butuh persetujuan).
Rate-limit: F10 (token back-channel satu bucket) + `/sh_auth_oidc/` belum dibatasi khusus (F9) → S3.

### 3.7 Kapasitas & downtime (Q7)
- RAM/CPU: tambahan diabaikan (modul Python kecil; JWKS cache per worker; client Keycloak ± beberapa KB). Disk: file secret < 1 KB/tenant.
  ADR 0004 sisa ≈ 2312 MiB tidak berubah.
- Downtime: **satu** recreate `odoo-pool-a` (mount + env + kode baru) — estimasi 10–30 s (start proses < 1 s F14 + stop graceful +
  load registry pertama); saat ini hanya berdampak `demo_demo` (tenant demo, belum ada client nyata). Satu recreate `odoo-staging`.
  Keycloak **tidak** restart (Admin REST saja). Traefik: file provider hot-reload, tanpa restart. Setelah itu onboarding tenant &
  rotasi secret = 0 downtime (diverifikasi AC-S3). Durasi nyata diukur di staging (AC-S5).
- Belum terverifikasi: apakah `-i sh_auth_oidc` via proses one-off terlihat oleh worker yang berjalan tanpa restart (registry
  signaling Odoo). Jika tidak, onboarding tenant pertama yang memasang modul butuh recreate → diuji di staging (AC-S4); bila gagal,
  alternatif: pasang `auth_oauth,sh_auth_oidc` di `provision-odoo-db.sh` saat DB dibuat (sebelum router aktif).

## 4. Acceptance criteria (bisa diverifikasi dengan perintah)

**Modul (S1)**
- AC-M1 `run-tests.sh sh_auth_oidc` lulus di `odoo:19.0-20260908` termasuk test baru: secret dari `<dir>/<dbname>`; file DB lain tidak
  pernah dibaca (provider dengan client_id tenant lain → secret milik DB sendiri); `dbname` invalid → error; issuer tidak terpercaya → error;
  rotasi file terbaca tanpa restart; [Q4] role hilang → `oauth_error`. CI addons hijau (ruff, semgrep, gitleaks).
- AC-M2 `__manifest__` version `19.0.1.2.0`, README §Configuration diperbarui; tidak ada secret/host hardcode (`grep`).

**Skrip & edge (S2/S3)**
- AC-S1 `provision-odoo-sso.sh ssotest staging` dua kali → run ke-2 `changed=0`; `GET /clients?clientId=odoo-ssotest-staging` = representasi F12 +
  redirect eksak; file secret `stat -c '%a %U:%g'` = `440 root:101`, `tail -c1 | xxd` bukan `0a`.
- AC-S2 `shellcheck` bersih; skrip tidak mencetak secret (`bash -x` tidak dipakai; grep log job untuk pola secret = 0).
- AC-S3 Tenant kedua di staging diaktifkan **tanpa** recreate pool: `docker inspect -f '{{.State.StartedAt}}' odoo-staging` sama sebelum/sesudah.
- AC-S4 Install modul via one-off pada DB baru → `/web/login` tenant tsb memuat link provider tanpa restart (atau keputusan fallback dicatat).
- AC-S5 Waktu recreate staging diukur (`curl` loop 1 s ke `/web/health` via host) dan dicatat.
- AC-S6 30 exchange token dalam 60 s dari pool (simulasi `curl` hairpin) → 0 respons 429 di router token baru; `ratelimit-login` user tetap untuk
  `/login-actions` (15 POST dari 1 IP → 429 setelah burst).
- AC-S7 `/sh_auth_oidc/authorize` > limit dari 1 IP → 429; alur normal 1 user = 200/303 semua.

**QA lintas tenant (S5 staging, S7 prod smoke)** — `demo_staging` + `ssotest_staging`, user `u_a` hanya tertaut di A:
- AC-Q1 `u_a` login SSO di host A → `get_session_info.db = demo_staging`; di host B → `/web/login?oauth_error=3`, tanpa sesi.
- AC-Q2 Code/ID token client A disuntik ke callback B → ditolak (`oauth_error=2`; log "missing, unknown or already used state" atau `invalid_grant`/audience).
- AC-Q3 Authorize ke Keycloak `client_id=odoo-a` + `redirect_uri` host B → Keycloak "Invalid parameter: redirect_uri".
- AC-Q4 Header `X-Odoo-Database: demo_staging` / `X-Sh-Odoo-Db` palsu / `X-Forwarded-Host` palsu pada `/sh_auth_oidc/*` host B → tetap DB B, redirect_uri host B.
- AC-Q5 Cookie `session_id` host A dikirim ke host B → tidak terautentikasi di B (F8).
- AC-Q6 Provider di DB B diubah admin B ke `client_id=odoo-a` → login gagal (Keycloak menolak redirect_uri host B untuk client A; exchange dengan secret file DB B juga ditolak); secret tenant lain tidak bisa dirujuk.
- AC-Q7 `sub` tak tertaut dengan `email_verified=true` → tidak ada `res.users` baru (`count` sebelum = sesudah).
- AC-Q8 `/auth_oauth/signin` → ditolak; hanya 1 provider enabled; password lokal user tertaut ditolak (web + XML-RPC); `admin` tenant OK.
- AC-Q9 ≥ 20 login SSO lewat edge → 0 AppSec 403, `cscli alerts list` tanpa alert baru untuk IP uji; `redirect=//evil.example` dibuang.
- AC-Q10 [Q4] user tanpa role `odoo_access` tetapi tertaut → ditolak.
- AC-P1 (prod) `demo.erp.bimacreative.tech`: E2E login user uji realm `platform` → sesi `demo_demo`; user uji dihapus setelah uji (204).
- AC-P2 Traefik/Keycloak/pool healthy (`docker compose ps`), `infra-healthcheck` OK, Kuma monitor pool hijau.

**Docs (S8)** — `odoo.md` §SSO (multi-tenant, file secret, skrip), `keycloak.md` (client per tenant, router token), runbook
`docs/runbooks/odoo-sso-tenant.md`, ADR 0008 → accepted, catatan revisi ADR 0003, CHANGELOG, tag addons.

## 5. Threat model ringkas (STRIDE)

| Ancaman | Entry point | Mitigasi | Verifikasi |
|---|---|---|---|
| S: user A masuk Odoo B | `/sh_auth_oidc/callback` B | tautan per DB, tanpa signup, [role gate] | AC-Q1, Q7, Q10 |
| S: token substitution / code injection | callback, token endpoint | `aud`/`azp`/`nonce`/state session, PKCE, redirect eksak | AC-Q2, Q3 |
| T: pilih DB lain via header | semua path | Traefik overwrite `X-Sh-Odoo-Db`, hapus `X-Odoo-Database`, fail-closed | AC-Q4 |
| I: secret tenant lain | record provider (admin tenant) | file per `cr.dbname`, tanpa env per tenant, trusted issuer | AC-M1, Q6 |
| I: secret bocor di log/git/`docker inspect` | skrip, compose | file 0440 di luar git, tidak di env, gitleaks | AC-S1, S2 |
| D: 429 massal pada token back-channel | hairpin 10.100.0.1 | router token terpisah | AC-S6 |
| D: amplifikasi authorize/callback | `/sh_auth_oidc/*` | rate-limit per IP, `MAX_PENDING=5` session | AC-S7 |
| E: implicit flow core | `/auth_oauth/signin` | `_auth_oauth_validate` ditolak untuk provider OIDC | AC-Q8 |
| R: siapa menautkan user | skrip/control plane | `RESULT` + audit `provision_jobs`, event admin Keycloak ON | log review |

## 6. Task, agent, dependency (deteksi konflik file)

| ID | Agent | Isi | Depends | File/dir disentuh | Branch |
|---|---|---|---|---|---|
| S1 | odoo-developer | `sh_auth_oidc` 19.0.1.2.0: secret file per DB (+ role gate bila Q4), test, README | GATE 1 | repo addons `sh_auth_oidc/**` | `feat/odoo-developer-oidc-multitenant` (addons) |
| S2 | infra-engineer | `provision-odoo-sso.sh`, `odoo-sso-user.sh`, `lib/keycloak-admin.sh`; compose mount + env kedua pool (belum diterapkan live) | GATE 1 (kontrak nama env/file dari S1 — disepakati di prompt) | `scripts/**`, `odoo/pool-a/docker-compose.yml`, `staging/odoo/docker-compose.yml` | `feat/infra-odoo-sso-scripts` |
| S3 | infra-engineer (agent kedua, paralel S2) | router token hairpin realm platform(-staging), middleware `ratelimit-oidc`, template tenant `/sh_auth_oidc/` + render ulang | GATE 1 | `traefik/dynamic/platform/auth.yml`, `traefik/dynamic/middlewares/ratelimit.yml`, `templates/traefik-client.yml`, `traefik/dynamic/clients/demo-*.yml` | `feat/infra-odoo-sso-edge` |
| S4 | infra-engineer | Staging live: submodule staging → S1, `.env` + recreate `odoo-staging` (ukur), migrasi `demo_staging` ke file (hapus env lama), `provision-odoo-db.sh ssotest staging` + `provision-odoo-sso.sh` kedua tenant, terapkan S3 | S1, S2, S3 | `staging/odoo/**`, gitlink | `feat/infra-odoo-sso-staging` |
| S5 | qa-security | AC-Q1..Q10, AC-S3..S7 di staging | S4 | `docs/qa/2026-09-xx-plan04-staging.md` | `feat/qa-plan04` |
| S6 | infra-engineer | Prod: backup `demo_demo`, submodule pool-a, `.env` + recreate `odoo-pool-a` (jendela GATE Q5), `provision-odoo-sso.sh demo demo --host demo.erp.bimacreative.tech`, user uji | S5 PASS | `odoo/pool-a/**`, gitlink | `feat/infra-odoo-sso-prod` |
| S7 | qa-security | AC-P1/P2 + subset Q (Q1–Q4 dengan tenant uji sementara bila perlu) di prod | S6 | laporan QA | `feat/qa-plan04` |
| S8 | docs-versioning | docs, runbook, ADR 0008 accepted, ADR 0003 revisi, CHANGELOG, tag addons `v19.0.1.2.0` | S7 | `docs/**`, `CHANGELOG.md` | `docs/docs-versioning-plan04` |
| S9 | nextjs-developer | (plan terpisah) job control plane memanggil skrip | S8 | repo control-plane | — |

Paralel: **S1 ‖ S2 ‖ S3** (repo/file berbeda). Serial: S4 → S5 → S6 → S7 → S8. Realm export: `partial-export` butuh `manage-realm`
(F11) → S4/S6 memakai `GET /clients/<id>` (pola H4) untuk mencatat representasi, atau user melakukan partial export via console.

## 7. Risiko & rollback

| Risiko | Dampak | Mitigasi |
|---|---|---|
| Recreate pool prod | ≈10–30 s semua tenant pool-a (kini hanya `demo_demo`) | lakukan sekarang selagi belum ada client nyata; ukur di staging |
| Rate-limit per IP untuk kantor di balik NAT (Keycloak `/login-actions` 10/menit; Odoo `/web/login` 10/menit) | beberapa user sekantor login bersamaan → 429 | QA mengukur; bila perlu naikkan limit login dengan persetujuan (brute force realm tetap aktif) — backlog |
| FP AppSec pada callback | login gagal 403, IP bisa di-ban (HTTP saja sejak H6) | AC-Q9; exclusion sempit hanya bila terbukti |
| Logout Odoo tidak mengakhiri sesi Keycloak | di komputer bersama, klik SSO masuk lagi tanpa password | dokumentasikan; RP-initiated logout = backlog |
| Role klaim tidak muncul dengan `fullScopeAllowed=false` (**UNVERIFIED**) | Q4 gate menolak semua | S1/S4 verifikasi via `evaluate-scopes/generate-example-id-token`; tambah scope mapping role sendiri bila perlu |
| gid 101 host = `messagebus` | proses dbus bisa membaca file secret | pilih owner/gid dan catat (ADR 0008) |

Rollback: ADR 0008 §Rollback + `odoo.md` §Rollback. Urutan prod: provider Allowed OFF → (bila perlu) `password_login_policy=allow` →
submodule kembali `18f6bcf` + recreate → hapus mount/env → restore dump `demo_demo` hanya bila DB rusak (destruktif, konfirmasi Lead).
Router Traefik baru dihapus = hot-reload.

## 8. Pertanyaan GATE 1 (untuk user)

1. **Model realm** — satu realm `platform` untuk semua client (isolasi di Odoo + client per tenant) atau realm per client?
   **Rekomendasi: satu realm** (SSO dengan portal control plane, otomasi tanpa admin master; realm per client nanti via brokering bila diminta).
2. **Penyimpanan secret client** — (B) file per DB + perubahan kecil modul, tanpa restart per tenant; (C) disimpan di DB tenant (tanpa ubah kode,
   terbaca admin tenant); (A) tetap env var (restart pool tiap tenant/rotasi). **Rekomendasi: B.**
3. **Onboarding user** — user dibuat & ditautkan oleh ops via skrip (nanti control plane), undangan email Keycloak (set password; TOTP wajib untuk
   admin tenant), tanpa self-signup; aktifkan "Forgot password" realm `platform` (butuh login console Anda, SMTP sudah jalan).
   `admin` tenant tetap password lokal (break-glass ops). **Rekomendasi: ya untuk semuanya.**
4. **Pengaman tambahan per tenant di Keycloak** — role `odoo_access` per client yang dicek Odoo (cabut akses satu tenant dari pusat tanpa menyentuh Odoo).
   **Rekomendasi: ya** (kecil, opsional per provider; wajib diverifikasi di staging).
5. **Jendela restart** — satu recreate `odoo-pool-a` (±10–30 s, saat ini hanya tenant demo) + satu `odoo-staging`; Keycloak tidak restart.
   **Rekomendasi: boleh kapan saja setelah QA staging lulus, tanpa pemberitahuan (belum ada client nyata).**
