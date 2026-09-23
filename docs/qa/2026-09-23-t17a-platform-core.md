# QA T17a — Platform core (host, container, pipeline scan, Postgres, backup)

- **Tanggal:** 2026-09-23 · **Basis:** `main` 4bb36da · **Branch QA:** `feat/qa-t17a`
- **Penguji:** qa-security (agent) · **Acuan:** plan 01 §7, plan 02 §4–§5, ADR 0002/0003/0006, CLAUDE.md §3.5/§3.6
- **Skrip reusable:** `qa/host-checks.sh`, `qa/container-inspect.sh`, `qa/pipeline-scans.sh` (hanya baca, tanpa perubahan konfigurasi)

## Ringkasan

| Status | Jumlah |
|---|---|
| PASS | 40 |
| FAIL | 8 (High 1 · Medium 3 · Low 4) |
| NOT TESTABLE | 23 |
| **Total kontrol** | **71** |

**Sign-off: TIDAK tercapai.** Masih ada 1 temuan **High** (QA-T17A-01, CVE CRITICAL fixable di image Keycloak).
Selain itu, **seluruh uji aktif edge/aplikasi** (header, TLS, AppSec, tenant crossing, rate limit, brute force,
Keycloak/Odoo runtime, nmap eksternal) berstatus NOT TESTABLE. Uji-uji ini wajib dijalankan sebelum T17 bisa di-sign-off.

### Kenapa uji aktif edge/aplikasi berstatus NOT TESTABLE

Uji aktif dari container probe di network `proxy` (`--ip 10.100.0.250`) **dihentikan di awal sesi ini**.
Sebelum dihentikan, hanya 1 request yang terkirim (GET `https://status.bimacreative.tech/` → 200). Request itu
membuktikan IP sumber probe tiba di backend sebagai `X-Real-Ip: 10.100.0.250`. Tidak ada payload SQLi/XSS, rate limit,
brute force, atau nmap yang dijalankan. Setelah dihentikan, container probe sudah dihapus
(`docker rm -f qa-probe`) dan `cscli decisions list --ip 10.100.0.250` → `No active decisions`. Tidak ada IP yang di-ban
dan tidak ada decision yang perlu dibersihkan. **Keputusan Lead diperlukan** untuk menjadwalkan ulang uji ini,
misalnya dijalankan operator manusia dari mesin di luar VPS, yang sekaligus menghilangkan batasan metode
hairpin di bawah.

**Batasan metode probe `proxy` (untuk uji ulang):** trafik tidak melewati internet/provider, hanya IPv4, dan
parser `crowdsecurity/whitelists` mengabaikan IP privat. Karena itu, "ban otomatis setelah brute force" **tidak
bisa** dibuktikan dari `10.100.0.x`. Ban hanya bisa dibuktikan dari IP publik di luar VPS.

### Catatan dari Lead selama sesi
- Keycloak dimatikan terencana satu kali ±90 s (maintenance yang disetujui user). Downtime kedua (±60 s) diumumkan lalu **dibatalkan** oleh Lead. Tidak ada uji `auth.*` yang berjalan selama sesi.
- Service account `automation` di realm `platform` & `platform-staging` = **disengaja** (info Lead). Token-nya saat ini tanpa role (`fullScopeAllowed=false`) — sudah diketahui Lead, bukan temuan T17a. Tidak diverifikasi di sesi ini.

## Tabel kontrol

### A. Host (plan 01 §7)

