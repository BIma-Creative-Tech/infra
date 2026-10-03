# Operasional — Observability ringan (T14a)

- **Stack:** `/opt/infra/observability/` · project compose `observability`
- **Terkait:** plan 02 T14, ADR 0001 (pin), ADR 0004 (RAM), ADR 0006 (backup), `traefik.md`, `crowdsec.md`, `keycloak.md`, `backup.md`

## Komponen

| Service (container) | Image (tag + digest, 2026-09-23) | User | mem_limit / cpus | Network | Data |
|---|---|---|---|---|---|
| `prometheus` | `prom/prometheus:v3.13.3@sha256:6976aa8a…` | 65534 | 384m / 0.25 | observability, metrics | volume `observability_prometheus_data` (retensi 15d / 3GB) |
| `node-exporter` | `prom/node-exporter:v1.12.1@sha256:1b4e4438…` | 65534 | 32m / 0.1 | observability | — (`/` host ro di `/host`; `/var/lib/node-exporter-textfile` ro di `/textfile`, T19 — §Metrik per container) |
| `loki` | `grafana/loki:3.7.8@sha256:1107dd52…` | 10001 | 384m / 0.25 | observability | volume `observability_loki_data` (retensi **7 hari**) |
| `alloy` | `grafana/alloy:v1.19.2@sha256:b8ec653c…` | 473 (+gid 4 adm, +gid 0 — lihat §Log) | 192m / 0.2 | observability | volume `observability_alloy_data` (positions) |
| `grafana` | `grafana/grafana:13.2.2@sha256:ac461fb3…` | 472 | 256m / 0.25 | observability, proxy | bind `data/grafana` |
| `uptime-kuma` | `louislam/uptime-kuma:2.5.5-slim-rootless@sha256:a292237a…` (QA-T17B-04, 2026-09-25; dulu `2.5.5-rootless@sha256:c4e17ce0…`) | 10101 | 192m / 0.2 | proxy | bind `data/uptime-kuma` (SQLite) |

Semua: `restart: unless-stopped`, `read_only: true` (+tmpfs `/tmp` bila perlu), `cap_drop: [ALL]`, `no-new-privileges`,
log json-file 10m×3, **tanpa port publish**. `GOMEMLIMIT` (soft limit GC Go) di grafana (210MiB) & node-exporter (26MiB)
karena pemakaian awal 79%/74% dari limit. Healthcheck semua kecuali **loki**: image distroless (hanya `/usr/bin/loki`,
tanpa shell/wget, tanpa flag health) → dipantau lewat `up{job="loki"}` dan `GET /ready` (lihat §Perintah).

### Keputusan

- **cAdvisor TIDAK dipasang.** ADR 0004 §5 langkah 1 menjadikannya komponen pertama yang dipangkas; registry/tag image
  masih UNVERIFIED (ADR 0001); butuh mount `/var/lib/docker`, `/sys`, `/dev/disk` dan biasanya `privileged` → bertentangan
  dengan §3.5. Metrik container cukup dari `docker stats` + log di Loki. RAM tidak menjadi alasan (available ±12 GiB).
  **Sejak T19 follow-up (2026-09-25):** riwayat memori/CPU per container dari timer host + textfile node-exporter
  (§Metrik per container) — tetap tanpa cAdvisor dan tanpa docker.sock di container.
- **postgres-exporter TIDAK dipasang** (opsional di brief). Butuh role `pg_monitor` via `postgres/init-roles.sh` —
  ditunda ke keputusan Lead; Postgres dipantau lewat log (Loki) + Uptime Kuma tidak langsung.
- **Log container dari file json-file, TANPA Docker API (H3, 2026-09-23)** — menggantikan `obs-docker-socket-proxy`
  (T14a) yang membuka `GET /containers/{id}/json` → `Config.Env` semua container ke Alloy. Detail di §Log.
- **node-exporter di network bridge, bukan `network_mode: host`** (host network = port 9100 baru di host). Konsekuensi:
  metrik `node_network_*` = netns container, bukan NIC host. CPU/RAM/disk/load = host (`--path.rootfs=/host`).
- **Grafana router aktif** (bukan `.disabled`): record A `grafana.bimacreative.tech` ternyata sudah ada saat T14a
  (pre-check `dig` @apollo/@1.1.1.1/@8.8.8.8 = 31.97.50.221, tanpa AAAA) → staging LE → production. Seluruh host
  di belakang `ipallowlist-admin`.
- **Uptime Kuma uid 10101** (bukan uid 1000 `node` di image): uid 1000 di host = user `admin`.

## Network

| Network | Subnet | Jenis | Anggota |
|---|---|---|---|
| `observability` | 10.100.4.0/24 | `--internal` | prometheus, node-exporter, loki, alloy, grafana |
| `metrics` | 10.100.5.0/24 | `--internal` | prometheus, **traefik**, **crowdsec**, **keycloak** (hanya scrape) |
| ~~`obs-dockerapi`~~ | ~~10.100.6.0/24~~ | — | **dihapus H3** (2026-09-23) bersama `obs-docker-socket-proxy` |
| `proxy` (sudah ada) | 10.100.0.0/24 | bridge | + grafana, uptime-kuma (Traefik → service, egress probe Kuma) |

