# ADR 0004 — Kapasitas: alokasi RAM/CPU, swap, threshold shared → dedicated

- **Status:** accepted (2026-09-23, GATE 1)
- **Tanggal:** 2026-09-23
- **Terkait:** CLAUDE.md §3.5, §4; `docs/discovery/2026-09-23.md` §2; keputusan user #4, #8

**Riwayat revisi:**
- 2026-09-23 (GATE 1, `accepted`): versi awal, seluruh angka ESTIMASI (Docker belum terpasang).
- 2026-09-23 (T07, analyst): ditambahkan **§"Pengukuran T07"** dengan angka NYATA (`docker stats`,
  `free`, `vmstat`, dll.) untuk service yang sudah bring-up (T03–T06: traefik, crowdsec, postgres,
  keycloak). Angka Odoo pool/mail/control-plane/observability/datamart **TIDAK berubah** (masih
  ESTIMASI § Decision asli) — service tersebut belum di-deploy saat pengukuran ini. Status tetap
  `accepted`; revisi penuh menyusul di T19 setelah semua service naik.
- 2026-09-23 (onboarding ProyekKas DRMS, infra Lead): Postgres **`max_connections` 150 → 200**. Alasan:
  jumlah `CONNECTION LIMIT` role setelah DRMS = 132 (keycloak 30, control_plane 20, datamart 10,
  odoo_pool_a 48, odoo_staging 24) + 30 (`pk_drms_*` 2/25/3) + 14 (`pk_drms_stg_*` 2/10/2) = **176** > 150;
  200 menyisakan ±24 untuk superuser/`superuser_reserved_connections` (default 3), backup
  (`pg_dump` via peer) dan admin. Limit = plafon, bukan reservasi (NYATA saat perubahan: 18 koneksi di
  `pg_stat_activity`, RSS container 118 MiB). **ESTIMASI RAM tambahan:** shared memory per slot
  (PGPROC, lock table `max_locks_per_transaction` 64 × slot) ≈ beberapa ratus KiB–±1 MiB untuk 50 slot,
  dialokasikan saat start; memori backend hanya terpakai bila koneksi benar-benar dibuka — ±5–10 MiB
  per backend idle, lebih bila query memakai `work_mem` (6 MB per operasi sort/hash). Skenario terburuk
  +50 koneksi aktif ≈ +250–500 MiB, masih di dalam `mem_limit 2048m` (target app DRMS prod ≤ 15 + staging
  ≤ 10 koneksi aktual → ±+125–250 MiB). Ukur `docker stats postgres` + `pg_stat_activity` setelah app
  DRMS naik (F1). `mem_limit` tidak diubah.
- 2026-09-25 (T19, analyst): ditambahkan **§"Pengukuran ulang T19 (2026-09-25)"** — semua service berjalan
  (20 container, jumlah `mem_limit` NYATA 12 400 MiB); riwayat host 48 j dari Prometheus. Sisa perencanaan turun
  **≈ 2 312 → ≈ 1 672 MiB** (≈ 1 096 setelah DRMS prod) karena drms-pk-stg + web-starter-staging belum tercatat di
  § Decision; usul T07 cadangan host 1 152 MiB **dibatalkan**; runway disk ≈ 1,3–2 hari akibat build lokal (risiko
  utama); target 3–5 tenant Odoo kecil dipertahankan (+3–4), website Next.js ≤ 3–4. Angka lama tidak diubah.
- 2026-09-25 (T19 follow-up #3, infra): **§ T19 §8.2** kolektor memori/CPU per container (timer host 60 s → textfile
  node-exporter), prasyarat R3; §8.1 ditambah dampak restart dockerd terukur (±2 s, H3). Belum diterapkan.
