# ADR 0010 — Segmentasi network Docker: network DB per konsumen, `kc-edge`, edge Odoo per env

- **Status:** accepted (GATE 1 plan 06, user 2026-09-25) — **diterapkan penuh 2026-09-26** (plan 06 EXECUTED, QA N7
  AC-06-01..16 PASS; §Results)
- **Tanggal:** 2026-09-25
- **Penulis:** Analyst (FASE 1 plan 06)
- **Terkait:** CLAUDE.md §3.2, §3.5, §3.6; QA `docs/qa/2026-09-25-t17b-platform-full.md` **QA-T17B-01** (High, B15) dan
  QA-T17B-03 (B16, sedang dikerjakan di branch `fix/infra-t17b-edge`); ADR 0003 D1 (`sh_dbfilter_header`); ADR 0008
  (back-channel OIDC pool Odoo); `docs/plans/06-network-isolation.md` (rencana eksekusi, matriks jangkauan, AC).
  Catatan: nomor 0010 di repo `infra`. Repo app ProyekKas punya ADR 0010 sendiri (App Links), tidak terkait.

## Context

Fakta (diverifikasi 2026-09-25, perintah di plan 06 §2):

1. Network `db` (`10.100.1.0/24`, `--internal`) dipakai bersama oleh **10 container**: `postgres`, `keycloak`, `odoo-pool-a`,
   `odoo-staging`, `control-plane`, `control-plane-worker`, `control-plane-staging`, `control-plane-staging-worker`,
   `drms-pk-stg`, `drms-pk-stg-worker`. Semua `pg_hba.conf` baris aplikasi memakai `10.100.1.0/24`.
2. Docker `icc: false` (daemon.json) **hanya berlaku di bridge default** `docker0`. Di network user-defined semua anggota
   saling terhubung ke semua port. Probe TCP 2026-09-25: dari `drms-pk-stg` (app klien staging) terbuka `odoo-pool-a:8069/8072`,
   `odoo-staging:8069/8072`, `keycloak:8080/9000`, `control-plane:3000`, `control-plane-staging:3000`.
3. Odoo `http_interface = 0.0.0.0` dan `sh_dbfilter_header` memercayai header `X-Sh-Odoo-Db` dari **siapa pun** yang
   bisa mencapai port Odoo (`proxy_mode = True`). Hasilnya (QA B15): login form DB prod `demo_demo` dari container staging
   klien, tanpa CrowdSec/AppSec, rate limit, atau header override Traefik.
4. Keycloak ada di `proxy` + `db` + `metrics`. Semua anggota `proxy` (uptime-kuma, grafana, control-plane{,-staging})
   dan `db` bisa membuka `keycloak:8080` langsung, termasuk `/realms/master/` dan `/admin` yang di :443 bernilai 403. Keycloak
   memakai `KC_PROXY_HEADERS=xforwarded` tanpa `proxy-trusted-addresses`, sehingga `X-Forwarded-*` dari peer mana pun dipercaya.
5. `odoo-edge` (`10.100.3.0/24`) berisi Traefik + **kedua** pool (`odoo-pool-a` prod, `odoo-staging`). Pool staging (kode addon
   staging) bisa membuka `odoo-pool-a:8069` langsung.
6. Tidak ada konsumen yang memanggil `keycloak:8080` atau `odoo-*:8069` langsung. Semua lewat URL publik Traefik:
   control plane (di `proxy`, tiba sebagai IP container-nya: `10.100.0.5`/`.6`), pool Odoo (hairpin, tiba sebagai `10.100.0.1`
   → router `auth-oidc-backchannel`), DRMS (network `drms-kc-admin-stg`, alias Traefik, tiba sebagai `10.100.9.x`). Sumber:
   access log Traefik. Satu-satunya pemakai port internal adalah Traefik (`keycloak:8080`, `odoo-*:8069/8072`) dan Prometheus
   (`keycloak:9000`).
