# Operasional — Observability ringan (T14a)

- **Stack:** `/opt/infra/observability/` · project compose `observability`
- **Terkait:** plan 02 T14, ADR 0001 (pin), ADR 0004 (RAM), ADR 0006 (backup), `traefik.md`, `crowdsec.md`, `keycloak.md`, `backup.md`

## Komponen

| Service (container) | Image (tag + digest, 2026-09-23) | User | mem_limit / cpus | Network | Data |
|---|---|---|---|---|---|
| `prometheus` | `prom/prometheus:v3.13.3@sha256:6976aa8a…` | 65534 | 384m / 0.25 | observability, metrics | volume `observability_prometheus_data` (retensi 15d / 3GB) |
| `node-exporter` | `prom/node-exporter:v1.12.1@sha256:1b4e4438…` | 65534 | 32m / 0.1 | observability | — (`/` host ro di `/host`) |
| `loki` | `grafana/loki:3.7.8@sha256:1107dd52…` | 10001 | 384m / 0.25 | observability | volume `observability_loki_data` (retensi **7 hari**) |
| `alloy` | `grafana/alloy:v1.19.2@sha256:b8ec653c…` | 473 (+gid 4 adm) | 192m / 0.2 | observability, obs-dockerapi | volume `observability_alloy_data` (positions) |
| `obs-docker-socket-proxy` | `tecnativa/docker-socket-proxy:v0.5.0@sha256:1f5038b5…` | 65534 (+gid 988 docker) | 64m / 0.1 | obs-dockerapi | — |
| `grafana` | `grafana/grafana:13.2.2@sha256:ac461fb3…` | 472 | 256m / 0.25 | observability, proxy | bind `data/grafana` |
| `uptime-kuma` | `louislam/uptime-kuma:2.5.5-rootless@sha256:c4e17ce0…` | 10101 | 192m / 0.2 | proxy | bind `data/uptime-kuma` (SQLite) |

Semua: `restart: unless-stopped`, `read_only: true` (+tmpfs `/tmp` bila perlu), `cap_drop: [ALL]`, `no-new-privileges`,
log json-file 10m×3, **tanpa port publish**. `GOMEMLIMIT` (soft limit GC Go) di grafana (210MiB) & node-exporter (26MiB)
karena pemakaian awal 79%/74% dari limit. Healthcheck semua kecuali **loki**: image distroless (hanya `/usr/bin/loki`,
tanpa shell/wget, tanpa flag health) → dipantau lewat `up{job="loki"}` dan `GET /ready` (lihat §Perintah).

### Keputusan

- **cAdvisor TIDAK dipasang.** ADR 0004 §5 langkah 1 menjadikannya komponen pertama yang dipangkas; registry/tag image
  masih UNVERIFIED (ADR 0001); butuh mount `/var/lib/docker`, `/sys`, `/dev/disk` dan biasanya `privileged` → bertentangan
  dengan §3.5. Metrik container cukup dari `docker stats` + log di Loki. RAM tidak menjadi alasan (available ±12 GiB).
- **postgres-exporter TIDAK dipasang** (opsional di brief). Butuh role `pg_monitor` via `postgres/init-roles.sh` —
  ditunda ke keputusan Lead; Postgres dipantau lewat log (Loki) + Uptime Kuma tidak langsung.
- **Log container via Docker API, bukan file**: nama container (`{container="traefik"}`) hanya ada di Docker API. Membaca
  `/var/lib/docker/containers/*` butuh root dan juga mengekspos `config.v2.json` (berisi env/secret). Dipilih
  `obs-docker-socket-proxy` read-only: `CONTAINERS=1`, `NETWORKS=1` (wajib — `discovery.docker` selalu memanggil
  NetworkList; tanpa ini 403 "error while computing network labels"), `POST=0`, `EVENTS=0`, `VERSION=0`, `PING=1`.
  Network `obs-dockerapi` (`--internal`) berisi **hanya** alloy + proxy.
  **Risiko tersisa:** `GET /containers/{id}/json` (inspect) mengembalikan `Config.Env` → siapa pun yang menguasai
  container `alloy` dapat membaca env semua container (mis. `POSTGRES_PASSWORD`, secret yang lewat `env_file`).
  Mitigasi: alloy non-root, read-only, tanpa capability, tanpa port publik, network internal. Diuji:
  `GET /containers/json` 200, `GET /images/json` 403, `GET /info` 403, `POST /containers/traefik/restart` 403.
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
| `obs-dockerapi` | 10.100.6.0/24 | `--internal` | alloy, obs-docker-socket-proxy |
| `proxy` (sudah ada) | 10.100.0.0/24 | bridge | + grafana, uptime-kuma (Traefik → service, egress probe Kuma) |

Dibuat `scripts/bootstrap.sh` (idempoten; subnet & `internal` diverifikasi). Network internal tidak punya gateway →
tidak mengubah gateway traefik/crowdsec/keycloak (diverifikasi `ip route` di crowdsec: default via 10.100.2.1).

## Target Prometheus (`prometheus/prometheus.yml`, interval 30 s)