| # | Kontrol | Perintah | Hasil | Status |
|---|---|---|---|---|
| A1 | sshd hardening | `sshd -T \| grep -E '^(port\|permitrootlogin\|…)'` | port 2221, permitrootlogin no, passwordauthentication no, kbdinteractiveauthentication no, maxauthtries 3, allowusers admin deploy | PASS |
| A2 | sshd hanya :2221 | `ss -tlnp` | `0.0.0.0:2221`, `[::]:2221` saja | PASS |
| A3 | Port listen host | `ss -tlnp` | publik: 80, 443 (dockerd), 2221. Lokal: 127.0.0.1:8080 (CrowdSec LAPI), resolver 127.0.0.53/54:53. Tidak ada 5432/8069/8072/8080 publik | PASS |
| A4 | ufw | `ufw status verbose` | active; deny (incoming) / allow (outgoing) / deny (routed); ALLOW 2221, 80, 443 (v4+v6); tanpa 22 | PASS |
| A5 | fail2ban jail sshd | `fail2ban-client status sshd` | jail aktif (0 banned) | PASS |
| A6 | Service aktif | `systemctl is-active auditd chrony fail2ban docker containerd crowdsec-firewall-bouncer` | active ×6 | PASS |
| A7 | auditd rules | `auditctl -l` | watch `/etc/ssh`, `/etc/sudoers(.d)`, `/etc/docker`, `/etc/restic`, `infra-deploy`, exec docker/sudo | PASS |
| A8 | swap, sysctl, TZ, locale | `swapon --show; sysctl …; timedatectl; localectl` | /swapfile 4G; 10 · 1 · 4096 · 524288; Asia/Jakarta; en_US.UTF-8 | PASS |
| A9 | Docker daemon | `docker version`, `docker compose version`, `docker info`, `daemon.json` | 29.8.1; v5.5.1; json-file true; `no-new-privileges: true`, `userland-proxy: false`, `icc: false`, log 10m×3 | PASS |
| A10 | User deploy | `id deploy; sudo -l -U deploy` | tanpa grup docker/sudo; hanya `(root) NOPASSWD: /usr/local/sbin/infra-deploy` | PASS |
| A11 | cloud-init | `grep -r ssh_pwauth /etc/cloud/cloud.cfg.d/` | `ssh_pwauth: false` | PASS |
| A12 | Ansible idempoten | `ansible-playbook -i inventories/local/hosts.yml site.yml --check --diff` | `ok=76 changed=0 failed=0` (mode **check**; run nyata ke-2 tidak dijalankan karena di luar scope non-destruktif) | PASS |
| A13 | Ansible remote dari laptop, `nc 22` gagal / `ssh -p 2221` dari laptop | — | tidak ada akses laptop | NOT TESTABLE |
| A14 | nmap semua port TCP 31.97.50.221 (dari luar/container) | — | uji aktif dihentikan (lihat ringkasan) | NOT TESTABLE |
| A15 | Eksposur IPv6 dari luar | — | tidak ada titik uji IPv6 eksternal; `ss` hanya menunjukkan `[::]:2221` | NOT TESTABLE |

### B. Container & Docker (CLAUDE.md §3.5)

| # | Kontrol | Hasil (`qa/container-inspect.sh`) | Status |
|---|---|---|---|
| B1 | `Privileged=false`, `CapDrop=[ALL]`, tanpa `CapAdd` | 9/9 container | PASS |
| B2 | `no-new-privileges:true` | 9/9 | PASS |
| B3 | `ReadonlyRootfs=true` | 9/9 | PASS |
| B4 | `mem_limit` + `cpus` | 9/9 (odoo-pool-a 2560m/2.0, odoo-staging 1280m/1.0, keycloak 1360m/1.0, postgres 2048m/1.5, crowdsec 384m/0.5, control-plane 384m/0.5, worker 256m/0.25, traefik 256m/1.0, whoami 32m/0.1) | PASS |
| B5 | User non-root | 8/9 non-root. `crowdsec` jalan sebagai root **tanpa capability** (terdokumentasi di `crowdsec.md`, butuh grup `adm`) | PASS (catatan) |
| B6 | Port binding | hanya `traefik` 0.0.0.0:80/443 dan `crowdsec` 127.0.0.1:8080 | PASS |
| B7 | docker.sock | tidak di-mount di container mana pun (Traefik file provider saja) | PASS |
| B8 | restart + logging | `unless-stopped`, json-file 10m×3 di semua container | PASS |
| B9 | Healthcheck | 8/9 healthy; **`whoami` tanpa healthcheck** (`Healthcheck.Test=[NONE]`) | FAIL → QA-T17A-06 |
| B10 | Network `db` internal | `db internal=true`, anggota: postgres, odoo-pool-a, odoo-staging, keycloak, control-plane, control-plane-worker. Postgres tidak di `proxy`/`odoo-edge` | PASS (konfigurasi) |
| B11 | `odoo-edge` hanya traefik + pool Odoo | anggota: traefik, odoo-pool-a, odoo-staging | PASS |

### C. Secret & repo

