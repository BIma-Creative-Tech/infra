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
| `KC_HOSTNAME_ADMIN` | `https://auth.bimacreative.tech:8443` | admin console hanya lewat SSH tunnel (lokal :8443) |
| realm `master` atribut `frontendUrl` | `https://auth.bimacreative.tech:8443` | login realm master (form + token) juga lewat :8443; tanpa ini form login admin mem-POST ke :443 publik → 403 |
| `KC_HTTP_ENABLED` | `true` | TLS di-terminate Traefik; 8080 hanya di network `proxy` |
| `KC_PROXY_HEADERS` | `xforwarded` | Traefik menimpa `X-Forwarded-*` (forwardedHeaders tidak dipercaya dari klien) |
| `KC_CACHE` | `local` | satu node, tanpa JGroups |
| health/metrics | management port **9000**, tidak di-route | docs management-interface |

Hardening container: `user 1000`, `read_only` + tmpfs `/tmp` & `/opt/keycloak/data`, `cap_drop: [ALL]`,
`no-new-privileges`, `mem_limit 1360m`, `cpus 1.0` (ADR 0004), tanpa port publish, healthcheck
`/health/ready` via bash `/dev/tcp` ke :9000.

## Paparan path (Traefik `auth.yml`, docs reverseproxy.adoc §Exposed path recommendations)

| Router | Rule | Middleware | Publik? |
|---|---|---|---|
| `auth-admin` (prio 100) | `/admin*`, `/realms/master/*` | crowdsec, **ipallowlist-admin**, auth-security-headers, ratelimit-default | tidak (allowlist) |
| `auth-login` (90) | `/realms/*/login-actions/*`, `/realms/*/protocol/openid-connect/(auth\|token)` | crowdsec, auth-security-headers, **ratelimit-login** | ya |
| `auth-public` (50) | `/realms/*`, `/resources/*`, `/.well-known/*` | crowdsec, auth-security-headers, ratelimit-default | ya |
| `auth-other` (1) | sisa host (`/`, `/metrics`, …) | crowdsec, **ipallowlist-admin**, … | tidak |

`auth-security-headers` = `security-headers` tanpa `frameDeny` (Keycloak sudah mengirim `X-Frame-Options:
SAMEORIGIN` + CSP `frame-ancestors 'self'`; admin console memakai iframe same-origin). HSTS tetap `max-age=300`
(Traefik menimpa default realm `max-age=31536000; includeSubDomains`) — dinaikkan Lead setelah QA.

## Realm

| Realm | Isi |
|---|---|
| `master` | hanya admin platform. Brute force ON (5 gagal, tunggu 60 s naik s/d 15 m), password policy `length(16) and maxLength(128) and upperCase(1) and lowerCase(1) and digits(1) and specialChars(1) and notUsername and notEmail and passwordHistory(5)`, event login+admin ON (7 hari), `frontendUrl` :8443 |
| `platform`, `platform-staging` | `sslRequired=external`, `registrationAllowed=false`, brute force ON (sama), password policy sama dengan `length(12)`, `resetPasswordAllowed=false` & `verifyEmail=false` (mail belum ada, T11), event login+admin ON (7 hari) |

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
echo '127.0.0.1 auth.bimacreative.tech' | sudo tee -a /etc/hosts
# 2) tunnel: port lokal 8443 → 127.0.0.1:443 di VPS (tiba di Traefik sebagai 10.100.0.1 = allowlist)
ssh -p 2221 -N -L 8443:127.0.0.1:443 admin@31.97.50.221
# 3) buka https://auth.bimacreative.tech:8443/admin/  → login platform-admin
# 4) selesai: hapus baris /etc/hosts tadi
```
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

## Info untuk T12 (Next.js/Auth.js) & T15 (Odoo `sh_auth_oidc`)

- Issuer: `https://auth.bimacreative.tech/realms/platform` (prod), `https://auth.bimacreative.tech/realms/platform-staging` (staging).
- Discovery: `<issuer>/.well-known/openid-configuration`; PKCE `S256` didukung.
- Buat client (admin console via tunnel → realm → Clients → Create): OpenID Connect, **Client authentication
  ON** (confidential, server-side), Standard flow saja (matikan Direct access grants & Implicit), advanced:
  **PKCE method S256**, redirect URI **eksak** (tanpa wildcard), web origins eksak. Secret client disimpan di
  `.env` 600 aplikasi — tidak di realm-export git. Setelah membuat client: partial export ulang realm
  (Realm settings → Action → Partial export, tanpa secret) → commit.
- Aplikasi di VPS memanggil Keycloak via **URL publik** (issuer harus cocok). Catatan: `ratelimit-login`
  (10/menit, burst 10 per IP) juga berlaku untuk `/protocol/openid-connect/token`; panggilan token
  server-to-server dari container platform tiba dengan satu IP sumber (gateway/host) → bisa kena 429 saat
  beban tinggi. Opsi (keputusan Lead): router token terpisah dengan limit lain, atau backchannel internal
  `http://keycloak:8080` + `KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true` (docs hostname.adoc) — belum diterapkan.
- Network: Keycloak di `proxy` (dan `db`, serta `metrics` internal sejak T14a — Prometheus scrape `keycloak:9000/metrics`).
  Jangan menambah router/path admin publik.