- 2026-09-25 (T19 follow-up #2, keputusan user): **cadangan host perencanaan 1 536 → 2 048 MiB** (usul R2 diterima).
  Dihitung ulang: § Decision "+ cadangan host" 13 680 → 14 192, sisa ≈ 2 312 → ≈ 1 800 MiB; § T19 §3 sisa ≈ 1 672 →
  **≈ 1 160 MiB** (setelah DRMS prod ≈ 1 096 → **≈ 584**); § T19 §5 website Next.js baru 6/4 → **4/2** (rencana ≤ 2).
  Kapasitas tenant Odoo (+3–4, dibatasi limit container pool) tidak berubah. Angka lama tetap ditampilkan (dicoret).
- 2026-09-25 (T19 follow-up #1, infra): **§ T19 §8.1** batas GC BuildKit di `daemon.json` (`builder.gc`: max 10 GiB,
  reserved 2 GiB, min-free 56 GiB Bfree); kunci diverifikasi dari source moby `docker-v29.8.1`. Belum diterapkan (butuh
  restart dockerd, dijadwalkan Lead).
- 2026-09-25 (grafana/kuma, sebelum T19): grafana 256 → 384 MiB, uptime-kuma 192 → 320 MiB (tabel § Decision).

> **SEMUA ANGKA DI § "Decision" DI BAWAH INI = ESTIMASI** kecuali yang diberi sumber resmi.
> Angka **NYATA** dari pengukuran T03–T06 ada di § "Pengukuran T07 (2026-09-23)" di bawah —
> dua bagian ini sengaja dipisah agar tidak tercampur ESTIMASI vs NYATA. Wajib direvisi lagi
> setelah bring-up tiap service berikutnya (plan 02 T19, gate "ukur ulang").

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
| **Cadangan host** (kernel, systemd, dockerd, containerd, sshd, fail2ban, crowdsec-firewall-bouncer, auditd, page cache minimum) | **2 048 MiB** | — | bukan limit; idle host sekarang ±689 MiB (discovery). **1 536 → 2 048 MiB (keputusan user 2026-09-25, T19 R2)**: overhead host non-container NYATA ±1 691 MiB saat sesi Claude Code + BuildKit di host |
| traefik | 256 MiB | 1.0 | + plugin bouncer |
| crowdsec (agent + LAPI + AppSec) | 384 MiB | 0.5 | |
| docker-socket-proxy | 64 MiB | 0.1 | |
| postgres (shared, prod+staging+keycloak+control_plane+datamart) | 2 048 MiB | 1.5 | `shared_buffers` 512MB, `work_mem` kecil (4–8MB), `max_connections` ≈ 150 (→ 200 sejak 2026-09-23, lihat riwayat revisi); Odoo `db_maxconn` diturunkan (mis. 16) — nilai final setelah ukur |
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
| grafana | 384 MiB | 0.25 | 256 → 384 MiB (2026-09-25) |
| uptime-kuma | 320 MiB | 0.2 | 192 → 320 MiB (2026-09-25) |
| **Jumlah mem_limit platform** | **12 144 MiB** | | +256 MiB (2026-09-25) |
| **+ cadangan host** | **14 192 MiB** | | sebelumnya 13 680 (cadangan 1 536) |
| **Sisa untuk client (web Next.js per client, growth)** | **≈ 1 800 MiB** | | 15 992 − 14 192 (sebelumnya ≈ 2 312) |

> **T19 (2026-09-25):** sisa nyata perencanaan = **≈ 1 160 MiB** (≈ 584 setelah DRMS prod) dengan cadangan host 2 048 MiB (sebelumnya ≈ 1 672 / ≈ 1 096 dengan 1 536) — tabel di atas belum memuat drms-pk-stg/web-starter-staging; lihat § "Pengukuran ulang T19" §3.

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

## Pengukuran T07 (2026-09-23)

**Status angka di bagian ini: NYATA**, diambil langsung dari VPS (read-only, tanpa mengubah
konfigurasi/container apa pun — Odoo pool sedang dibangun agent lain di branch terpisah dan
tidak disentuh). Cakupan: hanya 5 container yang sudah bring-up sampai T06 — `traefik`,
`crowdsec`, `postgres`, `keycloak`, plus `whoami` (container uji sementara T03, **akan dihapus**,
bukan bagian arsitektur final). Odoo pool, mail, control-plane, observability, datamart **belum
ada** saat pengukuran ini — dampaknya, § "Kapasitas client" dan § "Threshold" di ADR ini tetap
ESTIMASI, direvisi ulang di T19 (plan 02) setelah semua service naik.

**Metodologi:** `docker stats --no-stream` 3 sampel berjarak ±60 detik (11:36:06, 11:37:09,
11:38:11 WIB, 2026-09-23), dirata-ratakan per service. Host: `free -h`/`free -m`, `swapon --show`,
`uptime`, `vmstat 5 3`, `df -h /`, `du -sh /var/lib/docker`, `docker inspect` untuk `mem_limit`/
`nanocpus` nyata yang terpasang di container.

### Host (NYATA)

| Metrik | Nyata | Sumber |
|---|---:|---|
| RAM total | 15 992 MiB (15,6 GiB) | `free -m` |
| RAM used (proses, di luar buff/cache) | 1 696 MiB | `free -m` |
| RAM buff/cache (reclaimable) | 14 390 MiB | `free -m` |
| RAM available | **14 295 MiB (≈14,0 GiB)** | `free -m` |
| Swap terpakai | 0 / 4 095 MiB | `swapon --show`, `free -m` |
| Load average (4 vCPU) | 0,17 / 0,22 / 0,39 | `uptime` |
| CPU idle (3× sampel 5 detik) | 91–97% `id`, 0% `wa`, 2–4% `us`, 0–2% `sy` | `vmstat 5 3` |
| Disk `/` | 13 G terpakai / 193 G (7%), sisa 180 G | `df -h /` |
| `/var/lib/docker` | 1,6 G (image + volume 5 container saat ini) | `du -sh` |

Kesimpulan host: **jauh dari batas** — beban CPU nyaris nol dan RAM available masih 14 GiB karena
Odoo/mail/control-plane/observability/datamart belum berjalan. Angka ini adalah **lantai (floor)**,
bukan puncak beban — jangan dipakai untuk menyimpulkan headroom platform akhir.

### Per service — ESTIMASI (ADR/CLAUDE §4) vs NYATA (rata-rata 3 sampel `docker stats`)

| Service | mem_limit cgroup nyata (`docker inspect`) | Estimasi awal (CLAUDE §4 / ADR Context) | **NYATA** mem rata-rata | % dari mem_limit | **NYATA** CPU rata-rata | Catatan |
|---|---:|---:|---:|---:|---:|---|
| traefik | 256 MiB (`nanocpus`=1.0) | ~100 MB | **30,9 MiB** | 12,1% | 0,23% | idle; hanya healthcheck + 1 test route `whoami`, belum ada trafik client nyata |
| crowdsec | 384 MiB (`nanocpus`=0.5) | ~200 MB | **68,9 MiB** | 17,9% | 0,20% | idle; belum ada beban serangan/parsing log volume tinggi |
| postgres (shared) | 2 048 MiB (`nanocpus`=1.5) | 1–2 GB | **92,0 MiB** | 4,5% | 0,00% | baru DB `keycloak` terisi kecil; belum ada beban Odoo/datamart/control-plane |
| keycloak | 1 360 MiB — `docker inspect` melaporkan 1 426 063 360 B ≈ 1,328 GiB (`nanocpus`=1.0) | 700 MB–1 GB (CLAUDE §4, **lebih rendah** dari resmi) / 1 250–1 360 MB (resmi, dipakai ADR) | **469,0 MiB** | 34,5% | 0,38% | realm `platform` + `platform-staging` sudah dibuat; admin idle; **belum** ada login SSO nyata dari Odoo/Next.js (baru T15) |
| whoami (uji T03, bukan bagian ADR §2) | 32 MiB | — | 3,4 MiB | 10,6% | 0,03% | akan dihapus, bukan bagian arsitektur final |
| **Total 5 container berjalan** | **4 080 MiB** | — | **≈664 MiB** | **16,3%** | ≈0,8% (dari 4 vCPU) | |

Cek konsistensi: `free -m` used 1 696 MiB − total mem container ≈664 MiB ≈ **1 032 MiB** overhead
host non-container nyata (kernel, systemd, dockerd RSS 128 MiB, containerd RSS 61 MiB, sshd,
fail2ban RSS 37 MiB, crowdsec-firewall-bouncer, auditd, unattended-upgrades — via `ps aux`,
`systemctl is-active` mengonfirmasi `crowdsec-firewall-bouncer`/`fail2ban`/`auditd` aktif di host).
Ini **lebih rendah** dari estimasi "Cadangan host" 1 536 MiB di § Decision poin 2 — beri sedikit
headroom tambahan, tapi **ditandai INFORMATIF saja**: overhead host akan naik lagi setelah semua
daemon §3.6 CLAUDE.md aktif penuh dan trafik nyata (Odoo, mail) berjalan.

### Penyesuaian `mem_limit` yang DISARANKAN (belum diterapkan)

Baseline T03–T06 diukur **idle / tanpa beban produksi** (belum ada client, belum ada Odoo, belum
ada trafik nyata lewat Traefik/CrowdSec). Pemakaian nyata jauh di bawah `mem_limit` yang memang
sengaja dipasang tinggi untuk menyerap lonjakan (§ Decision poin 2: "batas atas, bukan pemakaian
nyata"). **Tidak disarankan menurunkan `mem_limit` ke angka idle ini** — cap harus tetap menyerap
lonjakan (GC Keycloak saat login massal, cache Postgres saat query berat, buffer CrowdSec saat
serangan nyata).

| Service | `mem_limit` sekarang | Disarankan (BELUM diterapkan) | Alasan |
|---|---:|---|---|
| traefik | 256 MiB | **tetap** | margin ≈8× nyata sudah wajar untuk lonjakan koneksi TLS saat client bertambah |
| crowdsec | 384 MiB | **tetap** | margin ≈5,6× nyata; AppSec collections akan menambah RAM saat trafik nyata masuk |
| postgres (shared) | 2 048 MiB | **tetap** | masih idle (Odoo/datamart belum ada); `shared_buffers=512MB` saja > pemakaian nyata — **jangan diturunkan sebelum Odoo pool (T10) diukur ulang di T19** |
| keycloak | 1 360 MiB | **tetap** (angka resmi Keycloak) | nyata 34,5% dari limit tapi baru idle; heap Java butuh headroom GC saat login SSO nyata Odoo+Next.js bersamaan |
| **Cadangan host** (§ Decision poin 2) | 1 536 MiB | **usul turun → 1 152 MiB** (satu-satunya perubahan yang disarankan) | overhead host nyata terukur 1 032 MiB; 1 152 MiB masih beri margin ~120 MiB di atas nyata |

**Kesimpulan:** tidak ada perubahan `mem_limit` yang diusulkan untuk 4 service yang sudah berjalan
pada tahap T07 — data idle belum cukup untuk menurunkan cap dengan aman (risiko OOM saat beban
nyata datang). Satu-satunya angka yang disarankan berubah adalah baris "Cadangan host" di § Decision
poin 2, dari 1 536 → 1 152 MiB (−384 MiB), berdasarkan overhead host nyata 1 032 MiB + margin.
**Ini masih usulan — belum diterapkan ke compose mana pun** (sesuai SCOPE-OUT tugas ini).

### Dampak ke jumlah client (masih ESTIMASI — Odoo pool belum diukur)

- RAM tersisa nyata sekarang (host lengkap, 5 container ini saja) = **14 295 MiB (≈14 GiB)** — jauh
  di atas proyeksi § Decision poin 2 karena komponen terbesar (Odoo pool prod+staging 3 840 MiB,
  mail 1 024 MiB, control-plane 960 MiB, observability ≈1 568 MiB, datamart 384 MiB) **belum
  di-deploy**. Angka 14 GiB ini **bukan** "sisa untuk client" — jangan dipakai untuk keputusan
  onboarding client.
- Bila seluruh `mem_limit` platform di § Decision poin 2 (total 11 888 MiB) dipasang persis seperti
  rencana semula (rekomendasi T07: jangan ubah, kecuali baris "Cadangan host" di atas), proyeksi
  sisa untuk client **tetap ≈2 568 MiB**, atau **≈2 952 MiB** bila usul cadangan host 1 152 MiB
  diterima (+384 MiB) — **tidak ada bukti baru dari T07 untuk menaikkan jumlah client di § Kapasitas
  client**, karena komponen terbesar (Odoo pool, mail, observability) belum diukur nyata.
- Target § Decision poin 3 (**3–5 client kecil**) tetap dipertahankan — angka itu dibatasi oleh
  worker CPU Odoo (≈18 user konkuren/3 worker), bukan oleh RAM, dan Odoo belum diukur nyata di T07.
- **Rekomendasi Analyst:** jangan menaikkan target jumlah client berdasarkan pengukuran T07 ini.
  Ukur ulang wajib di **T19** setelah T10 (Odoo pool), T11 (mail), T12 (control-plane), T14
  (observability) selesai — baru boleh merevisi § Kapasitas client dan § Threshold dengan angka
  nyata penuh.

## Pengukuran ulang T19 (2026-09-25)

**Status angka:** setiap angka diberi label **[NYATA]** (diukur di VPS pada sesi ini, read-only) atau
**[ESTIMASI]** (turunan/perkiraan, dengan dasar yang disebut). Tidak ada restart, perubahan limit, atau uji
beban. § Decision dan § "Pengukuran T07" di atas **tidak diubah** (riwayat) — bagian ini yang berlaku untuk
keputusan kapasitas mulai 2026-09-25.

**Metodologi (2026-09-25 ±16:54–17:01 WIB):** `docker stats --no-stream` 3 sampel berjarak ±45 s (16:59:32,
17:00:20, 17:01:07) dirata-ratakan; `docker inspect` (`HostConfig.Memory`/`NanoCpus`) untuk limit yang benar-benar
terpasang; `free -m`, `swapon --show`, `uptime`, `vmstat 5 3`, `df -h /`, `du -xsh`, `docker system df [-v]`,
`docker buildx du`; `pg_database_size()` + `pg_stat_activity` via `docker exec postgres psql`; `ps` di container
Odoo; riwayat host dari Prometheus (`docker exec prometheus wget -qO- …/api/v1/query[_range]`), jendela **48 jam**
(data TSDB tersedia ±51,9 jam, sejak 2026-09-23 ±13:00). **Tidak ada riwayat per container** (cAdvisor sengaja
tidak dipasang, `observability.md` §Keputusan) → angka per container hanya snapshot, bukan p95.

### 1. Host [NYATA]

| Metrik | Snapshot 16:54 | Riwayat 48 j (Prometheus, node-exporter) |
|---|---:|---|
| RAM used (total − available) | 4 638–4 724 MiB | **p95 5 029 MiB**, **maks 10 767 MiB** (2026-09-25 12:57) |
| RAM available | 11 268–11 353 MiB | p05 10 977 MiB, **min 5 225 MiB** |
| Swap terpakai | 416 MiB / 4 095 | **maks 1 187 MiB**; > 600 MiB 07:57–10:57 tgl 25 (puncak 1 008 MiB 09:27) |
| Load 1/5/15 (4 vCPU) | 0,50 / 0,57 / 0,62 | load1 maks 9,99; load5 p95 2,69; load15 maks 4,7 |
| CPU busy (1 − idle) | `vmstat`: 12–29% | **rata-rata 16,1%**, **p95 48,2%**, maks 92,9% |
| CPU steal | `vmstat` st 4–18% | rata-rata 4,1%, p95 9,1% (hypervisor; di luar kendali kita) |
| iowait | 0% | p95 1,6% |
| Disk `/` (ext4, 193 G) | **95 G terpakai (49%)**, sisa 99 G | 36,9 GB (23-09 16:58) → **101,0 GB (25-09 16:58)** — lihat §4 |

Puncak RAM/CPU berkorelasi dengan **build image lokal**, bukan dengan service platform: 08:57 (build `web-starter:dev-*`
08:33–09:10), 10:37 (build `proyekkas-{web,migrate}:0.1.0-stg-e7e997a` 10:40), 12:57 (build `control-plane:*` 12:43 &
12:59) — waktu dari `docker images` `CreatedAt`. Build berjalan di dockerd/BuildKit (`driver-type
io.containerd.snapshotter.v1`) **di luar cgroup container mana pun → tidak dibatasi `mem_limit`**. Saat pengukuran
tidak ada container build/throwaway ProyekKas (`pk-*`) yang berjalan (`docker ps -a`: hanya 3 container
`*-migrate` Exited(0)); riwayat `docker events` tidak cukup panjang untuk menghitung frekuensinya.

**Overhead host non-container [NYATA]:** used 4 724 − jumlah container 3 033 ≈ **1 691 MiB**, termasuk `dockerd`
RSS 470 MiB (BuildKit ada di dalam dockerd), `containerd` 58 MiB, **3 proses Claude Code 918 MiB** (sesi agent
berjalan di host), sisanya kernel/systemd/sshd/fail2ban/bouncer. Slab 4,1 GiB (3,7 GiB reclaimable). → Usul T07
menurunkan "Cadangan host" ke 1 152 MiB **dibatalkan**; lihat §5.

### 2. Per container — limit terpasang vs pemakaian [NYATA, snapshot rata-rata 3 sampel]

| Container | mem_limit | cpus | Mem nyata | % limit | CPU rata2 | Catatan |
|---|---:|---:|---:|---:|---:|---|
| traefik | 256 | 1.00 | 66 | 26% | 3,7% | |
| crowdsec | 384 | 0.50 | 198 (maks 215) | 52% | 7,4% | naik dari 69 MiB (T07) — AppSec + log nyata |
| postgres | 2 048 | 1.50 | 261 | 13% | 0,4% | 18 koneksi (1 active); `shared_buffers` 512MB belum hangat |
| keycloak | 1 360 | 1.00 | 548 | 40% | 0,3% | 469 MiB saat T07 |
| odoo-pool-a (prod, workers=3) | 2 560 | 2.00 | 335 | 13% | 0,0% | proses 86–110 MiB RSS; 1 DB tenant (`demo_demo`) |
| odoo-staging (workers=2) | 1 280 | 1.00 | 411 | **32%** | 0,1% | worker 136–160 MiB RSS; 2 DB (`demo_staging`, `ssotest_staging`) |
| mailserver | 1 024 | 0.75 | 142 (maks 154) | 14% | 8,2% | ClamAV off |
| control-plane / -worker | 384 / 256 | 0.50 / 0.25 | 77 / 32 | 20% / 12% | ~0% | |
| control-plane-staging / -worker | 192 / 128 | 0.15 / 0.10 | 61 / 27 | 32% / 21% | ~0% | total 320 = ADR |
| drms-pk-stg / -worker (ProyekKas staging) | 384 / 192 | 0.75 / 0.25 | 87 / 66 | 23% / 34% | ~0% | **tidak ada di tabel § Decision** |
| web-starter-staging (Next.js client, plan 03) | 256 | 0.50 | 70 (maks 77) | 27% | 2,9% | **tidak ada di tabel § Decision** |
| prometheus | 384 | 0.25 | 87 | 23% | 1,0% | |
| node-exporter | 32 | 0.10 | 16 | 50% | 1,3% | |
| loki | 384 | 0.25 | 85 | 22% | 1,1% | |
| alloy | 192 | 0.20 | 63 | 33% | 1,7% | |
| grafana | 384 | 0.25 | 258 | **67%** | 1,6% | tertinggi relatif; limit baru 384 (2026-09-25) |
| uptime-kuma | 320 | 0.20 | 143 | 45% | 1,5% | |
| **Total 20 container** | **12 400 MiB** | **11,50** | **3 033 MiB** | **24%** | | cpus = kuota, overcommit 2,9× dari 4 vCPU (disengaja) |

Rekonsiliasi dengan tabel § Decision (12 144 MiB): − docker-socket-proxy 64 (dihapus H3) − cAdvisor 128 (tidak
dipasang) − datamart dbt 384 (**belum di-deploy**: `/opt/infra/datamart` tidak ada, tidak ada timer) + drms-pk-stg 384
+ drms-pk-stg-worker 192 + web-starter-staging 256 = **12 400 MiB = jumlah `docker inspect`** ✔.

### 3. Headroom RAM

| Basis | Perhitungan | Hasil |
|---|---|---:|
| **mem_limit (dasar perencanaan, dipertahankan) — BERLAKU, cadangan host 2 048** [NYATA limit] | 15 992 − 12 400 (berjalan) − 384 (dbt, dicadangkan) − **2 048** (cadangan host, keputusan user 2026-09-25) | **≈ 1 160 MiB** |
| … setelah DRMS **prod** (web 384 + worker 192, [ESTIMASI] = limit staging; migrate one-shot 384 hanya saat deploy) — BERLAKU | 1 160 − 576 | **≈ 584 MiB** |
| ~~mem_limit, cadangan host 1 536~~ (angka awal T19, digantikan) | 15 992 − 12 400 − 384 − 1 536 | ~~≈ 1 672 MiB~~ (turun dari ≈ 2 312) |
| ~~… setelah DRMS prod, cadangan 1 536~~ (digantikan) | 1 672 − 576 | ~~≈ 1 096 MiB~~ |
| Pemakaian nyata p95 host [NYATA] | 15 992 − p95 used 5 029 | ≈ 10 960 MiB |
| Pemakaian nyata puncak (saat build) [NYATA] | 15 992 − maks 10 767 | ≈ 5 225 MiB (+ swap 1,2 GiB terpakai) |

Pemakaian nyata container hanya 24% dari limit, sehingga RAM **tidak** menjadi hambatan nyata hari ini; hambatannya
adalah (a) aturan perencanaan "jumlah limit ≤ RAM − cadangan" (ADR ini, anti OOM berantai) dan (b) **build lokal +
sesi Claude Code yang tidak terbatasi** — itulah yang mendorong swap ke 1,19 GiB, bukan client.

### 4. Disk & runway [NYATA kecuali ditandai]

| Komponen | Ukuran | Tumbuh karena |
|---|---:|---|
| `/var/lib/containerd` (image + build cache, snapshotter containerd) | **59 G** | `docker system df`: image 35,6 GB (71 image, 19,5 GB reclaimable), **build cache 30,0 GB (23,2 GB reclaimable)**; ±10 pasang tag `proyekkas-{web ±0,35, migrate ±1,9} GB` dalam 48 j, `lh-local:13.5.0` 1,66 GB |
| `/opt/src` (checkout repo aplikasi) | **22 G** | `/opt/src/proyekkas-wt` 19 G (worktree `f4b` 15 G, `native-login` 2,7 G) |
| `/tmp`, `/root` | 2,7 G + 2,7 G | artefak sesi/tool |
| `/var/lib/docker` (volume) | 2,3 G | `trivy-cache` 1,43 GB (tidak terpakai container), 8 volume anonim 0,46 GB, `postgres_pgdata` 254 MB, `prometheus` 119 MB |
| Data platform: DB Postgres total | ≈ 186 MB | DB tenant Odoo baru ±29–30 MB (`demo_demo`, `demo_staging`, `ssotest_staging`), keycloak 15 MB, `pk_drms_stg` 18 MB |
| Filestore Odoo | 9,2 MB (pool-a) + 4,7 MB (staging) | volume `odoo_pool_a_data`, `odoo_staging_data` |
| Backup lokal restic (`/opt/infra/backups/restic`) | 74 MB | harian 01:30; dedup |
| Log (`/var/log`) / Loki / swapfile | 216 MB / 9,6 MB / 4,1 G | |

- Laju tumbuh `/` [NYATA, `deriv()` Prometheus]: **29,5 GB/hari (48 j)**, **49,9 GB/hari (24 j)**; 64 GB dalam 48 j,
  bertahap mengikuti waktu build. Batas alert 80% `df` ≈ 155 G terpakai → sisa **≈ 60 GiB**.
- **Runway sampai 80% pada laju sekarang: ≈ 1,3–2 hari** [ESTIMASI linear dari laju NYATA]. **Ini risiko
  tertinggi T19** dan hampir seluruhnya berasal dari build/dev (image, build cache, worktree), bukan data client.
- Laju data platform saja [ESTIMASI]: Postgres+filestore+restic+Prometheus+Loki < 0,2 GB/hari saat ini (Prometheus
  ±55 MB/hari, dibatasi 3 GB/15 hari; Loki 7 hari) → runway **> 1 tahun** bila build dibersihkan & dibatasi. Per client
  kecil tetap pakai angka § Decision poin 3 (DB 1–3 G/tahun, filestore 1–5 G) [ESTIMASI, belum ada data tumbuh nyata];
  restic lokal ≈ 1–1,5× data dan **berada di disk yang sama** (ADR 0006).

### 5. Kapasitas client (revisi)

**Tenant Odoo di pool-a** (per tenant: DB `<slug>_prod` [+ `_demo`] di pool-a, `<slug>_staging` di odoo-staging):
- Disk per tenant: ±30 MB DB awal + filestore MB — **tidak membatasi** [NYATA awal].
- RAM: worker Odoo memuat registry per DB yang dilayaninya. Indikasi [NYATA, lemah]: worker staging yang melayani
  2 DB 136–160 MiB vs pool-a 1 DB 99–110 MiB → **±40–50 MiB per DB per proses** [ESTIMASI]. Pool-a: 3 worker + cron +
  gevent = 5 proses → ±250 MiB per DB aktif; sisa limit 2 560 − 335 ≈ 2 225 MiB → **±8 DB aktif lagi**; per worker
  `limit_memory_soft` 640 MiB ≈ 10 DB sebelum daur ulang worker berulang [ESTIMASI].
  **odoo-staging** (2 worker + cron + gevent = 4 proses, ±200 MiB/DB): sisa 1 280 − 411 ≈ 869 MiB → **±4 DB staging
  lagi** → **staging adalah pembatas pertama**.
- CPU/konkurensi: tetap ≈ 18 user konkuren total di prod (3 worker × 6, rumus docs Odoo); CPU prod sekarang ~0%.
- **Keputusan kapasitas: +3–4 tenant Odoo kecil lagi** (≤ 5 user konkuren masing-masing; dengan DB staging; DB
  `_demo` hanya bila perlu). Target total "3–5 client kecil" § Decision poin 3 **dipertahankan** (sekarang: 1 tenant
  prod `demo` + tenant uji `ssotest` di staging). Lebih dari itu → naikkan limit odoo-staging (butuh RAM dari §3) atau
  ukur ulang dengan tenant nyata.

**Website Next.js client (256m, `web-edge`)** — pemakaian nyata 70–77 MiB (web-starter-staging, 27% limit):
- Berdasarkan mem_limit (cadangan host 2 048, BERLAKU): 1 160 / 256 = **4** tanpa DRMS prod; **2** setelah DRMS prod
  (584 / 256) — **rencanakan ≤ 2 website/env baru** sampai R3 diputuskan (sisa ±72 MiB setelah 2 site + DRMS prod
  tidak cukup untuk migrate one-shot 384 → jadwalkan deploy migrate saat build tidak berjalan). Staging tiap website
  ikut dihitung (256m per env yang hidup). *(Angka awal T19 dengan cadangan 1 536: 1 672 / 256 = 6; 1 096 / 256 = 4;
  "≤ 3–4" — digantikan.)*
- Berdasarkan pemakaian nyata (±80 MiB/site) jauh lebih banyak (> 20) — **tidak dipakai** sebagai dasar tanpa kebijakan
  overcommit yang disetujui user (lihat usulan R3).

### 6. Pemicu pindah ke dedicated instance / VPS-2 (menambah § Decision poin 4, bukan mengganti)

Per client (tetap): > 10 user konkuren puncak atau > 25 user aktif; DB > 5 GB atau filestore > 20 GB; CPU pool > 70% dan
client > 40% request; versi/addon/SLA berbeda. **Tambahan level platform (7 hari berturut-turut, di luar jendela build):**
- RAM available **p05 < 3 GiB**, atau swap terpakai > 1 GiB > 15 menit berulang;
- CPU busy **p95 > 70%** atau steal p95 > 15%;
- jumlah `mem_limit` + cadangan host (2 048 MiB) melebihi 15 992 MiB (tidak bisa menambah client tanpa overcommit);
- odoo-staging atau odoo-pool-a > 80% `mem_limit` dengan tenant nyata, atau `/web/health` lambat saat jam kerja;
- disk `/` > 70% **setelah** build cache/image dibersihkan (artinya data nyata yang tumbuh).
Urutan pemindahan yang disarankan tetap: build/CI keluar host → mail/observability ke VPS-2 → dedicated Odoo client
besar (§ Decision poin 5 dan `00-server-environment.md` §1 "Skala lanjut").

### 7. Rekomendasi (USULAN — belum diterapkan; perubahan limit/konfigurasi butuh persetujuan user)

- **R1 (mendesak, disk):** bebaskan disk build — `docker builder prune` (≈ 23 GB reclaimable), hapus tag
  `proyekkas-*`/`web-starter:dev-*`/`control-plane:dev-*` lama (sisakan tag berjalan + 1 rollback), hapus volume
  `trivy-cache` & volume anonim tak terpakai, tinjau `/opt/src/proyekkas-wt/f4b` (15 G) bersama pemilik ProyekKas.
  **Destruktif → konfirmasi user (CLAUDE.md §0.5).** Lalu cegah berulang: batas GC BuildKit di `daemon.json`
  (`builder.gc`, nilai & sintaks diverifikasi dulu dari docs Docker), pindahkan build ke CI/GHCR (image lokal masih
  `TEMPORARY(2026-09-23)`), dan pasang **alert disk `/` > 70%** + swap > 1 GiB (masih "belum" di `observability.md`).
- **R2 (RAM host) — DITERIMA user 2026-09-25 (cadangan host 2 048 MiB berlaku, §3/§5 dihitung ulang):** naikkan "Cadangan host" di perencanaan 1 536 → **2 048 MiB** (bukan turun ke 1 152 seperti usul
  T07) selama sesi Claude Code + build berjalan di host; batasi build (mis. jadwal di luar jam kerja, atau builder
  terpisah ber-limit) agar puncak 10,7 GiB/swap 1,2 GiB tidak berulang. Efek: sisa perencanaan ≈ 1 160 MiB (584
  setelah DRMS prod) → **maks 2 website Next.js baru** sampai R3 diputuskan.
- **R3 (alokasi):** pilih salah satu, perlu keputusan user: (a) turunkan limit yang terbukti longgar setelah ada data
  per container ≥ 7 hari — kandidat [ESTIMASI]: mailserver 1 024 → 640 MiB (nyata 142–154), odoo-pool-a 2 560 → 2 048
  (nyata 335, 1 tenant) — **jangan** turunkan keycloak/postgres; atau (b) kebijakan overcommit terkendali: jumlah
  limit boleh sampai RAM − cadangan + 1 GiB selama p95 nyata < 50% RAM. Untuk keduanya perlu **riwayat memori per
  container** (sekarang tidak ada): usul collector ringan (mis. timer yang menulis `docker stats` ke textfile
  node-exporter — desain/verifikasi opsi flag di tugas terpisah) sebagai prasyarat.

### 8. Tindak lanjut T19 yang disetujui user (2026-09-25)

#### 8.1 Batas GC BuildKit (R1 bagian "cegah berulang") — `ansible/roles/docker` → `/etc/docker/daemon.json`

**Kunci [NYATA, diverifikasi dari source/docs versi pin Docker Engine 29.8.1, build `464cd50` = tag `docker-v29.8.1`]:**
`builder.gc.{enabled, defaultReservedSpace, defaultMaxUsedSpace, defaultMinFreeSpace}` — struct `BuilderGCConfig` di
moby `daemon/config/builder.go` (tag `docker-v29.8.1`) dan contoh `daemon.json` di docker/cli `docs/reference/dockerd.md`
(tag `v29.8.1`). `defaultKeepStorage` = alias **usang** untuk `defaultReservedSpace` (lantai, bukan plafon) → tidak
dipakai. Nilai diparse `units.RAMInBytes` (go-units v0.5.0): `GB` = GiB (1024³), **persen tidak didukung** di
`daemon.json`. Tanpa `policy` custom → dockerd memakai 4 aturan bawaan (`daemon/internal/builder-next/worker/gc.go`
`DefaultGCPolicy`, BuildKit v0.33.0) dengan tiga ambang ini.

| Kunci | Nilai | Arti (BuildKit v0.33.0 `cache/manager.go` `calculateKeepBytes`) |
|---|---|---|
| `enabled` | `true` | GC aktif (default juga `true`; ditulis eksplisit) |
| `defaultMaxUsedSpace` | `10GB` | plafon build cache (tidak-shared) ±10 GiB |
| `defaultReservedSpace` | `2GB` | lantai: cache tidak dipangkas di bawah 2 GiB |
| `defaultMinFreeSpace` | `56GB` | pangkas cache selama statfs **Bfree** < 56 GiB. Bfree ≈ `df` Avail + ±15,6 GiB (blok reserved + overhead ext4; NYATA `df -B1 /` 2026-09-25) → setara `df` Avail ≥ ±40 GiB ≈ ≥ 20% dari 193G (Use% ≤ ±79%) |

Sebelumnya (default dihitung dari ukuran disk, `docker buildx inspect default` [NYATA]): reserved **18,63 GiB**, max
144,4 GiB, min-free 36,32 GiB — lantai 18,6 GiB itu sebabnya build cache sempat 30 GB. Catatan: `minFreeSpace` hanya
memangkas **build cache**; image, volume, dan worktree `/opt/src` tetap harus dibersihkan manual (R1, destruktif →
konfirmasi user).

**`dockerd --validate` TIDAK memeriksa isi `builder`** [NYATA]: file dengan `"defaultMaxUsedSpace": "10XB"` maupun kunci
salah ketik tetap `configuration OK`. Nilai salah → dockerd **gagal start** (`error creating buildkit instance`,
`daemon/command/daemon.go`); kunci salah ketik → diabaikan diam-diam. Karena itu verifikasi wajib lewat
`docker buildx inspect default` setelah restart.

**Dampak penerapan:** `builder` tidak ada di daftar opsi reload (SIGHUP) `dockerd.md` §"Configuration reload behavior"
maupun `daemon/reload.go` → **restart dockerd wajib**; handler role `Restart docker` (`systemctl restart docker`)
otomatis terpicu saat `daemon.json` berubah. `live-restore: true` (terpasang) → container tetap berjalan (opsi
bridge/storage driver tidak berubah, syarat live-restore docs.docker.com "Live restore upon restart"). Selama jendela
restart (± detik): Docker API/`docker compose`/`infra-job`/`infra-deploy` tidak tersedia, healthcheck & restart policy
container tidak dievaluasi, log container tertahan di FIFO 64K (proses bisa tertahan menulis log bila jendela lama).
**Terukur pada restart dockerd sebelumnya (H3, 2026-09-23, `observability.md` §Rollback): gangguan ±2 s — DNS embedded
Docker & bouncer CrowdSec sempat gagal → 403/timeout singkat di edge.** Jadwalkan di jam sepi.
GC berjalan ±1 s setelah start (throttle 1 menit) dan setelah tiap build (BuildKit `control/control.go`).

**Langkah terapkan (Lead, jendela terjadwal, tidak ada build berjalan):**
```bash
# 0. pra-cek & snapshot
pgrep -af 'buildx|docker build|compose.*build' || echo "tidak ada build"
cp -a /etc/docker/daemon.json /etc/docker/daemon.json.bak-t19
docker ps --format '{{.Names}}' | sort | xargs docker inspect -f '{{.Name}} {{.State.StartedAt}}' > /root/t19-before.txt
docker buildx inspect default | sed -n '/GC Policy/,$p' > /root/t19-gc-before.txt
# 1. terapkan (handler me-restart docker)
cd /opt/infra/ansible && /opt/ansible-venv/bin/ansible-playbook site.yml --tags docker --check --diff   # diff hanya blok "builder"
/opt/ansible-venv/bin/ansible-playbook site.yml --tags docker --diff
# 2. verifikasi
systemctl is-active docker && docker info --format 'live-restore={{.LiveRestoreEnabled}}'
docker buildx inspect default | sed -n '/GC Policy/,$p'
#   harapan: rule#0 Max Used Space 488.3MiB (512 MB minimum); rule#1–3 Reserved Space 2GiB, Max Used Space 10GiB,
#   Min Free Space 56GiB; rule#1 Keep Duration 1440h0m0s; rule#3 All: true
docker ps --format '{{.Names}}' | sort | xargs docker inspect -f '{{.Name}} {{.State.StartedAt}}' | diff /root/t19-before.txt - && echo "StartedAt tidak berubah"
docker system df   # Build Cache ≤ ±10 GB setelah GC berikutnya
systemctl start infra-healthcheck.service && systemctl status infra-healthcheck.service --no-pager | tail -5
```
**Rollback:** `cp -a /etc/docker/daemon.json.bak-t19 /etc/docker/daemon.json && systemctl restart docker` (container
tetap berjalan, live-restore), lalu `git revert` commit role agar Ansible tidak menulis ulang. Bila dockerd gagal start:
`journalctl -u docker -n 50 --no-pager` → rollback yang sama.

#### 8.2 Riwayat memori/CPU per container (prasyarat R3) — role `container_metrics` + textfile node-exporter

Timer root di host tiap 60 s (`scripts/container-metrics.sh`) membaca cgroup v2 (`memory.current`, `memory.max`,
`memory.swap.current`, `memory.stat inactive_file`, `memory.events oom_kill`, `cpu.stat usage_usec`) tiap container
yang berjalan (`docker ps` di host — tidak ada docker.sock di container) → `/var/lib/node-exporter-textfile/containers.prom`
(atomik, label `name`/`compose_project` saja) → node-exporter `--collector.textfile.directory` (bind ro) → Prometheus
(retensi 15 hari cukup untuk jendela 7 hari R3). Detail, uji, PromQL, penerapan & rollback: `docs/03-operations/
observability.md` §"Metrik per container". **RAM [ESTIMASI]:** proses oneshot ±0,5 s/menit (`MemoryMax=64M`), node-exporter
+ Prometheus ±125 seri tambahan → dapat diabaikan; tidak mengubah angka §3. Belum diterapkan (Lead).

Status ADR tetap **accepted**; angka § Decision yang berubah tidak ditimpa, dibaca bersama bagian ini.

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
