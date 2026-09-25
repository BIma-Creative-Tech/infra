# Operasional — Odoo CE 19.0 pool shared (T10)

- **Image:** `odoo:19.0-20260908@sha256:144175ec0039d52daff1d79f7e51c9281ca3c98b96c830feb49d09764a9f5d7c`
  (tag + digest index diverifikasi 2026-09-23: `docker buildx imagetools inspect` = Docker Hub tags API).
- **Terkait:** ADR 0003 D1 (`sh_dbfilter_header`), ADR 0004 §2 (RAM), plan 02 T10/§4, CLAUDE.md §3.2,
  `traefik.md`, `postgres.md`, `crowdsec.md`.

## Pool

| | prod `pool-a` | staging |
|---|---|---|
| Direktori | `/opt/infra/odoo/pool-a/` | `/opt/infra/staging/odoo/` |
| Container | `odoo-pool-a` | `odoo-staging` |
| Env tenant | `prod`, `demo` | `staging` |
| `dbfilter` | `^[a-z0-9_]+_(prod\|demo)$` | `^[a-z0-9_]+_staging$` |
| Role Postgres | `odoo_pool_a` (CREATEDB, conn limit 48) | `odoo_staging` (CREATEDB, conn limit 24) |
| workers / cron | 3 / 1 | 2 / 1 |
| `limit_memory_soft/hard` | 640 / 896 MiB | 512 / 768 MiB |
| `mem_limit` / `cpus` | 2560m / 2.0 | 1280m / 1.0 |
| Volume data (filestore + sessions) | `odoo_pool_a_data` | `odoo_staging_data` |
| Hostname default | `<slug>.erp.bimacreative.tech` | `<slug>.staging.bimacreative.tech` |

Isi tiap direktori pool:

| Path | Isi | Git |
|---|---|---|
| `docker-compose.yml` | service `odoo`, network `db` + `odoo-edge` (H1), tanpa port publish | ya |
| `odoo.conf` | opsi server — **tanpa secret** (lihat §Secret) | ya |
| `addons/shared` | **git submodule** `odoo-addons-shared` ter-pin (prod & staging `35e6a99` sejak plan 04, 2026-09-25) | gitlink |
| `addons/clients/<slug>` | repo addons client (`odoo-addons-<slug>`) — kosong saat ini | ya (per client) |
| `.env` | `PGHOST/PGPORT/PGUSER/PGPASSWORD`, `ODOO_ADMIN_PASSWD` (hash) — 600 root | **tidak** |
| `secrets/master-password` | master password plaintext (48 char) — 600 root | **tidak** |
| `secrets/tenants/<db>.admin-password` | password user `admin` tenant — 600 root | **tidak** |
| `secrets/oidc/<db>` | secret client OIDC per DB (plan 04, §SSO) — file 0440 / dir 0750 `root:101`, mount ro `/run/sh-oidc` | **tidak** |

## Konfigurasi (`odoo.conf`) — keputusan

Setiap key diverifikasi di `odoo/tools/config.py` image. Prioritas sumber opsi di Odoo 19:
runtime > CLI > **env** > file > default (`configmanager.options` ChainMap).

- `proxy_mode = True`, `list_db = False`, `server_wide_modules = base,rpc,web,sh_dbfilter_header`.
- **`dbfilter` memakai `[a-z0-9_]+`, bukan `[a-z0-9]+` (ADR 0003 / README modul)**: slug platform
  `^[a-z0-9-]{3,30}$` boleh memuat `-`, sedangkan nama DB/header hanya `[a-z0-9_]`. Nama DB =
  `<slug dengan '-'→'_'>_<env>` (injektif: slug tidak memuat `_`, env selalu komponen terakhir).
  Pool prod tidak pernah cocok dengan `*_staging` dan sebaliknya. **Lead: mohon ratifikasi di ADR 0003.**
- `addons_path = /mnt/extra-addons/shared,/mnt/extra-addons/clients/*` — glob didukung
  (`_check_addons_path` → `glob.glob`), dievaluasi saat start: **tambah repo client = restart pool**.
  Seluruh `./addons` di-mount **read-only** ke `/mnt/extra-addons` (image mendeklarasikan
  `VOLUME /mnt/extra-addons`; tanpa mount ini Docker membuat volume anonim writable).
