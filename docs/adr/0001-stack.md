# ADR 0001 — Stack & pin versi

- **Status:** accepted (2026-09-23, GATE 1)
- **Tanggal:** 2026-09-23
- **Penulis:** Analyst (FASE 1)
- **Terkait:** CLAUDE.md §0.2, §0.10, §0.12, §3; `docs/discovery/2026-09-23.md`; ADR 0002–0006

## Context

CLAUDE.md §3 menetapkan stack (Traefik v3, CrowdSec, Postgres 16, Keycloak, Odoo CE 19.0,
Next.js 15 + Node 22, docker-mailserver, restic, Grafana/Loki/Promtail/Prometheus, Uptime Kuma,
docker-socket-proxy). §0.12 melarang `latest`; §0.2 mewajibkan verifikasi tag yang benar-benar ada.
Keputusan user FASE 1: OCA tidak dipakai (ADR 0003), DNS manual tanpa API (ADR 0002), spek tetap
4 vCPU / 15,6 GiB (ADR 0004).

Metode verifikasi (dijalankan 2026-09-23, ±01:30–02:30 UTC, dari VPS `srv2001692`):
- Docker Hub: `https://hub.docker.com/v2/repositories/<ns>/<repo>/tags?name=<prefix>&ordering=last_updated`
- Quay: `https://quay.io/api/v1/repository/keycloak/keycloak/tag/?filter_tag_name=like:26.7`
- GitHub releases: `https://api.github.com/repos/<owner>/<repo>/releases`
- APT Docker: `https://download.docker.com/linux/ubuntu/dists/noble/stable/binary-amd64/Packages.gz`
- PyPI: `https://pypi.org/pypi/<pkg>/json`; npm: `https://registry.npmjs.org/<pkg>`
- Galaxy: `https://galaxy.ansible.com/api/v3/plugin/ansible/content/published/collections/index/<ns>/<name>/`

## Decision — tabel pin

Semua tanggal cek = **2026-09-23**. "Rilis" = tanggal publish tag/rilis dari sumber.