7. Keycloak butuh **egress** SMTP `mail.bimacreative.tech:587` (SMTP realm `platform`, `platform-staging`, `drms`, `drms-staging`,
   tabel `realm_smtp_config`). Saat ini egress lewat `proxy`.

## Decision

1. **Tidak ada lagi network DB bersama.** Setiap konsumen Postgres (satu aplikasi/env, termasuk worker dan migrate-nya)
   mendapat network `--internal` sendiri, `db-<konsumen>`, dengan anggota **hanya `postgres` + konsumen itu**. Postgres
   di-attach ke semua network ini. Nama host DB di DSN tetap `postgres` (DNS Docker per network).
   Blok subnet `10.100.20.0/24`–`10.100.39.0/24` dicadangkan untuk `db-*` (alokasi di plan 06 §3.2).
2. **`pg_hba.conf` per subnet konsumen:** setiap baris `host <db> <role> <subnet db-konsumen> scram-sha-256`. Satu subnet
   hanya muncul di baris konsumennya sendiri. Baris `10.100.1.0/24` dihapus setelah migrasi. Network `db` dipensiunkan dan
   subnetnya tidak dipakai ulang.
3. **Keycloak keluar dari `proxy` dan `db`.** Network `kc-edge` (`10.100.12.0/24`, **bukan** `--internal` karena Keycloak butuh
   egress SMTP) berisi hanya Traefik + Keycloak. Di sisi Keycloak `kc-edge` memakai `gw_priority: 1`. Keycloak tetap di
   `metrics` (scrape `:9000`). Traefik join tanpa `gw_priority`, jadi `proxy` tetap gateway Traefik.
4. **Edge Odoo dipisah per env:** `odoo-edge` untuk Traefik + `odoo-pool-a` (prod), dan `odoo-edge-stg` baru (`10.100.13.0/24`,
   bukan internal karena pool butuh egress/hairpin) untuk Traefik + `odoo-staging`. Pola ini berlaku untuk pool/dedicated
   berikutnya. Untuk DRMS prod yang belum di-deploy: prod memakai `drms-kas-edge-prod` (`10.100.14.0/24`, dicadangkan) dan
   `db-drms`. `drms-kas-edge` tetap untuk staging.
5. **Defense-in-depth (lapisan aplikasi), task terpisah:**
   a. `sh_dbfilter_header` hanya memercayai `X-Sh-Odoo-Db` bila **peer TCP** (`environ['werkzeug.proxy_fix.orig']['REMOTE_ADDR']`
      bila ProxyFix sudah jalan, selain itu `REMOTE_ADDR`) ada di daftar CIDR proxy tepercaya dari env. Nama env diusulkan
      `SH_DBFILTER_TRUSTED_PROXIES`, belum ada di kode dan diputuskan odoo-developer (→ dipakai dengan nama ini, modul
      19.0.1.1.0, §Results). Nilainya subnet edge pool
      (`10.100.3.0/24` prod, `10.100.13.0/24` staging), yang setelah Decision 4 hanya berisi Traefik dan pool itu sendiri,
      jadi Traefik tidak butuh IP tetap. Peer di luar daftar ditangani fail-closed (`[]`). Bila env tidak diset, perilaku
      sekarang dipertahankan dan WARNING dicatat di log.
   b. Keycloak `proxy-trusted-addresses` (opsi ada di `keycloak-config-api-26.7.4.jar` `ProxyOptions`) = `10.100.12.0/24`.
      Status build-time atau runtime **UNVERIFIED** (infra-engineer memverifikasi dengan `kc.sh show-config` atau docs 26.7.4
      sebelum dipakai bersama `start --optimized`). → Terverifikasi **runtime** (§Results).
   c. **Tidak** mengikat Odoo `http_interface` ke satu IP. Setelah Decision 1 dan 4, satu-satunya peer non-Traefik di network
      pool adalah `postgres`. Bind ke IP butuh `ipv4_address` tetap dan healthcheck ke IP itu (sekarang `127.0.0.1`), padahal
      manfaat tambahannya kecil. Keycloak `http-host` (opsi ada di `HttpOptions`) juga **opsional**. Satu-satunya manfaatnya
      menutup `:8080` dari anggota `metrics` (prometheus, crowdsec, traefik).
