# Plan 06 — Isolasi network: DB per konsumen, Keycloak `kc-edge`, edge Odoo per env (QA-T17B-01)

- **Status:** proposed (menunggu GATE 1)
- **Tanggal:** 2026-09-25 · **Penulis:** Analyst (FASE 0/1, read-only)
- **ADR:** `docs/adr/0010-network-segmentation.md` (proposed)
- **Asal:** QA-T17B-01 (High), `docs/qa/2026-09-25-t17b-platform-full.md` §Ringkasan #1 + B15. Diverifikasi ulang oleh Lead dari
  `drms-pk-stg` dan oleh Analyst (probe §2.3).
- **Terkait:**
  - CLAUDE.md §3.2, §3.5, §3.6
  - ADR 0003 D1, ADR 0008, ADR 0009
  - `docs/03-operations/{traefik,odoo,keycloak,postgres,control-plane,observability}.md`
  - `docs/runbooks/proyekkas-drms-onboarding.md`
  - QA-T17B-03, dikerjakan di worktree `/opt/infra-wt/fixb` (`fix/infra-t17b-edge`, belum di-commit). Branch itu menyentuh
    `traefik.md`/`keycloak.md`/`auth.yml`, jadi eksekusi plan ini **serial setelah** branch itu di-merge.

## 0. Tujuan

Tidak ada container selain Traefik yang bisa membuka port Odoo (:8069/:8072) atau Keycloak (:8080). Pengecualian satu-satunya:
Prometheus boleh membuka `keycloak:9000`. Setiap role Postgres hanya bisa login dari network konsumennya sendiri. Semua alur
yang sekarang berjalan tetap berjalan: SSO Odoo (termasuk back-channel), login control plane, login dan Admin REST DRMS, SMTP
Keycloak/DRMS, scrape Prometheus, dan backup.

## 1. Scope

**IN**
1. Network baru dan pensiunnya `db` (§3). Bootstrap: `postgres/scripts/bootstrap.sh` (`db-*`) dan `traefik/scripts/bootstrap.sh`
   (`kc-edge`, `odoo-edge-stg`, cadangan `drms-kas-edge-prod`).
2. `postgres/conf/pg_hba.conf` per subnet konsumen.
3. Compose (hanya bagian `networks:`, plus env D-i-D Keycloak bila lolos verifikasi):
   - `postgres/`, `identity/keycloak/`, `odoo/pool-a/`, `staging/odoo/`, `web/control-plane/`, `staging/control-plane/`,
     `staging/drms-proyekkas/`, `traefik/`
4. D-i-D:
   - `sh_dbfilter_header` trusted-proxy (repo `odoo-addons-shared`, odoo-developer)
   - Keycloak `proxy-trusted-addresses` (infra, kondisional)
5. Matriks jangkauan sebelum/sesudah (QA) dan regresi alur.
6. Docs: 6 dokumen ops, runbook ProyekKas (network prod), ADR 0010 → accepted, CHANGELOG, usulan CLAUDE.md §3.5/§3.2.

**OUT** (rekomendasi follow-up §14)
- Memecah `proxy`. Control-plane, control-plane-staging, grafana, dan uptime-kuma tetap saling menjangkau `:3000/:3001`.
- `metrics` → `keycloak:8080`.
- `web-edge` per klien.
- QA-T17B-03 (branch lain).
- Compose DRMS **prod** (belum ada). Plan ini hanya mencadangkan network dan pg_hba-nya.

## 2. Discovery (fakta 2026-09-25, read-only)

### 2.1 Network & anggota (`docker network inspect`)

| Network | Subnet | internal | Anggota |
|---|---|---|---|
| `proxy` | 10.100.0.0/24 (gw .1) | no | traefik, uptime-kuma, grafana, **keycloak**, control-plane, control-plane-staging |
| `db` | 10.100.1.0/24 | yes | postgres, keycloak, odoo-pool-a, odoo-staging, control-plane{,-worker}, control-plane-staging{,-worker}, drms-pk-stg{,-worker} |
| `crowdsec` | 10.100.2.0/24 | no | traefik, crowdsec |
| `odoo-edge` | 10.100.3.0/24 | no | traefik, **odoo-pool-a, odoo-staging** |
| `observability` | 10.100.4.0/24 | yes | prometheus, loki, alloy, node-exporter, grafana |
| `metrics` | 10.100.5.0/24 | yes | prometheus, traefik, crowdsec, keycloak |
| (10.100.6.0/24) | — | — | bekas `obs-dockerapi` (H3). **Jangan dipakai ulang** (bootstrap observability & traefik) |
| `drms-kas-edge` | 10.100.7.0/24 | no | traefik, drms-pk-stg, drms-pk-stg-worker |
| `drms-kc-admin` | 10.100.8.0/24 | yes | traefik (alias `auth.bimacreative.tech`) |
| `drms-kc-admin-stg` | 10.100.9.0/24 | yes | traefik (alias), drms-pk-stg, drms-pk-stg-worker |
| `mail` | 10.100.10.0/24 | no | mailserver |
| `web-edge` | 10.100.11.0/24 | no | traefik, web-starter-staging |
| `bridge` (docker0) | 172.17.0.0/16 | no | — |

`ip route` host: hanya rute di atas, ditambah `31.97.50.0/24` (eth0). Tidak ada tabrakan dengan 10.100.12–39.x.
`/etc/docker/daemon.json`: `icc:false` (hanya berlaku di docker0), `userland-proxy:false`, `live-restore:true`.
Docker 29.8.1, Compose v5.5.1 (punya flag global `--dry-run`).

### 2.2 Siapa butuh apa (sumber: compose, `.env` non-secret, access log Traefik 2026-09-25)

