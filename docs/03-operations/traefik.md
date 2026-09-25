# Operasional — Traefik (edge, T03)

- **Stack:** `/opt/infra/traefik/` · image `traefik:v3.7.13` (pin tag + digest, ADR 0001)
- **Terkait:** ADR 0002 (HTTP-01 per hostname, tanpa wildcard), plan 02 §3–§4, CLAUDE.md §3.5.1

## Struktur

| Path | Isi | Git |
|---|---|---|
| `traefik.yml` | static config: entrypoints `web` :80 (redirect → https) & `websecure` :443, **`admin` :8443 (H5, publish `127.0.0.1:8443` host saja)**, `traefik` 127.0.0.1:8080 di dalam container (hanya `/ping`), `metrics` :8082, file provider, resolver `le-http-staging` & `le-http`, access log JSON | ya |
| `dynamic/middlewares/*.yml` | `security-headers`, `ratelimit-default`, `ratelimit-login`, `ratelimit-oidc`, `ratelimit-oidc-backchannel` (plan 04 S3), `ipallowlist-admin`, `strip-odoo-db-headers`, `deny-all` + service `deny-sink` (H5) | ya |
| `dynamic/tls.yml` | TLS option `default` (min TLS 1.2) | ya |
| `dynamic/platform/<svc>.yml` | router layanan platform (T06 `auth.yml`, T16a `cp.yml`, T16b `cp-staging.yml`, T14a `status.yml`/`grafana.yml`, T11 `mail.yml` = router dummy sertifikat `mail.bimacreative.tech` untuk docker-mailserver, `mail.md`, …) — satu file per task | ya |
| `dynamic/platform/metrics.yml` | router `metrics-prometheus` (entrypoint `metrics`, `prometheus@internal`) + middleware `ipallowlist-metrics` (QA-T17B-03) | ya |
| `dynamic/platform/odoo-pools.yml` | service `odoo-pool-a-{http,ws}`, `odoo-staging-{http,ws}` + middleware `odoo-security-headers` (T10) | ya |
| `dynamic/clients/<slug>-<env>.yml` | router tenant Odoo, dirender `scripts/render-client-route.sh` dari `templates/traefik-client.yml` (T10) — lihat `odoo.md` | ya |
| `dynamic/clients/web-<slug>-<env>.yml` | router website Next.js client (+ `-contact` POST ratelimit, opsional `-www` redirect), dirender `scripts/provision-web-client.sh` dari `templates/traefik-web-client.yml` (plan 03 W2) — lihat `docs/runbooks/web-client-onboarding.md`. Kedua skrip menolak menimpa file milik skrip lain (penanda baris 1) | ya (deploy permanen) |
| ~~`dynamic/test/whoami-status.yml`~~ | **dihapus 2026-09-23 (H2, QA-T17A-05/06/08)** bersama service `whoami`. `status.bimacreative.tech` kini tanpa router (404) sampai T14 menambah `dynamic/platform/status.yml` (Uptime Kuma) — **sudah ditambahkan T14a** (`observability.md`) | — |
| `acme/acme-staging.json`, `acme/acme.json` | akun ACME + private key sertifikat. Dir 700, file 600, owner 65532 | **tidak** (`traefik/.gitignore`) |
| `secrets/crowdsec-bouncer.key` | API key bouncer CrowdSec (T05). Dir 700, file 600, owner 65532 | **tidak** |
| `dynamic/middlewares/crowdsec.yml` | middleware plugin bouncer CrowdSec + AppSec (T05) — lihat `crowdsec.md` | ya |
| `logs/access.log` | access log JSON (dibaca CrowdSec T05, Alloy T14). Dir `65532:adm` 750 | **tidak** |
| `logrotate/traefik` | dipasang ke `/etc/logrotate.d/traefik` oleh bootstrap | ya |
| `scripts/bootstrap.sh` | idempoten: network `proxy`, `odoo-edge`, `drms-kas-edge`, `drms-kc-admin{,-stg}` (H5, `--internal`), dir/file acme & logs, logrotate | ya |

## Keputusan

- **Dashboard/API: tidak diaktifkan sama sekali** (`api` tidak diset, default `false`). `/dashboard/`
  dan `/api/rawdata` di IP publik → 404. Debug via `docker logs traefik` dan isi `dynamic/`.