Dibuat `scripts/bootstrap.sh` (idempoten; subnet & `internal` diverifikasi). Network internal tidak punya gateway →
tidak mengubah gateway traefik/crowdsec/keycloak (diverifikasi `ip route` di crowdsec: default via 10.100.2.1).

**Plan 06 / ADR 0010 (selesai 2026-09-26) — dampak ke observability:**
- `metrics` **tidak berubah** (prometheus, traefik, crowdsec, keycloak). Keycloak kini hanya di `kc-edge` + `db-keycloak` +
  `metrics`; Prometheus tetap scrape `keycloak:9000` lewat `metrics` (QA N7 AC-06-10: `up` = 1 untuk keycloak, traefik,
  crowdsec, alloy, grafana, loki, node, prometheus). Default route Keycloak = 10.100.12.1 (`kc-edge`), bukan network ini.
- Residual yang diterima: anggota `metrics` (prometheus, crowdsec, traefik) masih bisa membuka `keycloak:8080` (R2, plan 06
  §4.1 d/§14); `X-Forwarded-*` dari peer di `metrics` diabaikan Keycloak (`KC_PROXY_TRUSTED_ADDRESSES`, `keycloak.md`).
- `proxy`: Keycloak sudah keluar, sehingga Grafana dan Uptime Kuma **tidak** lagi menjangkau `keycloak:8080/9000`. Grafana,
  Uptime Kuma, control-plane, control-plane-staging masih saling menjangkau `:3000/:3001` lewat `proxy` (R1) — pemisahan
  `proxy` = **plan 10** (usulan follow-up, belum ditulis).
- Uptime Kuma memonitor URL publik → tidak terpengaruh (QA N7 AC-06-11: 8/8 monitor UP, 0 heartbeat DOWN 24 jam).
- `traefik:8082/metrics` = 403 dari network selain `metrics` sejak recreate Traefik plan 06 (`traefik.md` §Recreate Traefik plan 06).

## Target Prometheus (`prometheus/prometheus.yml`, interval 30 s)

| Job | Target | Sumber |
|---|---|---|
| prometheus | `localhost:9090` | — |
| node | `node-exporter:9100` | — |
| traefik | `traefik:8082` | entrypoint `metrics` (traefik.yml, T14a), tidak di-publish; hanya IP `10.100.5.0/24` (router `metrics-prometheus` + `ipallowlist-metrics`, QA-T17B-03 — `traefik.md`) |
| crowdsec | `crowdsec:6060` | `config.yaml` bawaan image: `prometheus.listen_addr 0.0.0.0`, port 6060, level full |
| keycloak | `keycloak:9000` | management interface (`KC_METRICS_ENABLED=true` saat build), tidak di-route |
| loki / alloy / grafana | `loki:3100`, `alloy:12345`, `grafana:3000` | — |

## Log (Alloy → Loki)

