# Operasional — Traefik (edge, T03)

- **Stack:** `/opt/infra/traefik/` · image `traefik:v3.7.13` (pin tag + digest, ADR 0001)
- **Terkait:** ADR 0002 (HTTP-01 per hostname, tanpa wildcard), plan 02 §3–§4, CLAUDE.md §3.5.1

## Struktur

| Path | Isi | Git |
|---|---|---|
| `traefik.yml` | static config: entrypoints `web` :80 (redirect → https) & `websecure` :443, **`admin` :8443 (H5, publish `127.0.0.1:8443` host saja)**, `traefik` 127.0.0.1:8080 di dalam container (hanya `/ping`), `metrics` :8082, file provider, resolver `le-http-staging` & `le-http`, access log JSON | ya |
| `dynamic/middlewares/*.yml` | `security-headers`, `ratelimit-default`, `ratelimit-login`, `ipallowlist-admin`, `strip-odoo-db-headers`, `deny-all` + service `deny-sink` (H5) | ya |
| `dynamic/tls.yml` | TLS option `default` (min TLS 1.2) | ya |
| `dynamic/platform/<svc>.yml` | router layanan platform (T06 `auth.yml`, T16a `cp.yml`, T16b `cp-staging.yml`, T14a `status.yml`/`grafana.yml`, …) — satu file per task | ya |
| `dynamic/platform/odoo-pools.yml` | service `odoo-pool-a-{http,ws}`, `odoo-staging-{http,ws}` + middleware `odoo-security-headers` (T10) | ya |
| `dynamic/clients/<slug>-<env>.yml` | router tenant Odoo, dirender `scripts/render-client-route.sh` dari `templates/traefik-client.yml` (T10) — lihat `odoo.md` | ya |
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
  subdirektori: `docker kill --signal=HUP traefik` (provider file memuat ulang konfigurasi saat SIGHUP).
  Berlaku juga untuk control plane (T10) yang merender `dynamic/clients/<slug>.yml`.
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

## Pindah staging → production (DILAKUKAN 2026-09-23 untuk `status` & `auth` T05/T06, `cp` T16a, `grafana` T14a, `cp.staging` T16b)

1. Backup: `cp -a acme/acme-staging.json acme/acme-staging.json.bak-$(date +%F)`.
2. Per router: `certResolver: le-http-staging` → `le-http`.
3. **Hapus entri sertifikat staging untuk hostname itu dari `acme-staging.json`** (akun tetap) lalu
   `docker compose restart traefik`. Tanpa langkah ini `le-http` TIDAK meminta sertifikat: provider ACME
   menganggap domain sudah tercakup sertifikat yang ada di TLS store (source v3.7 `getUncheckedDomains`),
   termasuk sertifikat staging (diuji: SIGHUP saja → tetap staging, tanpa log ACME).
4. Verifikasi issuer tidak lagi `(STAGING)`: `openssl s_client … -verify_return_error` → `Verify return code: 0`.
5. Naikkan HSTS di `security-headers.yml` & `auth-security-headers` (`stsSeconds: 31536000`) — keputusan Lead setelah QA.

## Rotasi / secret

- `acme*.json` berisi private key → 600, masuk backup terenkripsi (ADR 0006). Hapus akun/sertifikat
  staging = hapus isi `acme-staging.json` (**destruktif — konfirmasi Lead**), lalu restart.
- Access log: logrotate harian, simpan 14, `maxsize 100M`, `postrotate` mengirim USR1
  (`docker kill --signal=USR1 traefik`) — diuji `logrotate -f`, file baru dibuat Traefik.

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