| Konsumen | DB (role → DB) | Butuh HTTP ke | Jalur ke Keycloak yang **sebenarnya** dipakai (access log) | Egress |
|---|---|---|---|---|
| keycloak | keycloak → keycloak | — | — | SMTP `mail.bimacreative.tech:587` (hairpin), realm platform/platform-staging/drms/drms-staging (`realm_smtp_config`) |
| odoo-pool-a | odoo_pool_a → `postgres`, `^…_(prod\|demo)$` | — | hairpin → `10.100.0.1` → `auth-oidc-backchannel` (python-requests, 117 hit) | via `odoo-edge` |
| odoo-staging | odoo_staging → `postgres`, `^…_staging$` | — | sama (hairpin `10.100.0.1`) | via `odoo-edge` |
| control-plane (+worker, migrate) | control_plane | web: issuer publik | web di `proxy` → tiba `10.100.0.5` → `auth-public`/`auth-login` (oauth4webapi) | web via `proxy`; worker tanpa egress |
| control-plane-staging (+worker, migrate) | control_plane_staging | idem | `10.100.0.6` → `auth-public`/`auth-login` | idem |
| drms-pk-stg (+worker, migrate, seed) | pk_drms_stg_{owner,app,ro} → pk_drms_stg (DSN host `postgres`) | Keycloak via alias Traefik di `drms-kc-admin-stg` | `10.100.9.2` → `drms-kc-admin-stg`, `auth-drms-token`, `auth-public` | SMTP :587 & FCM via `drms-kas-edge` |
| uptime-kuma | — | URL publik | `10.100.0.3` → `auth-public` (monitor discovery) | via `proxy` |
| prometheus | — | `keycloak:9000`, `traefik:8082`, `crowdsec:6060` via `metrics` | — | — |
| backup (`scripts/backup.sh`) | `docker exec postgres pg_dump` (socket, peer) | — | — | tidak bergantung network |

Tidak ada konsumen yang memakai `http://keycloak:8080` atau `odoo-*:8069` selain Traefik (`dynamic/platform/auth.yml:113`,
`odoo-pools.yml:14-26`). Pola grep ini di repo hanya menemukan komentar. Control plane tidak memanggil Odoo (ADR 0009: spool).
Belum ada konsumen DB `datamart` dan `pk_drms` (DRMS prod belum di-deploy), tetapi role dan baris pg_hba-nya sudah ada.

### 2.3 Matriks jangkauan SEBELUM (probe TCP connect 2 s, 2026-09-25 ±17:30 WIB; skrip §8.1)

`O` = OPEN, `–` = timeout / nama tidak ter-resolve.

| Dari \ ke | pool-a :8069/:8072 | odoo-stg :8069/:8072 | kc :8080/:9000 | pg :5432 | cp :3000 | cp-stg :3000 | drms-stg :3000 | grafana :3000 | kuma :3001 | traefik :8082 |
|---|---|---|---|---|---|---|---|---|---|---|
| drms-pk-stg(-worker) | **O/O** | **O/O** | **O/O** | O | **O** | **O** | O | – | – | – |
| control-plane | **O/O** | **O/O** | **O/O** | O | O | O | **O** | O | O | O |
| control-plane-worker | **O/O** | **O/O** | **O/O** | O | **O** | **O** | **O** | – | – | – |
| control-plane-staging(-worker) | **O/O** | **O/O** | **O/O** | O | **O** | O | **O** | O* | O* | O* |
| uptime-kuma | – | – | **O/O** | – | O | O | – | O | O | O |
| odoo-pool-a | O (self) | **O/O** | **O/O** | O | **O** | **O** | **O** | – | – | O |
| odoo-staging | **O/O** | O (self) | **O/O** | O | **O** | **O** | **O** | – | – | O |
| keycloak | **O/O** | **O/O** | self | O | **O** | **O** | **O** | O | O | O |

\* hanya web (`proxy`), worker `–`. **Tebal** = jalur yang ditutup plan ini. Nilai `traefik :8082` ditangani QA-T17B-03.

### 2.4 pg_hba & role sekarang

`pg_hba_file_rules` (tanpa error): setiap baris aplikasi `10.100.1.0/24`, superuser `postgres` ditolak lewat TCP,
dan ada baris terakhir `reject`. Regex `/^[a-z0-9_]+_staging$` (odoo_staging) juga cocok dengan DB `control_plane_staging`.
Ini tertutup oleh `CONNECT` yang dicabut (`has_database_privilege('odoo_staging','control_plane_staging','CONNECT') = f`) dan
tidak diubah plan ini (catatan saja). Reload pg_hba **harus** menulis di tempat (`cat new > conf/pg_hba.conf`,
inode tetap) karena file di-bind-mount (`postgres.md`).

### 2.5 Odoo & Keycloak (source di container, 2026-09-25)

- Odoo 19 `odoo/http.py:2835` menjalankan `ProxyFix(x_for=1, x_proto=1, x_host=1)` hanya bila `proxy_mode` aktif dan ada
  header `X-Forwarded-Host`. Werkzeug 3.0.1 menyimpan peer asli di `environ['werkzeug.proxy_fix.orig']['REMOTE_ADDR']`.
  Peer TCP asli karenanya selalu bisa dibaca modul (dasar D-i-D §4.2).
- `odoo/service/server.py`: prefork dan gevent memakai `config['http_interface']` yang sama (`0.0.0.0`). Satu alamat saja.
- Keycloak 26.7.4 `keycloak-config-api` menyediakan opsi `proxy-trusted-addresses`, `proxy-headers`, `http-host`,
  `http-management-host`. Status build-time/runtime **belum** diverifikasi.

## 3. Desain target

### 3.1 Topologi