| # | Kontrol | Hasil | Status |
|---|---|---|---|
| C1 | Mode file secret | semua `.env`, `acme*.json`, `crowdsec-bouncer.key`, `master-password`, `tenants/*.admin-password`, `/etc/restic/*` = **600**; dir `secrets/`, `acme/`, `backups/`, `crowdsec/data` = **700** | PASS |
| C2 | Secret tidak di git | `git ls-files` tanpa `.env`/secret/acme; `git log -p --all` di 3 repo tidak memuat nilai secret (hanya nama variabel, placeholder `CHANGE_ME_…`, secret mock untuk test) | PASS |
| C3 | Image control-plane tanpa `.env` | `find / -name '.env*'` di image `control-plane:0.1.0-scaffold` → kosong (`.dockerignore` mengecualikan) | PASS |
| C4 | gitleaks (history) 3 repo | infra: 3 hit = **false positive** (`infra/keycloak:26.7.4-optimized` → `generic-api-key`, 2×, dan fingerprint kunci GPG APT CrowdSec yang publik); addons-shared: 0; control-plane: 0 | PASS |
| C5 | gitleaks pre-commit + CI pipeline | tidak ada `.pre-commit-config.yaml`, `.github/workflows`, atau git hook aktif di ketiga repo | FAIL → QA-T17A-04 |
| C6 | Kredensial awal admin Keycloak dihapus | `/opt/infra/identity/keycloak/.admin-credentials` **masih ada** (600 root) | FAIL → QA-T17A-07 |

### D. Pipeline scan (container sementara, tag ter-pin, `--rm`)

| # | Kontrol | Hasil | Status |
|---|---|---|---|
| D1 | trivy `traefik:v3.7.13` | 0 CRITICAL / 0 HIGH | PASS |
| D2 | trivy `odoo:19.0-20260908` | 0 / 0 | PASS |
| D3 | trivy `control-plane:0.1.0-scaffold` | 0 / 0 | PASS |
| D4 | trivy `infra/keycloak:26.7.4-optimized` | **3 CRITICAL (semua fixable)**, 7 HIGH (3 fixable) | FAIL → QA-T17A-01 |
| D5 | trivy `postgres:16.15-bookworm` | 16 CRITICAL (1 fixable: Go stdlib di `gosu`; 15 unfixed Debian: perl, zlib, sqlite, libxml2), 99 HIGH (21 fixable, semua di `gosu`) | FAIL → QA-T17A-02 |
| D6 | trivy `crowdsecurity/crowdsec:v1.8.1` | 0 CRITICAL, 26 HIGH (24 fixable: `google.golang.org/grpc`, `golang.org/x/net`) | FAIL → QA-T17A-03 |
| D7 | trivy `traefik/whoami:v1.12.0` | 0 CRITICAL, 10 HIGH fixable (Go stdlib, grpc) | FAIL → QA-T17A-05 |
| D8 | semgrep `p/owasp-top-ten` + `p/python` → `odoo-addons-shared` | 156 rule, 19 file, **0 temuan** | PASS |
| D9 | semgrep `p/owasp-top-ten` + `p/typescript` → `control-plane` | 0 temuan kode; 1 temuan supply-chain `.npmrc` tanpa `min-release-age` (Low, dicatat di QA-T17A-08) | PASS (catatan) |
| D10 | hadolint `control-plane/Dockerfile`, `keycloak/Containerfile` | Containerfile bersih; Dockerfile hanya `DL3066 info` (user non-numerik) | PASS |

### E. Postgres & backup

| # | Kontrol | Hasil | Status |
|---|---|---|---|
| E1 | pg_hba: role hanya ke DB-nya, superuser TCP ditolak | `pg_hba_file_rules`: `postgres` hanya peer lokal (TCP reject); keycloak/control_plane/datamart → DB sendiri; `odoo_pool_a` → `postgres` + `/^[a-z0-9_]+_(prod\|demo)$`; `odoo_staging` → `postgres` + `/_staging$/`; sisanya `reject`; semua dari `10.100.1.0/24` saja | PASS |
| E2 | Privilege CONNECT | `has_database_privilege`: odoo_pool_a → postgres, demo_demo (bukan demo_staging); odoo_staging → postgres, demo_staging (bukan demo_demo); keycloak → keycloak saja | PASS |
| E3 | Postgres tidak terjangkau dari `proxy`/`odoo-edge` (probe jaringan) | konfigurasi PASS (B10). Probe TCP dari container di `proxy`/`odoo-edge` tidak dijalankan (uji aktif dihentikan) | NOT TESTABLE |
| E4 | `restic snapshots` | 8 snapshot (pg-globals, db:* per DB, files) 2026-09-23 | PASS |
| E5 | `restic check` | `no errors were found` | PASS |
| E6 | Timer backup | `restic-backup.timer` (harian 01:30), `restic-prune.timer` (Min 03:00), `restic-restore-test.timer` (tgl 1 04:00) aktif. Belum pernah berjalan terjadwal (`LAST -`) | PASS |

