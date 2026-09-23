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
| `addons/shared` | **git submodule** `odoo-addons-shared` ter-pin (prod `18f6bcf`, staging `5fa8b70` sejak T15) | gitlink |
| `addons/clients/<slug>` | repo addons client (`odoo-addons-<slug>`) — kosong saat ini | ya (per client) |
| `.env` | `PGHOST/PGPORT/PGUSER/PGPASSWORD`, `ODOO_ADMIN_PASSWD` (hash) — 600 root | **tidak** |
| `secrets/master-password` | master password plaintext (48 char) — 600 root | **tidak** |
| `secrets/tenants/<db>.admin-password` | password user `admin` tenant — 600 root | **tidak** |

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
`traefik/dynamic/clients/<slug>-<env>.yml` (644); isi sama → tidak menulis/HUP; berubah → `docker kill
--signal=HUP traefik` + cek log error. `--remove` menghapus router (suspend) + HUP.
Env `demo` **wajib** `--host` (pola default `<slug>-demo.erp…` bisa bentrok dengan slug lain).

Tenant uji:
| slug | env | DB | pool | host | secret |
|---|---|---|---|---|---|
| demo | demo | `demo_demo` (data demo) | pool-a | `demo.erp.bimacreative.tech` | `/opt/infra/odoo/pool-a/secrets/tenants/demo_demo.admin-password` |
| demo | staging | `demo_staging` | staging | `demo.staging.bimacreative.tech` | `/opt/infra/staging/odoo/secrets/tenants/demo_staging.admin-password` |

## Router Traefik per tenant (`templates/traefik-client.yml`)

| Router | Rule | Prioritas | Middleware | Service |
|---|---|---|---|---|
| `<r>-dbmanager-deny` (`websecure` :443) | `PathPrefix(/web/database)` | 300 | crowdsec, **deny-all** (403) | `deny-sink` (tidak pernah tercapai) |
| `<r>-dbmanager` (**entrypoint `admin`** :8443, H5b) | `PathPrefix(/web/database)` | 300 | crowdsec, **ipallowlist-admin**, odoo-security-headers, ratelimit-default, strip-odoo-db-headers, `<r>-db` | `<pool>-http` |
| `<r>-websocket` | `PathPrefix(/websocket)` | 200 | crowdsec, odoo-security-headers, ratelimit-default, strip, `<r>-db` | `<pool>-ws` (:8072) |
| `<r>-login` | `/web/login`, `/web/session/authenticate`, `/web/reset_password*`, `/web/signup*` | 200 | crowdsec, odoo-security-headers, ratelimit-default, **ratelimit-login**, strip, `<r>-db` | `<pool>-http` |
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

## SSO — `sh_auth_oidc` ↔ Keycloak (T15)

Desain: ADR 0003 D2 + README modul (`addons/shared/sh_auth_oidc/README.md`). Aktif di `demo_staging`
(staging, modul `19.0.1.1.0`, submodule staging `5fa8b70`). **Prod (`pool-a`, `demo_demo`) belum** — menyusul setelah QA.

### Komponen per tenant

| Komponen | Nilai (`demo_staging`) | Pola |
|---|---|---|
| Client Keycloak | `odoo-demo-staging` @ realm `platform-staging` | `odoo-<slug>-<env>` |
| Konfigurasi client | confidential (`client-secret`), standard flow saja (implicit/direct grant/service account/device/CIBA/token exchange OFF), `pkce.code.challenge.method=S256`, `id.token.signed.response.alg=RS256`, `fullScopeAllowed=false`, default scopes `basic profile email acr`, optional scopes kosong, web origins kosong, frontchannel logout OFF | sama |
| Redirect URI (eksak) | `https://demo.staging.bimacreative.tech/sh_auth_oidc/callback` | `https://<host tenant>/sh_auth_oidc/callback` |
| Secret client | `/opt/infra/identity/keycloak/secrets/platform-staging-odoo-demo-staging.secret` (600, tanpa newline) | `<realm>-<client>.secret` |
| Env pool (`.env` 600) | `SH_OIDC_ODOO_DEMO_STAGING_SECRET=<secret>`, `SH_OIDC_TRUSTED_ISSUERS=https://auth.bimacreative.tech/realms/platform-staging` | `SH_OIDC_<CLIENT>_SECRET`; issuer dipisah koma |
| Provider Odoo | `Keycloak (platform-staging)`, client_id `odoo-demo-staging`, *OIDC Code Flow + PKCE* ON, issuer realm, token/JWKS/userinfo endpoint realm, *Client Secret Env Variable* `SH_OIDC_ODOO_DEMO_STAGING_SECRET`, *Allow Sign Up* OFF | sama |
| Parameter DB | `auth_oauth.authorization_header=True`, `auth_signup.invitation_scope=b2b` (install `auth_oauth` menarik `auth_signup` yang default-nya `b2c` = signup publik), provider bawaan *Odoo.com Accounts* dinonaktifkan | sama |

Compose **tidak** diubah: `env_file: .env` sudah meneruskan semua variabel ke container. Env baru butuh
`docker compose up -d --force-recreate`. `odoo-pool-bootstrap.sh` mempertahankan kunci lain di `.env` (hanya
menulis `PG*`/`ODOO_ADMIN_PASSWD`).