- **File provider saja** — tidak ada mount `/var/run/docker.sock`.
- **Non-root tanpa capability**: `user: 65532:65532`, `cap_drop: [ALL]`, **tanpa** `cap_add`. Docker
  menset `net.ipv4.ip_unprivileged_port_start=0` di netns container (ditulis eksplisit di `sysctls`), jadi
  uid biasa boleh bind 80/443. Uji: dengan sysctl `1024` + `--cap-add NET_BIND_SERVICE` + non-root →
  `listen tcp :80: bind: permission denied` (capability tambahan tidak masuk effective set proses non-root),
  jadi `NET_BIND_SERVICE` tidak berguna di sini dan tidak dipasang.
- `read_only: true` + tmpfs `/tmp`; yang writable hanya `acme/` dan `logs/`.
- `aliasHeadersStrategy: delete` di semua entrypoint: header bernama alias (`X_Sh_Odoo_Db`,
  `X.Odoo.Database`, …) dibuang sebelum routing — backend WSGI (Odoo) membaca alias itu sebagai
  header asli (docs `entrypoints.md` §aliasHeadersStrategy).
- **Metrics Prometheus (T14a):** entrypoint `metrics` `:8082` di dalam container (tidak di-publish, compose publik tetap
  hanya 80/443; + `127.0.0.1:8443` entrypoint `admin` sejak H5), `metrics.prometheus.entryPoint: metrics` (+ label entrypoint/router/service). Traefik join network
  internal **`metrics`** (10.100.5.0/24, tanpa gateway → `proxy` tetap gateway). Scrape: `prometheus` → `traefik:8082/metrics`.
  Semua router di `dynamic/` WAJIB menyebut `entryPoints` eksplisit — router tanpa `entryPoints` akan menempel ke
  semua entrypoint termasuk `metrics`/`traefik`.
- **Pembatasan metrics (QA-T17B-03, 2026-09-25):** socket `:8082` listen di **semua** network Traefik (bukan hanya
  `metrics`) — sebelumnya website klien (`web-edge`), pool Odoo (`odoo-edge`), ProyekKas (`drms-kas-edge`) dan anggota
  `proxy` bisa membaca daftar router/tenant. Kini `metrics.prometheus.manualRouting: true` (static) mematikan router
  internal otomatis; router file `metrics-prometheus` (`dynamic/platform/metrics.yml`, rule `PathPrefix(/metrics)`,
  service `prometheus@internal`) + middleware `ipallowlist-metrics` (`10.100.5.0/24`, 403). Sisa: crowdsec & keycloak
  (anggota `metrics`) tetap bisa membaca; /32 Prometheus butuh IP tetap (keputusan Lead). Uji:
  `docker exec web-starter-staging node -e "fetch('http://traefik:8082/metrics').then(r=>console.log(r.status))"` → 403;
  `docker exec prometheus wget -qO- http://traefik:8082/metrics | head -1` → metrik; Prometheus target `traefik` = up.
- `forwardedHeaders` tidak diset → `X-Forwarded-For`/`X-Real-Ip` dari client **ditimpa** (diuji:
  kirim `X-Forwarded-For: 1.2.3.4` → backend menerima IP koneksi sebenarnya).
- Email ACME: **kosong** (LE menerima akun tanpa email; notifikasi kedaluwarsa LE sudah dihentikan).
  Isi `certificatesResolvers.*.acme.email` bila Lead menetapkan alamat.

## Entrypoint `admin` — panel admin hanya lewat loopback host (H5, keputusan user 2026-09-23)

**Masalah yang ditutup:** dengan `userland-proxy: false`, request **hairpin** dari container mana pun ke
`https://<host publik>` (IP publik :443) tiba di Traefik dengan ClientHost **`10.100.0.1`** (gateway `proxy`) → lolos
`ipallowlist-admin`. Bukti sebelum H5: container di `drms-kas-edge`/`odoo-edge` → `GET /admin/realms/drms-staging/users`
= **401 dari Keycloak** (sampai backend).

**Desain:**
- Entrypoint `admin` `address: ":8443"` (+ `aliasHeadersStrategy: delete`, `tls: {}`), compose publish
  **`127.0.0.1:8443:8443/tcp` saja** (tidak ada port publik baru; ufw tidak diubah).