### F. Edge & aplikasi (review konfigurasi statis vs runtime)

| # | Kontrol | Hasil | Status |
|---|---|---|---|
| F1 | Dashboard/API Traefik mati | `traefik.yml`: `api` tidak diset; entrypoint `traefik` 127.0.0.1:8080 di dalam container, tidak di-publish | PASS (config) |
| F2 | Traefik tanpa docker.sock | file provider saja (B7) | PASS |
| F3 | Header anti tenant-crossing di config | `aliasHeadersStrategy: delete` di semua entrypoint; router tenant memakai `strip-odoo-db-headers` + `X-Sh-Odoo-Db` eksak + `X-Odoo-Database: ""` | PASS (config) |
| F4 | `whoami` di `status.bimacreative.tech` memantulkan header & IP internal | Diamati (GET tunggal): body berisi IP container `10.100.0.2`, `RemoteAddr 10.100.0.3`, hostname container, semua header request | FAIL → QA-T17A-08 |
| F5 | Security header runtime (HSTS, nosniff, referrer, CSP) | uji aktif dihentikan | NOT TESTABLE |
| F6 | TLS versi/cipher (testssl / ssl-enum-ciphers) | — | NOT TESTABLE |
| F7 | Redirect http→https | — | NOT TESTABLE |
| F8 | Dashboard/API Traefik 404 (runtime) | — | NOT TESTABLE |
| F9 | Keycloak `/admin`, `/realms/master`, `/` → 403 dari non-allowlist | — | NOT TESTABLE |
| F10 | OIDC discovery 200 | — | NOT TESTABLE |
| F11 | Odoo `/web/database/*` → 403 | — | NOT TESTABLE |
| F12 | Tenant crossing (`X-Sh-Odoo-Db`, `X-Odoo-Database`, alias underscore, `?db=`) | — | NOT TESTABLE |
| F13 | Host tak dikenal → 404 | — | NOT TESTABLE |
| F14 | AppSec SQLi/XSS/traversal/`.env` → 403 | — | NOT TESTABLE |
| F15 | False positive form Odoo & login Keycloak | — | NOT TESTABLE |
| F16 | Rate limit `ratelimit-login` Odoo & Keycloak → 429 | — | NOT TESTABLE |
| F17 | Brute force login Odoo staging + cleanup decision | tidak dijalankan; tidak ada decision tersisa | NOT TESTABLE |
| F18 | `list_db=False` efektif / `/web/database/list` Access Denied | — | NOT TESTABLE |
| F19 | Password `admin` default ditolak di prod | — | NOT TESTABLE |
| F20 | Cookie flags `session_id` (tanpa Secure — sudah diketahui, `odoo.md`) | tidak diamati ulang | NOT TESTABLE |
| F21 | Keycloak brute force detection realm `platform` (runtime) | butuh user uji → butuh kredensial admin | NOT TESTABLE |
| F22 | Keycloak registration off (runtime) | — | NOT TESTABLE |
| F23 | Ban CrowdSec otomatis setelah brute force | mustahil dari IP privat (whitelist parser); butuh IP publik eksternal | NOT TESTABLE |

Hitungan per baris tabel: PASS 40 (A1–A12, B1–B8, B10–B11, C1–C4, D1–D3, D8–D10, E1–E2, E4–E6, F1–F3) · FAIL 8 (B9, C5, C6, D4–D7, F4) · NOT TESTABLE 23 (A13–A15, E3, F5–F23).

## Bug report

### QA-T17A-01 · High · Keycloak image (`infra/keycloak:26.7.4-optimized`)
- **Langkah reproduksi:**
  `docker run --rm -v /var/run/docker.sock:/var/run/docker.sock:ro aquasec/trivy:0.74.0 image --scanners vuln --severity CRITICAL infra/keycloak:26.7.4-optimized`
