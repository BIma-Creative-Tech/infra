# Plan 11 — Web analytics self-hosted Umami (`analytics.bimacreative.tech`) untuk website client

- Status: **APPROVED — GATE 1 2026-09-27** (user: "Setuju" semua rekomendasi §11; Q8 DNS A `analytics` → 31.97.50.221 sudah ada, tanpa AAAA; Q11 teks privasi disusun Lead untuk bct-website). Eksekusi U1–U11 dimulai.
- Tanggal: 2026-09-27 · Penulis: Analyst (untuk Lead) · Permintaan owner (via Lead): "Ya, buat plan dulu".
- ADR: `docs/adr/0013-web-analytics-umami.md` (**proposed**). Plan 10 dicadangkan untuk pemecahan network `proxy`.
- Terkait: ADR 0002 (HTTP-01, DNS pre-check, tanpa AAAA, CAA), ADR 0004 (kapasitas), ADR 0006 (backup), ADR 0007 (stack
  web client, CSP nonce), ADR 0010 (network per konsumen), plan 03 (template web client), `docs/03-operations/{postgres,
  traefik,crowdsec,backup,observability,web-clients}.md`, CLAUDE.md §0, §3.5, §3.5.1, §3.6, §4.

Penanda: **[NYATA]** = diukur/dibaca di sesi ini (2026-09-27) · **[ESTIMASI]** = perkiraan · **[UNVERIFIED]** = belum
bisa dipastikan dari docs/kode, wajib diuji saat eksekusi.

## 1. Tujuan, scope, non-goal

**Tujuan:** analytics pengunjung website client yang di-host platform (pertama: `bct-website` di `bimacreative.tech`)
tanpa Google Analytics/pihak ketiga, tanpa cookie, data tetap di VPS sendiri.

**IN**
- Stack baru `/opt/infra/analytics/umami/` (1 container Umami 3.4.0) + DB `umami` di Postgres shared.
- Network `db-umami` (Postgres) dan `analytics-edge` (Traefik), keduanya `--internal`.
- Router Traefik `traefik/dynamic/platform/analytics.yml`: publik hanya skrip tracker + `POST /api/send`; UI admin hanya
  di entrypoint `admin` (:8443, SSH tunnel) — pola Grafana/Uptime Kuma (H5).
- Template web client: override opsional `docker-compose.umami.yml` + flag `provision-web-client.sh
  --umami-script-url/--umami-website-id` → env runtime `UMAMI_SCRIPT_URL`, `UMAMI_WEBSITE_ID`.
- Perubahan app `bct-website` (repo terpisah, Next.js developer): baca env runtime, render skrip dengan nonce, CSP.
- Backup (otomatis lewat daftar DB dinamis), monitor Uptime Kuma, docs ops + CHANGELOG + ADR 0013 + revisi ADR 0004.

**OUT (non-goal)**
- Login SSO/OIDC Keycloak ke Umami (tidak didukung Umami OSS, §3.4).
- Dashboard untuk client (link share publik `/share/*`, akun per client) — GATE 1 Q6; default tidak.
- ClickHouse/Kafka/Redis, instance Umami staging terpisah, analytics untuk Odoo/control plane/DRMS.
- Perubahan `COLLECT_API_ENDPOINT`/`BASE_PATH` (butuh rootfs writable / build ulang image).
- Integrasi control plane (menambah website Umami otomatis) — kelak, bila jumlah client banyak.
- Retensi otomatis data (butuh keputusan GATE 1 Q5; implementasi = task lanjutan).

## 2. Fakta discovery (2026-09-27)

### 2.1 Host & platform [NYATA]
- `free -m`: total 15 992 MiB, used 5 274, available 10 718, swap terpakai 1 220 / 4 095 MiB. 4 vCPU. Disk `/` 92 G / 193 G (48%).
- `docker stats --no-stream`: 28 container (2 di antaranya `e9qa-k6-smoke-*` sementara QA DRMS, tanpa limit). Jumlah
  `mem_limit` container platform **13 936 MiB** (T19 dulu 12 400; bertambah web-bct prod/staging, web-expomedia
  prod/staging, web-tambang-staging, webmail). Pemakaian nyata tetap rendah (web-* 54–76 MiB, postgres 221 MiB).
- Postgres 16.15: `max_connections` 200, `superuser_reserved_connections` 3, `sum(rolconnlimit)` = **186**, 30 koneksi aktif.
- Network terpakai (`docker network ls` + `ip -4 route`): 10.100.0,2,3,4,5,7,8,9,10,11,12,13,15,16,20,21,22,23,24,26.
  Dicadangkan di docs: 1 (pensiun), 6 (pensiun), 14 (`drms-kas-edge-prod`), 25 (`db-drms`), 27 (`db-datamart`),
  28–39 (`db-*` berikutnya). **Bebas & tidak disebut di repo (`git grep` main + `feat/infra-drms-prod`): 10.100.17–19.**