6. **Aturan desain baru** (usulan CLAUDE.md §3.5, butuh persetujuan user): network DB per konsumen. Backend HTTP sensitif
   (Odoo, Keycloak, app klien) hanya di network edge khusus bersama Traefik. Prod dan staging **tidak** berbagi network
   mana pun selain lewat Postgres (yang dibatasi pg_hba).

## Alternatives

| Alternatif | Ditolak karena |
|---|---|
| `com.docker.network.bridge.enable_icc=false` di `db` | memblok **semua** trafik antar-container di network itu, termasuk konsumen → `postgres:5432`. Tidak bisa selektif per port |
| Aturan `iptables`/`DOCKER-USER` per IP container | IP container dinamis. Aturan host di luar compose rawan drift dan sulit diaudit. Docker 29 bisa memakai backend firewall berbeda. Pola network per konsumen sudah terbukti di repo (`odoo-edge`, `web-edge`, `drms-kc-admin`) |
| Hanya D-i-D aplikasi (5a/5b) tanpa segmentasi | Keycloak `/realms/master` & port 9000, Odoo `/web/login` DB lain, dan port app klien (`control-plane:3000`, `drms-pk-stg:3000`) tetap terjangkau. Satu bug di satu lapisan membuka kembali lateral movement |
| Satu network DB per **env** (`db-prod`, `db-stg`) | prod masih berbagi antara Keycloak, Odoo prod, dan control plane. App klien DRMS prod juga akan berbagi dengan Odoo prod (inti QA-T17B-01 untuk prod) |
| Postgres port di host + koneksi via gateway | melanggar CLAUDE.md §3.5 (tanpa publish port DB). Semua sumber tiba sebagai IP gateway sehingga pg_hba per subnet tidak mungkin |
| Keycloak `kc-edge` `--internal` | Keycloak kehilangan egress SMTP :587 (fakta 7). Undangan `execute-actions-email` plan 04 dan email ProyekKas akan gagal |

## Consequences

- (+) Menutup QA-T17B-01: dari container non-Traefik tidak ada lagi jalur ke Odoo :8069/:8072 atau Keycloak :8080/:9000
  (kecuali Prometheus → `keycloak:9000`, sesuai desain). Lateral ke `control-plane:3000`/`drms-pk-stg:3000` lewat `db` juga
  ikut tertutup.
- (+) pg_hba kini mengikat role ↔ network. Kredensial yang bocor tidak bisa dipakai dari container lain.
- (−) Jumlah network: +8 sekarang (`kc-edge`, `odoo-edge-stg`, 6× `db-*`), +3 dicadangkan. Postgres punya 6 interface
  (kelak lebih). Overhead memori container tidak berubah. Kernel mendapat bridge + veth + aturan firewall per network.
- (−) Onboarding konsumen DB baru butuh 3 langkah tambahan: buat `db-<x>` (bootstrap postgres), attach `postgres` (live
  `docker network connect` + compose), lalu baris pg_hba. Didokumentasikan di `postgres.md` (task docs).
- (−) Satu kali recreate per stack konsumen (downtime terukur detik–±60 s, plan 06 §6).
- Residual, **di luar ADR ini**:
  - `proxy` masih berisi control-plane, control-plane-staging, grafana, uptime-kuma, sehingga mereka saling menjangkau
    `:3000/:3001` langsung.
  - Anggota `metrics` bisa menjangkau `keycloak:8080`.
  - `web-edge` dipakai bersama semua website klien.
  - Rekomendasinya ada di plan 06 §14 (follow-up).