- `http_interface = 0.0.0.0` eksplisit (Odoo 19 memperingatkan default berubah ke 127.0.0.1 di 20.0).
- `limit_time_cpu = 120`, `limit_time_real = 300` (ESTIMASI; default 60/120, contoh deploy.rst 600/1200).
  Install modul besar dari UI bisa melewati 300 s → install/upgrade lewat CLI (§Upgrade).
- `db_maxconn` 8 (prod) / 6 (staging) per proses; role `CONNECTION LIMIT` 48/24 (ESTIMASI, revisi T07/T19).
- `--without-demo=all` **tidak** dipakai: di 19.0 nilai non-boolean memicu warning ("since 19.0, invalid
  boolean value") — demo default mati; skrip memakai `--without-demo` / `--with-demo`.

## Secret

- **Koneksi DB** lewat env `PGHOST/PGPORT/PGUSER/PGPASSWORD` (`config.py` `env_name='PG*'`); entrypoint
  image tidak menambahkan `--db_password` ke argv bila `PGPASSWORD` ada (tidak terlihat di `ps`).
- **Master password (`admin_passwd`)**: opsi file-only mendapat env `ODOO_ADMIN_PASSWD` (config.py:
  `env_name = 'ODOO_' + dest.upper()`). Nilainya **hash** `pbkdf2_sha512` (600 000 rounds,
  `crypt_context` Odoo) — `verify_admin_password` menerima hash (diuji). Plaintext hanya di
  `secrets/master-password`. Dengan `list_db = False` database manager HTTP nonaktif total
  (create/drop/backup → "Access Denied", diuji), jadi master password praktis hanya cadangan.
- `scripts/odoo-pool-bootstrap.sh <pool-a|staging>` (idempoten) membuat/menyinkronkan `.env` dan
  secret. Nilai hash ditulis dalam kutip tunggal (`ODOO_ADMIN_PASSWD='$pbkdf2…'`) — compose tidak
  menginterpolasi `$` di dalam kutip tunggal (diuji).
- Rotasi password DB: `postgres.md` §Rotasi → `odoo-pool-bootstrap.sh <pool>` (sinkron `PGPASSWORD`)
  → `docker compose up -d`. Rotasi master password: hapus `secrets/master-password` → bootstrap →
  `docker compose up -d`.

## Start / stop

```bash
/opt/infra/scripts/odoo-pool-bootstrap.sh pool-a      # sekali / idempoten (juga: staging)
cd /opt/infra/odoo/pool-a && docker compose up -d     # staging: cd /opt/infra/staging/odoo
docker compose ps                                     # (healthy) — healthcheck curl /web/health
docker logs --tail 50 odoo-pool-a
docker compose down                                   # stop; volume odoo_pool_a_data TETAP
```
Clone ulang repo infra: `git submodule update --init` (URL submodule saat ini path lokal
`/opt/src/odoo-addons-shared` — ganti ke remote GitHub dengan `git submodule set-url` saat repo dipublikasikan;
`git -c protocol.file.allow=always` diperlukan untuk URL path lokal).

### Cek `sh_dbfilter_header` aktif
```bash
docker logs odoo-pool-a 2>&1 | grep 'sh_dbfilter_header active'
# … odoo.addons.sh_dbfilter_header.dbfilter: sh_dbfilter_header active: database selected from
#   X-Sh-Odoo-Db header (fail-closed), X-Odoo-Database ignored
```
Baris ini muncul di proses master **dan** proses gevent (websocket). Tidak ada baris / ada warning
"proxy_mode" → **jangan buka trafik**: modul tidak aktif = pemilihan DB tidak terkunci.

## Provisioning tenant

```bash
/opt/infra/scripts/provision-odoo-db.sh <slug> <prod|demo|staging> [--host <fqdn>]
/opt/infra/scripts/render-client-route.sh <slug> <prod|demo|staging> [--host <fqdn>]
```
Keduanya idempoten, harus root, output baris terakhir `RESULT key=value …` (exit ≠ 0 bila gagal).

`provision-odoo-db.sh`:
1. DB belum ada → `docker exec <pool> odoo -d <db> -i base,sh_dbfilter_header --stop-after-init
   --no-http --workers=0 --max-cron-threads=0` (+ `--with-demo` untuk env demo, `--without-demo` lainnya).
   Proses satu-kali di container pool (RAM dihitung di `mem_limit` pool). DB ada → cek owner = role pool
   dan `base` installed (DB setengah jadi → berhenti, **tidak pernah DROP**).
2. `sh_dbfilter_header` ter-install di DB (fungsinya tetap dari `server_wide_modules`).
3. `REVOKE ALL ON DATABASE <db> FROM PUBLIC` (default PG: PUBLIC boleh CONNECT DB baru).
4. `web.base.url=https://<host>` + `web.base.url.freeze=True`.
5. User `admin` (`base.user_admin`): password acak 40 char → `secrets/tenants/<db>.admin-password`;
   run berikutnya hanya memverifikasi hash. User lain dengan password = login (data demo `demo`/`portal`)
   diberi password acak (tidak disimpan).

`render-client-route.sh`: syarat DB ada; **DNS pre-check** (A = 31.97.50.221 di 1.1.1.1/8.8.8.8, tanpa
AAAA); hostname belum dipakai router client lain; render `templates/traefik-client.yml` →
`traefik/dynamic/clients/<slug>-<env>.yml` (644); isi sama → tidak menulis/HUP; berubah → `docker exec
traefik kill -HUP 1` + cek log error (H7: bukan `docker kill`, lihat `traefik.md`). `--remove` menghapus router (suspend) + HUP.
Env `demo` **wajib** `--host` (pola default `<slug>-demo.erp…` bisa bentrok dengan slug lain).

Tenant uji:
| slug | env | DB | pool | host | secret |
|---|---|---|---|---|---|
| demo | demo | `demo_demo` (data demo) | pool-a | `demo.erp.bimacreative.tech` | `/opt/infra/odoo/pool-a/secrets/tenants/demo_demo.admin-password` |
| demo | staging | `demo_staging` | staging | `demo.staging.bimacreative.tech` | `/opt/infra/staging/odoo/secrets/tenants/demo_staging.admin-password` |
| ssotest | staging | `ssotest_staging` (tenant regresi SSO lintas tenant, permanen) | staging | `ssotest.staging.bimacreative.tech` | `/opt/infra/staging/odoo/secrets/tenants/ssotest_staging.admin-password` |

## Router Traefik per tenant (`templates/traefik-client.yml`)

| Router | Rule | Prioritas | Middleware | Service |
|---|---|---|---|---|
| `<r>-dbmanager-deny` (`websecure` :443) | `PathPrefix(/web/database)` | 300 | crowdsec, **deny-all** (403) | `deny-sink` (tidak pernah tercapai) |
| `<r>-dbmanager` (**entrypoint `admin`** :8443, H5b) | `PathPrefix(/web/database)` | 300 | crowdsec, **ipallowlist-admin**, odoo-security-headers, ratelimit-default, strip-odoo-db-headers, `<r>-db` | `<pool>-http` |
| `<r>-websocket` | `PathPrefix(/websocket)` | 200 | crowdsec, odoo-security-headers, ratelimit-default, strip, `<r>-db` | `<pool>-ws` (:8072) |
| `<r>-login` | `/web/login`, `/web/session/authenticate`, `/web/reset_password*`, `/web/signup*` | 200 | crowdsec, odoo-security-headers, ratelimit-default, **ratelimit-login**, strip, `<r>-db` | `<pool>-http` |
| `<r>-oidc` (plan 04 S3) | `PathPrefix(/sh_auth_oidc/)` (authorize + callback) | 200 | crowdsec, odoo-security-headers, ratelimit-default, **ratelimit-oidc** (20/menit, burst 20 per IP), strip, `<r>-db` | `<pool>-http` |
| `<r>` | `Host(<fqdn>)` | 100 | crowdsec, odoo-security-headers, ratelimit-default, strip, `<r>-db` | `<pool>-http` (:8069) |

`<r>-db` = `customRequestHeaders: X-Sh-Odoo-Db: "<db>"`, `X-Odoo-Database: ""`. Service `odoo-pool-a-{http,ws}`,
`odoo-staging-{http,ws}` dan middleware `odoo-security-headers` ada di `traefik/dynamic/platform/odoo-pools.yml`.
`odoo-security-headers` = `security-headers` **tanpa `frameDeny`** (Odoo mengatur `X-Frame-Options` per route:
webclient `DENY`, login/portal `SAMEORIGIN`; editor/website builder memakai iframe same-origin) dan
`Permissions-Policy` `camera/microphone/geolocation=(self)` (Discuss RTC, scan barcode, hr_attendance).
Sertifikat: resolver `le-http` (production) per hostname.

**Database manager (H5b, 2026-09-23):** `/web/database*` **tidak pernah** lewat :443 — `<r>-dbmanager-deny` → `deny-all`
403 untuk **semua** IP (dulu `ipallowlist-admin` di `websecure`; hairpin dari container mana pun ke IP publik :443 tiba sebagai
`10.100.0.1` dan lolos — terbukti sebelum H5b: dari host `GET /web/database/selector` = 200 dari Odoo). Operator: tunnel
`ssh -p 2221 -N -L 8443:127.0.0.1:8443 admin@31.97.50.221` (`traefik.md` §Entrypoint `admin`) → `https://<host>:8443/web/database/...`
(header `X-Sh-Odoo-Db` tenant tetap dipasang). Hanya `/web/database*` yang di-route di :8443 — path lain host tenant (termasuk
`/web/static/*` & `/web/login`) → 404 di :8443. Ini lapisan tambahan: `list_db = False` tetap membuat Odoo menampilkan
"The database manager has been disabled by the administrator" (HTTP 200 dari Odoo, diuji 2026-09-23). Dari host:
`curl --resolve <host>:8443:127.0.0.1 https://<host>:8443/web/database/selector`.

## AppSec (CrowdSec CRS) — pengecualian Odoo

OWASP CRS (`appsec-crs-inband`) memblok simpan record Odoo biasa: konten editor HTML dengan `style`
inline, `<img>`, warna teks → 403 (rule 941100/941160, XSS libinjection, `ARGS.json.params…`), juga
posting chatter HTML. Pengecualian **sempit** di
`security/crowdsec/appsec-configs/odoo-crs-exclusions.yaml` (`pre_eval` → `RemoveInBandRuleByTag("attack-xss")`)
hanya untuk POST ke `/web/dataset/call_kw/`, `/web/dataset/call_button/`, `/mail/message/`, `/mail/thread/`,
`/discuss/channel/`, `/html_editor/`, `/web_editor/`. SQLi/RCE/LFI CRS, virtual patching & generic rules tetap
aktif; XSS di path lain tetap 403. Payload `<script>`/`onmouseover` yang lolos WAF di path itu disanitasi
Odoo (`fields.Html`, diuji: tersimpan `<p>x</p>`). Cek false positive baru:
```bash
docker exec crowdsec cscli alerts list -l 20          # scenario "anomaly score block: …"
docker exec crowdsec cscli alerts inspect <id> -d     # rule_name, matched_zones, uri
```
Tambah path hanya bila FP nyata terbukti; catat di sini. Diketahui masih mungkin FP: teks berisi pola SQL
(mis. "UNION SELECT") pada field biasa (rule 942 tetap aktif).

## SSO — `sh_auth_oidc` ↔ Keycloak, multi-tenant (plan 04, ADR 0008)

Desain: ADR 0003 D2 + **ADR 0008** (satu realm, satu client per tenant-env, secret per DB dari file) + README modul
(`addons/shared/sh_auth_oidc/README.md`). Modul **19.0.1.2.0** (addons `35e6a99`) di **kedua** pool sejak 2026-09-25.
Prosedur langkah demi langkah (onboard/user/rotasi/offboard/troubleshooting): **`docs/runbooks/odoo-sso-tenant.md`**.

Tenant SSO aktif (2026-09-25):

| DB | Pool | Host | Realm | Client Keycloak | Provider Odoo |
|---|---|---|---|---|---|
| `demo_demo` | `odoo-pool-a` | `demo.erp.bimacreative.tech` | `platform` | `odoo-demo-demo` | id 4, secret `file`, role gate `odoo_access` |
| `demo_staging` | `odoo-staging` | `demo.staging.bimacreative.tech` | `platform-staging` | `odoo-demo-staging` | id 4, secret `file`, role gate `odoo_access` |
| `ssotest_staging` | `odoo-staging` | `ssotest.staging.bimacreative.tech` | `platform-staging` | `odoo-ssotest-staging` | id 4, secret `file`, role gate `odoo_access` |

`ssotest_staging` = tenant staging kedua **permanen** untuk regresi lintas tenant (QA S5) — jangan dihapus.

### Model per tenant-env

| Komponen | Pola | Dibuat oleh |
|---|---|---|
| Realm | prod/demo → `platform`, staging → `platform-staging` (`kc_realm_for_env`, `scripts/lib/keycloak-admin.sh`) | — (sudah ada) |
| Client Keycloak | `odoo-<slug>-<env>`: confidential, standard flow saja, PKCE S256, RS256, `fullScopeAllowed=false`, default scopes `basic profile email acr`, optional kosong, web origins kosong, redirect URI **eksak** `https://<host>/sh_auth_oidc/callback` untuk setiap host (`scripts/lib/odoo_sso_kc.py`) | `provision-odoo-sso.sh` |
| Role gate | client role `odoo_access` + mapper *User Client Role* dengan nama klaim **literal** `resource_access.odoo-<slug>-<env>.roles` (ID/access/userinfo) | `provision-odoo-sso.sh` |
| Secret client | file host `<pool>/secrets/oidc/<db>` (`0440 root:101`, dir `0750 root:101`, tanpa newline, di luar git) → di container `/run/sh-oidc/<db>` (bind ro) | `provision-odoo-sso.sh` |
| Provider Odoo | `Keycloak (<realm>)`, client_id `odoo-<slug>-<env>`, `sh_oidc_enabled`, issuer + auth/token/JWKS/userinfo realm, `sh_oidc_secret_source=file`, `sh_oidc_client_secret_env` kosong, `sh_oidc_required_client_role=odoo_access`, `sh_oidc_allow_signup=False`, label "Masuk dengan SSO" | `provision-odoo-sso.sh` (`odoo shell`) |
| Parameter DB | `auth_signup.invitation_scope=b2b`, `auth_oauth.authorization_header=True`; provider lain (Odoo.com, dll.) Allowed OFF; ICP legacy `sh_auth_oidc.client_secret.*` dihapus | `provision-odoo-sso.sh` |
| Router Traefik | `<r>-oidc` (`PathPrefix(/sh_auth_oidc/)`, `ratelimit-oidc` 20/menit burst 20 per IP) — §Router Traefik per tenant | `render-client-route.sh` |
| User | user Keycloak (username = email) + role `odoo_access` + tautan `res.users` (`oauth_provider_id`, `oauth_uid` = id Keycloak) | `odoo-sso-user.sh` |

gid 101 = grup `odoo` di container (uid 100:101); di host gid 101 bernama `messagebus` (`ls -l` menampilkan
`root:messagebus`) — ADR 0008 §Security implications.

### Env pool (compose, kedua pool — `08739f4`)

| Variabel | prod `pool-a` | staging |
|---|---|---|
| `SH_OIDC_SECRET_DIR` | `/run/sh-oidc` | `/run/sh-oidc` |
| `SH_OIDC_TRUSTED_ISSUERS` | `https://auth.bimacreative.tech/realms/platform` | `https://auth.bimacreative.tech/realms/platform-staging` |

Keduanya di blok `environment:` compose (bukan secret); mount `./secrets/oidc` → `/run/sh-oidc` `read_only`,
`create_host_path: false` (`up` gagal bila direktori belum ada — dibuat `odoo-pool-bootstrap.sh`). Secret **tidak** di env:
modul membaca `<SH_OIDC_SECRET_DIR>/<cr.dbname>` di setiap token exchange (tanpa cache) → tenant baru & rotasi **tanpa
restart pool**. Nama file = DB request (bukan nilai provider): provider di DB B yang menyebut `client_id` tenant A tetap
membaca file DB B (QA S5 AC-Q6). Issuer provider wajib ada di `SH_OIDC_TRUSTED_ISSUERS`, kalau tidak secret tidak dilepas.
Mengubah env/mount = `docker compose up -d --force-recreate` (downtime semua tenant pool; §Riwayat).

> Sisa migrasi staging (dicek 2026-09-25): `staging/odoo/.env` dan env container `odoo-staging` **masih** memuat
> `SH_OIDC_ODOO_DEMO_STAGING_SECRET` (sumber lama T15), padahal provider `demo_staging` sudah `sh_oidc_secret_source=file`
> dengan `sh_oidc_client_secret_env` kosong (QA S5 baseline). Tidak dipakai modul; hapus baris itu dari `.env` pada recreate
> staging berikutnya (secret masih terlihat di `docker inspect odoo-staging`). Pool prod tidak punya env secret apa pun.

### Skrip (harus root, idempoten, baris terakhir `RESULT …`, jangan `bash -x`)

```bash
# client Keycloak + role + mapper + secret file + modul/ICP/provider Odoo + smoke
/opt/infra/scripts/provision-odoo-sso.sh <slug> <prod|demo|staging> [--host <fqdn>]… [--rotate-secret] [--disable] [--dry-run] [--skip-smoke]
# user: buat/undang user Keycloak, role odoo_access, tautkan res.users yang SUDAH ada
/opt/infra/scripts/odoo-sso-user.sh <slug> <env> --email <e> [--login <odoo login>] [--create-kc] [--admin] [--grant|--revoke] [--resend-invite] [--first-name <f>] [--last-name <l>] [--dry-run]
```
- Admin REST lewat client `automation` realm terkait (secret `identity/keycloak/secrets/automation-<realm>.secret`), hanya via
  entrypoint `admin` `https://auth.bimacreative.tech:8443` + `--resolve …:8443:127.0.0.1` (H5); body berisi `${` ditolak sebelum
  dikirim (CRS 932130) — `keycloak.md` §Client Odoo per tenant.
- `provision-odoo-sso.sh`: `--host` = daftar host **lengkap** (redirect URI di-PUT persis daftar ini); env `demo` wajib `--host`.
  Menolak jalan bila kode modul di pool < 19.0.1.2.0 atau DB masih memuat versi lama (tidak `-u` otomatis). Provider Odoo
  **tidak** diubah bila file secret belum terbaca di container (cek sha256 lewat mount). `--skip-smoke` dipakai bila router
  Traefik tenant belum ada. Output: `RESULT db= realm= client= provider= hosts= changed= secret_file=`.
- `odoo-sso-user.sh`: **tidak pernah** membuat `res.users` (hak akses = keputusan bisnis admin tenant/ops) dan tidak pernah
  menautkan `base.user_admin`. `--create-kc`: user Keycloak `enabled`, `emailVerified=false`, required actions
  `UPDATE_PASSWORD` (+ `CONFIGURE_TOTP` dengan `--admin`) lalu `execute-actions-email` (undangan). Output `RESULT` tanpa
  email/login (log job tanpa PII).

### Password lokal, break-glass, Keycloak down

- User **tertaut** (`oauth_provider_id` + `oauth_uid`) → password lokal ditolak (web, `/web/session/authenticate`, XML-RPC/JSON-RPC,
  identity check); API key yang sudah ada tetap berlaku untuk RPC (T15, README §Local password policy). Diuji ulang QA S5/S7 Q8.
- `admin` tenant (`base.user_admin`) **tidak ditautkan** → tetap password lokal, dipakai ops platform saja
  (`<pool>/secrets/tenants/<db>.admin-password`). `sh_oidc_password_exempt` tidak dipakai untuk user client.
- **Keycloak down** (user tidak bisa login): per DB set `sh_auth_oidc.password_login_policy = allow` (nilai lain/kosong =
  kebijakan aktif, fail-closed) — user tertaut butuh password lokal yang diketahui (reset oleh admin tenant). Kembalikan dengan
  menghapus parameter setelah Keycloak pulih:
  ```bash
  docker exec -i <pool> odoo shell -c /etc/odoo/odoo.conf -d <db> --no-http --workers=0 --max-cron-threads=0 --log-level=warn <<'PY'
  env['ir.config_parameter'].sudo().set_param('sh_auth_oidc.password_login_policy', 'allow')   # pulih: set_param(..., False)
  env.cr.commit()
  PY
  ```
  (Nama parameter & semantik: README modul; perintah `odoo shell` di atas mengikuti pola skrip, belum dijalankan untuk
  parameter ini di plan 04.)
- Logout Odoo tidak mengakhiri sesi Keycloak (RP-initiated logout = backlog, plan 04 §1 OUT).

### Rotasi secret client
`provision-odoo-sso.sh <slug> <env> [--host …] --rotate-secret` → `POST …/clients/<uuid>/client-secret` lalu file ditulis atomik
(temp file + `mv` di direktori yang di-mount). **Tanpa restart**; login yang sedang di tengah exchange saat rotasi bisa gagal
sekali (`oauth_error=2`, ulangi). Rotasi tanpa restart diuji di test modul (19.0.1.2.0, "rotation without restart").

### Nonaktifkan / rollback
- **Satu tenant:** `provision-odoo-sso.sh <slug> <env> [--host …] --disable` → provider Allowed OFF + client Keycloak
  `enabled=false` (tidak menghapus apa pun; smoke memastikan link hilang). User tertaut lalu tidak bisa login sama sekali →
  `password_login_policy=allow` (di atas) atau hapus tautan per user. Aktifkan lagi: jalankan skrip tanpa `--disable`.
- **Satu user:** `odoo-sso-user.sh … --revoke` (cabut role `odoo_access` tenant itu; login → `oauth_error=2`). Semua tenant
  sekaligus: disable user Keycloak (console/Admin REST).
- **Modul (pool):** submodule kembali ke `5fa8b70` (19.0.1.1.0; prod sebelum plan 04 = `18f6bcf`, tanpa `sh_auth_oidc` ter-install di `demo_demo`) + `-u sh_auth_oidc` per DB + recreate; provider harus kembali ke sumber env
  (`sh_oidc_client_secret_env` + env di `.env`) karena 19.0.1.1.0 tidak mengenal sumber file (ADR 0008 §Rollback). Backup sebelum
  plan 04: `/opt/infra/backups/odoo/demo_staging-20260925-100640-pre-plan04.{dump,filestore.tgz}`,
  `/opt/infra/backups/odoo/demo_demo-20260925-110513-pre-plan04.{dump,filestore.tgz}` (restore: §Rollback, destruktif).
- **Edge:** router `<r>-oidc` / `auth-oidc-backchannel` dihapus = hot-reload Traefik; exclusion WAF `local/oidc-backchannel-exclusions`
  (`crowdsec.md`) dicabut = recreate crowdsec.

### Riwayat
- **T15 (2026-09-23):** SSO pertama di `demo_staging` (modul 19.0.1.1.0), secret dari env `SH_OIDC_ODOO_DEMO_STAGING_SECRET`
  di `.env` pool, client/provider dibuat manual; E2E + kebijakan password lokal diuji. Celah: env global per pool (tenant baru/
  rotasi = recreate pool, env bisa dirujuk lintas DB) → ADR 0008.
- **Plan 04 (2026-09-25):** staging recreate 10:07 WIB (±11 s; + satu restart staging tambahan ±10 s oleh Lead), `demo_staging`
  `-u` → provider sumber file + role gate; tenant `ssotest_staging` dibuat; CrowdSec recreate 10:50:07–10:50:54 WIB (±47 s semua
  host ber-CrowdSec 403) untuk BUG-S5-01; prod `odoo-pool-a` recreate 11:05:47–11:05:55 WIB (±8 s), `demo_demo` SSO aktif.
  QA: `docs/qa/2026-09-25-plan04-staging.md` (11/11 PASS), `docs/qa/2026-09-25-plan04-prod.md` (PASS).

## Upgrade modul (staging dulu, backup sebelum `-u`)

1. **Staging**: naikkan submodule staging saja:
   ```bash
   cd /opt/infra/staging/odoo/addons/shared && git fetch && git checkout <commit>
   cd /opt/infra/staging/odoo && docker compose up -d --force-recreate   # muat kode baru
   ```
2. **Backup setiap DB terdampak** (wajib sebelum `-u`): `systemctl start restic-backup.service` (T13, `backup.md`)
   → `RESULT status=ok`. Alternatif manual satu DB (file lokal):
   ```bash
   DB=<db>; C=<odoo-staging|odoo-pool-a>; TS=$(date +%Y%m%d-%H%M%S); B=/opt/infra/backups/odoo
   install -d -m 700 $B
   docker exec postgres pg_dump -U postgres -Fc -d $DB > $B/$DB-$TS.dump
   docker exec $C tar -C /var/lib/odoo/filestore -czf - $DB > $B/$DB-$TS.filestore.tgz
   chmod 600 $B/$DB-$TS.*; docker exec -i postgres pg_restore -l < $B/$DB-$TS.dump | head   # dump terbaca
   ```
   (diuji 2026-09-23 pada `demo_staging`; `backups/` di-ignore git; disk sama = bukan backup sejati.)
3. **Update**:
   ```bash
   docker exec -i $C odoo -c /etc/odoo/odoo.conf -d $DB --no-http --workers=0 --max-cron-threads=0 \
     -u <modul> --stop-after-init 2>&1 | tee /opt/infra/backups/odoo/$DB-$TS-upgrade.log
   ```
   Wajib untuk modul `sh_dbfilter_header` setelah image Odoo baru: jalankan test modul
   (`/opt/src/odoo-addons-shared/test/run-tests.sh sh_dbfilter_header`) — modul memakai internal `odoo.http`.
4. QA di staging → ulangi 1–3 untuk `odoo/pool-a` (prod) + commit gitlink submodule baru.

## Rollback

- **Kode addons**: `git -C <pool>/addons/shared checkout <commit-lama>` → `docker compose up -d --force-recreate`.
- **DB setelah `-u` gagal** (DESTRUKTIF — konfirmasi Lead): hentikan akses (router `--remove`), lalu
  `docker exec postgres dropdb -U postgres <db>`; `docker exec postgres createdb -U postgres -O <role> -T template0 <db>`;
  `docker exec -i postgres pg_restore -U postgres -d <db> --no-owner --role=<role> < <dump>`;
  filestore: `docker exec -i <C> sh -c 'rm -rf /var/lib/odoo/filestore/<db> && tar -C /var/lib/odoo/filestore -xzf -' < <tgz>`;
  `REVOKE ALL ON DATABASE <db> FROM PUBLIC`; render router lagi. (Langkah restore BELUM diuji — T13.)
- **Image Odoo**: kembalikan tag+digest di compose → `docker compose up -d`.
- **`sh_dbfilter_header`** (ADR 0003 Rollback): hapus dari `server_wide_modules` **hanya** bersama `dbfilter` eksak satu DB.
- **Router tenant**: `render-client-route.sh <slug> <env> --remove`.

## Keamanan — catatan

- Odoo di network `db` (internal) + **`odoo-edge`** (H1, 2026-09-23); **tidak ada port di-publish**
  (`ss -tlnp` tanpa 8069/8072).
- `user 100:101`, `read_only: true` + tmpfs `/tmp` (512m; wkhtmltopdf/report diuji OK), `cap_drop: [ALL]`,
  `no-new-privileges`, tanpa `cap_add`. Writable hanya volume data `/var/lib/odoo`.
- **Network `odoo-edge`** (`10.100.3.0/24`, dibuat `traefik/scripts/bootstrap.sh`, bukan `--internal`):
  anggota **hanya** `traefik`, `odoo-pool-a`, `odoo-staging`. Pool Odoo **tidak** lagi di `proxy`, jadi
  container lain di `proxy` (keycloak, control-plane, whoami, …) tidak bisa me-resolve/menghubungi
  `odoo-pool-a:8069`/`:8072` langsung dan memasang `X-Sh-Odoo-Db` sendiri (melewati CrowdSec/ratelimit).
  Diuji: container uji di `proxy` (`10.100.0.250`) → `nslookup odoo-pool-a` SERVFAIL, `curl http://odoo-pool-a:8069`
  dan `http://10.100.3.4:8069` → timeout. Egress Odoo tetap ada (OIDC ke `auth.bimacreative.tech` via hairpin
  IP publik → 200). **Pool/dedicated Odoo baru wajib join `odoo-edge`, bukan `proxy`.** Cek anggota:
  `docker network inspect odoo-edge --format '{{range .Containers}}{{.Name}} {{end}}'`.
- Cookie `session_id` dari core Odoo 19 tanpa `Secure`/`SameSite` (`odoo/http.py` `set_cookie(... httponly=True)`).
  HSTS (`max-age` masih 300) + redirect HTTP→HTTPS mengurangi risiko; perbaikan permanen butuh keputusan Lead.
- Semua modul di `addons/clients/*` terlihat oleh semua DB di pool (tenant admin bisa meng-install modul
  client lain). Prefix `cl_<slug>_` + review; pertimbangkan pool terpisah bila modul client sensitif.
