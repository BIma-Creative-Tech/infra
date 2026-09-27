# Operasional — Web analytics Umami (`analytics.bimacreative.tech`)

- **Stack:** `/opt/infra/analytics/umami/` · image `ghcr.io/umami-software/umami:3.4.0@sha256:85909afc…2f367` (MIT)
- **Terkait:** ADR 0013, plan 11, ADR 0010 (network), ADR 0002 (TLS), ADR 0006 (backup), `postgres.md`, `traefik.md`,
  `web-clients.md`, `observability.md`
- **Diterapkan:** 2026-09-27 (plan 11 U1–U5, U10).

## Struktur

| Path | Isi | Git |
|---|---|---|
| `docker-compose.yml` | service `umami` (uid 1001, rootfs ro + tmpfs `/tmp`, `/app/.next/cache`, cap_drop ALL, 256m / 0.5 CPU / pids 128) | ya |
| `scripts/bootstrap.sh` | idempoten: `.env` 600 root — `APP_SECRET`, `TWO_FACTOR_ENCRYPTION_KEY` (`openssl rand -hex 32`, dibuat sekali, tidak pernah ditimpa), `DATABASE_URL` diselaraskan dengan `PG_UMAMI_PASSWORD` di `postgres/.env`; `secrets/` 700 | ya |
| `.env` | secret di atas — **jangan** mengganti `APP_SECRET`/`TWO_FACTOR_ENCRYPTION_KEY` setelah ada data (token/2FA tidak valid) | **tidak** |
| `secrets/admin-password` | password admin Umami (40 char, 600 root) — untuk owner; pindahkan ke password manager lalu `shred -u` | **tidak** |

## Arsitektur

| Komponen | Nilai |
|---|---|
| Network | `analytics-edge` 10.100.17.0/24 `--internal` (traefik + umami) · `db-umami` 10.100.28.0/24 `--internal` (postgres + umami) → **tanpa egress** |
| DB | DB `umami`, role owner `umami` (`CONNECTION LIMIT 10`), pg_hba `host umami umami 10.100.28.0/24`; migrasi Prisma otomatis saat start (26 migrasi di 3.4.0, ext `pgcrypto`) |
| Env | `TRACKER_SCRIPT_NAME=insight.js` (proxy Umami mencocokkan path persis `/<nilai>` → wajib `.js`), `CLIENT_IP_HEADER=x-real-ip`, `DISABLE_TELEMETRY`/`DISABLE_UPDATES`/`PRIVATE_MODE=1` (dibaca `!!process.env.X`) |
| Router | `traefik/dynamic/platform/analytics.yml` (subdirektori → `docker exec traefik kill -HUP 1`) |

Paparan:

| Entrypoint | Router | Rule | Middleware |
|---|---|---|---|
| :443 | `analytics-script` | `GET\|HEAD /insight.js` | crowdsec, analytics-headers, ratelimit-default |
| :443 | `analytics-collect` | `POST\|OPTIONS /api/send` | crowdsec, analytics-headers, `ratelimit-analytics-collect` (120/menit, burst 60 per IP) |
| :443 | — | semua path lain (`/`, `/login`, `/api/*`, `/share/*`, `/script.js`) | **404** (tanpa router) |
| :8443 | `analytics-admin-login` | `POST /api/auth/login`, `/api/2fa/verify` (prio 100) | crowdsec, ipallowlist-admin, analytics-headers, ratelimit-login |
| :8443 | `analytics-admin` | seluruh host | crowdsec, ipallowlist-admin, analytics-headers, ratelimit-default |

`analytics-headers` = salinan `security-headers` (**`stsSeconds` wajib sama**, lihat `traefik.md` §HSTS) + menghapus header
request IP/geo yang bisa dipalsukan klien (`True-Client-IP`, `CF-Connecting-IP`, `Forwarded`, `X-Client-IP`, …, serta header
lokasi CDN `CF-IPCountry`, `X-Vercel-IP-*`, `CloudFront-Viewer-*`, `EO-*` — Umami 3.4.0 membaca lokasi dari header itu
**sebelum** GeoLite2). `X-Real-Ip` selalu ditimpa Traefik dengan IP koneksi. CORS dari Umami sendiri (`*`, max-age 86400).

## Akses admin

```bash
ssh -p 2221 -N -L 8443:127.0.0.1:8443 admin@31.97.50.221
# browser: https://analytics.bimacreative.tech:8443/  (hosts lokal: analytics.bimacreative.tech → 127.0.0.1)
# user `admin`, password: sudo cat /opt/infra/analytics/umami/secrets/admin-password
```
Password bawaan `admin/umami` sudah diganti 2026-09-27 (login bawaan → 401). **Owner:** aktifkan 2FA (Settings → Profile →
Two-factor authentication), simpan password di password manager, lalu `shred -u` file di atas.

Website (Website ID bukan secret — muncul di HTML):

| Nama | Domain | Website ID | Status |
|---|---|---|---|
| `bimacreative.tech` | `bimacreative.tech` | `dd77fb50-e047-49fe-919f-682dc6d10f44` | prod (plan 11 U9) |
| `bct-staging` | `bct.staging.bimacreative.tech` | `f43f3730-811d-4846-8c43-c9c8ac80b840` | hanya selama QA (U8), lalu flag dicabut dari staging; berisi 5 event uji 2026-09-27 |