- **Container (json-file, H3)** — `local.file_match` → `discovery.relabel` → `loki.source.file "docker"` → `loki.process "docker"`:
  label `job="docker"`, `container` (= nama container), `compose_project`, `compose_service`, `stream`; label `filename`
  dibuang. Timestamp = field `time` Docker (`stage.docker`). Container baru dibaca dari awal file (`tail_from_end=false`).
  - **Sumber nama:** dockerd menulis `attrs` di setiap baris json-file: `daemon.json` `log-opts`
    `"tag": "{{.Name}}"` + `"labels": "com.docker.compose.project,com.docker.compose.service"` (role Ansible `docker`,
    `roles/docker/defaults/main.yml`). Opsi `tag`/`labels` json-file diverifikasi dari source moby `docker-v29.8.1`
    (`daemon/logger/jsonfilelog/jsonfilelog.go`: `ValidateLogOpt` menerima `tag`, `New()` menulis `attrs.tag`) dan uji
    `docker run --log-opt tag={{.Name}}`. Log-opts daemon di-merge ke container **saat create**
    (`daemon/create.go` → `mergeAndVerifyLogConfig`, juga untuk compose yang menulis `logging.options` sendiri) →
    container lama harus di-**recreate**; tidak perlu mengubah compose stack mana pun. Alternatif per-compose
    `logging.options.tag` ditolak: harus menyentuh semua stack (termasuk `postgres/` milik task lain) dan tidak
    mencakup container di luar `/opt/infra`.
  - **Fallback:** baris tanpa `attrs.tag` (container dibuat sebelum 2026-09-23 13:25 WIB / dengan `--log-opt` sendiri)
    → `container="id-<12 hex>"`. Container `--log-driver none` tidak punya file → Alloy mencatat
    `failed to tail file, stat failed` (level error) setiap sinkronisasi — noise, bukan kegagalan.
  - **Akses tanpa capability & tanpa secret:** `/var/lib/docker/containers` di-mount `:ro`. Dir container `0710
    root:root`, `<id>-json.log` `0640 root:root`, `config.v2.json`/`hostconfig.json` `0600`. Alloy (uid 473) diberi
    **grup tambahan 0** → bisa melintasi dir & membaca file log, **tidak** bisa `ls` dir mana pun dan **tidak** bisa
    membaca `config.v2.json` (diuji: `Permission denied`, `CapEff=0000000000000000`). Karena listing tidak mungkin,
    ID container yang **berjalan** ditemukan dari cgroup: `/sys/fs/cgroup/system.slice` di-mount `:ro` ke
    `/host/cgroup/system.slice`, glob `docker-*.scope/cgroup.type` (cgroup v2, driver systemd — `docker info`), lalu
    relabel ke `/var/lib/docker/containers/<id>/<id>-json.log`. Container berhenti → scope hilang → berhenti di-tail
    (baris terakhir yang belum terbaca dalam < `sync_period` 10 s bisa tidak terkirim).
  - **Trade-off vs alternatif:**
    | Opsi | Akses Alloy | Ditolak karena |
    |---|---|---|
    | socket-proxy `CONTAINERS=1` (T14a) | Docker API read: inspect → `Config.Env` semua container; proxy memegang `docker.sock` (setara root bila proxy tertembus) | risiko env/secret + socket |
    | `cap_add: DAC_READ_SEARCH` / root | bypass semua izin baca di mount → **`config.v2.json` terbaca** (env/secret sama seperti inspect) | tidak menurunkan risiko env |
    | `chmod`/ACL `/var/lib/docker/containers` | perlu drop-in systemd: dockerd `MkdirAllAndChown(0o710)` meng-`chmod` ulang saat start (moby/sys/user v0.4.1 `setPermissions`); dir per container tetap 0710 | kompleks, rapuh |
    | **gid 0 + cgroup discovery (dipilih)** | baca `*-json.log` saja + daftar ID container berjalan + statistik cgroup `system.slice` (read-only) | — |
    Sisa risiko: siapa pun yang menguasai `alloy` bisa membaca **isi log** semua container (inheren untuk log shipper)
    dan statistik cgroup service host. Log yang memuat secret tetap harus dicegah di sisi aplikasi.
- `loki.source.file`: `traefik/logs/access.log` (ro, grup adm), label `job="traefik-access"`, `tail_from_end`.
- Retensi 7 hari (`limits_config.retention_period: 168h`, compactor `retention_enabled`, `delete_request_store: filesystem`).
- Access log berisi IP klien (data pribadi): dibutuhkan untuk keamanan, retensi 7 hari, akses hanya admin.

## Akses publik & admin

| URL | Siapa | Router |
|---|---|---|
| `https://status.bimacreative.tech/` | publik — status page `platform` (host dipetakan ke status page) | `status-public` (prio 50): `/`, `/status*`, `/api/status-page/*`, `/api/entry-page`, `/assets/*`, `/upload/*`, ikon/manifest/serviceWorker/robots |
| `https://status.bimacreative.tech:8443/dashboard` dst. (`/socket.io/`, `/setup`, `/settings`, `/metrics`, `/api/push`, `/api/badge`, …) | **hanya entrypoint `admin`** (127.0.0.1:8443 host, SSH tunnel) + ipallowlist-admin | `status-admin` (entrypoint `admin`, seluruh host) |
| `https://grafana.bimacreative.tech:8443/` | **hanya entrypoint `admin`** + ipallowlist-admin, seluruh host | `grafana` (entrypoint `admin`) |

H5 (keputusan user 2026-09-23): di :443 publik `grafana.*` dan path dashboard Kuma tidak punya router → **404** (dulu
allowlist; hairpin container tiba sebagai 10.100.0.1 dan lolos). Halaman status publik tetap di :443.

Path publik diturunkan dari source image 2.5.5 (`server/server.js`, `server/routers/*.js`, `src/router.js`,
`src/mixins/socket.js` `noSocketIOPages = [/^\/status-page$/, /^\/status/, /^\/$/]`): halaman status tidak membuka
socket.io; seluruh fungsi admin/login lewat socket.io → allowlist.