Client dibuat lewat Admin REST dengan client `automation` (service account, token dari
`/realms/platform-staging/protocol/openid-connect/token`, Admin API via `--resolve auth.bimacreative.tech:443:127.0.0.1` —
sejak H5 (2026-09-23) Admin API hanya via entrypoint `admin`: `--resolve auth.bimacreative.tech:8443:127.0.0.1` + URL `:8443`).
**Catatan WAF:** sejak H4 (2026-09-23) rule CRS 911100 dikecualikan HANYA untuk `auth.bimacreative.tech/admin/realms/*`
dari IP allowlist → PUT/DELETE Admin REST via `automation` berfungsi (lihat `crowdsec.md` §Pengecualian CRS 911100).
Body berisi `${…}` (rule 932130) tetap diblok — tulis nama klaim mapper secara literal. `partial-export` butuh `manage-realm` (tidak dimiliki `automation`) → realm-export
git belum memuat client ini (konfigurasi tercatat di tabel di atas).

### Aktivasi tenant (urutan)
1. Backup DB (§Upgrade langkah 2).
2. Checkout submodule pool ke commit modul → `docker compose up -d --force-recreate`.
3. `docker exec -i <pool> odoo -c /etc/odoo/odoo.conf -d <db> --no-http --workers=0 --max-cron-threads=0 -i sh_auth_oidc --stop-after-init` (`-u` bila sudah ter-install).
4. Buat client Keycloak (tabel) → simpan secret (600, tanpa newline) → tambah `SH_OIDC_*` ke `<pool>/.env` → recreate pool.
5. Buat provider (Settings > Users & Companies > OAuth Providers, mode debug, atau `odoo shell`), set parameter DB (tabel).
6. Uji: `/web/login` menampilkan tombol "Masuk dengan SSO" (`/sh_auth_oidc/authorize?provider=<id>`).

### Menautkan user (tanpa auto-create)
Login SSO hanya untuk `res.users` dengan `oauth_provider_id` = provider **dan** `oauth_uid` = Keycloak user id
(claim `sub`, UUID di Admin API `GET /admin/realms/<realm>/users?username=<u>&exact=true` → `id`). Tidak ada
pencocokan email. Set di form user tab **SSO (OIDC)** (admin, mode biasa) atau `odoo shell`:
```python
p = env['auth.oauth.provider'].search([('client_id', '=', 'odoo-demo-staging')])
env['res.users'].search([('login', '=', '<login>')]).write({'oauth_provider_id': p.id, 'oauth_uid': '<keycloak user id>'})
env.cr.commit()
```
**Efek kebijakan password (T15):** begitu tertaut, password lokal Odoo user tersebut **ditolak** (web login,
`/web/session/authenticate`, XML-RPC/JSON-RPC, identity check ganti password/API key). API key yang sudah ada tetap
berlaku untuk RPC. User tanpa tautan (mis. `admin` tenant = admin teknis platform, portal) tetap memakai password.
Admin teknis yang tertaut tetap boleh password hanya bila anggota `base.group_system` **dan** centang
*OIDC: Allow Local Password (technical admin)*. Detail: README modul §Local password policy.

### Rotasi secret client
1. Admin console (tunnel) → realm → Clients → `odoo-<slug>-<env>` → Credentials → *Regenerate* (atau
   `POST /admin/realms/<realm>/clients/<uuid>/client-secret` dengan `automation` — metode POST, belum diuji).
2. Tulis ke file secret tanpa newline (600), update baris `SH_OIDC_<CLIENT>_SECRET` di `<pool>/.env`
   (jangan `echo` nilai ke terminal/log).
3. `cd <pool> && docker compose up -d --force-recreate` (±10 s). Login SSO yang sedang di tengah jalan saat rotasi gagal sekali (ulangi).
4. Uji login SSO.

### Rollback
- **Nonaktifkan SSO tenant**: provider → *Allowed* OFF (tombol hilang, `/sh_auth_oidc/*` menolak provider nonaktif).
  User tertaut tidak bisa login password selama tautan ada → pilih: (a) `ir.config_parameter`
  `sh_auth_oidc.password_login_policy = allow` (kebijakan password mati untuk DB itu; user perlu password yang
  diketahui — reset oleh admin), atau (b) hapus tautan (`oauth_provider_id`/`oauth_uid` kosong) per user.
  Kembalikan: hapus parameter / set ke nilai lain (nilai selain `allow` = kebijakan aktif, fail-closed).
- **Modul**: uninstall `sh_auth_oidc` per DB (login password lokal kembali untuk semua user), atau
  submodule kembali ke `18f6bcf` + `-u sh_auth_oidc` (versi tanpa kebijakan password).
- Backup sebelum aktivasi `demo_staging`: `/opt/infra/backups/odoo/demo_staging-20260923-142718.{dump,filestore.tgz}`.

### Uji E2E (T15, 2026-09-23, `demo_staging`)
curl + cookie jar: `/web/login` (200, link provider) → `/sh_auth_oidc/authorize?provider=4` (303 ke Keycloak,
parameter `response_type client_id redirect_uri scope state nonce code_challenge code_challenge_method`) →
form login Keycloak (200) → POST kredensial (302 ke `/sh_auth_oidc/callback?state&session_state&iss&code`) →
callback (303 → `/odoo`) → `/web/session/get_session_info` = `db demo_staging`, `uid` = user uji. Negatif:
password lokal user tertaut via `/web/session/authenticate` → `AccessDenied`, via XML-RPC → `False`; `admin` tenant
password → OK; callback dengan `state` palsu → 303 `/web/login?oauth_error=2`, tanpa sesi. ID token contoh
(Admin API `evaluate-scopes/generate-example-id-token`): `iss` realm, `aud`=`azp`=`odoo-demo-staging`, `sub` = user id.

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