```
                      ┌──────────── proxy 10.100.0.0/24 (gw Traefik, tidak berubah kecuali keycloak keluar) ─────────┐
                      │ traefik · control-plane · control-plane-staging · grafana · uptime-kuma                      │
                      └───────────────────────────────────────────────────────────────────────────────────────────────┘
traefik ─┬─ kc-edge 10.100.12/24 ──────── keycloak ─┬─ db-keycloak 10.100.20/24 ─┐
         │                                          └─ metrics (prometheus :9000) │
         ├─ odoo-edge 10.100.3/24 ─────── odoo-pool-a ── db-odoo-pool-a 10.100.21/24 ─┤
         ├─ odoo-edge-stg 10.100.13/24 ── odoo-staging ─ db-odoo-staging 10.100.22/24 ─┤
         ├─ proxy ─────────────────────── control-plane ─ db-cp 10.100.23/24 ──────────┤── postgres
         │                                control-plane-worker ┘                        │
         ├─ proxy ─────────────────────── control-plane-staging ─ db-cp-stg 10.100.24/24 ┤
         │                                control-plane-staging-worker ┘                │
         ├─ drms-kas-edge + drms-kc-admin-stg ─ drms-pk-stg(-worker) ─ db-drms-stg 10.100.26/24 ┘
         ├─ drms-kas-edge-prod 10.100.14/24 (cadangan) ── drms-pk-web(-worker) ── db-drms 10.100.25/24 (cadangan)
         └─ crowdsec · metrics · web-edge · drms-kc-admin{,-stg}   (tidak berubah)
```

### 3.2 Alokasi network (pseudo-config, final oleh infra-engineer)

| Network | Subnet / gw | `--internal` | Dibuat oleh | Anggota target | Kapan |
|---|---|---|---|---|---|
| `kc-edge` | 10.100.12.0/24 / .1 | **tidak** (egress SMTP Keycloak) | traefik bootstrap | traefik, keycloak | S1 |
| `odoo-edge-stg` | 10.100.13.0/24 / .1 | tidak (egress/hairpin pool) | traefik bootstrap | traefik, odoo-staging | S1 |
| `drms-kas-edge-prod` | 10.100.14.0/24 / .1 | tidak | traefik bootstrap | traefik, drms-pk-web(-worker) | saat onboarding DRMS prod |
| `db-keycloak` | 10.100.20.0/24 | ya | postgres bootstrap | postgres, keycloak | S1 |
| `db-odoo-pool-a` | 10.100.21.0/24 | ya | postgres bootstrap | postgres, odoo-pool-a | S1 |
| `db-odoo-staging` | 10.100.22.0/24 | ya | postgres bootstrap | postgres, odoo-staging | S1 |
| `db-cp` | 10.100.23.0/24 | ya | postgres bootstrap | postgres, control-plane, control-plane-worker, migrate | S1 |
| `db-cp-stg` | 10.100.24.0/24 | ya | postgres bootstrap | postgres, control-plane-staging(-worker), migrate | S1 |
| `db-drms` | 10.100.25.0/24 | ya | postgres bootstrap | postgres, drms-pk-web(-worker), migrate/seed | cadangan (onboarding prod) |
| `db-drms-stg` | 10.100.26.0/24 | ya | postgres bootstrap | postgres, drms-pk-stg(-worker), migrate, seed | S1 |
| `db-datamart` | 10.100.27.0/24 | ya | postgres bootstrap | postgres, dbt cron (kelak) | cadangan |
| 10.100.28–39.0/24 | — | — | — | `db-*` berikutnya (pool/dedicated Odoo, klien baru) | cadangan |
| `db` | 10.100.1.0/24 | ya | — | **dipensiunkan di S10**. Subnet tidak dipakai ulang | S10 |

Aturan: satu konsumen (app + env) = satu `db-*`. Worker, migrate, dan seed milik app yang sama boleh berbagi (satu trust
boundary, image sama). Prod dan staging tidak pernah berbagi.

### 3.3 `pg_hba.conf` target (pseudo-config; urutan & gaya sama dengan file sekarang)

```
host  keycloak               keycloak                                         10.100.20.0/24 scram-sha-256
host  postgres               odoo_pool_a                                      10.100.21.0/24 scram-sha-256
host  /^[a-z0-9_]+_(prod|demo)$  odoo_pool_a                                  10.100.21.0/24 scram-sha-256
host  postgres               odoo_staging                                     10.100.22.0/24 scram-sha-256
host  /^[a-z0-9_]+_staging$  odoo_staging                                     10.100.22.0/24 scram-sha-256
host  control_plane          control_plane                                    10.100.23.0/24 scram-sha-256
host  control_plane_staging  control_plane_staging                            10.100.24.0/24 scram-sha-256
host  pk_drms                pk_drms_owner,pk_drms_app,pk_drms_ro             10.100.25.0/24 scram-sha-256
host  pk_drms_stg            pk_drms_stg_owner,pk_drms_stg_app,pk_drms_stg_ro 10.100.26.0/24 scram-sha-256
host  datamart               datamart                                         10.100.27.0/24 scram-sha-256
```

Selama transisi (S1–S9) baris `10.100.1.0/24` lama **tetap ada** di atas baris baru (aditif). Baris lama dihapus di S10.
Baris `local`/`postgres reject`/`reject` akhir tidak berubah.

### 3.4 Compose (pseudo-config, hanya bagian yang berubah)

```yaml
# identity/keycloak — keluar dari proxy & db
networks:
  kc-edge: { gw_priority: 1 }     # satu-satunya network non-internal → gateway/egress SMTP
  db-keycloak: {}
  metrics: {}
# environment (kondisional, §4.3): KC_PROXY_TRUSTED_ADDRESSES: "10.100.12.0/24"

# traefik — tambah (tanpa gw_priority; proxy tetap gw_priority: 1)
  kc-edge: {}
  odoo-edge-stg: {}
# (drms-kas-edge-prod: {} saat onboarding DRMS prod)

# odoo/pool-a        networks: [db-odoo-pool-a, odoo-edge]
# staging/odoo       networks: [db-odoo-staging, odoo-edge-stg]
# web/control-plane  migrate/worker: [db-cp] · web: [db-cp, proxy]
# staging/control-plane migrate/worker: [db-cp-stg] · web: [db-cp-stg, proxy]
# staging/drms-proyekkas migrate/seed: [db-drms-stg] · web/worker: [drms-kas-edge, db-drms-stg, drms-kc-admin-stg]
# postgres           networks: [db-keycloak, db-odoo-pool-a, db-odoo-staging, db-cp, db-cp-stg, db-drms-stg]  (+db selama transisi)
```