- **Hasil aktual:** 3 CRITICAL, semuanya fixable: `CVE-2026-75595` `io.netty:netty-handler` 4.1.136.Final (fix 4.1.137.Final / 4.2.17.Final); `CVE-2026-8763` `org.bouncycastle:bcprov-jdk18on` 1.84 (fix 1.85) — 2 entri. Ditambah 7 HIGH (3 fixable: bcprov, mssql-jdbc).
- **Hasil diharapkan:** 0 CRITICAL (CLAUDE.md §3.6: Trivy gagal jika CRITICAL; DoD §5).
- **Bukti:** `trivy-infra_keycloak_26.7.4-optimized.json` (ringkasan: `CRIT total/fixable=3/3 HIGH total/fixable=7/3`).
- **Rekomendasi:** cek rilis patch Keycloak 26.7.x yang lebih baru (tag + digest, `docker buildx imagetools inspect`) yang sudah membawa netty/bouncycastle terbaru, lalu rebuild `Containerfile`. Keycloak ada di jalur publik, jadi prioritasnya tinggi. Bila belum ada rilis: nilai apakah komponen rentan bisa dijangkau (netty dipakai di jalur HTTP Keycloak) dan catat risk acceptance dengan tanggal kedaluwarsa.
- **Agent tujuan:** infra-engineer

### QA-T17A-02 · Medium · Postgres image (`postgres:16.15-bookworm`)
- **Langkah reproduksi:** `… trivy:0.74.0 image --scanners vuln --severity HIGH,CRITICAL postgres:16.15-bookworm`
- **Hasil aktual:** 16 CRITICAL. 1 fixable (`CVE-2025-68121` Go stdlib v1.24.6 di binary `gosu`); 15 **unfixed** Debian (perl `CVE-2026-13221/42496/8376`, zlib `CVE-2023-45853`, sqlite `CVE-2025-7458`, libxml2 `CVE-2026-6653`). 99 HIGH (21 fixable, semua `gosu`).
- **Hasil diharapkan:** 0 CRITICAL fixable; CRITICAL unfixed dicatat sebagai risk acceptance.
- **Bukti:** `trivy-postgres_16.15-bookworm.json`.
- **Konteks severity:** container jalan sebagai `999:999` tanpa memanggil `gosu` (`postgres.md`), network `db` internal, tanpa port publish. Paket rentan tidak berada di jalur protokol Postgres, jadi eksploitabilitas rendah. Karena itu diberi Medium, bukan High.
- **Rekomendasi:** naikkan ke tag 16.x terbaru (atau varian `-alpine`/rebuild yang membawa `gosu` baru); dokumentasikan CVE unfixed di ADR/issue dengan tinjauan ulang berkala; tambahkan `.trivyignore` beralasan hanya setelah Lead setuju.
- **Agent tujuan:** infra-engineer

### QA-T17A-03 · Medium · CrowdSec image (`crowdsecurity/crowdsec:v1.8.1`)
- **Langkah reproduksi:** `… trivy:0.74.0 image --scanners vuln --severity HIGH,CRITICAL crowdsecurity/crowdsec:v1.8.1`
- **Hasil aktual:** 0 CRITICAL, 26 HIGH (24 fixable) di dependency Go `google.golang.org/grpc` (crowdsec, cscli, plugin notification-*) dan `golang.org/x/net` (binary `yq`).
- **Hasil diharapkan:** tanpa HIGH fixable (DoD §5 "tanpa CRITICAL/HIGH baru").
- **Bukti:** `trivy-crowdsecurity_crowdsec_v1.8.1.json`.
- **Rekomendasi:** cek rilis CrowdSec v1.8.x terbaru dan pin tag+digest-nya. Plugin notifikasi tidak dipakai, sehingga risiko nyata terfokus pada binary `crowdsec`/`cscli`.
- **Agent tujuan:** infra-engineer

### QA-T17A-04 · Medium · Pipeline DevSecOps (repo infra, odoo-addons-shared, control-plane)
- **Langkah reproduksi:** `for r in /opt/infra /opt/src/odoo-addons-shared /opt/src/control-plane; do ls $r/.pre-commit-config.yaml $r/.github/workflows; ls $r/.git/hooks | grep -v sample; done`
- **Hasil aktual:** tidak ada konfigurasi pre-commit, tidak ada workflow CI, dan tidak ada hook aktif. Scan hanya berjalan manual (sesi QA ini).
- **Hasil diharapkan:** CLAUDE.md §3.6 Pipeline: gitleaks pre-commit + CI, Semgrep, Hadolint, Trivy, npm audit/pip-audit, branch protection.
- **Bukti:** output perintah di atas kosong. Plan 02 tidak memiliki task CI (T01–T19).
- **Rekomendasi:** tambahkan task CI/pre-commit ke plan (Lead). Sementara itu, `qa/pipeline-scans.sh` bisa dipakai sebagai gate manual sebelum merge.
- **Agent tujuan:** infra-engineer (CI), Lead (penjadwalan)