- Router panel admin **hanya** di entrypoint `admin`: `auth-admin` (`/admin*`, `/realms/master/*`), `auth-other`
  (sisa host auth), `grafana` (seluruh host), `status-admin` (seluruh host Uptime Kuma). Tetap `crowdsec` +
  `ipallowlist-admin` (defense-in-depth) + `certResolver: le-http`.
- Di `websecure` (:443): `auth-admin-deny` (prioritas 110, `/admin*` + `/realms/master/*`) → middleware `deny-all`
  (**403**) → service `deny-sink` (tidak pernah tercapai). Path auth lain di luar `/realms/`, `/resources/`,
  `/.well-known/`, serta seluruh `grafana.*` dan dashboard Kuma (`/dashboard`, `/socket.io/`, `/metrics`, …) tidak punya
  router di :443 → **404**. Halaman status publik (`status-public`) tetap di :443.
- **H5b (2026-09-23): DB manager Odoo per tenant.** Di `websecure` `<r>-dbmanager-deny` (`Host(<tenant>) &&
  PathPrefix(/web/database)`, prioritas 300) → `deny-all` 403 → `deny-sink`; router operator `<r>-dbmanager` pindah ke
  entrypoint `admin` (`ipallowlist-admin` + `<r>-db`), dirender dari `templates/traefik-client.yml` (`odoo.md` §Router).
  Setelah H5b **tidak ada** router di `websecure` yang mengandalkan `ipallowlist-admin` (diperiksa: semua pemakainya ber-
  `entryPoints: [admin]` — `auth-admin`, `auth-other`, `grafana`, `status-admin`, `odoo-*-dbmanager`).
- `deny-all` = `ipAllowList` dengan `sourceRange: [255.255.255.255/32]` (tak mungkin jadi IP klien TCP), `rejectStatusCode:
  403` — Traefik v3.7 OSS tidak punya middleware deny/ipDenyList. Service **bukan** `noop@internal`: router ber-service
  `@internal` tidak masuk access log (source v3.7 `pkg/server/router/router.go` + `pkg/server/middleware/observability.go`
  `shouldAccessLog`), padahal CrowdSec membaca access log; `deny-sink` = `http://127.0.0.1:9` (tidak ada listener →
  502 bila `deny-all` terlepas karena salah edit, bukan meneruskan ke backend).
- **IP sumber di :8443:** koneksi ke `127.0.0.1:8443` di host (termasuk `ssh -L`) tiba sebagai **`10.100.0.1`** (diverifikasi
  access log 2026-09-23, `entryPointName=admin`) → `ipallowlist-admin` tidak perlu diubah. Container yang menghubungi
  `traefik:8443` langsung membawa IP container-nya sendiri → 403; container → `31.97.50.221:8443` / `10.100.0.1:8443` →
  timeout (DNAT hanya untuk tujuan 127.0.0.1).
- **Sertifikat:** router admin tetap `certResolver: le-http`; challenge HTTP-01 memakai entrypoint `web`
  (`certificatesResolvers.le-http.acme.httpChallenge.entryPoint: web`) — tidak bergantung pada entrypoint router. Sertifikat
  `auth`/`grafana`/`status` sudah ada di `acme.json` (tidak ada order baru; `openssl s_client -connect 127.0.0.1:8443
  -servername grafana.bimacreative.tech` → issuer `Let's Encrypt YE1`).

### Akses admin (laptop)
```bash
# 1) selama sesi admin saja — nama host → loopback laptop (sertifikat LE valid untuk nama ini)
echo '127.0.0.1 auth.bimacreative.tech grafana.bimacreative.tech status.bimacreative.tech' | sudo tee -a /etc/hosts
# 2) tunnel: port lokal 8443 → 127.0.0.1:8443 di VPS (entrypoint admin)
ssh -p 2221 -N -L 8443:127.0.0.1:8443 admin@31.97.50.221
# 3) https://auth.bimacreative.tech:8443/admin/ · https://grafana.bimacreative.tech:8443/ · https://status.bimacreative.tech:8443/dashboard
#    DB manager Odoo (H5b): https://<host tenant>:8443/web/database/selector (host tenant juga dipetakan ke 127.0.0.1)
# 4) selesai: hapus baris /etc/hosts tadi (kalau tidak, halaman status publik ikut mengarah ke laptop)
```
Tunnel lama `-L 8443:127.0.0.1:443` **tidak berfungsi lagi** untuk panel admin (:443 → 403/404).
Dari host (skrip/automation): `curl --resolve auth.bimacreative.tech:8443:127.0.0.1 https://auth.bimacreative.tech:8443/admin/…`.