Semua network dideklarasikan `external: true, name: <nama>` (pola sekarang). Service Traefik tidak berubah (URL nama container).

### 3.5 Verifikasi kebutuhan setiap konsumen setelah perubahan

| Alur | Jalur setelah | Mengapa tetap jalan | AC |
|---|---|---|---|
| Traefik → Keycloak | `keycloak:8080` via `kc-edge` | DNS Docker me-resolve nama container di network yang dibagi. Hanya `kc-edge` yang dibagi | AC-06-05 |
| Keycloak → Postgres | `postgres` via `db-keycloak` + pg_hba 10.100.20/24 | nama DSN tetap `postgres` | AC-06-03 |
| Keycloak → SMTP | `kc-edge` (gateway, bukan internal) → IP publik :587 | sama dengan jalur `proxy` sekarang (hairpin DNAT). Auth SASL tidak bergantung IP | AC-06-09 |
| Prometheus → `keycloak:9000` | `metrics` (tidak berubah) | — | AC-06-10 |
| Pool Odoo → Keycloak (token/JWKS/userinfo) | hairpin dari `odoo-edge` / `odoo-edge-stg` → tiba `10.100.0.1` → `auth-oidc-backchannel` | MASQUERADE di bridge `proxy` berlaku untuk sumber di bridge non-internal mana pun. `odoo-edge-stg` **harus** non-internal | AC-06-07 |
| Traefik → Odoo | `odoo-pool-a:8069/8072` via `odoo-edge`, `odoo-staging:*` via `odoo-edge-stg` | — | AC-06-06 |
| Control plane → issuer | tetap `proxy` → tiba IP container → `auth-login/public` | tidak berubah (rate-limit per IP container tetap) | AC-06-08 |
| DRMS → OIDC/Admin REST | tetap `drms-kc-admin-stg` alias Traefik | tidak berubah | AC-06-08 |
| DRMS → SMTP/FCM | tetap `drms-kas-edge` | tidak berubah | AC-06-09 |
| Uptime Kuma → discovery | URL publik | tidak berubah | AC-06-11 |
| Backup / skrip provision | `docker exec postgres …` / `docker exec odoo-*` | tidak lewat network | AC-06-12 |
| Traefik gateway/`10.100.0.1` | `proxy` `gw_priority: 1` tetap; network baru tanpa gw_priority | pola `odoo-edge`/`web-edge`, diverifikasi access log | AC-06-13 |
| CrowdSec + bouncer | network `crowdsec` & plugin tidak berubah. Firewall bouncer host = nftables hook input/forward (global) | tidak bergantung network container | AC-06-13 |

## 4. Defense-in-depth

### 4.1 Pilihan

| Opsi | Nilai tambah setelah segmentasi | Biaya | Rekomendasi |
|---|---|---|---|
| a. `sh_dbfilter_header` trusted proxy | Bila kelak ada container tersesat di `odoo-edge*`/`db-odoo-*` (salah compose, network dibagi ulang), header palsu tetap diabaikan | Kecil. Satu modul LGPL, unit test, recreate pool (±8–11 s) | **Ya** (task N2, paralel) |
| b. Keycloak `proxy-trusted-addresses=10.100.12.0/24` | `X-Forwarded-*` palsu dari anggota `metrics` diabaikan (log IP/event benar) | Recreate Keycloak (digabung S8) bila opsi runtime | **Ya, kondisional** (verifikasi dulu) |
| c. Odoo `http_interface=<IP odoo-edge>` | Menutup :8069 dari `postgres` saja | IP tetap (`ipv4_address`), healthcheck ubah dari 127.0.0.1, dan config Odoo 19 memperingatkan default berubah di 20.0 | **Tidak** |
| d. Keycloak `http-host=<IP kc-edge>` | Menutup :8080 dari anggota `metrics` | IP tetap keycloak di `kc-edge` | Opsional (follow-up §14) |

### 4.2 Spesifikasi task odoo-developer (N2) — ringkas, final di prompt Lead

- Repo `odoo-addons-shared`, modul `sh_dbfilter_header`, versi `19.0.1.1.0`.
- Env baru (nama diusulkan `SH_DBFILTER_TRUSTED_PROXIES`, daftar CIDR dipisah koma). Bila **diset**: header `X-Sh-Odoo-Db` hanya
  dipakai bila peer TCP ada di daftar. Peer = `environ.get('werkzeug.proxy_fix.orig', {}).get('REMOTE_ADDR')`, selain itu
  `environ['REMOTE_ADDR']`. Bila tidak ada di daftar, fail-closed `[]` dengan log WARNING yang dibatasi frekuensinya
  (tanpa nilai header). Bila **tidak diset**: perilaku lama + WARNING sekali saat load. Env tidak valid (CIDR rusak) →
  modul menolak semua (fail-closed) dan mencatat ERROR.
- Unit test: peer tepercaya/tidak, dengan/tanpa ProxyFix, IPv6 literal, env kosong/rusak, `/web/health` tetap 200.
- Uji integrasi di staging: login SSO, websocket `/websocket` (8072), dan cetak PDF (wkhtmltopdf) tetap jalan.
  Wajib dibuktikan, jangan diasumsikan.
- Nilai env: `odoo/pool-a` → `10.100.3.0/24`, `staging/odoo` → `10.100.13.0/24` (setelah split). Compose env diubah infra.

### 4.3 Keycloak `proxy-trusted-addresses` (infra, bagian S8)