| Job | Target | Sumber |
|---|---|---|
| prometheus | `localhost:9090` | — |
| node | `node-exporter:9100` | — |
| traefik | `traefik:8082` | entrypoint `metrics` (traefik.yml, T14a), tidak di-publish |
| crowdsec | `crowdsec:6060` | `config.yaml` bawaan image: `prometheus.listen_addr 0.0.0.0`, port 6060, level full |
| keycloak | `keycloak:9000` | management interface (`KC_METRICS_ENABLED=true` saat build), tidak di-route |
| loki / alloy / grafana | `loki:3100`, `alloy:12345`, `grafana:3000` | — |

## Log (Alloy → Loki)

- `loki.source.docker` (via proxy): semua container, label `container`, `compose_project`, `compose_service`, `job="docker"`.
- `loki.source.file`: `traefik/logs/access.log` (ro, grup adm), label `job="traefik-access"`, `tail_from_end`.
- Retensi 7 hari (`limits_config.retention_period: 168h`, compactor `retention_enabled`, `delete_request_store: filesystem`).
- Access log berisi IP klien (data pribadi): dibutuhkan untuk keamanan, retensi 7 hari, akses hanya admin.

## Akses publik & admin

| URL | Siapa | Router |
|---|---|---|
| `https://status.bimacreative.tech/` | publik — status page `platform` (host dipetakan ke status page) | `status-public` (prio 50): `/`, `/status*`, `/api/status-page/*`, `/api/entry-page`, `/assets/*`, `/upload/*`, ikon/manifest/serviceWorker/robots |
| `https://status.bimacreative.tech/dashboard` dst. (`/socket.io/`, `/setup`, `/settings`, `/metrics`, `/api/push`, `/api/badge`, …) | **ipallowlist-admin** | `status-admin` (prio 1, catch-all) |
| `https://grafana.bimacreative.tech/` | **ipallowlist-admin** seluruhnya | `grafana` |

Path publik diturunkan dari source image 2.5.5 (`server/server.js`, `server/routers/*.js`, `src/router.js`,
`src/mixins/socket.js` `noSocketIOPages = [/^\/status-page$/, /^\/status/, /^\/$/]`): halaman status tidak membuka
socket.io; seluruh fungsi admin/login lewat socket.io → allowlist.

### Via SSH tunnel (laptop admin; pola sama dengan `keycloak.md` §Akses admin console)
```bash
echo '127.0.0.1 grafana.bimacreative.tech status.bimacreative.tech' | sudo tee -a /etc/hosts   # selama sesi saja
ssh -p 2221 -N -L 8443:127.0.0.1:443 admin@31.97.50.221
# Grafana:     https://grafana.bimacreative.tech:8443/        user `admin`, password: sudo cat /opt/infra/observability/secrets/grafana-admin-password
# Uptime Kuma: https://status.bimacreative.tech:8443/dashboard user `platform-admin`, password: sudo cat /opt/infra/observability/secrets/uptime-kuma-admin-password
```
Status uji: dari host (IP 10.100.0.1 = allowlist) `/dashboard` 200, handshake `/socket.io/?EIO=4&transport=polling` 200,
Grafana `/login` 200. Tunnel dari laptop **belum** diuji (tidak ada private key di VPS); redirect Grafana dengan port :8443
(root_url tanpa port) **UNVERIFIED** — bila bermasalah pakai `sudo ssh … -L 443:127.0.0.1:443` (port lokal 443).
Setelah login pertama: ganti password Grafana di UI, aktifkan 2FA Uptime Kuma (Settings → Security), lalu hapus file
`secrets/*-password` (`shred -u`) bila password sudah disimpan di password manager — **ingat**: Grafana membaca
`GF_SECURITY_ADMIN_PASSWORD__FILE` saat start → setelah file dihapus, hapus juga baris env + mount itu dari compose.

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

## Belum / berikutnya

- Alert: belum ada aturan alert (Prometheus tanpa Alertmanager; Grafana alerting belum dikonfigurasi) — termasuk alert
  yang diminta T13 (`REMOTE NOT CONFIGURED`, unit `restic-*` failed, disk `/` > 70%, swap > 1 GiB). Butuh kanal notifikasi.
- Grafana login via Keycloak (client OIDC baru) — keputusan Lead berikutnya.
- Dashboard: belum ada yang di-provision (hanya datasource Prometheus & Loki).

## Rollback

`docker compose down` di `observability/` (volume & `data/` tetap). Lepas integrasi: hapus
`traefik/dynamic/platform/{status,grafana}.yml` + SIGHUP Traefik; kembalikan `traefik/traefik.yml` & compose
traefik/crowdsec/keycloak dari git (`git checkout <rev> -- …`) lalu `docker compose up -d` per stack (recreate:
crowdsec ±40 s fail-closed 403, keycloak ±25–60 s, traefik ±7 s). Network: `docker network rm metrics observability
obs-dockerapi` setelah tidak ada anggota. Hapus volume/data = destruktif → konfirmasi.