### Via SSH tunnel (laptop admin; pola sama dengan `keycloak.md` §Akses admin console)
```bash
echo '127.0.0.1 auth.bimacreative.tech grafana.bimacreative.tech status.bimacreative.tech' | sudo tee -a /etc/hosts   # selama sesi saja
ssh -p 2221 -N -L 8443:127.0.0.1:8443 admin@31.97.50.221     # H5: entrypoint Traefik `admin` (bukan lagi :443)
# Grafana:     https://grafana.bimacreative.tech:8443/        user `admin`, password: sudo cat /opt/infra/observability/secrets/grafana-admin-password
# Uptime Kuma: https://status.bimacreative.tech:8443/dashboard user `platform-admin`, password: sudo cat /opt/infra/observability/secrets/uptime-kuma-admin-password
```
Status uji H5 (2026-09-23, dari host `--resolve <host>:8443:127.0.0.1`, access log `entryPointName=admin`, ClientHost
10.100.0.1): Kuma `/dashboard` 200, `/socket.io/?EIO=4&transport=polling` 200; Grafana `/` → 302 `:8443/login`, `/login` 200.
Lewat :443 publik: Grafana `/`, `/login`, Kuma `/dashboard`, `/socket.io/`, `/metrics` → 404. Tunnel dari laptop **belum** diuji
(tidak ada private key di VPS).
H5b (2026-09-23): `GF_SERVER_ROOT_URL=https://grafana.bimacreative.tech:8443/` (env `GF_<SECTION>_<KEY>` untuk
`[server] root_url`, `conf/defaults.ini` image 13.2.2) → `appUrl` di halaman = `:8443`. Diuji dari host (`--resolve …:8443:127.0.0.1`):
`/` → 302 `/login` (relatif; `curl -L` berakhir di `https://grafana.bimacreative.tech:8443/login` 200), `POST /login` 200
`Logged in`, `/api/user` dengan sesi 200, `/logout` → 302 `/login`. Bila tunnel laptop tetap bermasalah: `sudo ssh … -L
443:127.0.0.1:8443` (port lokal 443) — **catatan:** dengan ROOT_URL ber-port, URL absolut Grafana tetap menyebut `:8443`.
Setelah login pertama: ganti password Grafana di UI, aktifkan 2FA Uptime Kuma (Settings → Security), lalu hapus file
`secrets/*-password` (`shred -u`) bila password sudah disimpan di password manager — **ingat**: Grafana membaca
`GF_SECURITY_ADMIN_PASSWORD__FILE` saat start → setelah file dihapus, hapus juga baris env + mount itu dari compose.

## Uptime Kuma — varian slim-rootless (QA-T17B-04, keputusan user 2026-09-25)

- Image `louislam/uptime-kuma:2.5.5-slim-rootless@sha256:a292237a108fa8843d09bb4066e738f02e913ef893542740f80c26556601ab77`
  (index multi-arch; amd64 `sha256:8bdad438…`; `docker buildx imagetools inspect` 2026-09-25).
- Beda dengan `2.5.5-rootless` (dibaca dari `docker/dockerfile` + `docker/debian-base.dockerfile` tag `2.5.5`, dan
  `docker image inspect`): base `base2-slim` **tanpa** `chromium`, `fonts-indic/noto/noto-cjk`, `mariadb-server`, dan tanpa env
  `UPTIME_KUMA_ENABLE_EMBEDDED_MARIADB=1`. User (`node`), entrypoint, cmd, workdir, HEALTHCHECK (`extra/healthcheck`), Node 22.22.3
  sama. Release notes 2.5.5 tidak menyebut perubahan varian.
- Dampak fungsi: monitor tipe **Real Browser** (Chromium lokal, `playwright-core`) dan tombol uji Chrome di Settings tidak
  bekerja (auto-install `apt install chromium` Kuma gagal di rootless/read_only). Per 2026-09-25 (salinan `kuma.db`, read-only):
  8 monitor = 6 `http` + 2 `port`, tabel `remote_browser` 0 baris → **tidak ada yang terdampak**. MariaDB embedded tidak dipakai
  (`UPTIME_KUMA_DB_TYPE=sqlite`). Bila kelak butuh Real Browser: pakai *Remote Browser* (container terpisah, ADR baru), bukan
  kembali ke image penuh.
- Trivy (`aquasec/trivy:0.74.0`, sock ro, `--severity CRITICAL,HIGH`, 2026-09-25): rootless **164 CRITICAL (145 fixable) /
  1 688 HIGH (1 513)** → slim-rootless **14 CRITICAL (8 fixable) / 213 HIGH (110)**. CRITICAL sisa: gnutls (2, fix
  `deb12u7`), Go stdlib di `extra/healthcheck` (2) + grpc di `cloudflared` (1), npm `protobufjs` (1) + `tar` (2) — fixable, menunggu
  rilis Kuma; perl-base (3), sqlite (2), zlib (1) unfixed Debian 12.
- Uji 2026-09-25: container sekali-pakai slim-rootless dengan **salinan** `data/uptime-kuma`, `user 10101`, `read_only`, tmpfs,
  `cap_drop ALL`, network internal → `healthy`, 8 monitor dimuat (probe gagal karena tanpa egress — diharapkan), 149 MiB.

### Terapkan (Lead)
```bash
cd /opt/infra/observability && docker compose config --quiet
docker compose pull uptime-kuma                  # image sudah ada lokal (dipull 2026-09-25) → no-op
docker compose up -d uptime-kuma                 # recreate; status.bimacreative.tech 502/404 ±30–60 s (start_period 180 s)
docker compose ps uptime-kuma                    # (healthy) — bisa sampai ±3 menit
docker inspect uptime-kuma --format '{{.Config.Image}}'
docker logs --since 5m uptime-kuma 2>&1 | grep -iE "error|listening" | head
curl -s -o /dev/null -w '%{http_code}\n' --resolve status.bimacreative.tech:443:127.0.0.1 https://status.bimacreative.tech/api/entry-page   # 200
```
Dampak: status page publik & probe Kuma berhenti selama recreate (±1–3 menit, ESTIMASI); tidak ada data yang dimigrasi (versi
aplikasi sama 2.5.5). Rollback: kembalikan baris `image:` ke `louislam/uptime-kuma:2.5.5-rootless@sha256:c4e17ce033deb811aff8a61a5f8f736f35b1bd937458ddeec46c59ca190f0e03`
(image lama masih ada lokal) → `docker compose up -d uptime-kuma`.