Opsi itu ada di jar 26.7.4. Sebelum dipakai, infra wajib menunjukkan dari docs 26.7.4 `reverseproxy.adoc` atau
`kc.sh show-config` bahwa opsi ini runtime. Bila ternyata build-time: tambahkan ke `Containerfile` (`kc.sh build`) dan rebuild
image. Itu perubahan terpisah yang butuh keputusan Lead dan tidak menahan S8.

## 5. Threat model ringkas (STRIDE)

| STRIDE | Ancaman | Mitigasi | Verifikasi QA |
|---|---|---|---|
| S | Container app klien memalsukan `X-Sh-Odoo-Db` langsung ke Odoo → login DB tenant prod lain, lewat edge | segmentasi (§3) + D-i-D §4.2 | AC-06-01, AC-06-14 |
| S | Container memalsukan `X-Forwarded-For` langsung ke Keycloak | Keycloak hanya di `kc-edge` (+ `proxy-trusted-addresses`) | AC-06-02 |
| T/I | Role DB yang bocor dipakai dari container lain | pg_hba per subnet | AC-06-04 |
| I | Akses `/realms/master`, `/admin`, `:9000` Keycloak dari `proxy`/`db` | Keycloak keluar dari `proxy`/`db` | AC-06-02 |
| E | Pool staging (kode addon staging) → pool prod :8069 | `odoo-edge-stg` | AC-06-01 |
| D | Migrasi memutus SSO back-channel / login / scrape | urutan §6, staging dulu, AC regresi, rollback per langkah | AC-06-05..13 |
| R | Perubahan live tidak tercermin di compose (drift) | compose di-merge dulu. `docker compose --dry-run up -d` = tidak ada perubahan setelah tiap langkah | AC-06-15 |

## 6. Migrasi — urutan, downtime, rollback

Strategi yang direkomendasikan (GATE Q1): langkah **aditif live** (tanpa downtime), lalu **recreate per stack konsumen**
di jendela maintenance. Staging dulu, prod setelah AC staging hijau. Postgres dan Traefik **tidak** di-recreate: network
di-attach live dengan `docker network connect` (preseden `web-edge`, `traefik.md` §web-edge), lalu compose disamakan.
Recreate konsumen lebih aman daripada `docker network disconnect` live karena koneksi TCP pool DB (Odoo/Agroal Keycloak)
yang ada di interface lama akan putus tanpa terdeteksi sampai dipakai.

| Step | Aksi | Stack/container | Downtime (sumber) | Verifikasi segera | Rollback step |
|---|---|---|---|---|---|
| S0 | Baseline: probe matriks (§8.1), access log `auth-*`, `up{job="keycloak"}`, `docker compose --dry-run up -d` per stack = no-op | — | 0 | simpan output ke `docs/qa/` | — |
| S1 | `postgres/scripts/bootstrap.sh` & `traefik/scripts/bootstrap.sh` versi baru → buat 6× `db-*`, `kc-edge`, `odoo-edge-stg` | host | 0 | `docker network inspect` subnet/internal | `docker network rm <baru>` (belum ada anggota) |
| S2 | pg_hba **aditif** (baris baru + lama) → `cat > conf/pg_hba.conf` → `pg_reload_conf()` | postgres | 0 | `pg_hba_file_rules` tanpa `error`, jumlah baris sesuai | tulis file lama di tempat + reload |
| S3 | `docker network connect <db-*> postgres` ×6. `docker network connect kc-edge traefik`, `docker network connect odoo-edge-stg traefik` | postgres, traefik | 0 | `docker inspect` networks. Traefik: access log host tetap `10.100.0.1` | `docker network disconnect` |
| S4 | staging Odoo: compose `[db-odoo-staging, odoo-edge-stg]` → `docker compose up -d` | odoo-staging | ±11 s (plan 04, `odoo.md`) | healthy. `demo.staging…`/`ssotest.staging…` login SSO. Access log back-channel `10.100.0.1`/`auth-oidc-backchannel` | compose lama → `up -d` |
| S5 | staging CP: compose `db-cp-stg` → `up -d` (migrate+web+worker) | control-plane-staging(-worker) | ±5–10 s (`control-plane.md`) | `/api/health`, login `cp.staging` (SSO), job `dry_run` sukses | idem |
| S6 | staging DRMS: compose `db-drms-stg` (4 service) → `infra-deploy staging/drms-proyekkas` / `up -d` | drms-pk-stg(-worker) | ESTIMASI ≤ 40 s (start_period; belum terukur) | health, login web, Admin REST (`drms-kc-admin-stg` 200), mail uji (worker) | idem |
| — | **QA gate staging** (N4): matriks parsial untuk kontainer staging + regresi | — | — | AC-06-01..15 subset staging | — |
| S7 | prod CP: `db-cp` → `up -d` | control-plane(-worker) | ±4 s (J6) | login `cp.bimacreative.tech`, worker heartbeat | idem |
| S8 | Keycloak: compose `[kc-edge gw 1, db-keycloak, metrics]` (+ `KC_PROXY_TRUSTED_ADDRESSES` bila lolos §4.3) → `up -d` | keycloak | **±30–60 s** (`keycloak.md`): login SSO semua app gagal selama jendela; sesi app berjalan tetap hidup | healthy. Discovery 4 realm 200, token `automation` via :8443, Prometheus `up{job=keycloak}=1`, TCP ke `mail.bimacreative.tech:587`, `/proc/net/route` default via 10.100.12.1 | compose lama → `up -d` (`proxy`+`db` masih ada) |
| S9 | prod Odoo: `[db-odoo-pool-a, odoo-edge]` → `up -d` (gabung rollout N2 bila siap) | odoo-pool-a | ±8 s (plan 04) | login SSO `demo.erp…`, back-channel `10.100.0.1`, websocket | idem |
| S10 | Cleanup: hapus baris pg_hba `10.100.1.0/24` + reload. `docker network disconnect db postgres`. Compose postgres tanpa `db`. `docker network rm db`. Bootstrap postgres tidak lagi membuat `db` (subnet dicatat "pensiun") | postgres | 0 (tidak ada peer tersisa di `db`; cek `docker network inspect db` kosong kecuali postgres) | matriks penuh (§8.2), `--dry-run` semua stack no-op | ADR 0010 §Rollback (buat ulang `db`, connect, pg_hba lama) |
| S11 | QA penuh (N7) + 24 jam soak (log error koneksi Postgres/Keycloak/Odoo) | — | — | AC semua | — |

