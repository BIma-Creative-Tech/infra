# Operasional — Keycloak (SSO, T06)

- **Stack:** `/opt/infra/identity/keycloak/` · image lokal `infra/keycloak:26.7.4-optimized`, dibangun dari
  `Containerfile` (`FROM quay.io/keycloak/keycloak:26.7.4@sha256:82a778…`, `kc.sh build` dengan
  `KC_DB=postgres`, `KC_HEALTH_ENABLED=true`, `KC_METRICS_ENABLED=true`). Jalan: `start --optimized` (mode produksi).
- **Publik:** `https://auth.bimacreative.tech` (router `traefik/dynamic/platform/auth.yml`, sertifikat LE production).
- **DB:** `keycloak` @ Postgres shared (`postgres:5432`, network `db`), pool maks 20 (limit role 30).
- **Terkait:** ADR 0001/0002/0004, plan 02 T06, docs Keycloak 26.7.4 `guides/server/{hostname,reverseproxy,
  containers,management-interface,bootstrap-admin-recovery}.adoc`.

## Konfigurasi utama (`docker-compose.yml`)

| Opsi (env) | Nilai | Alasan |
|---|---|---|
| `KC_HOSTNAME` | `https://auth.bimacreative.tech` | URL publik tetap → issuer token |
| `KC_HOSTNAME_ADMIN` | `https://auth.bimacreative.tech:8443` | admin console hanya lewat SSH tunnel (lokal :8443 → entrypoint Traefik `admin` `127.0.0.1:8443` di VPS, H5) |
| realm `master` atribut `frontendUrl` | `https://auth.bimacreative.tech:8443` | login realm master (form + token) juga lewat :8443; tanpa ini form login admin mem-POST ke :443 publik → 403 |
| `KC_HTTP_ENABLED` | `true` | TLS di-terminate Traefik; 8080 hanya di network `proxy` |
| `KC_PROXY_HEADERS` | `xforwarded` | Traefik menimpa `X-Forwarded-*` (forwardedHeaders tidak dipercaya dari klien) |
| `KC_CACHE` | `local` | satu node, tanpa JGroups |
| health/metrics | management port **9000**, tidak di-route | docs management-interface |

Hardening container: `user 1000`, `read_only` + tmpfs `/tmp` & `/opt/keycloak/data`, `cap_drop: [ALL]`,
`no-new-privileges`, `mem_limit 1360m`, `cpus 1.0` (ADR 0004), tanpa port publish, healthcheck
`/health/ready` via bash `/dev/tcp` ke :9000.

## Paparan path (Traefik `auth.yml`, docs reverseproxy.adoc §Exposed path recommendations)

| Router | Entrypoint | Rule | Middleware | Publik? |
|---|---|---|---|---|
| `auth-admin` (prio 100) | **`admin`** (127.0.0.1:8443 host) | `/admin*`, `/realms/master/*` | crowdsec, **ipallowlist-admin**, auth-security-headers, ratelimit-default | tidak (tunnel) |
| `auth-other` (1) | **`admin`** | sisa host (`/`, `/resources/`, `/realms/<lain>/`, …) | crowdsec, **ipallowlist-admin**, … | tidak (tunnel) |
| `drms-kc-admin-{stg,prod}` (120) | websecure | `ClientIP(10.100.{9,8}.0/24)` + `/admin/realms/drms{-staging,}/` | crowdsec, drms-kc-admin-strict-path, auth-security-headers, ratelimit-drms-kc-admin | tidak (network internal DRMS) |
| `auth-admin-deny` (110) | websecure | `/admin*`, `/realms/master/*` | crowdsec, **deny-all** (403) | **ditolak** |
| `auth-drms-token` (95) | websecure | token realm `drms`/`drms-staging` | crowdsec, …, ratelimit-drms-kc-token | ya |
| `auth-oidc-backchannel` (96, plan 04 S3) | websecure | `ClientIP(10.100.0.1/32)` + `Path` eksak `/realms/{platform,platform-staging}/protocol/openid-connect/{token,certs,userinfo}` | crowdsec, auth-security-headers, **ratelimit-oidc-backchannel** (300/menit, burst 100) | hairpin host/pool Odoo saja |
| `auth-login` (90) | websecure | `/realms/*/login-actions/*`, `/realms/*/protocol/openid-connect/(auth\|token)` | crowdsec, auth-security-headers, **ratelimit-login** | ya |
| `auth-public` (50) | websecure | `/realms/*`, `/resources/*`, `/.well-known/*` | crowdsec, auth-security-headers, ratelimit-default | ya |