## Security implications

- STRIDE ringkas ada di plan 06 §5. Aset: DB tenant Odoo prod, realm Keycloak (`master`, `platform`, `drms`), DB control plane.
- Hairpin tetap sama: container di network non-internal selain `proxy` → IP publik :443 → tiba sebagai `10.100.0.1`
  (MASQUERADE). Pool staging di `odoo-edge-stg` tetap cocok dengan router `auth-oidc-backchannel`. Ini wajib diverifikasi dari
  access log (AC-06-07).
- `odoo-edge-stg` & `kc-edge` bukan `--internal`, karena sama seperti `odoo-edge` konsumennya butuh egress. Tidak ada port yang
  di-publish.
- Lisensi: tidak ada tool baru (fitur Docker/Compose/Postgres/Keycloak yang sudah dipakai).

## Rollback

Per langkah, lihat plan 06 §7. Ringkasnya:

- Sebelum langkah cleanup (S10), setiap stack dikembalikan dengan `git checkout <rev> -- <stack>/docker-compose.yml`, lalu
  `docker compose up -d`. Network `db` dan baris pg_hba `10.100.1.0/24` masih ada.
- Setelah S10: `git checkout <rev> -- postgres/ traefik/scripts/bootstrap.sh`, lalu `postgres/scripts/bootstrap.sh` (membuat
  ulang `db` 10.100.1.0/24). Setelah itu `docker network connect db postgres`, tulis pg_hba lama di tempat (`cat > …`),
  jalankan `pg_reload_conf()`, dan recreate stack konsumen dari revisi lama.

## Perubahan CLAUDE.md yang diusulkan (butuh persetujuan user; penulis ADR tidak mengedit)

- §3.5 poin pertama diganti menjadi: "Setiap stack punya network internal sendiri. Konsumen Postgres memakai network
  `db-<konsumen>` sendiri (`--internal`, anggota hanya `postgres` + konsumen), tidak ada network DB bersama, dan `pg_hba`
  per subnet konsumen. Backend HTTP hanya di network edge khusus bersama Traefik (`odoo-edge*`, `kc-edge`, `*-edge`). Prod
  dan staging tidak berbagi network edge. `proxy` hanya untuk service HTTP yang belum punya edge sendiri."
- §3.2 kalimat "database manager hanya bisa diakses control plane via jaringan internal dengan `admin_passwd`" diganti
  menjadi: "database manager tidak terjangkau dari container mana pun selain lewat Traefik (router admin + `ipallowlist-admin`).
  Provisioning DB lewat `infra-job` (ADR 0009)." Sejak ADR 0009 control plane tidak memanggil Odoo langsung.

## Results (plan 06 N3–N7, 2026-09-25/26)

Sumber: `docs/plans/06-network-isolation.md` §15, QA `docs/qa/2026-09-25-plan06-staging.md` (N4) dan
`docs/qa/2026-09-26-plan06-prod.md` (N7).

- **Decision 1–2 diterapkan:** 6 network `db-*` aktif (`db-keycloak` .20, `db-odoo-pool-a` .21, `db-odoo-staging` .22, `db-cp`
  .23, `db-cp-stg` .24, `db-drms-stg` .26; `db-drms` .25 dan `db-datamart` .27 cadangan). `pg_hba_file_rules` final 16 aturan,
  0 error, tanpa `10.100.1.0/24`. Network `db` dihapus 2026-09-26 16:08 WIB (S10). Uji silang 6 network × 10 role@db: hanya
  role konsumen sendiri lolos pg_hba.
- **Decision 3:** Keycloak = `kc-edge` (gw 10.100.12.1) + `db-keycloak` + `metrics`; `proxy` tanpa Keycloak. Egress SMTP :587
  berjalan (undangan Keycloak terkirim), Prometheus `up{job="keycloak"}=1`.