| Komponen | Pin yang diusulkan | Rilis | Sumber (di-fetch) | Lisensi (sumber) | Catatan |
|---|---|---|---|---|---|
| Docker Engine | `docker-ce=5:29.8.1-1~ubuntu.24.04~noble` | — | download.docker.com …/noble/stable/binary-amd64/Packages.gz | Apache-2.0 (UNVERIFIED — tidak di-fetch sesi ini) | Repo resmi Docker, bukan `docker.io` Ubuntu (29.1.3) |
| Docker Compose plugin | `docker-compose-plugin=5.5.1-1~ubuntu.24.04~noble` | — | idem | Apache-2.0 (UNVERIFIED) | Compose v5 |
| Traefik | `traefik:v3.7.13` | 2026-09-04 | hub.docker.com library/traefik; api.github.com/repos/traefik/traefik/releases | MIT (GitHub API) | Opsi config diverifikasi dari `raw.githubusercontent.com/traefik/traefik/v3.7/docs/content/...` (lihat ADR 0002) |
| CrowdSec (agent+LAPI+AppSec) | `crowdsecurity/crowdsec:v1.8.1` | 2026-09-03 | hub.docker.com crowdsecurity/crowdsec; GitHub releases | MIT (GitHub API) | v1.8.0 baru 2026-08-31 → uji di staging dulu; fallback `v1.7.8` (2026-05-11) |
| CrowdSec bouncer Traefik (plugin) | `github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin` `v1.7.1` | 2026-07-31 | api.github.com/repos/maxlerebourg/crowdsec-bouncer-traefik-plugin/releases; README v1.7.1 | Apache-2.0 | `v1.8.0-alpha` = prerelease, jangan dipakai. Plugin Traefik masih **experimental** (docs plugins.md) |
| CrowdSec firewall bouncer (host) | paket `crowdsec-firewall-bouncer-iptables` atau `-nftables` | versi UNVERIFIED | raw.githubusercontent.com/crowdsecurity/crowdsec-docs/main/crowdsec-docs/unversioned/bouncers/firewall.mdx | MIT (repo cs-firewall-bouncer) | Pin versi paket saat implementasi (`apt-cache policy`) |
| WAF | CrowdSec AppSec (collections `crowdsecurity/appsec-virtual-patching`, `crowdsecurity/appsec-generic-rules`, **`crowdsecurity/appsec-crs-inband`** — OWASP CRS blocking, diratifikasi user 2026-09-23) menggantikan Coraza plugin | — | crowdsec-docs …/docs/appsec/quickstart/traefik.mdx | MIT | Tanpa CRS, XSS/SQLi generik lolos (uji T05). Tuning false positive Odoo di staging; rollback di `docs/03-operations/crowdsec.md` |
| (ditolak) Coraza plugin Traefik | `jcchavezs/coraza-http-wasm-traefik` v0.3.0 | 2024-10-29 | api.github.com/repos/jcchavezs/coraza-http-wasm-traefik | Apache-2.0 | commit terakhir 2026-01-13 (> 6 bulan) → **gagal kriteria §0.10** |
| PostgreSQL | `postgres:16.15-bookworm` | 2026-09-19 | hub.docker.com library/postgres | PostgreSQL License (COPYRIGHT di repo) | EOL PG16 = 2028-11-09 (postgresql.org/support/versioning). PG18 tersedia, tetap 16 sesuai §3 |
| Keycloak | `quay.io/keycloak/keycloak:26.7.4` | 2026-09-16 | quay.io API; GitHub releases keycloak/keycloak | Apache-2.0 | Sizing resmi: request 1250 MB / limit 1360 MB per pod (keycloak.org/high-availability/multi-cluster/concepts-memory-and-cpu-sizing) |
| Odoo CE | `odoo:19.0-20260908` | 2026-09-16 (last_updated) | hub.docker.com library/odoo; Dockerfile `github.com/odoo/docker/master/19.0/Dockerfile` (`ODOO_RELEASE=20260908`) | LGPL-3 (LICENSE repo odoo 19.0) | Pin juga digest saat implementasi (`docker buildx imagetools inspect`) |
| Node.js | **Rekomendasi `node:24.21.0-bookworm-slim`**; alternatif sesuai §3 `node:22.23.2-bookworm-slim` | 2026-09-19 | hub.docker.com library/node; `raw.githubusercontent.com/nodejs/Release/main/schedule.json` | MIT (UNVERIFIED) | Node 22: maintenance sejak 2025-10-21, **EOL 2027-04-30**. Node 24: LTS, maintenance 2026-10-20, EOL 2028-04-30 |
| Next.js | **Rekomendasi `next@16.3.6`**; alternatif `15.5.26` | 2026-09-22 | api.github.com/repos/vercel/next.js/releases; nextjs.org/support-policy | MIT | 15.x = Maintenance LTS, "two years following the initial release" (rilis 2024-10-21 → berakhir ±2026-10-21). 16.x Active LTS. `next@16.3.6` engines `node >=20.9.0` (registry.npmjs.org) |
| Auth.js / next-auth | UNVERIFIED — keputusan diserahkan ke nextjs-developer | — | registry.npmjs.org/next-auth: `latest=4.24.15`, `beta=5.0.0-beta.32` | ISC (UNVERIFIED) | v5 masih beta per dist-tags → perlu ADR tersendiri |
| Drizzle ORM | `0.45.3` (latest) | — | registry.npmjs.org/drizzle-orm | Apache-2.0 (UNVERIFIED) | |
| docker-mailserver | `mailserver/docker-mailserver:16.0.1` | 2026-09-04 | hub.docker.com; GitHub releases | MIT | v16.0.0 major (2026-08-30) — changelog breaking changes **UNVERIFIED**, wajib dibaca mail implementer |
| restic | binary resmi `restic_0.19.1_linux_amd64.bz2` + verifikasi `SHA256SUMS` & `SHA256SUMS.asc` | 2026-07-05 | api.github.com/repos/restic/restic/releases/tags/v0.19.1 | BSD-2-Clause | APT noble hanya 0.16.4 (`apt-cache policy restic`) — terlalu tua |
| Grafana | `grafana/grafana:13.2.2` | 2026-09-15 | hub.docker.com; GitHub releases | AGPL-3.0 | |
| Loki | `grafana/loki:3.7.8` | 2026-09-17 | hub.docker.com; GitHub releases | AGPL-3.0 | |
| Log shipper | **Grafana Alloy `grafana/alloy:v1.19.2`** (ganti Promtail) | 2026-08-26 | hub.docker.com; GitHub releases grafana/alloy | Apache-2.0 | Loki docs v3.7.8 `send-data/promtail/_index.md`: "Promtail is end of life (EOL) as of March 2, 2026" |
| Prometheus | `prom/prometheus:v3.13.3` (LTS) | 2026-09-07 | hub.docker.com; prometheus.io/docs/introduction/release-cycle/ (3.13 LTS, support s.d. 2027-07-31) | Apache-2.0 | 3.14.0 ada, tetapi non-LTS |
| node-exporter | `prom/node-exporter:v1.12.1` | 2026-07-14 | hub.docker.com; GitHub releases | Apache-2.0 | |
| cAdvisor | `v0.60.6` | 2026-09-18 | GitHub releases google/cadvisor | Apache-2.0 (LICENSE file) | **Registry/tag image UNVERIFIED** (gcr.io tags list tidak mengembalikan v0.60.x). Opsional — lihat ADR 0004 |
| Uptime Kuma | `louislam/uptime-kuma:2.5.5-rootless` | 2026-09-16 | hub.docker.com | MIT | varian rootless dipilih (§3.5 non-root) — perilaku rootless UNVERIFIED |
| docker-socket-proxy | `tecnativa/docker-socket-proxy:v0.5.0` | 2026-07-27 | hub.docker.com; GitHub releases | Apache-2.0 | |
| Ansible | `ansible-core==2.21.4` (venv/pipx, butuh Python ≥ 3.12; host 3.12.3) | — | pypi.org/pypi/ansible-core/json | GPL-3.0 | APT noble: ansible-core 2.16.3 (lebih tua). Collections: `community.general 13.4.0`, `ansible.posix 2.2.2`, `community.docker 5.3.0` (Galaxy API) |
| fail2ban | APT noble `1.0.2-3ubuntu0.1` | — | `apt-cache policy fail2ban` | GPL-2.0 (COPYING) | Lihat "Perubahan CLAUDE.md" #4 (lisensi GPL) |
| auditd / chrony | APT `auditd 1:3.1.2-2.1build1.1`, `chrony 4.5-1ubuntu4.2` | — | `apt-cache policy` | GPL (UNVERIFIED) | |
| dbt | `dbt-core==1.12.5`, `dbt-postgres==1.11.0` | — | pypi.org | Apache-2.0 (UNVERIFIED) | kompatibilitas 1.12 ↔ adapter 1.11 **UNVERIFIED** (bukan scope FASE 2 awal) |