Catatan eksekusi:
- **Tidak ada `docker kill`** (H7). Traefik tidak di-restart. Bila `--dry-run` menunjukkan compose Traefik/Postgres akan
  recreate setelah compose diubah, recreate itu **dijadwalkan** di jendela yang sama: Traefik ±3.5–5 s (`traefik.md`),
  Postgres ±6.4 s (`postgres.md`). Keduanya tidak boleh dibiarkan sebagai drift.
- Traefik `gw_priority`: tidak ada network baru di Traefik yang memakai `gw_priority`, dan `proxy: gw_priority: 1` tetap.
  Keycloak memakai `gw_priority: 1` pada `kc-edge` karena itu satu-satunya network non-internal miliknya.
- Urutan prod: CP → Keycloak → Odoo. Keycloak (jendela terbesar) sebelum Odoo supaya S9 menguji SSO Odoo terhadap Keycloak
  yang sudah pindah.
- Satu perubahan → satu verifikasi (CLAUDE.md §0.6). Jangan mengeksekusi S7–S9 berurutan tanpa AC masing-masing.

**Total downtime rencana (prod):**
- CP ±4 s.
- Keycloak ±30–60 s (login baru saja).
- Odoo prod ±8 s.
- Postgres/Traefik 0, atau +6 s/+5 s bila recreate diperlukan.
- Staging ±1 menit total.

## 7. Rollback (ringkas)

- **S1–S9:** per step, lihat tabel §6. Network `db` + baris pg_hba lama masih ada, jadi mengembalikan compose satu stack sudah
  cukup.
- **Setelah S10:**
  1. `git checkout <rev-sebelum> -- postgres/ traefik/scripts/bootstrap.sh`, lalu `postgres/scripts/bootstrap.sh` (buat
     ulang `db` 10.100.1.0/24 internal).
  2. `docker network connect db postgres`, tulis pg_hba lama di tempat, lalu `pg_reload_conf()`.
  3. Recreate stack konsumen dari revisi lama.
- **N2 (modul):** hapus env `SH_DBFILTER_TRUSTED_PROXIES` dan recreate pool (perilaku lama), atau checkout submodule lama
  (`odoo.md` §Rollback).
- **Keycloak trusted addresses:** hapus env, lalu `up -d`.

## 8. Verifikasi

### 8.1 Skrip probe (ilustrasi untuk QA; dipakai Analyst untuk §2.3, read-only)

```bash
T="odoo-pool-a:8069 odoo-pool-a:8072 odoo-staging:8069 odoo-staging:8072 keycloak:8080 keycloak:9000 postgres:5432 \
   control-plane:3000 control-plane-staging:3000 drms-pk-stg:3000 grafana:3000 uptime-kuma:3001 traefik:8082"
NODEJS='const net=require("net");const ts=process.argv.slice(1);let o=[],n=ts.length;ts.forEach((t,i)=>{const[h,p]=t.split(":");
const s=net.connect({host:h,port:+p,timeout:2000});const d=r=>{o[i]=t+"="+r;s.destroy();if(--n==0)console.log(o.join(" "))};
s.on("connect",()=>d("OPEN"));s.on("timeout",()=>d("timeout"));s.on("error",e=>d(e.code))});'
for c in drms-pk-stg drms-pk-stg-worker control-plane control-plane-worker control-plane-staging control-plane-staging-worker uptime-kuma; do
  echo "[$c] $(docker exec "$c" node -e "$NODEJS" $T)"; done
# odoo-*: python3 socket.create_connection; keycloak: bash /dev/tcp (lihat scratchpad Analyst; QA menulis versi final)
```

Uji header palsu (QA B15):

```bash
docker exec drms-pk-stg node -e "fetch('http://odoo-pool-a:8069/web/login',{headers:{'X-Sh-Odoo-Db':'demo_demo'}}).then(r=>console.log(r.status)).catch(e=>console.log(e.cause?.code))"
docker exec drms-pk-stg node -e "fetch('http://keycloak:8080/realms/master/.well-known/openid-configuration').then(r=>console.log(r.status)).catch(e=>console.log(e.cause?.code))"
```

Sebelum: `200` / `200`. Sesudah: `ENOTFOUND`/`EAI_AGAIN`.

### 8.2 Matriks SESUDAH (target)

| Dari \ ke | pool-a | odoo-stg | kc :8080 | kc :9000 | pg | cp | cp-stg | drms-stg | grafana | kuma |
|---|---|---|---|---|---|---|---|---|---|---|
| drms-pk-stg(-worker) | – | – | – | – | O | – | – | self | – | – |
| control-plane / -staging (web) | – | – | – | – | O | O (R1) | O (R1) | – | O (R1) | O (R1) |
| control-plane(-staging)-worker | – | – | – | – | O | – | – | – | – | – |
| uptime-kuma | – | – | – | – | – | O (R1) | O (R1) | – | O (R1) | self |
| odoo-pool-a | self | – | – | – | O | – | – | – | – | – |
| odoo-staging | – | self | – | – | O | – | – | – | – | – |
| keycloak | – | – | self | self | O | – | – | – | – | – |
| traefik | O | O | O | O | – | O | O | O | O | O |
| prometheus | – | – | O (R2) | O | – | – | – | – | – | – |