## Network `drms-kc-admin` / `drms-kc-admin-stg` (H5 — Admin REST ProyekKas tanpa hairpin)

- `drms-kc-admin` **10.100.8.0/24** (prod) dan `drms-kc-admin-stg` **10.100.9.0/24** (staging), keduanya **`--internal`**,
  dibuat `scripts/bootstrap.sh` (`ensure_network … internal`; subnet & flag internal diverifikasi saat dijalankan ulang).
  Anggota: `traefik` + app ProyekKas (web + worker) env terkait. **Keycloak tidak join.**
- Traefik join keduanya dengan **network alias `auth.bimacreative.tech`** (tanpa `gw_priority`; internal = tanpa gateway,
  `proxy` tetap gateway). App di network itu me-resolve `auth.bimacreative.tech` ke IP Traefik di network tsb (mis.
  10.100.9.2) → koneksi langsung ke `websecure` :443, ClientIP = IP container app (tanpa NAT). Semua trafik Keycloak app
  (token, discovery, JWKS, Admin REST) lewat jalur ini.
- Router `dynamic/clients/drms-proyekkas-kc-admin.yml` (prioritas 120 > `auth-admin-deny` 110):
  `drms-kc-admin-stg` = `ClientIP(10.100.9.0/24) && PathPrefix(/admin/realms/drms-staging/)`, `drms-kc-admin-prod` =
  `ClientIP(10.100.8.0/24) && PathPrefix(/admin/realms/drms/)`; middleware `crowdsec`, `drms-kc-admin-strict-path`
  (`encodedCharacters`, semua `false` → `%2F` dll. ditolak), `auth-security-headers`, `ratelimit-drms-kc-admin` (20/s,
  burst 40 — ESTIMASI); service `keycloak`. Path admin lain dari subnet ini → `auth-admin-deny` 403.
- Network internal = tanpa egress & tanpa DNS eksternal: app tetap butuh `drms-kas-edge` (ingress + egress) — alias
  `auth.bimacreative.tech` di network internal menang atas DNS publik untuk container yang join keduanya.
- Runbook app: `docs/runbooks/proyekkas-drms-onboarding.md` §Network Admin API.

## Rate limit SSO Odoo (plan 04 S3, F9/F10)

Semua `rateLimit` = token bucket per IP koneksi (default `sourceCriterion` = remote address; `average`/`period` = laju isi
ulang, `burst` = kapasitas; docs v3.7 `middlewares/ratelimit.md`), lewat batas → **429**. Definisi di
`dynamic/middlewares/ratelimit.yml`. ESTIMASI — tuning dari access log (`RouterName`, `DownstreamStatus=429`).

| Middleware | Nilai | Router | Alasan |
|---|---|---|---|
| `ratelimit-oidc-backchannel` | 300/1m, burst 100 | `auth-oidc-backchannel` (`platform/auth.yml`, prio 96, websecure) | Exchange token + JWKS pool Odoo via hairpin tiba sebagai **10.100.0.1** → satu bucket untuk semua tenant kedua pool. 30 exchange/60 s (AC-S6) ≤ 1/3 burst. Dulu ikut `ratelimit-login` 10/menit (F10). |
| `ratelimit-oidc` | 20/1m, burst 20 | `<r>-oidc` per tenant (`templates/traefik-client.yml`, prio 200) | 1 login = authorize + callback (2 request); burst 20 = 10 login beruntun/IP (MAX_PENDING=5 tab, NAT kantor); ≥ laju `ratelimit-login` Keycloak `/auth` sehingga bukan hambatan pertama; membatasi amplifikasi callback → back-channel (F9). |