Aturan pin: image dipin tag eksplisit **+ digest** saat implementasi; paket APT di-pin versi
di Ansible vars; tidak ada `latest`, `edge`, `master`, `nightly`.

## Alternatives

| Alternatif | Ditolak karena |
|---|---|
| Next.js 15 (sesuai §3) | Maintenance LTS berakhir ±2026-10-21 → proyek baru langsung di versi hampir tanpa patch |
| Node 22 (sesuai §3) | EOL 2027-04-30 (7 bulan lagi) |
| Promtail | EOL 2026-03-02 per docs Loki |
| Coraza plugin Traefik | Maintenance tidak aktif (> 6 bulan), rilis terakhir 2024; plugin WASM menambah RAM/latensi |
| Paket `docker.io` Ubuntu | Versi lebih tua (29.1.3) dan tidak menyertakan compose plugin v5 |
| restic dari APT | 0.16.4, jauh di belakang 0.19.1 |
| Postgres 17/18 | §3 sudah memutuskan 16; 16 didukung s.d. 2028-11 — cukup |

## Consequences

- Setiap kenaikan versi = PR terpisah + staging dulu (§3.7). Dependabot/Renovate memantau tag.
- Next.js 16 / Node 24: nextjs-developer wajib membaca upgrade guide 16 sebelum scaffold (UNVERIFIED breaking changes).
- CrowdSec 1.8.x baru — risiko regresi; fallback 1.7.8 dicatat.
- Plugin Traefik diunduh dari katalog plugin saat start (docs plugins.md: "experimental") →
  start Traefik bergantung jaringan ke katalog. Mitigasi yang harus dievaluasi saat implementasi:
  `experimental.localPlugins` (ada di docs v3.7) dengan source plugin di-vendor + pin commit.

## Security implications