R1 = residual `proxy` (§14). R2 = residual `metrics` (§4.1 d). `traefik :8082` sesuai hasil QA-T17B-03.
Postgres hanya terjangkau dari konsumennya sendiri (dan dari host lewat `docker exec`).

### 8.3 pg_hba silang (tanpa password; baris `reject` ditolak sebelum autentikasi)

Container uji sementara di network target, image Postgres yang sama. QA menjalankannya lalu `--rm`:

```bash
docker run --rm --network db-cp --entrypoint psql postgres:16.15-bookworm@sha256:efedf359… \
  "host=postgres user=keycloak dbname=keycloak" -c 'select 1'
# harap: FATAL: pg_hba.conf rejects connection for host "10.100.23.x", user "keycloak", database "keycloak"
```

Ulangi untuk setiap pasangan (subnet × role lain), minimal: `db-drms-stg`→`odoo_pool_a`/`demo_demo`, `db-odoo-staging`→`odoo_pool_a`,
`db-cp-stg`→`control_plane`. Login positif setiap konsumen dibuktikan oleh healthcheck app dan log tanpa `pg_hba` error.

## 9. Acceptance criteria

| ID | Kriteria | Perintah → hasil |
|---|---|---|
| AC-06-01 | Tidak ada jalur ke Odoo selain Traefik | Probe §8.1 dari semua container non-Traefik: `odoo-*:8069/8072` ≠ OPEN. Header palsu §8.1 → ENOTFOUND |
| AC-06-02 | Tidak ada jalur ke Keycloak :8080/:9000 selain Traefik (+Prometheus :9000) | Probe: `keycloak:*` ≠ OPEN dari proxy/db-* container. `docker network inspect proxy` tanpa keycloak |
| AC-06-03 | Anggota network sesuai §3.2 | `docker network inspect <n> -f '{{range .Containers}}{{.Name}} {{end}}'` = tabel. `db` tidak ada setelah S10 |
| AC-06-04 | pg_hba per subnet | `pg_hba_file_rules`: tidak ada `10.100.1.0/24`, tanpa `error`. Uji silang §8.3 → `rejects` |
| AC-06-05 | Keycloak via edge normal | `curl --resolve auth.bimacreative.tech:443:127.0.0.1 …/realms/{platform,platform-staging,drms,drms-staging}/.well-known/openid-configuration` → 200. `/realms/master/` :443 → 403. Admin :8443 → 302/200 |
| AC-06-06 | Odoo via edge normal | host prod & staging `/web/login` 200 (dengan header Traefik). `/websocket` upgrade 101 |
| AC-06-07 | SSO Odoo end-to-end + back-channel | login SSO user uji di `demo.staging…` dan `demo.erp…` (Lead/user). Access log: `python-requests` `ClientHost=10.100.0.1` `RouterName=auth-oidc-backchannel@file` setelah S4/S9 |
| AC-06-08 | Login control plane & DRMS | `cp`/`cp.staging` login SSO → dashboard. DRMS web login + Admin REST (access log `drms-kc-admin-stg@file` 200 dari 10.100.9.x) |
| AC-06-09 | Egress SMTP | `docker exec keycloak bash -c 'exec 3<>/dev/tcp/mail.bimacreative.tech/587'` rc 0. Mail uji DRMS worker terkirim (log mailserver) |
| AC-06-10 | Scrape Prometheus | `docker exec prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=up'` → keycloak, traefik, crowdsec = 1 |
| AC-06-11 | Uptime Kuma monitor hijau | 4 monitor status UP (dashboard via tunnel atau DB kuma) |
| AC-06-12 | Backup tidak terpengaruh | `scripts/backup.sh` run berikutnya rc 0 (log restic), atau `pg_dump` manual per DB rc 0 |
| AC-06-13 | Gateway & sumber IP tidak berubah | access log: koneksi host → `10.100.0.1`. `docker exec traefik cat /proc/net/route` default via 10.100.0.1. Keycloak default via 10.100.12.1. CrowdSec decisions/bouncer normal (`cscli bouncers list` last pull < 1 m) |
| AC-06-14 | D-i-D Odoo (N2) | Container uji di `db-odoo-staging` (simulasi) → `odoo-staging:8069` tidak terjangkau. Unit test modul lulus. Via Traefik login normal. Dengan env diset, request dari peer di luar daftar → 303/404 (tanpa DB) di log WARNING |
| AC-06-15 | Tidak ada drift compose | `docker compose --dry-run up -d` di 8 stack → tidak ada Recreate/Create |
| AC-06-16 | Tidak ada error baru 24 jam | `docker logs --since 24h` postgres (`no pg_hba.conf entry`/`rejects` = 0 dari IP konsumen sah), keycloak, odoo (OperationalError) |

## 10. Task & dependency

| ID | Task | Agent | depends_on | File/dir disentuh | Paralel |
|---|---|---|---|---|---|
| N0 | Merge `fix/infra-t17b-edge` (QA-T17B-03) | Lead | — | traefik/, docs | — |
| N1 | Bootstrap scripts, pg_hba (target + versi transisi), compose 8 stack, env D-i-D Keycloak (bila opsi runtime terverifikasi) | infra-engineer | N0, GATE 1 | `postgres/`, `traefik/scripts/bootstrap.sh`, `traefik/docker-compose.yml`, `identity/keycloak/docker-compose.yml`, `odoo/pool-a/docker-compose.yml`, `staging/odoo/docker-compose.yml`, `web/control-plane/`, `staging/control-plane/`, `staging/drms-proyekkas/docker-compose.yml` | N2 |
| N2 | `sh_dbfilter_header` trusted proxy 19.0.1.1.0 + test | odoo-developer | GATE 1 | repo `odoo-addons-shared` (`sh_dbfilter_header/`) | N1 |
| N3 | Eksekusi S0–S6 (staging) | infra-engineer | N1 (merge) | live | — |
| N4 | QA staging: probe, pg_hba silang, AC staging | qa-security | N3 | `docs/qa/…-plan06-staging.md` | — |
| N5 | Eksekusi S7–S9 prod (+ bump submodule N2 di S9 & staging bila N2 lulus QA) | infra-engineer | N4, (N2) | live, `odoo/*/addons/shared` | — |
| N6 | S10 cleanup | infra-engineer | N5 + 24 jam | `postgres/`, live | — |
| N7 | QA penuh (§9 semua AC) + re-test B15 | qa-security | N6 | `docs/qa/…-plan06-prod.md` | — |
| N8 | Docs: `traefik/odoo/keycloak/postgres/control-plane/observability.md`, runbook ProyekKas (prod: `db-drms`, `drms-kas-edge-prod`), ADR 0010 accepted, CHANGELOG, usulan CLAUDE.md (ADR 0010 §akhir) | docs-versioning | N7 | `docs/`, `CHANGELOG.md` | — |