## Uptime Kuma — provisioning (idempoten)

`scripts/uptime-kuma-provision.sh` (root) → container sementara dari image yang sama, network `proxy`, langsung ke
`http://uptime-kuma:3001` via socket.io (API yang dipakai UI; tidak ada REST API tulis di 2.5.5). Membuat/menjaga:
admin `platform-admin` (password acak 40 char, `secrets/uptime-kuma-admin-password` 600 root, dikirim via stdin),
monitor HTTP (interval 60 s, retry 2, notifikasi kedaluwarsa sertifikat ON):

| Monitor | URL |
|---|---|
| Control plane (cp) | `https://cp.bimacreative.tech/` (307 → /login 200) |
| Keycloak OIDC discovery (platform) | `https://auth.bimacreative.tech/realms/platform/.well-known/openid-configuration` |
| Odoo demo (prod pool) | `https://demo.erp.bimacreative.tech/web/health` |
| Odoo demo (staging pool) | `https://demo.staging.bimacreative.tech/web/health` |
| Mail SMTP (25) — T11 | TCP `mail.bimacreative.tech:25` (tipe `port`) |
| Mail IMAPS (993) — T11 | TCP+TLS `mail.bimacreative.tech:993` (tipe `port`, `smtpSecurity: secure`, cek sertifikat) |
| ProyekKas DRMS staging (drms-kas.staging) | `https://drms-kas.staging.bimacreative.tech/api/v1/health` (GET; HEAD → 404) — **`public: false`**: tidak ditampilkan di status page publik (nama client), hanya dashboard admin |
| Umami analytics tracker (analytics) — plan 11 | `https://analytics.bimacreative.tech/insight.js` — **`public: false`**. **BELUM diterapkan** (2026-09-27): password admin Kuma dipegang owner → jalankan `uptime-kuma-provision.sh` dengan password sementara (komentar skrip) atau tambah manual di dashboard (HTTP, interval 60 s, retry 2, notifikasi sertifikat ON) |

`/web/health` Odoo 19: `auth='none', save_session=False` (tidak membuat file sesi tiap probe). Status page `platform`
(grup "Layanan", 4 monitor) dengan domain `status.bimacreative.tech`. Probe keluar lewat IP publik → tiba di Traefik
sebagai 10.100.0.1 (hairpin) — kena `ratelimit-default` host yang sama (1 req/menit/monitor, jauh di bawah limit).
**Notifikasi (email/Telegram) belum dikonfigurasi** — butuh kanal dari user (mail T11 / bot Telegram).

## Backup