- Pin tag + digest mencegah supply-chain drift; Trivy memindai image sebelum deploy.
- Grafana/Loki AGPL-3: dipakai apa adanya (tidak dimodifikasi/didistribusikan) → tidak ada kewajiban source tambahan dari kita (catatan, bukan nasihat hukum).
- restic diverifikasi via `SHA256SUMS.asc` (kunci GPG restic — fingerprint diverifikasi saat implementasi).

## Rollback

Tiap service: kembalikan tag/digest sebelumnya di compose → `docker compose pull && up -d`.
Paket APT: `apt install <pkg>=<versi-lama>` + `apt-mark hold`. ADR ini sendiri: tidak ada efek
sistem sampai FASE 2.

## Perubahan CLAUDE.md yang diusulkan (butuh persetujuan user; Analyst tidak mengedit)

1. §3 Web: "Next.js 15 … Node 22 LTS" → "Next.js 16 … Node 24 LTS" (alasan di atas).
2. §3 WAF: "Coraza (OWASP CRS) sebagai plugin Traefik" → "CrowdSec AppSec (virtual patching + generic rules) via bouncer Traefik yang sama"; §3.6 Edge "Coraza CRS paranoia level 1" diganti "AppSec collections + tuning false positive di staging".
3. §3 Observability: "Promtail" → "Grafana Alloy".
4. §0.10: tambahkan "GPL-2/GPL-3 diterima untuk tool host yang tidak di-link/didistribusikan (fail2ban, auditd, ansible)" — saat ini daftar lisensi tidak mencantumkan GPL padahal §3 sudah memakai fail2ban (GPL-2) dan Ansible (GPL-3).
5. §3 SSO / §3.1 / §3.2 / §3.5.1: lihat ADR 0002 & 0003.

## Riwayat revisi

- 2026-09-23 (T05, disetujui user): tambah `crowdsecurity/appsec-crs-inband` (OWASP CRS, mode blocking)
  ke AppSec — dua collection awal terbukti tidak memblok XSS/SQLi generik.
- 2026-09-23 (T05, disetujui user): firewall bouncer host menerapkan **semua** decision termasuk
  blocklist komunitas CAPI, **tanpa** whitelist IP admin. Risiko: IP admin ikut terblokir → pemulihan
  via konsol Hostinger (`docs/03-operations/crowdsec.md`, `docs/runbooks/emergency-console-access.md`).
- 2026-09-23 (T12, disetujui user): base image Node untuk control plane → **`node:24-alpine`** (pin tag+digest
  di Dockerfile) menggantikan `node:24.21.0-bookworm-slim`. Alasan: Trivy bookworm-slim 4 CRITICAL + 52 HIGH
  unfixed vs alpine 0 CRITICAL / 4 HIGH; gate CI "gagal jika CRITICAL" (CLAUDE.md §3.6).
- 2026-09-23 (T12): Auth.js v5 (`next-auth@5.0.0-beta.32`) dipakai meski berstatus beta — satu-satunya rilis
  dengan peer `next ^16`. Risiko diterima; pantau rilis stabil.
