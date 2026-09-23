# ADR 0004 — Kapasitas: alokasi RAM/CPU, swap, threshold shared → dedicated

- **Status:** proposed (menunggu GATE 1)
- **Tanggal:** 2026-09-23
- **Terkait:** CLAUDE.md §3.5, §4; `docs/discovery/2026-09-23.md` §2; keputusan user #4, #8

> **SEMUA ANGKA DI ADR INI = ESTIMASI** kecuali yang diberi sumber. Belum ada `docker stats` nyata
> (Docker belum terpasang). Wajib direvisi setelah bring-up tiap service (plan 02, gate "ukur").

## Context

- Host: 4 vCPU (AMD EPYC 9354P), RAM 16 376 008 kB = **15,6 GiB ≈ 15 992 MiB**, disk `/` 193 G, swap 0
  (discovery §1.2). Spek tetap, tanpa upgrade (keputusan #4). Staging **selalu hidup** (keputusan #8).
- Sumber sizing resmi yang dipakai:
  - Odoo 19.0 `deploy.rst` (raw.githubusercontent.com/odoo/documentation/19.0/…/deploy.rst):
    "(#CPU * 2) + 1", "1 worker ~= 6 concurrent users", worker ringan ≈150 MB, berat ≈1 GB,
    RAM = #worker × (0,8×150 + 0,2×1024) MB ≈ 324 MB/worker; contoh `limit_memory_hard = 1677721600`,
    `limit_memory_soft = 629145600`, `max_cron_threads = 1`.
  - Odoo 19.0 `config.py` default: `limit_memory_soft` 2048 MiB, `limit_memory_hard` 2560 MiB,
    `db_maxconn` 64, `max_cron_threads` 2, `workers` 0.
  - Keycloak 26.7 sizing (keycloak.org/high-availability/multi-cluster/concepts-memory-and-cpu-sizing):
    request 1250 MB, limit 1360 MB, heap = 70% limit, non-heap ≈ 300 MB.
- CLAUDE.md §4 memberi angka referensi kasar (Keycloak 700 MB–1 GB — **lebih rendah** dari angka resmi).

## Decision

### 1. Swap 4 GiB (file `/swapfile`), `vm.swappiness=10`
Sebagai bantalan lonjakan, bukan kapasitas. Alert bila swap terpakai > 1 GiB selama > 15 menit.

### 2. Alokasi per service (`mem_limit` = batas keras cgroup; `cpus` = kuota, boleh overcommit)

| Stack / service | mem_limit | cpus | Catatan (ESTIMASI kecuali disebut) |
|---|---:|---:|---|
| **Cadangan host** (kernel, systemd, dockerd, containerd, sshd, fail2ban, crowdsec-firewall-bouncer, auditd, page cache minimum) | 1 536 MiB | — | bukan limit; idle host sekarang ±689 MiB (discovery) |
| traefik | 256 MiB | 1.0 | + plugin bouncer |
| crowdsec (agent + LAPI + AppSec) | 384 MiB | 0.5 | |
| docker-socket-proxy | 64 MiB | 0.1 | |
| postgres (shared, prod+staging+keycloak+control_plane+datamart) | 2 048 MiB | 1.5 | `shared_buffers` 512MB, `work_mem` kecil (4–8MB), `max_connections` ≈ 150; Odoo `db_maxconn` diturunkan (mis. 16) — nilai final setelah ukur |
| odoo pool-a **prod** (`workers=3`, `max_cron_threads=1`, gevent) | 2 560 MiB | 2.0 | 3 × 324 ≈ 1 GB rumus docs + master/gevent/cron; `limit_memory_soft` 640 MiB, `limit_memory_hard` 896 MiB per worker. Kapasitas ≈ 18 user konkuren (3×6, rumus docs) |
| odoo pool **staging** (`workers=2`, `max_cron_threads=1`) | 1 280 MiB | 1.0 | always-on; hard limit per worker 768 MiB |
| keycloak (1 instance: realm `platform` + realm `platform-staging`) | 1 360 MiB | 1.0 | angka resmi; heap 70% |
| docker-mailserver (Postfix, Dovecot, Rspamd+Redis internal, fail2ban; **ClamAV OFF**, Amavis/SpamAssassin OFF) | 1 024 MiB | 0.75 | ClamAV dimatikan untuk hemat RAM (env `ENABLE_CLAMAV=0` default, `ENABLE_AMAVIS`, `ENABLE_SPAMASSASSIN` — docs DMS environment.md) |
| control-plane prod (Next.js standalone) | 384 MiB | 0.5 | |
| control-plane worker (pg-boss) | 256 MiB | 0.25 | |
| control-plane staging (web+worker digabung) | 320 MiB | 0.25 | |
| datamart dbt (job terjadwal, tidak persisten) | 384 MiB | 0.5 | hanya saat jalan |
| prometheus (retensi 15 hari) | 384 MiB | 0.25 | |
| node-exporter | 32 MiB | 0.1 | |
| cAdvisor (**opsional**) | 128 MiB | 0.2 | image UNVERIFIED (ADR 0001) |
| loki (retensi 7 hari, single-binary) | 384 MiB | 0.25 | |
| alloy (log shipper) | 192 MiB | 0.2 | |
| grafana | 256 MiB | 0.25 | |
| uptime-kuma | 192 MiB | 0.2 | |
| **Jumlah mem_limit platform** | **11 888 MiB** | | |
| **+ cadangan host** | **13 424 MiB** | | |
| **Sisa untuk client (web Next.js per client, growth)** | **≈ 2 568 MiB** | | 15 992 − 13 424 |

Catatan: jumlah `mem_limit` = batas atas, bukan pemakaian nyata; pemakaian tipikal diperkirakan
lebih rendah. Namun perencanaan memakai batas atas agar tidak ada OOM berantai.

### 3. Kapasitas client (ESTIMASI)

- Client di **shared pool** tidak menambah container: hanya DB (`<slug>_prod`, `_demo`, `_staging`) +
  filestore. Batas praktisnya CPU/worker: **≈ 18 user konkuren total** di prod pool (3 worker × 6).
  Target awal: **3–5 client kecil** (≤ 5 user konkuren masing-masing).
- Website Next.js per client (opsional): ±192–256 MiB tiap container → sisa 2,5 GiB ≈ **maks 6–8**
  website, dikurangi bantalan → rencanakan **≤ 4** hingga ada data `docker stats`.
- Disk (ESTIMASI): OS+images ±15 G; Postgres ±1–3 G per client kecil/tahun; filestore ±1–5 G per client;
  restic repo lokal ≈ 1–1,5× data (ADR 0006); Loki 7 hari ±2–5 G; Prometheus 15 hari ±1–3 G.
  Alert disk `/` > 70%.

### 4. Threshold shared → dedicated

Client dipindah ke instance dedicated (atau di host ini: tidak mungkin → butuh VPS-2/upgrade) bila
salah satu terpenuhi selama 7 hari berturut-turut:
- > **10 user konkuren** puncak (≈ 55% kapasitas pool prod), atau > 25 user aktif terdaftar;
- DB > **5 GB** atau filestore > **20 GB**;
- CPU pool prod rata-rata > 70% dan client tsb menyumbang > 40% request (dari access log Traefik);
- butuh versi Odoo/addon berbeda atau SLA terpisah (§3.2).
Karena spek tetap, **memicu threshold = memicu keputusan user** (upgrade/VPS-2), bukan otomatis.

### 5. Urutan perampingan bila RAM kurang (diterapkan berurutan, ukur setelah tiap langkah)

1. Matikan cAdvisor (−128 MiB); metrik container cukup dari `docker stats` + node-exporter.
2. Loki retensi 7 → 3 hari dan limit 384 → 256 MiB; atau hentikan Loki+Alloy, pakai `docker logs` +
   journald (−576 MiB).
3. Staging Odoo `workers=0` (mode threaded) + limit 768 MiB (−512 MiB) — staging tetap hidup.
4. Grafana + Prometheus dijalankan hanya saat investigasi; monitoring harian via Uptime Kuma + alert
   node-exporter sederhana (−640 MiB).
5. Keycloak limit 1 360 → 1 024 MiB (di bawah angka resmi → risiko GC/latensi; uji login beban kecil).
6. Pool prod `workers=2` (−±324 MiB, kapasitas turun ke ≈12 user konkuren).
7. Terakhir: pindah mail ke luar host (ADR baru).

## Alternatives

| Alternatif | Ditolak karena |
|---|---|
| Staging on-demand | Keputusan user #8: always-on |
| Keycloak terpisah untuk staging | +1,3 GiB; realm terpisah di instance yang sama cukup untuk isolasi konfigurasi |
| Postgres terpisah untuk staging | +±1 GiB; DB & role terpisah di cluster yang sama, dengan `CONNECTION LIMIT` per role |
| Tanpa `mem_limit` (biarkan kernel) | Melanggar §3.5; OOM killer bisa memilih Postgres |

## Consequences

- Platform muat, tetapi **hanya untuk tahap uji / 3–5 client kecil**. Headroom tipis (±2,5 GiB).
- Staging berbagi Postgres & Keycloak dengan prod → beban staging (mis. ZAP scan, restore test) dapat
  mengganggu prod; jadwalkan di jam sepi dan beri `cpus` rendah.
- Semua angka direvisi setelah bring-up (plan 02 tugas "ukur baseline").

## Security implications

- `mem_limit` mencegah satu service (mis. Odoo report besar) menjatuhkan seluruh host (DoS internal).
- Staging dan prod di host & cluster DB yang sama: wajib role DB terpisah, password berbeda, tidak ada
  data prod mentah di staging tanpa anonimisasi (butuh keputusan user — lihat pertanyaan terbuka).
- Swap tidak terenkripsi (sesuai §3.6) → secret di memori bisa tertulis ke disk; risiko diterima.

## Rollback

Ubah `mem_limit`/`cpus` di compose → `docker compose up -d` (recreate service). Swap: `swapoff /swapfile`
+ hapus entri fstab (Ansible `state: absent`).