`data/grafana`, `data/uptime-kuma`, `secrets/` berada di `/opt/infra` → ikut snapshot `files` restic harian (ADR 0006
"Uptime Kuma data, Grafana data") tanpa perubahan skrip (diverifikasi `restic backup --dry-run`). TSDB Prometheus/Loki
= named volume → **tidak** di-backup (ADR 0006 #5). SQLite dibaca tanpa quiesce → risiko snapshot tidak konsisten,
diterima (Kuma dapat di-provision ulang; datasource Grafana dari git).

## Perintah

```bash
cd /opt/infra/observability
./scripts/bootstrap.sh                  # sekali / idempoten
docker compose up -d && docker compose ps
./scripts/uptime-kuma-provision.sh      # setelah start pertama (idempoten)

# target Prometheus
docker run --rm --network observability curlimages/curl:8.22.0 -s http://prometheus:9090/api/v1/targets \
  | python3 -c 'import json,sys; [print(t["labels"]["job"], t["health"], t["lastError"]) for t in json.load(sys.stdin)["data"]["activeTargets"]]'
# Loki
docker run --rm --network observability curlimages/curl:8.22.0 -s http://loki:3100/ready
docker run --rm --network observability curlimages/curl:8.22.0 -sG http://loki:3100/loki/api/v1/query_range \
  --data-urlencode 'query={container="traefik"}' --data-urlencode limit=5
```
Validasi config sebelum restart: `promtool check config` (entrypoint `promtool` image prometheus), `loki -verify-config`,
`alloy fmt`. Perubahan `prometheus.yml`/`config.yaml`/`config.alloy` → `docker compose restart <svc>`.
Cek label container di Loki: `…/loki/api/v1/series --data-urlencode 'match[]={job="docker"}'` (lihat laporan H3).

## Metrik per container (T19 follow-up, 2026-09-25)

Prasyarat keputusan ADR 0004 § "Pengukuran ulang T19" R3 (limit per container berdasar data ≥ 7 hari). **Tanpa
docker.sock di container mana pun, tanpa cAdvisor.**

| Bagian | Isi |
|---|---|
| `scripts/container-metrics.sh` | dijalankan **root di host**: `docker ps --no-trunc` (id, nama, label `com.docker.compose.project`) → baca cgroup v2 `/sys/fs/cgroup/system.slice/docker-<id>.scope/` → tulis atomik (tmp `.containers.prom.XXXXXX` di dir yang sama + `mv -f`) `/var/lib/node-exporter-textfile/containers.prom` (0644, dir root 0755). Docker API gagal → file lama dibiarkan, exit 1 |
| role Ansible `container_metrics` | dir textfile + `container-metrics.service` (oneshot, `ProtectSystem=strict`, `ReadWritePaths=` dir textfile, `CapabilityBoundingSet=` kosong, `RestrictAddressFamilies=AF_UNIX`, `MemoryMax=64M`) + `container-metrics.timer` (`OnBootSec=1min`, `OnUnitActiveSec=60s`, `AccuracySec=1s`). Rollback: `container_metrics_state: absent` |
| node-exporter | `--collector.textfile.directory=/textfile` (flag diverifikasi `--help` v1.12.1; kolektor textfile aktif default) + bind `/var/lib/node-exporter-textfile:/textfile:ro` |

Label **hanya** `name` (nama container) dan `compose_project` — tanpa image/env/command/label lain (tidak ada secret).

| Metrik | Tipe | Sumber cgroup v2 |
|---|---|---|
| `infra_container_memory_current_bytes` | gauge | `memory.current` (termasuk page cache) |
| `infra_container_memory_max_bytes` | gauge | `memory.max` (= `mem_limit`; `+Inf` bila tanpa limit) |
| `infra_container_memory_swap_current_bytes` | gauge | `memory.swap.current` |
| `infra_container_memory_inactive_file_bytes` | gauge | `memory.stat` `inactive_file` → *working set* = current − inactive_file (= angka `docker stats`) |
| `infra_container_memory_oom_kill_total` | counter | `memory.events` `oom_kill` |
| `infra_container_cpu_usage_seconds_total` | counter | `cpu.stat` `usage_usec` / 1e6 |
| `infra_container_metrics_{containers,missing_cgroup,duration_seconds,last_success_timestamp_seconds}` | gauge | status kolektor |

Counter reset saat container dibuat ulang (label sama → `rate()`/`increase()` menangani reset). Nilai sesaat tiap 60 s,
di-scrape tiap 30 s → resolusi efektif 60 s (lonjakan < 60 s bisa terlewat; `memory.peak` tidak diekspor).

Uji 2026-09-25 (worktree, belum diterapkan): run manual ke dir sementara → 20 container, 0 missing, ±0,45–0,5 s;
working set cocok dengan `docker stats` (postgres 372 592 640 − 95 780 864 B = 264,0 MiB vs `docker stats` 264,5 MiB;
grafana 252,3 MiB = 252,3 MiB); `promtool check metrics` (prom/prometheus:v3.13.3) bersih; shellcheck v0.11.0 bersih;
unit hardening diuji via `systemd-run` properti sama (exit 0); node-exporter v1.12.1 sekali-pakai (`--network none`)
membaca file → `node_textfile_scrape_error 0`; Docker API tak terjangkau → exit 1, file lama utuh.

### Terapkan (Lead)
```bash
cd /opt/infra/ansible && /opt/ansible-venv/bin/ansible-playbook site.yml --tags container_metrics --check --diff
/opt/ansible-venv/bin/ansible-playbook site.yml --tags container_metrics --diff
systemctl list-timers container-metrics.timer; journalctl -u container-metrics.service -n 5 --no-pager
head -3 /var/lib/node-exporter-textfile/containers.prom; stat -c '%U %a %y' /var/lib/node-exporter-textfile/containers.prom
cd /opt/infra/observability && docker compose up -d node-exporter && docker compose ps node-exporter   # recreate ±detik
docker exec node-exporter wget -qO- http://127.0.0.1:9100/metrics | grep -E '^node_textfile_scrape_error|^infra_container_metrics_containers'
```
Dampak: recreate node-exporter → metrik host (`job="node"`) kosong beberapa detik (satu scrape bisa hilang); tidak ada
service lain tersentuh. +±125 seri Prometheus (±20 container × 6 + 4), dapat diabaikan terhadap retensi 3 GB.
Rollback: `git revert` baris flag + mount di compose → `docker compose up -d node-exporter`; role dengan
`-e container_metrics_state=absent --tags container_metrics` (timer/unit + `containers.prom` dihapus).

### Contoh PromQL (tanpa Grafana)
```bash
q() { docker run --rm --network observability curlimages/curl:8.22.0 -sG http://prometheus:9090/api/v1/query \
        --data-urlencode "query=$1" | python3 -c 'import json,sys; [print(r["metric"].get("name",""), r["value"][1]) for r in json.load(sys.stdin)["data"]["result"]]'; }
# puncak memory.current 7 hari per container (termasuk page cache)
q 'max by (name) (max_over_time(infra_container_memory_current_bytes[7d])) / 2^20'
# puncak working set 7 hari (≈ docker stats) — dasar usul penurunan limit (ADR 0004 T19 R3)
q 'max by (name) (max_over_time((infra_container_memory_current_bytes - infra_container_memory_inactive_file_bytes)[7d:1m])) / 2^20'
# p95 working set 7 hari
q 'quantile_over_time(0.95, (infra_container_memory_current_bytes - infra_container_memory_inactive_file_bytes)[7d:1m]) / 2^20'
# puncak 7 hari sebagai % mem_limit
q 'max_over_time(infra_container_memory_current_bytes[7d]) / on (name, compose_project) infra_container_memory_max_bytes * 100'
# swap per container (puncak 7 hari), OOM kill 7 hari
q 'max by (name) (max_over_time(infra_container_memory_swap_current_bytes[7d])) / 2^20'
q 'increase(infra_container_memory_oom_kill_total[7d]) > 0'
# CPU (core) rata-rata 5 menit, dan p95 7 hari
q 'rate(infra_container_cpu_usage_seconds_total[5m])'
q 'quantile_over_time(0.95, rate(infra_container_cpu_usage_seconds_total[5m])[7d:5m])'
# kolektor basi (> 3 menit) atau container tanpa cgroup
q 'time() - infra_container_metrics_last_success_timestamp_seconds > 180'
q 'infra_container_metrics_missing_cgroup > 0'
```

## Belum / berikutnya

- Alert: belum ada aturan alert Prometheus/Grafana (tanpa Alertmanager). Kanal email **sudah ada** (H7, §Healthcheck &
  alert email) dan mencakup unit `restic-*` failed; yang belum: `REMOTE NOT CONFIGURED`, disk `/` > 70%, swap > 1 GiB (sejak 2026-10-03: hanya bila swap-in > `HC_SWAPIN_PPS` 50 page/s sejak run sebelumnya, atau swap > `HC_SWAP_CRIT_MIB` 3 GiB — swap terpakai oleh page dingin bukan masalah; logika di `scripts/infra-healthcheck.sh` §5).
- Grafana login via Keycloak (client OIDC baru) — keputusan Lead berikutnya.
- Dashboard: belum ada yang di-provision (hanya datasource Prometheus & Loki).

## Healthcheck & alert email (H7, keputusan user 2026-09-23)

Pemicu: insiden 2026-09-23 21:03 WIB — setelah reboot CrowdSec tidak start (`HasBeenManuallyStopped=true` akibat reload
`docker kill --signal=HUP`, lihat `traefik.md` §Start/stop/reload) dan tidak ada yang memberi tahu selama ±1 j 51 m.

| Komponen | Isi |
|---|---|
| `scripts/infra-healthcheck.sh` | pemeriksaan + state anti-spam + kirim email (root) |
| `scripts/lib/infra_alert_mail.py` | kirim email: `smtplib` host → `mail.bimacreative.tech:587` STARTTLS (sertifikat diverifikasi) + AUTH `alerts@bimacreative.tech`; password dibaca dari file, tidak di argv/env |
| role Ansible `healthcheck` | `/etc/infra-healthcheck/alert.env` (tanpa secret), `infra-healthcheck.service` + `.timer` (`OnBootSec=3min`, `OnUnitActiveSec=5min`), template `infra-unit-failure@.service` |
| role `backup` | `OnFailure=infra-unit-failure@%n.service` di `restic-{backup,prune,restore-test}.service` |
| mailbox `alerts@bimacreative.tech` | kuota 256M, password `mail/secrets/alerts@bimacreative.tech.password` (600 root) — **dipakai sistem, jangan di-`shred`** (berbeda dari mailbox manusia di `mail.md` §Akun) |
| state | `/var/lib/infra-healthcheck/active/<kunci>` (epoch kirim terakhir + pesan) |

Yang diperiksa tiap run: (1) setiap service `restart` ≠ `"no"` dari compose stack `healthcheck_stacks` (dibaca `docker
compose config`; saat ini 19 container) ada, running, dan `healthy` bila punya healthcheck — `starting` hanya warning;
(2) `crowdsec-firewall-bouncer` active; (3) tidak ada container berjalan dengan `HasBeenManuallyStopped=true`
(`config.v2.json`); (4) unit `healthcheck_units` (restic-*) tidak `failed`. Hasil: `journalctl -t infra-healthcheck`
(`err` per masalah, `info` bila OK). Exit 1 bila ada masalah → `infra-healthcheck.service` tampil failed sampai run OK.

Email: satu email `[ALERT]` berisi semua masalah baru; masalah yang sama dikirim ulang paling cepat tiap
`infra_alert_repeat_minutes` (60); `[RESOLVED]` saat masalah hilang. Email gagal → state tidak berubah → dicoba lagi 5 menit
kemudian. **Keterbatasan:** bila `mailserver` sendiri mati / mail keluar ditahan, alert hanya di journal (masalah
`container-mailserver` tetap tercatat `err`).

### Mengganti penerima alert
1. Edit **satu** variabel `infra_alert_to` di `ansible/group_vars/all.yml` (beberapa alamat: pisahkan koma, mis.
   `postmaster@bimacreative.tech,nama@gmail.com`) → commit.
2. `cd /opt/infra/ansible && /opt/ansible-venv/bin/ansible-playbook site.yml --tags healthcheck` (menulis ulang
   `/etc/infra-healthcheck/alert.env`; tidak perlu restart apa pun — dibaca tiap run).
3. Uji: `sudo /opt/infra/scripts/infra-healthcheck.sh --selftest` (email `[ALERT]` masalah palsu) lalu
   `sudo /opt/infra/scripts/infra-healthcheck.sh` (email `[RESOLVED]`).
- Sementara/sekali jalan: `sudo ALERT_TO=nama@contoh.id /opt/infra/scripts/infra-healthcheck.sh --selftest` (env proses menang
  atas file).
- **Alamat di luar domain lokal** (mis. Gmail) tertahan di antrean Postfix selama guard `defer_transports = smtp` aktif
  (sampai PTR diset — `mail.md` §PTR). Sampai itu gunakan mailbox lokal (`postmaster@`, baca via IMAPS 993).

### Perintah
```bash
systemctl list-timers infra-healthcheck.timer
sudo /opt/infra/scripts/infra-healthcheck.sh --no-mail      # cek saja, tanpa email & tanpa ubah state
journalctl -t infra-healthcheck --since -1h                  # hasil; -p err untuk masalah saja
ls /var/lib/infra-healthcheck/active/                        # masalah yang sudah di-alert & belum pulih
sudo HC_EXTRA_CONTAINERS=nama-fiktif /opt/infra/scripts/infra-healthcheck.sh --no-mail   # uji negatif tanpa email
```
Flag manual-stop terdeteksi → `docker restart <c>` di jendela pemeliharaan (Traefik ±5 s; CrowdSec ±40 s 403). Untuk
`traefik`/`crowdsec` (`restart: always`) flag tidak menghalangi start saat reboot, tetapi crash tetap tidak di-restart
sampai container di-start ulang.

Uji 2026-09-23: run manual → `OK: 19 container …`; `HC_EXTRA_CONTAINERS=h7-fiktif-tidak-ada` + container uji yang
di-`docker kill --signal=HUP` → dua `MASALAH` (exit 1, `--no-mail`); `--selftest` → email `[ALERT]` di maildir postmaster
(23:32:56, submission `sasl_username=alerts@`, LMTP `Saved`); `--selftest` kedua → tanpa email (anti-spam); run normal →
`[RESOLVED]` (23:33:16); unit dummy `h7-dummy-fail.service` (`OnFailure=infra-unit-failure@%n.service`, `exit 3`) → email
`[ALERT] unit h7-dummy-fail.service gagal` (23:33:29) → setelah `reset-failed` + hapus unit, run normal → `[RESOLVED]`.

Rollback: `systemctl disable --now infra-healthcheck.timer`; hapus role dari `site.yml` + unit di `/etc/systemd/system/`
(`infra-healthcheck.*`, `infra-unit-failure@.service`) + baris `OnFailure=` di template role `backup` → `ansible-playbook
site.yml --tags backup` → `systemctl daemon-reload`.

## Rollback

`docker compose down` di `observability/` (volume & `data/` tetap). Lepas integrasi: hapus
`traefik/dynamic/platform/{status,grafana}.yml` + `docker exec traefik kill -HUP 1`; kembalikan `traefik/traefik.yml` & compose
traefik/crowdsec/keycloak dari git (`git checkout <rev> -- …`) lalu `docker compose up -d` per stack (recreate:
crowdsec ±40 s fail-closed 403, keycloak ±25–60 s, traefik ±7 s). Network: `docker network rm metrics observability`
setelah tidak ada anggota. Hapus volume/data = destruktif → konfirmasi.

Rollback H3 (kembali ke socket-proxy — **tidak disarankan**, lihat §Log): `git revert <commit H3>` untuk
`observability/` → `./scripts/bootstrap.sh` (membuat ulang `obs-dockerapi`) → `docker compose up -d`. `log-opts`
`tag`/`labels` di `daemon.json` boleh tetap (hanya menambah field `attrs`, ±100 byte/baris); bila dicabut: ubah
`roles/docker/defaults/main.yml` → `ansible-playbook site.yml --tags docker` (restart dockerd, live-restore; gangguan
±2 s — DNS embedded Docker & bouncer CrowdSec sempat gagal → 403/timeout, diukur 2026-09-23) lalu recreate container.


## Kredensial awal dihapus (2026-09-24)
- Password admin Grafana & Uptime Kuma diganti user dan disimpan di password manager user; file `secrets/grafana-admin-password` dan `secrets/uptime-kuma-admin-password` di-`shred`.
- Grafana tidak lagi memakai `GF_SECURITY_ADMIN_PASSWORD__FILE` (password di DB Grafana).
- Provisioning Kuma butuh password sementara di `secrets/uptime-kuma-admin-password` (lihat komentar `scripts/uptime-kuma-provision.sh`), lalu `shred -u`.