- 2026-09-23 (H2, remediasi QA T17a): **pin Keycloak & CrowdSec TIDAK berubah** — tidak ada rilis resmi yang
  lebih baru. Keycloak: `26.7.4` = rilis 26.x terbaru (quay.io tag list: `26.7`/`latest` → digest `82a778…` sama;
  GitHub releases terbaru 26.7.4, 2026-09-16). CVE CRITICAL netty `CVE-2026-75595` sudah diperbaiki di `main`/nightly
  (issue keycloak#52549) tetapi backport `release/26.7` masih terbuka (#52763); bouncycastle `CVE-2026-8763` masih
  terbuka (#52971). CrowdSec: `v1.8.1` = rilis terbaru (Docker Hub & GitHub releases; digest `0f2523…` sama). Trivy
  ulang 2026-09-23 (`aquasec/trivy:0.74.0`): Keycloak 3 CRITICAL / 7 HIGH (fixable 3/3), CrowdSec 0 CRITICAL /
  26 HIGH (24 fixable) — sama dengan QA. Opsi lanjutan menunggu keputusan Lead (lihat laporan QA §Status temuan).
- 2026-09-23 (H2): hook pre-commit gitleaks memakai `zricethezav/gitleaks:v8.30.1@sha256:c00b6bd0…abbb7f`
  (Docker Hub, rilis 2026-03-21, MIT — GitHub API) di `.githooks/pre-commit` repo infra, odoo-addons-shared,
  control-plane. Service uji `traefik/whoami:v1.12.0` dihapus (bukan bagian arsitektur).
- 2026-09-23 (H3): **docker-socket-proxy tidak lagi dipakai untuk observability.** Service `obs-docker-socket-proxy`
  & network `obs-dockerapi` (T14a) dihapus; Alloy membaca file json-file `/var/lib/docker/containers/<id>/<id>-json.log`
  langsung (bind ro, grup tambahan 0, tanpa capability, tidak bisa membaca `config.v2.json`) dengan nama container dari
  `attrs.tag` (daemon.json `log-opts.tag={{.Name}}` + `labels=com.docker.compose.project,com.docker.compose.service`,
  role Ansible `docker`). Pin `tecnativa/docker-socket-proxy:v0.5.0` tetap berlaku untuk **control plane** saja
  (CLAUDE.md §3 "Hanya control-plane"). Detail & trade-off: `docs/03-operations/observability.md` §Log.
- 2026-09-23 (H4, disetujui user): **pengecualian CRS sempit untuk Admin REST Keycloak** — hanya rule **911100**
  ("Method is not allowed by policy") dinonaktifkan (`pre_eval` → `RemoveInBandRuleByID(911100)`), hanya bila in-band
  **dan** host `auth.bimacreative.tech` (atau `:8443` tunnel admin) **dan** path diawali `/admin/realms/` **dan** IP klien
  127.0.0.1/10.100.0.1 (= `ipallowlist-admin`). Alasan: Admin REST memakai PUT/DELETE secara sah; tanpa ini ubah/hapus
  user/client lewat edge (termasuk admin console via tunnel) = 403. Semua rule CRS lain, virtual patching & generic rules
  tetap aktif pada path itu; 911100 tetap berlaku di host/path lain (diuji, `docs/03-operations/crowdsec.md` §Pengecualian
  CRS 911100). Rollback: hapus `security/crowdsec/appsec-configs/keycloak-admin-exclusions.yaml` + barisnya di
  `acquis.d/appsec.yaml` + mount di `docker-compose.yml` → `docker compose up -d` (recreate, fail-closed ±40–50 s).
- 2026-09-23 (H5, disetujui user): **panel admin hanya lewat entrypoint Traefik terpisah `admin` (:8443, publish
  `127.0.0.1:8443` host saja)** — Keycloak `/admin*` & `/realms/master/*`, Grafana, dashboard Uptime Kuma. Alasan: hairpin
  dari container mana pun ke IP publik :443 tiba sebagai `10.100.0.1` (gateway `proxy`, `userland-proxy: false`) dan lolos
  `ipallowlist-admin` (bukti: container `drms-kas-edge` → `GET /admin/realms/drms-staging/users` = 401 dari Keycloak). Di :443
  path itu kini 403 (`auth-admin-deny`) / 404. Tunnel admin: `ssh -p 2221 -N -L 8443:127.0.0.1:8443 admin@31.97.50.221`.
  Sekaligus: network `--internal` `drms-kc-admin` (10.100.8.0/24) / `drms-kc-admin-stg` (10.100.9.0/24) — Traefik join dengan
  alias `auth.bimacreative.tech`; app ProyekKas hanya boleh Admin REST realm `drms` / `drms-staging` (router `ClientIP` ×
  `PathPrefix`), dan pengecualian CRS 911100 (H4) diperluas **sempit** ke pasangan subnet × prefix realm yang sama
  (`IpInRange`, CrowdSec v1.8.1). Detail: `docs/03-operations/{traefik,keycloak,crowdsec}.md`.
- 2026-09-23 (H5b, cakupan H5 yang disetujui user): **DB manager Odoo per tenant ikut entrypoint `admin`.**
  `templates/traefik-client.yml`: `/web/database*` di `websecure` → `<r>-dbmanager-deny` (`deny-all` 403, service `deny-sink`,
  prioritas 300); router operator `<r>-dbmanager` hanya di entrypoint `admin` (`ipallowlist-admin` + header `X-Sh-Odoo-Db`
  tenant). Alasan sama dengan H5: hairpin container ke :443 tiba sebagai `10.100.0.1` dan lolos `ipallowlist-admin` (bukti
  sebelum H5b: `GET /web/database/selector` dari host via :443 = 200 dari Odoo). `list_db=False` tetap menolak di Odoo. Tenant
  `demo-demo`/`demo-staging` dirender ulang. Grafana `GF_SERVER_ROOT_URL` kini memuat `:8443`. Setelah H5b tidak ada router
  `websecure` yang bergantung pada `ipallowlist-admin`. Detail: `docs/03-operations/{odoo,traefik,observability}.md`.
- 2026-09-23 (H6, **keputusan user 2026-09-23**, mengubah keputusan T05 "firewall bouncer menerapkan semua decision"):
  **ban dari scenario AppSec tidak lagi diterapkan firewall bouncer host** — hanya di HTTP lewat bouncer Traefik. Pemicu:
  tombol "Masuk" control plane (Server Action Next.js, `text/plain`) kena CRS 920420 → ban `crowdsecurity/appsec-native`
  → IP user terblokir di semua port termasuk SSH 2221; ban kedua 20:55 WIB dari false positive lain (`POST
  /admin/collections/users/create` drms-kas.staging). Implementasi: `scenarios_not_containing: [crowdsecurity/appsec-]`
  (role `crowdsec_bouncer`). Blocklist CAPI, sshd, `http-*`, mail & decision manual **tetap host-wide**; tetap tanpa
  whitelist IP admin. Sekaligus **pengecualian CRS sempit 920420** untuk Server Action cp/cp.staging (POST + `Next-Action`
  hex + `text/plain`) ditambah rule lokal 19100/19101 (body diparse JSON agar XSS/SQLi tetap terdeteksi; body non-JSON 403).
  Rollback: hapus kunci dari template/var → `ansible-playbook site.yml --tags crowdsec_bouncer`; WAF: lihat
  `docs/03-operations/crowdsec.md` §Pengecualian CRS 920420.
- 2026-09-23 (H7, **keputusan user 2026-09-23**, menyimpang dari CLAUDE.md §3.5 "`restart: unless-stopped`"):
  **`traefik` dan `crowdsec` memakai `restart: always`.** Insiden: reboot 21:03 WIB → CrowdSec tidak start → semua router
  ber-`crowdsec` 403 fail-closed ±1 j 51 m. Akar masalah: reload `docker kill --signal=HUP crowdsec` — Docker v29.8.1
  (`daemon/kill.go` `killWithSignal`) untuk sinyal **apa pun** men-set `HasBeenManuallyStopped=true` (disimpan di
  `config.v2.json`) dan membatalkan restart manager walau container tetap berjalan; `unless-stopped` lalu tidak start saat
  daemon start (`daemon/internal/restartmanager` `ShouldRestart`: `IsUnlessStopped() && !hasBeenManuallyStopped`).
  Dibuktikan dengan container uji (HUP & USR1 via `docker kill` → flag `True`; crash sesudahnya tidak di-restart walau
  `always`). Dua lapis perbaikan: (1) semua reload/rotasi memakai `docker exec <c> kill -<SIG> 1` (flag tetap `False`,
  diuji pada Traefik & CrowdSec nyata) — termasuk postrotate logrotate Traefik (USR1) yang sebelumnya akan men-set flag
  setiap malam; (2) `always` untuk dua service edge: docs Docker *Start containers automatically* — "If it's manually
  stopped, it's restarted only when Docker daemon restarts" (juga `ShouldRestart`: `IsAlways()` → restart). Konsekuensi:
  `docker stop traefik|crowdsec` tidak bertahan melewati restart daemon/reboot — untuk mematikan permanen pakai
  `docker compose down`. Service lain tetap `unless-stopped`. Ditambah `scripts/infra-healthcheck.sh` (timer 5 menit, role
  Ansible `healthcheck`): container stack running/healthy, firewall bouncer active, tanpa flag manual-stop, unit restic
  tidak failed → email alert dari `alerts@bimacreative.tech` (anti-spam 60 menit, RESOLVED). Detail:
  `docs/03-operations/{traefik,crowdsec,observability}.md`.
- 2026-09-23 (H7(a), disetujui user): **pengecualian CRS 920420 sempit untuk Server Action admin Payload ProyekKas**
  (host `drms-kas.staging.bimacreative.tech` / `drms-kas.bimacreative.tech`, POST, path `/admin/*`, `Next-Action` hex 40–64,
  `text/plain`) + rule lokal 19102/19103 (body diparse JSON; body non-JSON 403) — pola H6. Rollback: `crowdsec.md`
  §Pengecualian CRS 920420 admin Payload.