Integrasi website: `provision-web-client.sh … --umami-script-url https://analytics.bimacreative.tech/insight.js
--umami-website-id <uuid>` (`web-clients.md` §Analytics).

## Start / stop / verifikasi

```bash
cd /opt/infra/analytics/umami
./scripts/bootstrap.sh                 # idempoten
docker compose up -d && docker compose ps     # (healthy) — healthcheck curl /api/heartbeat
docker exec postgres psql -U postgres -d umami -Atc "select count(*), count(finished_at) from _prisma_migrations"
H=analytics.bimacreative.tech
curl -sI --resolve $H:443:127.0.0.1 https://$H/insight.js          # 200 application/javascript
curl -s -o /dev/null -w '%{http_code}\n' --resolve $H:443:127.0.0.1 https://$H/login     # 404
curl -s -o /dev/null -w '%{http_code}\n' --resolve $H:8443:127.0.0.1 https://$H:8443/login   # 200
```

## Uji 2026-09-27 (dari host → Traefik sebagai 10.100.0.1)

| Uji | Hasil |
|---|---|
| Hardening `docker inspect` | uid 1001, ReadonlyRootfs, CapDrop ALL, no-new-privileges, 256m, 0.5 CPU, pids 128, tanpa port, network analytics-edge + db-umami |
| Log / migrasi | tanpa `EROFS`/error; `_prisma_migrations` 26/26 `finished_at` |
| Egress | `wget https://example.com`, `curl https://1.1.1.1` dari container → gagal |
| pg_hba | umami@db-umami→umami OK; →control_plane/postgres dan dari db-cp → `pg_hba.conf rejects connection` |
| Publik :443 | `/insight.js` 200 (LE `CN=analytics.bimacreative.tech`, verify 0), HTTP→301; `/`, `/login`, `/api/websites`, `/api/heartbeat`, `/api/me`, `/share/x`, `/script.js`, `GET /api/send`, `POST /api/auth/login`, `PUT /api/send` → 404 |
| :8443 | `/login` 200 via loopback; dari container di `proxy` → 403 |
| CORS | `OPTIONS /api/send` → 204 + `Access-Control-Allow-Origin: *` |
| AppSec FP | beacon judul Indonesia (`–`, `&`, `"`, `'`), path 150+ char, referrer Google `?q=…&utm_*`, event + data, header `x-umami-cache` (JWT) → **200**; `url` berisi `<script>alert(1)</script>` → **403** (alert `xss: 20`, tanpa decision — IP privat) |
| IP/geo spoof | `X-Real-Ip`/`CF-Connecting-IP`/`True-Client-IP`/`X-Forwarded-For: 8.8.8.8` + `CF-IPCountry: US` → sesi tanpa negara (IP koneksi privat), bukan US |
| Rate limit | 200 `OPTIONS` beruntun → 93 × 204, 107 × 429; tanpa decision CrowdSec |
| Restore | `restore.sh umami umami_restoretest` → website_event 5/5, session 2/2, website 2/2, migrasi 26/26 → DB uji di-DROP |

## Backup / restore

DB `umami` ikut dump dinamis (`db:umami`); `.env` (APP_SECRET) + `secrets/` ikut snapshot `files` (diverifikasi `restic ls`).
Restore: `sudo /opt/infra/scripts/restore.sh umami umami_restoretest` (uji) — restore sungguhan ke DB baru lalu ganti
`DATABASE_URL` (`backup.md`).

## Upgrade (migrasi DB maju otomatis)

1. `systemctl start restic-backup.service` (atau `pg_dump` DB `umami`) — rollback image saja **tidak cukup**.
2. Ganti tag + digest di `docker-compose.yml` (verifikasi `docker buildx imagetools inspect`), Trivy image.
3. `docker compose up -d` → log migrasi → `docker exec postgres psql -U postgres -d umami -c 'ANALYZE;'`.
4. Gagal: restore dump pra-upgrade ke DB baru, `DATABASE_URL` → DB itu, image lama.

GeoLite2-City dibundel di image (build Umami, sumber redistribusi `node-geolite2-redist`). EULA GeoLite (diperbarui
2026-02-12) §6(3): versi lama wajib dihentikan/dihapus ≤ 30 hari setelah rilis database baru → **upgrade image Umami
minimal bulanan** (sekalian patch CVE). Atribusi wajib (§3) — lihat §Privasi.

## Privasi

Tanpa cookie; IP tidak disimpan (tabel `session`: browser, os, device, screen, language, country, region, city); website
memakai `data-do-not-track` + `data-exclude-search`. Atribusi MaxMind (EULA GeoLite §3): *"This product includes GeoLite
Data created by MaxMind, available from https://www.maxmind.com"* — dicantumkan di dokumen ini; disarankan juga di halaman
privasi website (keputusan Lead/owner). Retensi 25 bulan (GATE 1 Q5) = job bulanan, **task lanjutan (belum dibuat)**.

## Rollback

- Router: hapus `traefik/dynamic/platform/analytics.yml` → `docker exec traefik kill -HUP 1` (host → 404).
- Stack: `docker compose down` (tanpa volume; data di Postgres).
- Network/DB: plan 11 §9 (`DROP DATABASE umami` hanya dengan konfirmasi user).

## Drift diketahui

`postgres` dan `traefik` di-attach live (`docker network connect db-umami postgres`, `analytics-edge traefik`) → `docker
compose --dry-run up -d` di kedua stack = **Recreate** sampai jendela recreate terjadwal berikutnya (plan 11 R9).