- **Decision 4:** `odoo-edge` = traefik + odoo-pool-a; `odoo-edge-stg` = traefik + odoo-staging. Back-channel OIDC pool tetap
  tiba sebagai `10.100.0.1` → `auth-oidc-backchannel@file` (prod dan staging).
- **Decision 5a (D-i-D Odoo) terverifikasi:** `sh_dbfilter_header` 19.0.1.1.0 (addons 4bd278a),
  `SH_DBFILTER_TRUSTED_PROXIES=10.100.3.0/24` (prod) / `10.100.13.0/24` (staging). Container uji di `db-odoo-staging`
  (10.100.22.4) dan `db-odoo-pool-a` (10.100.21.4) dengan `X-Sh-Odoo-Db` palsu → `/web/login` 303 `/web/database/selector`
  (tanpa DB) + WARNING `untrusted peer … ignored (fail-closed)`.
- **Decision 5b (D-i-D Keycloak) terverifikasi:** `KC_PROXY_TRUSTED_ADDRESSES=10.100.12.0/24` adalah opsi **runtime** di 26.7.4
  (tidak di `kc.sh build --help-all`; `show-config` → `(ENV)`) → tanpa rebuild. Container uji di `metrics` (10.100.5.6) dengan
  `X-Forwarded-For: 203.0.113.77` → event Keycloak `ipAddress="10.100.5.6"` (header diabaikan); lewat Traefik → `10.100.0.1`.
- **Matriks jangkauan sesudah** = plan 06 §8.2 (`scripts/net-matrix.sh --check` → `RESULT: OK`, 13 sumber; probe per-IP 30
  alamat dari 19 container). QA-T17B-01 **tertutup**.
- **Downtime terukur (vs rencana):** staging Odoo ±3 s (±11 s), staging DRMS ±33 s (≤ 40 s), prod CP ±4 s (±4 s), Traefik
  ±5 s (+5 s), Keycloak ±27 s discovery tidak tersedia (±30–60 s), prod Odoo ±7 s (±8 s). S10 recreate Postgres: error
  koneksi transien di odoo-pool-a/odoo-staging (1× masing-masing) dan control-plane-worker (2×), pulih sendiri.
- **Drift:** `docker compose --dry-run up -d` di 12 stack tanpa Recreate/Create (AC-06-15).

### Konsekuensi tambahan yang teramati

- (−) Recreate Traefik (wajib karena drift `networks:`) mendaftarkan **akun ACME baru** karena resolver `le-http` tidak punya
  `email` → CAA `accounturi` yang baru dipasang (ADR 0002 #15b) memblok sertifikat baru (403). Diperbaiki di S10 dengan
  `email` ACME (akun `acct/3793253016` stabil melewati restart). Pelajaran: setiap recreate Traefik bergantung pada akun ACME
  yang persisten; periksa `acme.json` sebelum/sesudah.
- (+) Recreate Traefik juga mengaktifkan perubahan static QA-T17B-03 (`manualRouting`): `traefik:8082/metrics` 403 dari semua
  network kecuali `metrics`.
- Residual tetap (di luar ADR ini): R1 `proxy` (pemisahan = **plan 10**, nomor 07–09 sudah terpakai), R2 `metrics` →
  `keycloak:8080`, `web-edge` bersama.
- Temuan alat uji BUG-N4-01 (`net-matrix.sh` false negative) diperbaiki e90fd9a sebelum AC prod dinilai.

## Riwayat revisi

| Tanggal | Perubahan |
|---|---|
| 2026-09-25 | Dibuat (Analyst, FASE 1 plan 06); accepted pada GATE 1 plan 06 (user). Usulan CLAUDE.md §3.5/§3.2 disetujui dan diterapkan. |
| 2026-09-26 | Diterapkan penuh (S10 selesai, `db` dihapus). Tambah §Results: downtime terukur, D-i-D 5a/5b terverifikasi (opsi Keycloak runtime), konsekuensi ACME/CAA, follow-up proxy = plan 10. |
