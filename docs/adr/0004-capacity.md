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
| **Cadangan host** (kernel, systemd, dockerd, containerd, sshd, fail2ban, crowdsec-firewall-bouncer, auditd, page cache minimum) | 1 536 MiB | — | bukan limit; idle host sekarang ±689 MiB (discovery) |
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
| **+ cadangan host** | **13 680 MiB** | | |
| **Sisa untuk client (web Next.js per client, growth)** | **≈ 2 312 MiB** | | 15 992 − 13 680 |

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