### QA-T17A-05 · Low · `traefik/whoami:v1.12.0` (router uji)
- **Langkah reproduksi:** `… trivy:0.74.0 image --severity HIGH,CRITICAL traefik/whoami:v1.12.0`
- **Hasil aktual:** 10 HIGH fixable (Go stdlib, grpc).
- **Hasil diharapkan:** tidak ada container uji dengan HIGH fixable yang terekspos publik.
- **Rekomendasi:** hapus `whoami` + `dynamic/test/whoami-status.yml` sesegera mungkin (rencananya di T14). Temuan ini digabung dengan QA-T17A-06/08.
- **Agent tujuan:** infra-engineer

### QA-T17A-06 · Low · `whoami` tanpa healthcheck
- **Langkah reproduksi:** `docker inspect whoami --format '{{.Config.Healthcheck}}'` → `map[Test:[NONE]]`
- **Hasil diharapkan:** CLAUDE.md §3.5 mewajibkan healthcheck.
- **Rekomendasi:** hapus container uji (lihat QA-T17A-05) atau tambahkan healthcheck.
- **Agent tujuan:** infra-engineer

### QA-T17A-07 · Low · Kredensial awal admin Keycloak masih di disk
- **Langkah reproduksi:** `stat -c '%a %U %n' /opt/infra/identity/keycloak/.admin-credentials` → `600 root …`
- **Hasil aktual:** file password awal `platform-admin` (40 char) masih ada. `keycloak.md` mengharuskan `shred -u` setelah login pertama (UPDATE_PASSWORD + CONFIGURE_TOTP). File juga ikut ke snapshot restic `files`.
- **Hasil diharapkan:** file dihapus setelah admin menyelesaikan required actions.
- **Rekomendasi:** pastikan `platform-admin` sudah login dan mengganti password + TOTP, lalu `shred -u` file tersebut. Isi file tidak dibaca oleh QA.
- **Agent tujuan:** Lead / user (aksi manual admin), infra-engineer (verifikasi)

### QA-T17A-08 · Low · `status.bimacreative.tech` (whoami) membocorkan detail internal + `.npmrc`
- **Langkah reproduksi:** dari IP mana pun: `curl -s https://status.bimacreative.tech/`
- **Hasil aktual:** respons memuat hostname container, IP internal (`10.100.0.2`, `RemoteAddr 10.100.0.3`), dan semua header request (termasuk `X-Forwarded-Server`, `X-Real-Ip`).
- **Hasil diharapkan:** tidak ada endpoint publik yang memantulkan topologi internal.
- **Bukti:** 1 request dari probe `10.100.0.250` → 200 dengan isi di atas.
- **Rekomendasi:** sama dengan QA-T17A-05 (hapus router uji). Tambahan (supply chain, semgrep): pertimbangkan `min-release-age` di `/opt/src/control-plane/.npmrc` (nama opsi persis harus diverifikasi di docs npm versi yang dipakai).
- **Agent tujuan:** infra-engineer; nextjs-developer (`.npmrc`)

## Artefak & metode

- Image tool (dihapus otomatis `--rm`): `zricethezav/gitleaks:v8.30.1`, `aquasec/trivy:0.74.0`, `semgrep/semgrep:1.177.0`,
  `hadolint/hadolint:v2.15.1`, probe `curlimages/curl:8.22.0`. Trivy memakai mount `docker.sock` **read-only** di container
  sementara untuk membaca image lokal. Ini pengecualian QA sementara (container dihapus setelah scan); alternatif tanpa
  socket ada di komentar `qa/pipeline-scans.sh`.
- Output mentah (JSON gitleaks/trivy/semgrep) disimpan di scratchpad sesi, tidak di-commit (bisa memuat path/cuplikan).
  Jalankan ulang: `sudo qa/pipeline-scans.sh <dir>`.
- Tidak ada konfigurasi, container, atau decision CrowdSec yang diubah. Tidak ada secret yang ditampilkan (password restic dibaca via `RESTIC_PASSWORD_FILE`).