- Rule `auth-oidc-backchannel`: `Host(auth) && ClientIP(10.100.0.1/32) && Path(...)` eksak untuk
  `/realms/{platform,platform-staging}/protocol/openid-connect/{token,certs,userinfo}`. `/auth`, `/login-actions/*`, realm
  lain dan IP lain tetap `auth-login` (`ratelimit-login`) / `auth-public`; `/realms/master/*` & `/admin*` tetap
  `auth-admin-deny` (110) — H5 tidak berubah.
- Catatan: 10.100.0.1 = **semua** proses host + hairpin container mana pun (bukan hanya pool Odoo) → siapa pun di host
  memakai bucket 300/menit untuk 6 path tsb. Tidak membuka path baru (path yang sama sudah publik lewat `auth-login`/
  `auth-public`); token endpoint tetap butuh code/secret sah. Uji ratelimit "publik" dari host tidak mewakili klien internet.
- Validasi (2026-09-25, container `traefik:v3.7.13` sekali pakai, `--network none`/internal, salinan `dynamic/`): 0 error
  konfigurasi, router 40 → 43 semua `enabled`; uji fungsi (ClientIP diganti IP uji): 45 request back-channel → 0×429,
  130 beruntun → 115 lolos/15×429; `/login-actions` dari IP sama → 10 lolos lalu 429; `/sh_auth_oidc/authorize` ×25 →
  20 lolos lalu 429; `/realms/master/.../token` & `/admin/...` → 403.

## Network `proxy`

- Bridge, **subnet tetap `10.100.0.0/24`, gateway `10.100.0.1`**, dibuat `scripts/bootstrap.sh`
  (bukan oleh compose, agar `docker compose down` satu stack tidak menghapus network bersama).
- Service HTTP lain join sebagai network external dan **tidak** publish port:
  ```yaml
  services:
    app:
      networks: [proxy]          # + network internal stack sendiri (mis. db)
  networks:
    proxy:
      external: true
      name: proxy
  ```
- Router ditulis di `dynamic/platform/<svc>.yml` (atau `dynamic/clients/<slug>.yml`), service
  `loadBalancer.servers[].url: http://<container_name>:<port>` (DNS Docker di network `proxy`).
- Template router platform:
  ```yaml
  http:
    routers:
      <svc>:
        entryPoints: [websecure]
        rule: "Host(`<fqdn>`)"          # FQDN eksplisit, bukan HostRegexp (ADR 0002 #2)
        middlewares: [security-headers, ratelimit-default]
        service: <svc>
        tls:
          certResolver: le-http-staging # ganti ke le-http HANYA setelah keputusan Lead
    services:
      <svc>:
        loadBalancer:
          servers:
            - url: "http://<container>:<port>"
  ```