H5 (keputusan user 2026-09-23): di :443 publik tidak ada router allowlist lagi — hairpin container (tiba sebagai
`10.100.0.1`) dulu lolos `ipallowlist-admin`. Path lain di :443 (`/`, `/metrics`, …) → 404. Detail: `traefik.md`
§Entrypoint `admin`.

`auth-security-headers` = `security-headers` tanpa `frameDeny` (Keycloak sudah mengirim `X-Frame-Options:
SAMEORIGIN` + CSP `frame-ancestors 'self'`; admin console memakai iframe same-origin). HSTS `max-age=604800`
(Traefik menimpa default realm `max-age=31536000; includeSubDomains`) — bertahap ke 31536000 mulai 2026-10-09 (`traefik.md` §HSTS bertahap).

## Realm

| Realm | Isi |
|---|---|
| `master` | hanya admin platform. Brute force ON (5 gagal, tunggu 60 s naik s/d 15 m), password policy `length(16) and maxLength(128) and upperCase(1) and lowerCase(1) and digits(1) and specialChars(1) and notUsername and notEmail and passwordHistory(5)`, event login+admin ON (7 hari), `frontendUrl` :8443 |
| `platform`, `platform-staging` | `sslRequired=external`, `registrationAllowed=false`, brute force ON (sama), password policy sama dengan `length(12)`, `resetPasswordAllowed=false` & `verifyEmail=false` (mail belum ada, T11), event login+admin ON (7 hari) |