- DNS: `analytics.bimacreative.tech` A/AAAA/CNAME **kosong** (@1.1.1.1), tidak ada wildcard `*.bimacreative.tech`.
  CAA (@athena.dns-parking.com) = `0 issue "letsencrypt.org"` saja, tanpa `accounturi` (dilepas 2026-09-26) → **tidak ada
  perubahan CAA** yang diperlukan; `issuewild` tidak bisa dipasang di Hostinger (ADR 0002 #16).
- `bct-website` (`/opt/src/bct-website`, v0.1.0): `lib/csp.ts` sudah menambahkan origin `NEXT_PUBLIC_UMAMI_SRC` ke
  `script-src`/`connect-src`, tetapi **skrip Umami belum pernah dirender** (tidak ada `next/script`/`UMAMI_ID` di
  `app/`, `components/`) dan variabel `NEXT_PUBLIC_*` dibakar saat build — tidak cocok dengan pola "satu image untuk
  staging & prod" (Turnstile sengaja dibuat runtime karena alasan ini, `lib/env.ts`).

### 2.2 Umami (sumber resmi; dibaca 2026-09-27)
| Hal | Fakta | Sumber |
|---|---|---|
| Lisensi | MIT | `LICENSE` v3.4.0, GitHub API spdx |
| Versi | **v3.4.0** (2026-09-17); rilis rutin (3.3.1 08-20, 3.3.0 08-12, 3.2.0 06-24); push terakhir repo 2026-09-26 → aktif | GitHub releases |
| Image | `ghcr.io/umami-software/umami:3.4.0@sha256:85909afc45bdcda1917394594a087421fdbb05610fded0fa9f6fb861abb2f367` (OCI index amd64+arm64; diverifikasi ulang `docker buildx imagetools inspect`). Tag v3 = `3.4.0` (bukan `postgresql-v…`; itu skema v2) | ghcr tags/list |
| DB | **PostgreSQL saja** sejak v3 (MySQL dihapus). Docs: minimum PG 12.14 → PG 16.15 kita OK. Migrasi `01_init`: `CREATE EXTENSION IF NOT EXISTS "pgcrypto"` (trusted extension sejak PG13 → bisa dibuat owner DB) | release v3.0.0, docs install, source |
| Migrasi | **Otomatis saat start**: `scripts/start-docker.sh` → `check-db.js` (cek env, koneksi, versi, lalu `prisma migrate deploy`) → `exec node server.js`. `SKIP_DB_MIGRATION` / `SKIP_DB_CHECK` ada | Dockerfile, scripts |
| Container | `node:22-alpine`, `USER nextjs` **uid 1001**, port 3000, tanpa `HEALTHCHECK` (compose resmi: `curl http://localhost:3000/api/heartbeat`), `init: true` | Dockerfile, docker-compose.yml |
| Rootfs | `update-tracker.js` menulis `/app/public/script.js` **hanya bila** `COLLECT_API_ENDPOINT` diset; engine Prisma dibakar saat build. `read_only: true` **[UNVERIFIED]** — kemungkinan butuh tmpfs `/tmp` + `/app/.next/cache` | source |
| Env runtime | `DATABASE_URL` (wajib), `APP_SECRET`, `TRACKER_SCRIPT_NAME`, `CLIENT_IP_HEADER`, `DISABLE_TELEMETRY`, `DISABLE_UPDATES`, `PRIVATE_MODE` (matikan semua panggilan keluar), `IGNORE_IP`, `CORS_MAX_AGE`, `SALT_ROTATION`, `TWO_FACTOR_ENCRYPTION_KEY` (64 hex), `DISABLE_BOT_CHECK`, `REDIS_URL`. `HASH_SALT` **sudah tidak ada** — tanpa `APP_SECRET` secret = `DATABASE_URL` | docs.umami.is/docs/environment-variables, `src/lib/crypto.ts` |
| Env build-time | `BASE_PATH`, `FORCE_SSL`, `DEFAULT_LOCALE` dll. → tidak dipakai (image resmi apa adanya) | docs, Dockerfile |
| Login | User bawaan **`admin` / `umami`** dibuat migrasi; ganti password **tidak dipaksa**. 2FA TOTP ada. **Tidak ada OIDC/SAML/SSO** (issue #1112, #1608, #3163 masih terbuka) | docs login, source |
| Tracker | `POST /api/send`, `fetch` `keepalive`, **`Content-Type: application/json`** + header `x-umami-website-id`, `x-umami-hostname`, `x-umami-cache` → **preflight CORS**. Server: `Access-Control-Allow-Origin: *`, `Allow-Headers: *`, max-age `CORS_MAX_AGE` (86400). Atribut: `data-website-id`, `data-domains`, `data-do-not-track`, `data-exclude-search`, `data-exclude-hash`, `data-fetch-credentials` (default `omit`) | `src/tracker/index.ts`, `docker/proxy.ts` |
| Privasi | Tanpa cookie. **IP tidak disimpan** (tabel session: browser/os/device/screen/language/country/region/city). `sessionId = uuidv5(hash(website, ip, UA, salt, …))`, salt rotasi bulanan (`SALT_ROTATION`). GeoLite2-City (±66 MB) dibundel di image saat build (EULA MaxMind — atribusi; **[UNVERIFIED]** dari docs Umami). Payload `/api/send` menerima override `ip`/`userAgent` | source `detect.ts`, `session` schema |
| Retensi | **Tidak ada retensi otomatis** (hanya reset/hapus data per website manual) **[UNVERIFIED — dari grep source]** | source |
| RAM | Tidak ada angka resmi. Laporan komunitas ±100 MB (limit 256 MB, ±500 event/hari); ada laporan > 1 GB setelah jalan lama (#1134) → **[ESTIMASI]** | discussions #2715, issue #1134 |
| Upgrade | Pull image + restart; migrasi otomatis; docs menyarankan `ANALYZE;` setelah upgrade mayor. Tidak ada saran backup resmi → `pg_dump` sebelum upgrade (wajib di runbook) | docs.umami.is/docs/updates |

## 3. Arsitektur

```
Pengunjung bimacreative.tech ──GET /insight.js, OPTIONS+POST /api/send──▶ :443 Traefik
   │ crowdsec(+AppSec) → analytics-headers → ratelimit-*                        │
   │                                                                              │ analytics-edge 10.100.17.0/24 (--internal)
Admin (SSH tunnel 127.0.0.1:8443) ──seluruh UI/API──▶ :8443 entrypoint admin    ▼
   crowdsec → ipallowlist-admin → headers → ratelimit-default/-login      umami:3000 (uid 1001, ro rootfs, tanpa egress)
                                                                                  │ db-umami 10.100.28.0/24 (--internal)
                                                                                  ▼
                                                                    postgres (shared, DB `umami`, role `umami`)
```

### 3.1 Container & DB — rekomendasi: **Postgres shared, DB baru `umami`**
| Opsi | Untung | Rugi |
|---|---|---|
| **A. DB `umami` di Postgres shared (DIREKOMENDASIKAN)** | +0 container DB; backup/restore/monitoring/patching sudah ada (dump dinamis ADR 0006); isolasi via `db-umami` + `pg_hba` per subnet (ADR 0010); RAM tambahan hanya koneksi | Berbagi `max_connections` (sisa 11 slot di atas limit role sekarang) dan I/O dengan Odoo/Keycloak; upgrade PG mayor serentak |
| B. Postgres dedicated | Isolasi penuh, bisa PG versi lain | +128–256 MiB `mem_limit` di atas anggaran yang sudah minus (§6), path backup baru, patch CVE tambahan |

Alasan A: beban tulis Umami untuk beberapa website kecil rendah (satu `INSERT` per pageview/event); pola ini sudah
dipakai Keycloak, control plane, DRMS. Pindah ke B kelak = `pg_dump`/`pg_restore` + ganti `DATABASE_URL` (tanpa ubah app).

**Role:** satu role `umami` = **owner DB `umami`** (pola `keycloak`/`control_plane`, bukan pola 3 role DRMS), karena
Umami menjalankan `prisma migrate deploy` sendiri saat start (butuh DDL + `CREATE EXTENSION pgcrypto`). Memisah
owner/app butuh `SKIP_DB_MIGRATION` + container migrate terpisah + GRANT tabel manual tiap upgrade — kompleksitas tidak
sebanding untuk data analytics. `LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 10`;
`REVOKE ALL ON DATABASE umami FROM PUBLIC`. Password 48 char alnum di `postgres/.env` `PG_UMAMI_PASSWORD` (bootstrap.sh).
Anggaran koneksi: 186 + 10 = **196 ≤ 197** (200 − 3 reserved) → **ketat**; lihat Risiko R4. Batas pool Prisma di sisi
app (`?connection_limit=5` pada URL) **[UNVERIFIED untuk Prisma 7 + driver adapter]** — QA mengukur `pg_stat_activity`;
batas keras tetap `CONNECTION LIMIT` role.

### 3.2 Network (ADR 0010)
| Network | Subnet / gw | `--internal` | Dibuat oleh | Anggota | Alasan |
|---|---|---|---|---|---|
| `db-umami` | 10.100.28.0/24 / .1 | ya | `postgres/scripts/bootstrap.sh` | postgres, umami | blok `db-*` 28–39, slot pertama bebas |
| `analytics-edge` | 10.100.17.0/24 / .1 | **ya** | `traefik/scripts/bootstrap.sh` | traefik, umami | 17–19 bebas; internal karena Umami tidak butuh egress (GeoIP dibundel, `PRIVATE_MODE=1`, telemetri/update off) — pola `webmail-edge` |

Traefik join tanpa `gw_priority` (internal = tanpa gateway, `proxy` tetap gateway). `pg_hba`: satu baris
`host umami umami 10.100.28.0/24 scram-sha-256 # db-umami`, ditulis **di tempat** (`cat > …`, inode tetap) + `pg_reload_conf()`.
Menambah network ke compose `postgres`/`traefik` membuat `--dry-run` = Recreate (fakta runbook plan 06 #2) → attach
**live** (`docker network connect`) dulu, recreate di jendela terjadwal berikutnya (tercatat sebagai drift diketahui).

### 3.3 Router Traefik (`traefik/dynamic/platform/analytics.yml`) — rekomendasi
| Router | EntryPoint | Rule | Middleware | Catatan |
|---|---|---|---|---|
| `analytics-collect` | websecure | `Host(analytics…) && Path(/api/send) && (Method(POST) \|\| Method(OPTIONS))` | crowdsec, analytics-headers, `ratelimit-analytics-collect` | beacon + preflight |
| `analytics-script` | websecure | `Host(analytics…) && Path(/<TRACKER>.js) && (Method(GET) \|\| Method(HEAD))` | crowdsec, analytics-headers, ratelimit-default | skrip tracker |
| (lainnya di :443) | — | tidak ada router | — | 404 dari Traefik: `/login`, `/api/auth/*`, `/api/websites/*`, `/share/*`, `/api/heartbeat` tidak publik |
| `analytics-admin-login` | admin | `Host(analytics…) && Method(POST) && Path(/api/auth/login)` | crowdsec, ipallowlist-admin, analytics-headers, ratelimit-login | prioritas 100 |
| `analytics-admin` | admin | `Host(analytics…)` | crowdsec, ipallowlist-admin, analytics-headers, ratelimit-default | seluruh UI/API; `https://analytics.bimacreative.tech:8443/` via SSH tunnel |

- **`ratelimit-analytics-collect`** (per IP sumber, default `sourceCriterion`): `average: 120, period: 1m, burst: 60`
  **[ESTIMASI]** — satu pageview = 1 preflight (di-cache 86400 s) + 1 POST; toleran NAT kantor. Tuning dari access log
  (`RouterName=analytics-collect@file`, status 429).
- **`analytics-headers`**: salinan `security-headers` (stsSeconds **sama**, wajib ikut daftar "nilai sama" di
  `security-headers.yml`) + `customRequestHeaders` yang **menghapus** header IP yang bisa dipalsukan klien
  (`CF-Connecting-IP`, `True-Client-IP`, `X-Client-IP`, `Fastly-Client-IP`, `X-Cluster-Client-IP`, `Forwarded`: `""`), dan
  Umami diset `CLIENT_IP_HEADER=x-real-ip` (Traefik menimpa `X-Real-Ip` dengan IP koneksi; tanpa `trustedIPs`
  `X-Forwarded-For` klien tidak dipercaya — **[UNVERIFIED untuk urutan header Umami 3.4.0]**, QA uji dengan header palsu).
  `frameDeny: true` (UI admin tidak perlu di-iframe).
- **CORS:** dibiarkan dari Umami (`Access-Control-Allow-Origin: *`, tanpa kredensial; `data-fetch-credentials` default
  `omit`). Traefik **tidak** menambah header CORS (ganda/konflik dengan header app). Membatasi origin di edge tidak
  menambah keamanan berarti: siapa pun bisa mengirim beacon palsu langsung dengan curl (tidak butuh CORS) — itu risiko
  bawaan analytics publik (R6), dimitigasi rate limit + `isbot` + CrowdSec.
- `CORS_MAX_AGE` default 86400 dipertahankan → preflight jarang.
- Nama skrip: `TRACKER_SCRIPT_NAME` → usulan **`insight`** ⇒ `https://analytics.bimacreative.tech/insight.js`
  (nama `script.js` bawaan ada di banyak daftar adblock). Format nilai (dengan/tanpa `.js`) **[UNVERIFIED]** — diverifikasi
  dari `next.config` 3.4.0 saat eksekusi; URL final dicatat di ops doc. Nama host `analytics.` sendiri bisa tetap
  diblok filter generik — terima (GATE Q3).
- `COLLECT_API_ENDPOINT` **tidak** diset (menyetelnya menulis ulang `/app/public/script.js` saat start → bentrok rootfs ro).

### 3.4 UI admin & autentikasi — rekomendasi: **lokal + entrypoint `admin` saja**
Umami OSS tidak mendukung OIDC → tidak bisa di belakang Keycloak secara native (proxy auth seperti oauth2-proxy = tool
baru, butuh ADR tersendiri; tidak direkomendasikan untuk 1 admin). Maka pola Grafana/Keycloak H5: UI hanya di :8443
(loopback host, SSH tunnel) + `ipallowlist-admin`. Langkah wajib saat start pertama (sebelum router publik dipasang pun
login tidak terjangkau publik): login `admin/umami` via tunnel → ganti password (acak 40 char, disimpan
`analytics/umami/secrets/admin-password` 600 root, lalu password manager owner) → ganti username bila didukung UI →
aktifkan **2FA** (`TWO_FACTOR_ENCRYPTION_KEY` di `.env`). Akun per client = non-goal (GATE Q6).

### 3.5 Compose `/opt/infra/analytics/umami/docker-compose.yml` (pseudo-config, final oleh infra-engineer)
```yaml
services:
  umami:
    image: ghcr.io/umami-software/umami:3.4.0@sha256:85909afc45bdcda1917394594a087421fdbb05610fded0fa9f6fb861abb2f367
    container_name: umami
    restart: unless-stopped
    init: true
    user: "1001:1001"
    read_only: true
    tmpfs: ["/tmp:uid=1001,gid=1001,mode=0700,size=16m", "/app/.next/cache:uid=1001,gid=1001,mode=0700,size=64m"]  # [UNVERIFIED] path tulis
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    env_file: .env        # 600 root: DATABASE_URL (password), APP_SECRET, TWO_FACTOR_ENCRYPTION_KEY — tidak di git
    environment:
      TRACKER_SCRIPT_NAME: insight
      CLIENT_IP_HEADER: x-real-ip
      DISABLE_TELEMETRY: "1"
      DISABLE_UPDATES: "1"
      PRIVATE_MODE: "1"
    networks: [analytics-edge, db-umami]
    healthcheck: { test: ["CMD", "curl", "-fsS", "http://127.0.0.1:3000/api/heartbeat"], interval: 30s, timeout: 5s, retries: 3, start_period: 60s }
    mem_limit: 256m
    cpus: 0.5
    pids_limit: 128
    logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }
```
`scripts/bootstrap.sh` (idempoten, pola postgres): buat `.env` dengan `APP_SECRET` (`openssl rand -hex 32`),
`TWO_FACTOR_ENCRYPTION_KEY` (`openssl rand -hex 32` = 64 hex), `DATABASE_URL` dari `PG_UMAMI_PASSWORD`; tidak mencetak
secret, tidak menimpa nilai yang ada. **`APP_SECRET` tidak boleh berubah** setelah data ada (dipakai hash sesi/token) →
ikut backup `files`. Nilai boolean env (`1` vs `true`) **[UNVERIFIED]** — cek parsing di source 3.4.0 saat eksekusi.
Bila `read_only` gagal: identifikasi path dari log (`EROFS`) → tambah tmpfs; **jangan** matikan `read_only` diam-diam
(bila terpaksa: `# TEMPORARY(<tanggal>)` + issue, CLAUDE.md §0.9).

### 3.6 CSP / integrasi website client
Umami dipasang lewat app (CSP dikirim app dengan nonce, ADR 0007 §5), **bukan** Traefik:
- `script-src`: nonce + `'strict-dynamic'` sudah ada; origin Umami ditambahkan sebagai fallback CSP2 (kode `bct-website`
  sudah punya `umamiOrigin()`); skrip WAJIB dirender dengan atribut `nonce` (CSP3 mengabaikan host saat `strict-dynamic`).
- `connect-src 'self' https://analytics.bimacreative.tech` (beacon).
- Tag: `<script defer src={UMAMI_SCRIPT_URL} data-website-id={UMAMI_WEBSITE_ID} data-domains={host kanonik}
  data-do-not-track="true" data-exclude-search="true" nonce={nonce}>` — `data-exclude-search` agar query string (bisa berisi
  data pribadi / pemicu WAF) tidak terkirim; `data-do-not-track` menghormati DNT (GATE Q4).
- Tidak ada `NEXT_PUBLIC_*`: nilai dibaca server per request (pola Turnstile) → satu image untuk staging & prod.

### 3.7 Env passthrough template web client (nama FIX)
| Env (container web) | Contoh | Validasi skrip | Validasi app (Zod) |
|---|---|---|---|
| `UMAMI_SCRIPT_URL` | `https://analytics.bimacreative.tech/insight.js` | `^https://[a-z0-9.-]+(:[0-9]{1,5})?/[A-Za-z0-9._-]+\.js$` | URL https; origin → CSP |
| `UMAMI_WEBSITE_ID` | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` (UUID dari UI Umami) | `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$` | UUID |

- Berpasangan (keduanya atau tidak sama sekali), di skrip **dan** app (boot gagal bila hanya satu — pola Turnstile).
- `provision-web-client.sh … [--umami-script-url <url> --umami-website-id <uuid>]` → `.env` (`UMAMI_SCRIPT_URL=`,
  `UMAMI_WEBSITE_ID=`, bukan secret) + override **`templates/web-client/docker-compose.umami.yml`** dimuat lewat
  `COMPOSE_FILE` (pola `docker-compose.turnstile.yml`). Dengan override (bukan menambah baris ke `docker-compose.yml`
  dasar), website yang tidak memakai analytics **tidak** berubah config-hash-nya → tidak di-recreate saat re-provision
  (backward compatible, CLAUDE.md §3.5).
- Website ID bukan secret (terlihat di HTML), tetapi tetap tidak di git (konsisten `.env` render).
- App lain (web-starter, web-expomedia, web-tambang) memakai nama env yang sama saat diaktifkan kelak (port pola bct).

## 4. Hardening & keamanan (ringkas STRIDE)
| Ancaman | Mitigasi |
|---|---|
| Brute force / eksploit UI admin | UI & semua `/api/*` selain `/api/send` tidak ada router di :443 (404); :8443 loopback + allowlist + ratelimit-login; 2FA; password default diganti sebelum go-live |
| Umami RCE → lateral | uid 1001, ro rootfs, cap_drop ALL, no-new-privileges, pids 128, **tanpa egress** (2 network internal), DB hanya `umami` (pg_hba per subnet), tidak ada secret platform lain di container |
| Spoof IP / geo | hapus header IP alternatif di Traefik + `CLIENT_IP_HEADER=x-real-ip`; override `ip` di payload `/api/send` tetap mungkin (hanya merusak statistik, R6) |
| Beacon memicu WAF → pengunjung di-ban | Uji FP CRS (§8 AC-11); `data-exclude-search`; pengecualian sempit hanya bila FP terbukti (pola H6/H7, persetujuan user) |
| Spam statistik / DoS tulis DB | ratelimit per IP, `isbot`, CrowdSec; `CONNECTION LIMIT 10`; mem_limit |
| Supply chain | image resmi pin digest; Trivy image scan (CRITICAL = stop, HIGH = catat risiko) sebelum deploy |
| Kebocoran data pengunjung | tanpa cookie, IP tidak disimpan, query string dikecualikan; DB di backup terenkripsi restic |

## 5. Privasi & UU PDP (catatan, bukan nasihat hukum)
Umami tanpa cookie dan tidak menyimpan IP; sesi = hash (IP+UA+salt bulanan) → data pseudonim/agregat. UU No. 27/2022 (PDP)
tetap relevan karena IP diproses sesaat dan lokasi kota disimpan. Rekomendasi: (1) kalimat analytics di kebijakan privasi
website client (tanpa cookie, tujuan statistik, retensi); (2) `data-exclude-search` + `data-do-not-track`; (3) retensi
terbatas (GATE Q5, usulan 25 bulan agregat YoY — job hapus event lama = task lanjutan, nama tabel diverifikasi dari
`schema.prisma` 3.4.0 dulu); (4) atribusi GeoLite2 (EULA MaxMind) di halaman privasi/about bila diwajibkan **[UNVERIFIED]**.
Karena tanpa cookie, **tidak perlu banner consent cookie** untuk Umami [ESTIMASI hukum — konfirmasi owner/legal].

## 6. Kapasitas (ADR 0004)
| Item | Nilai |
|---|---|
| Umami `mem_limit` | **256 MiB** (idle [ESTIMASI] 100–150 MiB; laporan komunitas ±100 MB) |
| Postgres | +≤ 10 koneksi × 5–10 MiB ≈ **+50–100 MiB** di dalam limit 2 048 yang ada [ESTIMASI]; limit tidak diubah |
| Disk | image ≈ 400–600 MB [ESTIMASI, GeoLite ±66 MB]; data ≈ 0,5–1 KB/event termasuk index [ESTIMASI] → bct 1 000 pageview/hari ≈ 0,2–0,4 GB/tahun |
| CPU | `cpus: 0.5` (kuota; overcommit disengaja) |

**Aturan perencanaan ADR 0004 sudah terlampaui sebelum plan ini [NYATA]:** 15 992 − 13 936 (limit berjalan) − 384 (dbt)
− 2 048 (cadangan host) = **−376 MiB**; + Umami 256 → **−632 MiB**; + DRMS prod yang direncanakan 576 → **−1 208 MiB**.
Pemakaian nyata tetap aman (available 10 718 MiB; p95 T19 ±5 GiB), tetapi keputusan **R3** ADR 0004 (turunkan limit
longgar vs overcommit terkendali) kini harus diambil — **GATE Q1**. Data riwayat per container sudah tersedia
(`container-metrics.sh` → textfile node-exporter, ADR 0004 §8.2).

## 7. Langkah eksekusi (setelah GATE 1)

| # | Task | Owner | Dep | Estimasi | Downtime |
|---|---|---|---|---|---|
| U0 | Record **A `analytics.bimacreative.tech` → 31.97.50.221**, tanpa AAAA (Hostinger manual) | **owner** | — | 5 mnt + propagasi | 0 |
| U1 | Postgres: `ensure_internal_network db-umami 10.100.28.0/24`, `docker network connect db-umami postgres` + compose, role/DB `umami` di `init-roles.sh` (+`PG_UMAMI_PASSWORD`), baris pg_hba di tempat + reload, uji silang pg_hba | infra-engineer | GATE 1 | 45 mnt | 0 |
| U2 | Traefik: `analytics-edge` 10.100.17.0/24 `--internal` di `bootstrap.sh`, `network connect` live + compose (Recreate tertunda = drift diketahui) | infra-engineer | GATE 1 | 30 mnt | 0 |
| U3 | Stack `analytics/umami/` (compose, `bootstrap.sh`, `.env.example`, `.gitignore`), Trivy image, `up -d`, verifikasi migrasi/heartbeat/ro rootfs/tanpa egress | infra-engineer | U1, U2 | 1–1,5 j | — |
| U4 | Router `platform/analytics.yml` hanya entrypoint **admin** dulu + HUP; login via tunnel, ganti password, 2FA, buat website `bimacreative.tech` (+ `bct-staging` bila GATE Q7 ya), catat Website ID | infra-engineer + Lead (secret ke owner) | U3 | 30 mnt | 0 |
| U5 | DNS pre-check (`lib/traefik-route.sh dns_precheck`) → tambah router publik collect+script, HUP, sertifikat `le-http` | infra-engineer | U0, U4 | 30 mnt | 0 |
| U6 | Template: `docker-compose.umami.yml`, flag + validasi di `provision-web-client.sh`, `docs/03-operations/web-clients.md`, runbook onboarding (paralel) | infra-engineer | GATE 1 | 1 j | 0 |
| U7 | `bct-website`: env runtime `UMAMI_SCRIPT_URL`/`UMAMI_WEBSITE_ID` (Zod, berpasangan), render skrip ber-nonce di layout, CSP dari env runtime (ganti `NEXT_PUBLIC_UMAMI_SRC`), unit test CSP + guard `check-csp.mjs`, rilis v0.2.0 → GHCR (paralel) | Next.js developer (repo bct-website) | GATE 1 | 2–3 j | 0 |
| U8 | QA staging: re-provision `bct` staging dengan flag → event muncul; uji AppSec/CORS/ratelimit/IP spoof/404 admin publik (§8) | QA & Security | U5, U6, U7 | 1,5 j | staging ±detik (recreate) |
| U9 | Prod: re-provision `bct` prod (image v0.2.0 + flag) → verifikasi | infra-engineer | U8 lulus + OK owner | 20 mnt | ±5–10 s (recreate web) |
| U10 | Monitor Uptime Kuma `https://analytics.bimacreative.tech/insight.js` (`public: false`), drill restore `restore.sh umami umami_restoretest` → cek jumlah baris → DROP | infra-engineer | U5 | 30 mnt | 0 |
| U11 | Docs: `docs/03-operations/analytics.md` (baru), `postgres.md` (tabel network + limit 196), `traefik.md` (network), `backup.md`, CHANGELOG, ADR 0013 → accepted, ADR 0004 riwayat revisi, usul baris CLAUDE.md §3 (butuh persetujuan user) | Docs & Versioning | U9 | 1 j | — |

Paralel: {U1, U2, U6, U7} setelah GATE 1; U0 kapan saja (owner). Serial: U3 → U4 → U5 → U8 → U9.
Total kerja ≈ 8–10 jam agen; kalender 1–2 hari (tergantung DNS + review PR bct-website).

## 8. Acceptance criteria (QA)
- [ ] AC-01 `docker inspect umami`: image digest sesuai §2.2, uid 1001, `ReadonlyRootfs=true`, `CapDrop=[ALL]`,
      no-new-privileges, Memory 256m, NanoCpus 0.5, PidsLimit 128, tanpa port host, network hanya `analytics-edge` + `db-umami`.
- [ ] AC-02 healthcheck `healthy`; `docker logs umami` tanpa `EROFS`/error migrasi; `_prisma_migrations` semua `finished_at` terisi.
- [ ] AC-03 Tanpa egress: `docker exec umami wget -qO- -T 5 https://example.com` (atau `curl`) gagal.
- [ ] AC-04 pg_hba: role `umami` dari `db-umami` → DB `umami` OK; dari `db-cp` → reject; role `umami` → DB `control_plane` → reject.
      `sum(rolconnlimit)` = 196 ≤ 197. `scripts/net-matrix.sh` tanpa selisih baru.
- [ ] AC-05 `curl -sI https://analytics.bimacreative.tech/insight.js` → 200 `application/javascript`, sertifikat LE `CN=analytics.bimacreative.tech` verify 0; HTTP → 301.
- [ ] AC-06 Publik :443 → **404**: `/`, `/login`, `/api/auth/login` (POST), `/api/websites`, `/api/heartbeat`, `/share/x`, `/script.js`.
- [ ] AC-07 :8443 via tunnel → UI login; dari container lain ke `traefik:8443` → 403 (ipallowlist). Login `admin/umami` → gagal (password sudah diganti); 2FA aktif.
- [ ] AC-08 Preflight `OPTIONS /api/send` dengan `Origin: https://bimacreative.tech` + `Access-Control-Request-Headers: content-type,x-umami-cache` → 2xx + `Access-Control-Allow-Origin`; POST beacon valid → 200, event tampil di UI.
- [ ] AC-09 Rate limit: 200 POST cepat dari 1 IP → 429 setelah burst; tidak ada decision CrowdSec untuk IP VPS.
- [ ] AC-10 IP spoof: POST dengan `CF-Connecting-IP`/`True-Client-IP`/`X-Forwarded-For` palsu → negara/kota sesuai IP koneksi, bukan header (bandingkan dua request dari IP sama).
- [ ] AC-11 AppSec FP (staging dulu, IP uji privat/hairpin agar ban tidak mengenai owner — dan `cscli decisions list` dicek setelahnya):
      beacon dengan judul halaman berbahasa Indonesia + tanda baca (`'`, `&`, `–`, `"`), URL path panjang, referrer Google/`?utm_*` → **bukan 403**;
      payload `url":"/<script>alert(1)</script>` → **403** (WAF tetap aktif). Tidak ada 403 di access log `analytics-*` selama 24 jam trafik nyata staging+prod.
- [ ] AC-12 bct staging & prod: HTML memuat `<script … src="https://analytics.bimacreative.tech/insight.js" data-website-id=… nonce=…>`;
      header CSP memuat origin analytics di `script-src` & `connect-src`; **0 pelanggaran CSP** di console (Chrome) desktop & mobile; tanpa env → HTML & CSP identik dengan v0.1.0 (uji `check-csp.mjs`).
- [ ] AC-13 Tidak ada cookie baru di domain client (DevTools Application → Cookies) dan tidak ada `Set-Cookie` dari `analytics.*` untuk pengunjung.
- [ ] AC-14 `provision-web-client.sh` dengan hanya satu flag umami → gagal jelas; tanpa flag → `.env`/`COMPOSE_FILE` identik sebelumnya (site lain tidak di-recreate: `docker compose --dry-run` = Running).
- [ ] AC-15 Backup: run `restic-backup.service` → snapshot `db:umami` ada; restore ke `umami_restoretest` → jumlah baris `website_event` sama; DB uji di-DROP.
- [ ] AC-16 Uptime Kuma monitor UP; `docker stats umami` idle < 200 MiB setelah 24 jam; Trivy image tanpa CRITICAL.

## 9. Rollback
- **Website:** re-provision tanpa flag umami (override tidak dimuat → env hilang, CSP kembali seperti v0.1.0) atau image v0.1.0. ±5–10 s.
- **Router:** hapus `traefik/dynamic/platform/analytics.yml` + `docker exec traefik kill -HUP 1` (H7) → host 404; sertifikat dibiarkan kedaluwarsa.
- **Stack:** `docker compose down` (tanpa `-v`; tidak ada volume — data di Postgres).
- **Data:** `DROP DATABASE umami; DROP ROLE umami;` = **destruktif, konfirmasi eksplisit user** (setelah `pg_dump` terakhir disimpan).
- **Network:** hapus baris pg_hba (tulis di tempat + reload) → `docker network disconnect` + `docker network rm db-umami analytics-edge` → hapus dari compose/bootstrap. 0 downtime (attach/detach live).
- **Upgrade Umami gagal:** migrasi maju otomatis → rollback image **tidak cukup**; restore `pg_dump` pra-upgrade ke DB baru, alihkan `DATABASE_URL`, image lama. Maka runbook upgrade = `backup.sh`/`pg_dump` → pull → up → `ANALYZE`.
- DNS record A boleh dibiarkan (host tanpa router = 404) atau dihapus owner.

## 10. Risiko
| # | Risiko | Dampak | Mitigasi |
|---|---|---|---|
| R1 | Anggaran RAM perencanaan sudah minus (§6) | menambah limit melanggar aturan ADR 0004 | GATE Q1 (R3); pemakaian nyata ±100–150 MiB |
| R2 | FP AppSec pada beacon → ban 4 jam pengunjung di **semua** host HTTP (bouncer Traefik) | pengunjung tidak bisa membuka website client | AC-11, `data-exclude-search`, pengecualian sempit bila perlu (butuh persetujuan) |
| R3 | `read_only` tidak jalan out-of-the-box | penundaan U3 | tmpfs tambahan dari log; tidak menurunkan hardening diam-diam |
| R4 | `max_connections` tersisa 1 slot di atas total limit role (196/197) | onboarding DB berikut (datamart sudah dihitung; client baru) butuh naikkan `max_connections` (recreate postgres ±6 s) | limit Umami 10 cukup; catat di ADR 0004; keputusan terpisah |
| R5 | Adblocker memblok `analytics.*`/tracker | statistik under-count (±10–40% [ESTIMASI]) | nama skrip custom; alternatif proxy first-party via website (`/_a/*` → Umami) = desain lanjutan (GATE Q3) |
| R6 | Beacon palsu (endpoint publik, website ID terlihat) | data statistik tercemar | rate limit, isbot, CrowdSec; diterima (bawaan semua analytics publik) |
| R7 | Tanpa retensi otomatis → DB tumbuh | disk (kecil) + PDP | GATE Q5 + job retensi |
| R8 | Umami 3.x memakai Next.js/Prisma — CVE pihak ketiga | patch berkala | Trivy saat deploy + Dependabot-style cek rilis bulanan; upgrade minor via runbook |
| R9 | Recreate Traefik/Postgres tertunda (drift network) | `--dry-run` menunjukkan Recreate sampai jendela berikut | dicatat; gabungkan dengan recreate terjadwal lain |
| R10 | `APP_SECRET` hilang/berubah | sesi/token tidak valid (bukan kehilangan event) | di `.env` 600 → backup `files`; tidak dirotasi tanpa alasan |

## 11. Pertanyaan GATE 1 (untuk owner)
1. **Kapasitas (wajib):** jumlah `mem_limit` sudah melebihi aturan ADR 0004 (−376 MiB, −632 dengan Umami, −1 208 dengan DRMS
   prod). Pilih R3: **(a)** turunkan limit yang terbukti longgar (mis. mailserver 1 024 → 640, odoo-pool-a 2 560 → 2 048,
   berdasarkan data ≥ 7 hari), atau **(b)** kebijakan overcommit terkendali (jumlah limit ≤ RAM − cadangan + 1 GiB selama p95
   nyata < 50% RAM)? *Rekomendasi: (b) sekarang + (a) setelah 7 hari data container-metrics.*
2. **Arsitektur:** setuju DB `umami` di Postgres shared (bukan Postgres dedicated) dengan satu role owner `umami`?
3. **URL tracker:** setuju `https://analytics.bimacreative.tech/insight.js` (`TRACKER_SCRIPT_NAME=insight`)? Atau nama lain?
   Terima bahwa sebagian adblocker tetap memblok (proxy first-party = fase berikut)?
4. **Privasi pengunjung:** aktifkan `data-do-not-track` (menghormati DNT) dan `data-exclude-search` (tidak mengirim query
   string)? *Rekomendasi: keduanya ya.*
5. **Retensi data:** berapa lama event mentah disimpan? *Usulan: 25 bulan* (perbandingan tahun-ke-tahun), dihapus job bulanan
   (task lanjutan). Atau tanpa batas untuk sekarang?
6. **Akses dashboard:** hanya admin platform via SSH tunnel (rekomendasi)? Atau client perlu melihat statistik — (a) link
   share publik read-only (membuka `/share/*` + API share ke publik), atau (b) laporan berkala dikirim admin?
7. **Staging:** website staging (`bct` staging) ikut dilacak dengan Website ID terpisah (untuk uji), atau staging tanpa analytics
   setelah QA? *Rekomendasi: website ID terpisah hanya selama QA, lalu dimatikan.*
8. **DNS:** owner menambahkan A `analytics.bimacreative.tech` → `31.97.50.221` (tanpa AAAA) — kapan? (Router publik baru dibuat setelah pre-check lulus.)
9. **Perubahan bct-website:** setuju Next.js developer mengganti `NEXT_PUBLIC_UMAMI_SRC/ID` (build-time) menjadi env runtime
   `UMAMI_SCRIPT_URL`/`UMAMI_WEBSITE_ID` dan merilis v0.2.0 (PR ke repo `bctech-adm/bct-website`)?
10. **CLAUDE.md §3:** setuju menambah baris "Web analytics: Umami 3.x (MIT), self-hosted, DB di Postgres shared" ke tabel
    stack yang sudah diputuskan (ADR 0013)?
11. **Kebijakan privasi:** siapa yang menulis kalimat analytics di halaman privasi `bimacreative.tech` (owner/konten, atau kami usulkan draf)?