- **Sebelum menulis router hostname baru**: `dig +short A <fqdn> @1.1.1.1` dan `@8.8.8.8` harus
  `31.97.50.221`, `dig +short AAAA <fqdn>` kosong (ADR 0002 #5).

## Network `odoo-edge` (H1)

- Bridge **`10.100.3.0/24`, gateway `10.100.3.1`**, dibuat `scripts/bootstrap.sh` (fungsi `ensure_network`),
  bukan `--internal` (Odoo butuh egress). Anggota **hanya** `traefik` + pool Odoo (`odoo-pool-a`, `odoo-staging`);
  service `odoo-*-{http,ws}` di `dynamic/platform/odoo-pools.yml` di-resolve lewat DNS Docker network ini.
- Traefik join `odoo-edge` **tanpa** `gw_priority` (default 0) — `proxy` tetap `gw_priority: 1` sehingga koneksi
  dari host tetap tiba sebagai `10.100.0.1` (diverifikasi di access log setelah perubahan, 2026-09-23).
- Jangan menambahkan service lain ke `odoo-edge`; jangan menambahkan pool Odoo ke `proxy`.

## Network `drms-kas-edge` (ProyekKas DRMS)

- Bridge **`10.100.7.0/24`, gateway `10.100.7.1`**, dibuat `scripts/bootstrap.sh` (`ensure_network`), bukan
  `--internal` (app butuh egress: FCM, issuer publik Keycloak via hairpin). Anggota **hanya** `traefik` + container
  web ProyekKas (`drms-pk-web`, `drms-pk-stg`) — bukan `proxy`.
- Traefik join **tanpa** `gw_priority` → koneksi host tetap `10.100.0.1` (diverifikasi access log 2026-09-23).
- Router: `dynamic/clients/drms-proyekkas-{staging,middlewares,kc-token}.yml` (manual, bukan
  `render-client-route.sh`); runbook `docs/runbooks/proyekkas-drms-onboarding.md`.
- Staging app **berjalan** sejak 2026-09-23 (`/opt/infra/staging/drms-proyekkas/`); router `drms-pk-stg-*` memakai
  `le-http` (production; backup `acme/acme-staging.json.bak-drms-stg-1840`, restart Traefik ±3,6 s tanpa respons).

## Network `web-edge` (website client, W2b — keputusan user 2026-09-25)

- Bridge **`10.100.11.0/24`, gateway `10.100.11.1`**, dibuat `scripts/bootstrap.sh` (`ensure_network`), bukan
  `--internal` (website butuh egress: SMTP :587 hairpin ke `mail.bimacreative.tech`, API eksternal). Subnet dipilih
  setelah cek `docker network inspect` semua network + `ip route` host (10.100.6.0/24 pensiun, 10.100.10.0/24 = `mail`).
- Anggota **hanya** `traefik` + container website `web-<slug>-<env>` (`templates/web-client/docker-compose.yml`,
  `scripts/provision-web-client.sh`) — website **tidak** di `proxy`, jadi tidak bisa menjangkau control-plane, Grafana,
  Uptime Kuma, dst. `provision-web-client.sh` gagal lebih awal bila network tidak ada atau traefik belum terhubung.
- Traefik join **tanpa** `gw_priority` (pola `odoo-edge`/`drms-kas-edge`) → gateway tetap `proxy`, koneksi host tetap
  tiba sebagai `10.100.0.1` (`ipallowlist-admin`).
- Penerapan live tanpa recreate: `scripts/bootstrap.sh` (idempoten) lalu `docker network connect web-edge traefik`;
  compose sudah memuat network yang sama sehingga recreate berikutnya konsisten. Verifikasi: access log `ClientHost`
  = `10.100.0.1`, `curl --resolve auth.bimacreative.tech:8443:127.0.0.1 https://auth.bimacreative.tech:8443/admin/` → 302,
  situs biasa → 200. Regresi → `docker network disconnect web-edge traefik`.
- **Sisa risiko diterima:** semua website di `web-edge` saling bisa menjangkau `:3000` satu sama lain (satu network
  bersama). Opsi masa depan: network per client (`web-edge-<slug>`) — butuh `docker network connect` traefik per client.

## Network `webmail-edge` (webmail Roundcube, ADR 0012 — 2026-09-25)

- `10.100.15.0/24` `--internal`, dibuat `scripts/bootstrap.sh`; anggota HANYA `traefik` + `webmail` (`webmail:8000`).
  Diterapkan live: `bootstrap.sh` lalu `docker network connect webmail-edge traefik` (tanpa recreate; Traefik 10.100.15.2).
  Internal → tanpa gateway, tidak memengaruhi gateway Traefik (`proxy` gw_priority 1).
- Router `dynamic/clients/webmail-expomedia.yml`: `webmail-expomedia-login` (POST `_task=login`/tanpa `_task`, priority 100,
  `ratelimit-login`) + `webmail-expomedia`. Middleware `webmail-security-headers` = salinan `security-headers` dengan
  `X-Frame-Options: SAMEORIGIN` (iframe pratinjau Roundcube) + CSP minimal — **`stsSeconds` wajib ikut dinaikkan** bersama
  `security-headers` / `auth-security-headers` / `odoo-security-headers` (§HSTS bertahap).
- Regresi → hapus file router + `kill -HUP 1`, `docker network disconnect webmail-edge traefik`.

## Start / stop / reload

```bash
cd /opt/infra/traefik
./scripts/bootstrap.sh            # sekali / idempoten
docker compose up -d
docker compose ps                 # traefik: (healthy)
docker logs --tail 50 traefik
docker compose down               # stop (network proxy & acme tetap)
```
- **Watch hanya untuk file di level atas `dynamic/`** — file di subdirektori (`middlewares/`, `platform/`,
  `clients/`, `test/`) dimuat saat start tetapi perubahannya **tidak** terdeteksi (source v3.7
  `pkg/provider/file/file.go`: `// ignore sub-dir`; diuji 2026-09-23). Setelah mengubah/menambah file di
  subdirektori: `docker exec traefik kill -HUP 1` (provider file memuat ulang konfigurasi saat SIGHUP; bukti reload:
  metrik `traefik_config_reloads_total` naik — hanya bila konfigurasi berubah).
- **H7 — JANGAN `docker kill --signal=<apa pun>`** ke container yang harus hidup terus (Traefik, CrowdSec, dst.). Docker
  v29.8.1 `daemon/kill.go` `killWithSignal` untuk sinyal APA PUN (juga HUP/USR1, container tetap berjalan) men-set
  `HasBeenManuallyStopped=true` di `config.v2.json` **dan** membatalkan restart manager (`ExitOnNext`) → `unless-stopped`
  tidak start saat reboot, dan crash berikutnya tidak di-restart (bahkan `always`) sampai container di-start ulang.
  Insiden 2026-09-23 21:03 WIB (CrowdSec mati ±1 j 51 m). Pakai `docker exec <c> kill -<SIG> 1` (sinyal dikirim dari
  dalam container oleh uid yang sama dengan PID 1; `/bin/kill` busybox ada di image Traefik v3.7.13 & CrowdSec v1.8.1).
  Berlaku juga untuk control plane (T10) yang merender `dynamic/clients/<slug>.yml`.
- `restart: always` (H7, keputusan user 2026-09-23, pengecualian CLAUDE.md §3.5): start saat daemon/reboot walau flag
  manual-stop ter-set. `docker stop traefik` tidak bertahan melewati reboot → matikan permanen dengan `docker compose down`.
  Recreate H7: tanpa respons 23:24:35.9–23:24:39.4 WIB (±3.5 s). Uji reload H7 (`docker exec traefik kill -HUP 1` +
  file uji di `dynamic/platform/`): `traefik_config_reloads_total` 2 → 3 → 4 (tambah/hapus file), HUP tanpa perubahan → tetap
  4; `HasBeenManuallyStopped` tetap `False`.
- Perubahan `traefik.yml` → `docker compose restart traefik`; perubahan `ports`/`networks` compose → `docker compose up -d`
  (recreate; terukur H5: 5 s tanpa respons, 17:18:18–17:18:23 WIB) (plugin CrowdSec diunduh ulang ke tmpfs
  `/plugins-storage` dan diverifikasi `hash`).
- Validasi sebelum restart: `docker compose config -q`.

## Cek sertifikat

```bash
echo | openssl s_client -connect 31.97.50.221:443 -servername <fqdn> 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates
# staging → issuer mengandung "(STAGING)"
docker logs traefik 2>&1 | grep -i -E 'acme|lego|certificate' | tail
```
Jangan me-restart berulang bila ACME gagal: baca log, perbaiki (DNS/port 80), baru ulang —
limit LE: 5 authorization failure / identifier / jam (ADR 0002).

## Pindah staging → production (DILAKUKAN 2026-09-23 untuk `status` & `auth` T05/T06, `cp` T16a, `grafana` T14a, `cp.staging` T16b, `drms-kas.staging` ProyekKas)

1. Backup: `cp -a acme/acme-staging.json acme/acme-staging.json.bak-$(date +%F)`.
2. Per router: `certResolver: le-http-staging` → `le-http`.
3. **Hapus entri sertifikat staging untuk hostname itu dari `acme-staging.json`** (akun tetap) lalu
   `docker compose restart traefik`. Tanpa langkah ini `le-http` TIDAK meminta sertifikat: provider ACME
   menganggap domain sudah tercakup sertifikat yang ada di TLS store (source v3.7 `getUncheckedDomains`),
   termasuk sertifikat staging (diuji: SIGHUP saja → tetap staging, tanpa log ACME).
4. Verifikasi issuer tidak lagi `(STAGING)`: `openssl s_client … -verify_return_error` → `Verify return code: 0`.
5. Naikkan HSTS — lihat §HSTS bertahap.

## HSTS bertahap (QA-T17B-06 / F3, disetujui user 2026-09-25)

`stsSeconds` didefinisikan di **empat** middleware dan harus selalu sama: `security-headers`
(`dynamic/middlewares/security-headers.yml`), `auth-security-headers` (`dynamic/platform/auth.yml`),
`odoo-security-headers` (`dynamic/platform/odoo-pools.yml`), `webmail-security-headers`
(`dynamic/clients/webmail-expomedia.yml`, ADR 0012). `stsIncludeSubdomains: false` dan `stsPreload: false`
di ketiganya — **tidak** diubah (preload tidak direncanakan; includeSubDomains = keputusan terpisah: berlaku untuk
semua subdomain host yang mengirimnya, mis. `*.staging.bimacreative.tech` dari host `staging.…` bila kelak ada).

| Tahap | `max-age` | Tanggal | Syarat |
|---|---|---|---|
| 0 | 300 | s/d 2026-09-25 | fase ACME staging |
| 1 | 604800 (1 minggu) | 2026-09-25 | semua host `le-http` (QA T17b F1) |
| 2 | 31536000 (1 tahun) | **2026-10-09** | 2 minggu tahap 1 tanpa insiden TLS/sertifikat (cek `docker logs traefik` ACME, Uptime Kuma) |

Terapkan (dynamic, subdirektori → HUP; tanpa restart):
```bash
docker exec traefik kill -HUP 1
for h in cp auth status demo.erp; do curl -sI --resolve $h.bimacreative.tech:443:127.0.0.1 https://$h.bimacreative.tech/ \
  | grep -i strict-transport; done     # max-age=<nilai baru>
```
Rollback: kembalikan `stsSeconds` di ketiga file → HUP. Catatan: browser yang sudah menerima `max-age` panjang tetap
memaksa HTTPS sampai kedaluwarsa — rollback tidak menghapus cache HSTS di klien (itulah alasan bertahap).

## Rotasi / secret

- `acme*.json` berisi private key → 600, masuk backup terenkripsi (ADR 0006). Hapus akun/sertifikat
  staging = hapus isi `acme-staging.json` (**destruktif — konfirmasi Lead**), lalu restart.
- Access log: logrotate harian, simpan 14, `maxsize 100M`, `postrotate` mengirim USR1
  (`docker exec traefik kill -USR1 1`; sebelum H7 `docker kill --signal=USR1` — men-set flag manual-stop, lihat
  §Start/stop/reload) — diuji `logrotate -f`, file baru dibuat Traefik.

## Admin via SSH tunnel (catatan penting)

> **H5 (2026-09-23):** panel admin kini hanya di entrypoint `admin` (`127.0.0.1:8443`) — tunnel
> `ssh -p 2221 -N -L 8443:127.0.0.1:8443 admin@31.97.50.221` (§Entrypoint `admin`). Uraian di bawah tetap berlaku untuk
> IP sumber; `10.100.0.1` di :443 **tidak lagi** membuka path admin (hairpin container juga tiba sebagai 10.100.0.1).

Daemon Docker memakai `userland-proxy: false`. Koneksi yang berasal dari host itu sendiri
(termasuk `ssh -L 8443:127.0.0.1:8443 …`, dulu `…:443`, dan curl ke IP publik sendiri) tiba di Traefik dengan IP sumber
**gateway network `proxy` = `10.100.0.1`**, bukan `127.0.0.1`. Koneksi dari internet tetap membawa IP asli
client. **Keputusan Lead (2026-09-23): `10.100.0.1/32` ditambahkan ke `ipallowlist-admin`** (= semua proses
di host; host hanya bisa diakses admin via SSH 2221). Syarat: Traefik harus memakai `proxy` sebagai network
gateway (`gw_priority: 1` di compose) — bila tidak, sumbernya menjadi gateway network lain (mis. 10.100.2.1).
Konsekuensi: uji "dari publik" tidak bisa dilakukan dari host (hairpin = 10.100.0.1); gunakan container uji
di network `proxy` dengan IP tetap (mis. `--ip 10.100.0.250`) atau uji dari luar. Contoh admin Keycloak:
`keycloak.md` §Akses admin console.

## Rollback

`docker compose down` → kembalikan file dari git (`git checkout <rev> -- traefik/`) → `up -d`.
`acme/` tidak tersentuh oleh rollback git (di-ignore). Menghapus stack sepenuhnya: `down` saja;
jangan hapus `acme/` tanpa konfirmasi.