SMTP realm `platform`/`platform-staging` aktif sejak 2026-09-23 (`auth-noreply@bimacreative.tech`) — dipakai undangan
`execute-actions-email` plan 04. **"Forgot password" (`resetPasswordAllowed`) realm `platform` masih OFF — menunggu user
mengaktifkan via console** (plan 04 GATE 1 #3; `automation` tidak punya `manage-realm`).

Export (tanpa secret) di `identity/keycloak/realm-export/{platform,platform-staging}.json` — dibuat dengan
Admin REST **partial export** (`POST /admin/realms/<r>/partial-export?exportClients=true&exportGroupsAndRoles=true`):
tanpa user, key provider tanpa `privateKey`/`secret`, client tanpa field `secret`. Cek sebelum commit:
```bash
grep -n -i -E '"(secret|privateKey|password|value)"' identity/keycloak/realm-export/*.json   # harus kosong
```

## Admin

- **Admin permanen:** `platform-admin` (realm `master`, role `admin`). Password awal acak 40 char di
  `/opt/infra/identity/keycloak/.admin-credentials` (600 root, di-ignore git). Required actions:
  **UPDATE_PASSWORD + CONFIGURE_TOTP** saat login pertama → setelah itu hapus file kredensial:
  `shred -u /opt/infra/identity/keycloak/.admin-credentials`.
- **Admin bootstrap sementara:** `temp-admin` dibuat saat start pertama dari `KC_BOOTSTRAP_ADMIN_USERNAME/
  PASSWORD` (`.env`), lalu **sudah dihapus** (2026-09-23) memakai sesi `platform-admin`; variabel bootstrap
  sudah dihapus dari `.env` (+ penanda `.bootstrap-done`) dan container di-recreate. Log start berikutnya
  tidak lagi berisi `Created temporary admin user`.

### Akses admin console via SSH tunnel
Di laptop admin (butuh private key user `admin`):
```bash
# 1) arahkan nama host ke loopback SELAMA sesi admin (sertifikat LE valid untuk nama ini)
echo '127.0.0.1 auth.bimacreative.tech grafana.bimacreative.tech status.bimacreative.tech' | sudo tee -a /etc/hosts
# 2) tunnel: port lokal 8443 → 127.0.0.1:8443 di VPS = entrypoint Traefik `admin` (H5; tiba sebagai 10.100.0.1 = allowlist)
ssh -p 2221 -N -L 8443:127.0.0.1:8443 admin@31.97.50.221
# 3) buka https://auth.bimacreative.tech:8443/admin/  → login platform-admin
# 4) selesai: hapus baris /etc/hosts tadi
```
Windows: langkah 1 = Notepad **Run as administrator** → `C:\Windows\System32\drivers\etc\hosts`, tambah baris yang
sama, lalu `ipconfig /flushdns` dan buka ulang browser (tanpa langkah ini browser memakai IP publik :8443 → "can't be
reached"; dialami user 2026-09-25). Hapus baris itu + `ipconfig /flushdns` setelah selesai — selama ada, SSO dari
laptop gagal bila tunnel mati.

Pengecualian client (keputusan user 2026-09-25, **staging saja**): `drms-staging` / `proyekkas-mobile` (public, PKCE
S256) **Direct access grants ON** + standard flow ON — login APK native username+password (Custom Tab kehilangan hasil
di HP user). Brute force realm tetap ON. Realm prod `drms` tetap OFF (diverifikasi token endpoint `unauthorized_client`).
Diubah user via console; export `realm-export/drms-staging.json` disesuaikan manual (1 baris, commit a6024cd).
H5 (2026-09-23): tunnel lama `-L 8443:127.0.0.1:443` tidak lagi membuka admin (:443 → 403). Diverifikasi dari host
(`--resolve auth.bimacreative.tech:8443:127.0.0.1`): `GET :8443/admin/` → 302 ke `:8443/admin/master/console/` → 200,
discovery realm master via :8443 → 200. Uji T06 (sebelum H5, jalur :443) di bawah tetap relevan untuk alur login.
Status uji: sisi server tunnel **diemulasikan** di host (forwarder TCP 127.0.0.1:8443 → 127.0.0.1:443, jalur
jaringan identik dengan `ssh -L`), dengan `auth.bimacreative.tech:443` sengaja di-blackhole: GET
`/admin/` → 302 ke `:8443/admin/master/console/`; login code+PKCE client `security-admin-console` → 302 +
token; `GET :8443/admin/realms` → 200. Perintah `ssh -L` persis di atas **belum** dijalankan dari laptop
(tidak ada private key di VPS); sshd: `allowtcpforwarding yes`.

### Pemulihan admin (terkunci / lupa password / TOTP hilang)
docs `bootstrap-admin-recovery.adoc` — hentikan server, buat admin sementara, start, perbaiki, hapus lagi:
```bash
cd /opt/infra/identity/keycloak && docker compose stop keycloak
docker compose run --rm -e KC_BOOTSTRAP_ADMIN_PASSWORD="$(openssl rand -hex 24)" keycloak \
  bootstrap-admin user --optimized --username tmp-recovery --password:env KC_BOOTSTRAP_ADMIN_PASSWORD --no-prompt
docker compose up -d
```
(BELUM diuji — password acak di atas tidak tersimpan; simpan dulu ke variabel/file 600 sebelum menjalankan.)
Setelah akses pulih: hapus user `tmp-recovery` di realm master.

## Start / stop

```bash
cd /opt/infra/identity/keycloak
./scripts/bootstrap.sh              # sekali / idempoten: .env (KC_DB_PASSWORD dari postgres/.env)
docker compose up -d --build        # build image teroptimasi + start
docker compose ps                   # keycloak: (healthy)  (start ±30–60 s)
docker logs --tail 50 keycloak
docker compose down                 # stop; data di Postgres
```
- Rotasi password DB: ikuti `postgres.md` §Rotasi → `./scripts/bootstrap.sh` (menyinkronkan `KC_DB_PASSWORD`)
  → `docker compose up -d`.
- Upgrade: ubah tag+digest di `Containerfile` → `docker compose up -d --build`; baca upgrading guide dulu.

## Client Odoo per tenant (plan 04, ADR 0008)

Satu client OIDC **per tenant-env** `odoo-<slug>-<env>` di realm `platform` (env `prod`/`demo`) atau `platform-staging`
(env `staging`); tidak ada realm per client. Client dibuat/diperbarui **hanya** oleh `scripts/provision-odoo-sso.sh`
(idempoten; representasi di `scripts/lib/odoo_sso_kc.py`), user oleh `scripts/odoo-sso-user.sh` — keduanya lewat
`scripts/lib/keycloak-admin.sh` (client `automation`, Admin REST via `:8443`). Prosedur: `docs/runbooks/odoo-sso-tenant.md`;
sisi Odoo: `odoo.md` §SSO.

| Aspek | Nilai |
|---|---|
| Representasi | confidential, standard flow saja, PKCE `S256`, ID token RS256, `fullScopeAllowed=false`, default scopes `basic profile email acr`, optional kosong, web origins kosong |
| Redirect URI | eksak `https://<host>/sh_auth_oidc/callback` untuk **setiap** host tenant-env; host baru → jalankan ulang skrip dengan daftar `--host` lengkap (PUT) |
| Role gate | client role `odoo_access` (deskripsi `Login Odoo <db> (sh_auth_oidc role gate)`); user tenant diberi role oleh `odoo-sso-user.sh --grant`, dicabut `--revoke` |
| Mapper | *User Client Role* (`oidc-usermodel-client-role-mapper`), multivalued, klaim **literal** `resource_access.odoo-<slug>-<env>.roles` di ID/access token, userinfo, introspection. Jangan pakai placeholder `${client_id}` — body berisi `${` diblok CRS 932130 (403) dan `keycloak-admin.sh` menolaknya sebelum dikirim |
| Secret | diambil skrip (`GET/POST …/clients/<uuid>/client-secret`) langsung ke file `<pool>/secrets/oidc/<db>`; tidak dicetak, tidak di realm-export git, tidak di `identity/keycloak/secrets/` |
| User | username = email; dibuat `--create-kc` (`emailVerified=false`, required actions `UPDATE_PASSWORD` [+ `CONFIGURE_TOTP` admin tenant]) + `execute-actions-email` (tautan kembali ke client tenant) |

Verifikasi klaim role (tanpa login): `GET /admin/realms/<realm>/clients/<uuid>/evaluate-scopes/generate-example-id-token?userId=<id>`
→ `aud`=`azp`=`odoo-<slug>-<env>`, `resource_access={"odoo-<slug>-<env>":{"roles":["odoo_access"]}}` (QA S5/S7; user tanpa role →
`resource_access` absen). Ini menutup risiko plan 04 §7 "role klaim tidak muncul dengan `fullScopeAllowed=false`".

Client aktif (2026-09-25): `odoo-demo-demo` (`platform`, redirect `https://demo.erp.bimacreative.tech/sh_auth_oidc/callback`),
`odoo-demo-staging`, `odoo-ssotest-staging` (`platform-staging`). Realm-export git **belum** memuat client ini (`partial-export`
butuh `manage-realm`); representasi dapat dibaca dengan `GET /clients?clientId=…` (tanpa field `secret`).

Isolasi user antar tenant **tidak** di Keycloak (user realm bisa mengautentikasi ke client tenant mana pun): Odoo menolak
lewat role gate (`oauth_error=2`) lalu tautan `res.users` (`oauth_error=3`). Back-channel token/JWKS pool → router
`auth-oidc-backchannel` (tabel §Paparan path; `traefik.md` §Rate limit SSO Odoo) + exclusion WAF
`local/oidc-backchannel-exclusions` (`crowdsec.md`, BUG-S5-01).

## Info untuk T12 (Next.js/Auth.js) & T15 (Odoo `sh_auth_oidc`)

- Issuer: `https://auth.bimacreative.tech/realms/platform` (prod), `https://auth.bimacreative.tech/realms/platform-staging` (staging).
- Discovery: `<issuer>/.well-known/openid-configuration`; PKCE `S256` didukung.
- Buat client (admin console via tunnel → realm → Clients → Create): OpenID Connect, **Client authentication
  ON** (confidential, server-side), Standard flow saja (matikan Direct access grants & Implicit), advanced:
  **PKCE method S256**, redirect URI **eksak** (tanpa wildcard), web origins eksak. Secret client disimpan di
  `.env` 600 aplikasi — tidak di realm-export git (client Odoo tenant: file per DB, §Client Odoo per tenant). Setelah membuat client: partial export ulang realm
  (Realm settings → Action → Partial export, tanpa secret) → commit.
- Aplikasi di VPS memanggil Keycloak via **URL publik** (issuer harus cocok). Catatan: `ratelimit-login`
  (10/menit, burst 10 per IP) juga berlaku untuk `/protocol/openid-connect/token`; panggilan token
  server-to-server dari container platform tiba dengan satu IP sumber (gateway/host) → bisa kena 429 saat
  beban tinggi. **Plan 04 S3:** untuk realm `platform`/`platform-staging` dari hairpin `10.100.0.1` (pool Odoo) kini
  lewat router `auth-oidc-backchannel` (token/certs/userinfo, `ratelimit-oidc-backchannel` 300/menit burst 100 —
  `traefik.md` §Rate limit SSO Odoo); `/auth` & `/login-actions` tetap `ratelimit-login`. Control plane (tiba sebagai
  IP container-nya di `proxy`, mis. 10.100.0.5) tetap `auth-login`. Backchannel internal `http://keycloak:8080` +
  `KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true` (docs hostname.adoc) — belum diterapkan.
- **Admin REST lewat Traefik + CrowdSec AppSec (T16b):** body JSON yang memuat `${…}` (mis. mapper
  `claim.name: resource_access.${client_id}.roles`) diblokir AppSec (`anomaly score block: rce`, 403 kosong dari router
  `auth-admin`, alert `waf` untuk 10.100.0.1). Tulis nilai literal (`resource_access.<clientId>.roles`) — klaim identik.
  Client `control-plane` realm `platform-staging`: lihat `control-plane.md` §Staging.
- **PUT/DELETE Admin REST lewat edge (H4, 2026-09-23):** CRS 911100 ("Method is not allowed by policy") dulu memblok
  semua PUT/DELETE ke `/admin/realms/…` (403 dari router `auth-admin`). Kini dikecualikan **hanya** rule 911100, hanya untuk
  host `auth.bimacreative.tech` (juga `:8443` tunnel), path `/admin/realms/*`, IP 127.0.0.1/10.100.0.1 — config
  `local/keycloak-admin-exclusions` (`crowdsec.md` §Pengecualian CRS 911100). Rule CRS lain tetap berlaku: body berisi
  `${…}`/`<script>`/SQLi tetap 403. **Sejak H5 Admin REST dari host hanya via entrypoint `admin` `:8443`** (:443 → 403).
  Contoh (token `automation`, tanpa menampilkan secret):
  ```bash
  S=/opt/infra/identity/keycloak/secrets/automation-platform-staging.secret
  K=(--resolve auth.bimacreative.tech:8443:127.0.0.1); A=https://auth.bimacreative.tech:8443
  T=$(curl -s "${K[@]}" -d grant_type=client_credentials -d client_id=automation \
      --data-urlencode "client_secret@$S" $A/realms/platform-staging/protocol/openid-connect/token \
      | python3 -c 'import sys,json;sys.stdout.write(json.load(sys.stdin)["access_token"])')
  curl -s -o /dev/null -w '%{http_code}\n' "${K[@]}" -X DELETE \
       -H "Authorization: Bearer $T" $A/admin/realms/platform-staging/users/<id>   # 204
  ```
  H5 diuji: `PUT`/`DELETE` ke user id acak via :8443 → 404 `{"error":"User not found"}` dari Keycloak (bukan 403 WAF).
  User uji T15 `t15-sso-test` (realm `platform-staging`) **dihapus** 2026-09-23 dengan cara ini (204, GET → 404).
- Network: Keycloak di `proxy` (dan `db`, serta `metrics` internal sejak T14a — Prometheus scrape `keycloak:9000/metrics`).
  Jangan menambah router/path admin publik. Keycloak **tidak** join `drms-kc-admin{,-stg}` (H5): app ProyekKas mencapai
  Admin REST realm `drms`/`drms-staging` saja lewat Traefik (router `drms-kc-admin-*`, `traefik.md` §Network drms-kc-admin).