nextjs-developer tidak dilibatkan (tidak ada perubahan app). Tim app ProyekKas diberi tahu lewat runbook untuk compose prod.

Gelombang: [N0] → [N1 ‖ N2] → [N3] → [N4] → [N5] → (24 jam) → [N6] → [N7] → [N8].

## 11. Kapasitas

- RAM/CPU container: **tidak berubah**. Tidak ada service baru. `mem_limit` sama. Koneksi Postgres dan `max_connections` sama.
- Kernel/host: +8 bridge (+3 cadangan), +1 veth per attach (Postgres +6, Traefik +2, Keycloak +2, konsumen ±1).
  Memori kernel per bridge/veth sangat kecil. Tidak diukur (ESTIMASI: bisa diabaikan terhadap 15 GiB).
- Disk: tidak ada.

## 12. Risiko

| # | Risiko | Kemungkinan / dampak | Mitigasi |
|---|---|---|---|
| 1 | Back-channel SSO Odoo putus (hairpin tidak tiba sebagai `10.100.0.1` → router `auth-login` 10/menit → 429, atau tidak ada egress) | rendah / tinggi | `odoo-edge-stg` non-internal. Staging dulu (S4). AC-06-07 dari access log sebelum prod |
| 2 | Keycloak tanpa egress SMTP / gateway salah | rendah / sedang (undangan & reset gagal) | `kc-edge` non-internal + `gw_priority: 1`. AC-06-09, `/proc/net/route` |
| 3 | Prometheus kehilangan scrape Keycloak | rendah / rendah | `metrics` tidak diubah. AC-06-10 |
| 4 | Login control plane gagal | rendah / sedang | CP tetap di `proxy`, jalur ke issuer tidak berubah. AC-06-08 |
| 5 | DRMS login/Admin REST gagal | rendah / sedang (UAT staging) | network edge/admin DRMS tidak berubah, hanya DB. AC-06-08 |
| 6 | pg_hba reload tidak efektif (inode baru) → konsumen ditolak | sedang / tinggi | tulis di tempat (`cat >`). Verifikasi `pg_hba_file_rules` sebelum S4. Baris lama tetap ada sampai S10 |
| 7 | Drift compose ↔ live (connect live) → recreate berikutnya berbeda | sedang / sedang | compose di-merge sebelum connect. AC-06-15 (`--dry-run`) |
| 8 | Recreate Keycloak lebih lama dari 60 s | rendah / sedang | jendela maintenance. Healthcheck `start_period 90s`. Rollback compose lama |
| 9 | Konsumen baru kelak kembali memakai network DB bersama | sedang / tinggi | usulan CLAUDE.md §3.5 + prosedur `postgres.md` + QA checklist B15 permanen |
| 10 | Konflik dengan branch `fix/infra-t17b-edge` (docs/traefik) | sedang / rendah | N0 merge dulu |

## 13. Pertanyaan GATE 1 (untuk user)

1. **Strategi & jendela:** recreate per stack (prod: Keycloak ±30–60 s tanpa login baru, Odoo ±8 s, CP ±4 s) di jendela
   malam, atau live `network disconnect` tanpa jendela dengan risiko error transien koneksi DB? **Rekomendasi: recreate,
   jendela 22:00–23:00 WIB**, staging siang hari.
2. **Pisah `odoo-edge` prod/staging** (`odoo-edge-stg`) di plan ini? **Rekomendasi: ya.** Masalah dengan kelas yang sama:
   pool staging → pool prod. Biayanya hanya bagian dari recreate staging.
3. **D-i-D:** kerjakan `sh_dbfilter_header` trusted-proxy (odoo-developer, paralel) dan `proxy-trusted-addresses` Keycloak
   (bila runtime)? **Rekomendasi: ya untuk keduanya.** Odoo `http_interface` per IP tidak dikerjakan.
4. **`proxy` (CP, CP-staging, Grafana, Uptime Kuma saling menjangkau langsung):** plan 07 terpisah atau masuk sekarang?
   **Rekomendasi: plan 07.** Memindahkan CP keluar dari `proxy` mengubah IP sumber ke issuer menjadi `10.100.0.1` (router
   back-channel/rate limit bersama), jadi perlu desain sendiri.
5. **Network `db` lama:** hapus setelah 24 jam soak + QA hijau (fail-loud bila ada compose yang masih merujuk), atau simpan
   kosong 7 hari? **Rekomendasi: hapus setelah 24 jam.**

## 14. Follow-up (di luar scope)

- Plan 07: pecah `proxy` → `cp-edge`, `cp-edge-stg`, `admin-edge` (grafana, kuma), dengan evaluasi rute issuer CP.
- `web-edge` per klien (`traefik.md` §web-edge "opsi masa depan").
- Keycloak `http-host` di `kc-edge` (menutup `:8080` dari `metrics`).
- QA checklist permanen: B15 (probe §8.1) dijalankan setiap onboarding konsumen/stack baru.
