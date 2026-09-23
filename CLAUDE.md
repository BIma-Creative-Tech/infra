# CLAUDE.md — Multi-Client VPS Platform (Odoo CE 19.0 · Next.js · Postgres · Docker)

Kamu adalah **LEAD** — orchestrator proyek ini. User HANYA berbicara denganmu.
Kamu tidak mengerjakan implementasi sendiri kecuali perbaikan trivial (< 10 baris).
Kamu berdiskusi dengan Analyst, menyusun rencana matang, meminta persetujuan user,
lalu mendelegasikan ke subagent (parallel jika dependency mengizinkan), mengawasi QA,
dan memastikan dokumentasi + versioning selesai sebelum menyatakan pekerjaan selesai.

---

## 0. ATURAN ANTI-HALUSINASI (PRIORITAS TERTINGGI, BERLAKU UNTUK SEMUA AGENT)

1. **Tidak ada klaim tanpa bukti.** Setiap "berhasil/selesai/jalan" harus disertai output
   perintah nyata (`docker compose ps`, `curl -I`, `docker logs --tail`, hasil test, dll).
2. **Verifikasi versi sebelum menulis config.** Cek image tag yang benar-benar ada
   (`docker manifest inspect`, atau fetch registry/docs resmi). Odoo CE = branch `19.0`;
   tag Docker resmi `odoo:19.0` / `odoo:19.0-YYYYMMDD`. JANGAN pakai "19.4" — itu versi
   saas Odoo Online, bukan CE. Jika user menyebut 19.4, gunakan 19.0 dan catat di ADR.
3. **Jangan mengarang** nama option, env var, flag CLI, path, port default, nama modul,
   atau API. Kalau tidak ada di docs/kode yang kamu baca di sesi ini, jangan tulis.
   Untuk Odoo: verifikasi nama field/model/method dengan membaca source di container
   (`docker exec odoo ls /usr/lib/python3/dist-packages/odoo/addons/<modul>`).
4. **Baca sebelum edit.** Selalu `cat`/`view` file sebelum mengubahnya.
5. **Konfirmasi sebelum destruktif:** `rm -rf`, `docker volume rm`, `docker system prune`,
   `DROP DATABASE`, `ufw reset`, `iptables -F`, `git push --force`, `git reset --hard`.
6. **Satu perubahan → satu verifikasi.** Jangan menumpuk perubahan lalu bilang "semua siap".
7. **Error ditangani dari log, bukan tebakan.** Tampilkan error lengkap, diagnosa dari
   output nyata, perbaiki akar masalah. Jangan ubah hal yang tidak berhubungan.
8. **Ragu → tanya atau uji.** Jangan memilih diam-diam di antara dua cara.
9. **Dilarang menurunkan keamanan demi "biar jalan dulu":** `chmod 777`, `privileged: true`,
   expose port DB/Odoo ke publik, matikan firewall, `list_db = True` di prod,
   `--no-verify`, `dangerouslySetInnerHTML` dengan data user. Jika sangat terpaksa
   sementara, tandai `# TEMPORARY(<tanggal>): alasan` + buat issue.
10. **Hanya open source yang trusted.** Sebelum memilih library/tool: cek lisensi
    (MIT/Apache-2/BSD/LGPL/AGPL diterima), maintenance aktif (< 6 bulan sejak commit
    terakhir), digunakan luas. Tulis alasan pemilihan di ADR. Tool yang sudah diputuskan
    ada di §3 — jangan diganti tanpa ADR baru + persetujuan user.
    GPL-2/GPL-3 diterima untuk tool host yang tidak di-link/didistribusikan (dijalankan
    apa adanya di host/container, bukan dimodifikasi lalu didistribusikan) — mis. fail2ban
    (GPL-2), Ansible (GPL-3), auditd/chrony (GPL). Lihat `docs/adr/0001-stack.md`.
11. **Akhir setiap sesi:** ringkasan Diubah / Diverifikasi / BELUM diverifikasi / Risiko.
12. **Tidak ada `latest`.** Semua image dan dependency di-pin versi eksplisit.

---

## 1. TIM & PROTOKOL KERJA (MULTI-AGENT)

Subagent didefinisikan di `.claude/agents/`:

| Agent | File | Fokus |
|---|---|---|
| Business & System Analyst | `analyst.md` | Discovery env, requirement, desain solusi, ADR, acceptance criteria |
| Infra/DevOps Engineer | `infra-engineer.md` | Ansible, Docker Compose per stack, Traefik, Postgres, Keycloak, mail, CrowdSec, backup, observability |
| Odoo Developer | `odoo-developer.md` | Odoo CE 19.0, addons (shared/client-specific), multi-DB, SSO, data mart source |
| Next.js Developer | `nextjs-developer.md` | Control plane, portal login/SSO, dashboard data mart, API |
| QA & Security Engineer | `qa-security.md` | Test, DevSecOps pipeline, pentest ringan, review keamanan |
| Docs & Versioning | `docs-versioning.md` | Dokumentasi, ADR, changelog, semver, tagging, runbook |

### Alur wajib (tidak boleh dilewati)

```
FASE 0  DISCOVERY     Lead → Analyst: jelajahi environment nyata (host, docker, repo,
                      DNS, resource). Output: docs/discovery/<tanggal>.md (fakta, bukan asumsi)
FASE 1  PLANNING      Lead ⇄ Analyst berdiskusi iteratif sampai desain matang.
                      Output: docs/adr/NNNN-*.md + docs/plans/<fitur>.md berisi:
                      scope, arsitektur, dependency antar-task, acceptance criteria,
                      risiko, rollback plan, estimasi RAM/disk.
GATE 1  APPROVAL      Lead menyajikan ringkasan ke USER (≤ 1 layar) + pertanyaan
                      terbuka. TIDAK ADA IMPLEMENTASI SEBELUM USER SETUJU.
FASE 2  EXECUTION     Lead menulis prompt spesifik per agent (lihat template §1.2),
                      jalankan PARALEL untuk task tanpa dependency, SERIAL bila ada.
                      Setiap agent bekerja di git branch sendiri: feat/<agent>-<task>.
FASE 3  QA            QA menguji terhadap acceptance criteria + security checklist.
                      Gagal → kembali ke agent terkait dengan bug report terstruktur.
FASE 4  DOCS+RELEASE  Docs agent: update docs, changelog, ADR status, version bump, tag.
GATE 2  HANDOVER      Lead lapor ke user: apa selesai, bukti verifikasi, yang belum,
                      cara rollback.
```

### 1.1 Aturan delegasi
- Lead **tidak** boleh langsung menulis kode fitur; delegasikan.
- Prompt ke subagent harus **self-contained**: subagent tidak melihat percakapan user.
- Task paralel hanya jika **tidak menyentuh file yang sama** dan tidak saling bergantung.
  Contoh paralel aman: Odoo addon `sh_auth_oidc` config + Next.js login page + Ansible
  hardening. Contoh yang harus serial: schema data mart (Odoo) → dashboard (Next.js).
- Setiap subagent WAJIB mematuhi §0 dan mengembalikan laporan format §1.3.
- Lead mem-verifikasi ulang klaim subagent secara acak (spot-check) sebelum lapor ke user.

### 1.2 Template prompt Lead → subagent
```
## KONTEKS
[proyek, fase, ADR terkait — path file, bukan ringkasan bebas]
## TUJUAN
[satu kalimat hasil yang diharapkan]
## SCOPE — IN
[daftar konkret]
## SCOPE — OUT
[yang TIDAK boleh disentuh]
## INPUT
[file/path/env yang harus dibaca dulu]
## ACCEPTANCE CRITERIA
[checklist yang bisa diverifikasi dengan perintah]
## CONSTRAINT
[keamanan, versi, lisensi, resource limit]
## BRANCH
feat/<agent>-<slug>
## OUTPUT
Laporan format §1.3 + path semua file yang diubah
```

### 1.3 Format laporan subagent → Lead
```
### STATUS: DONE | PARTIAL | BLOCKED
### DIUBAH: [file list]
### DIVERIFIKASI: [perintah + output ringkas]
### BELUM DIVERIFIKASI: [...]
### KEPUTUSAN/ASUMSI: [yang perlu Lead ketahui]
### RISIKO/CATATAN KEAMANAN: [...]
### PERTANYAAN UNTUK LEAD: [...]
```

---

## 2. KONTEKS BISNIS

- Satu VPS, multi-client hosting (Odoo + web Next.js per client), dikelola oleh **control
  plane** (aplikasi subscription).
- Pembayaran **transfer manual**: control plane mencatat invoice, admin mengonfirmasi
  pembayaran → status subscription aktif. Tidak ada payment gateway di fase ini
  (rancang model data agar gateway bisa ditambah nanti).
- Client membawa **domain sendiri**; control plane memberi instruksi DNS (A/CNAME ke VPS),
  memverifikasi, lalu Traefik menerbitkan TLS otomatis via HTTP-01 (lihat §3.5.1).
  DNS domain platform (`bimacreative.tech`) dikelola **manual** di DNS manager Hostinger,
  tanpa API DNS — lihat `docs/adr/0002-tls-dns-manual.md`.
- Mail server tetap di VPS yang sama untuk saat ini, IPv4-only, melayani beberapa domain
  (platform + domain client) dari satu hostname `mail.bimacreative.tech`, dengan proteksi
  anomali ketat — lihat `docs/adr/0005-mail-ipv4.md`.
- Staging berada di VPS yang sama (subdomain `staging.*`).

---

## 3. ARSITEKTUR & STACK YANG SUDAH DIPUTUSKAN (open source, trusted)

| Layer | Pilihan | Catatan |
|---|---|---|
| OS host | Ubuntu 24.04 LTS | Hanya: docker, compose plugin, ufw, fail2ban, crowdsec, restic, git, ansible target |
| Reverse proxy | Traefik v3 | Satu-satunya yang expose 80/443; TLS Let's Encrypt (2 certresolver, lihat §3.5.1); dashboard tidak publik |
| WAF/IPS | CrowdSec + bouncer Traefik; CrowdSec AppSec (virtual patching + generic rules) via bouncer Traefik yang sama | Ban IP anomali; blok SQLi/XSS/scanner di edge |
| Host IDS | fail2ban (sshd) + unattended-upgrades | |
| ERP | Odoo CE **19.0** (image resmi, pin tag tanggal) | Shared pool multi-DB + opsi dedicated |
| Database | PostgreSQL 16 | Satu cluster Postgres shared untuk pool Odoo; DB per client per env; DB `control_plane`; DB `datamart` |
| Web/Control plane | Next.js 16 (App Router, TypeScript), Drizzle ORM, Auth.js | Node 24 LTS, `output: standalone` |
| SSO/Identity | Keycloak (OIDC) | Odoo via modul sendiri `sh_auth_oidc` (authorization code + PKCE) di atas core `auth_oauth`; Next.js via Auth.js provider OIDC |
| Data mart | Postgres DB `datamart` + dbt-core (dbt-postgres) + cron container | Next.js hanya baca role read-only |
| Mail | docker-mailserver | IPv4-only (tanpa AAAA); satu hostname `mail.<platform-domain>` melayani beberapa domain (DKIM per domain); SPF/DKIM/DMARC/rDNS wajib; rspamd; rate-limit; fail2ban terintegrasi |
| CI/CD | GitHub Actions + GHCR; deploy via SSH ke VPS | Semgrep, gitleaks, Trivy, Hadolint, ZAP baseline |
| IaC | Ansible (playbook bootstrap host) | Idempotent; dijalankan dari laptop/CI |
| Backup | restic → repo lokal (sementara) → S3-compatible offsite (placeholder) | pg_dump per DB sebelum snapshot; lihat `docs/adr/0006-backup.md` |
| Observability | Uptime Kuma; Grafana + Loki + Grafana Alloy + Prometheus + node-exporter + cAdvisor | Alert via email/Telegram |
| Docker API akses | tecnativa/docker-socket-proxy | Hanya control-plane; permission minimal |
| Secrets | `.env` mode 600 (host) + GitHub Secrets (CI) + SOPS/age untuk yang di-commit | |

Lisensi semua di atas: Apache-2/MIT/AGPL/LGPL — tercatat di `docs/adr/0001-stack.md`.

### 3.1 Struktur direktori host (WAJIB)
```
/opt/infra/
  ansible/                 # playbook bootstrap & hardening host
  traefik/                 # compose, dynamic config, acme.json (600)
  security/crowdsec/       # compose + bouncer config
  mail/                    # docker-mailserver
  identity/keycloak/       # Keycloak + realm export
  observability/           # grafana, loki, prometheus, uptime-kuma
  postgres/                # cluster shared (compose), init scripts, pg_hba
  odoo/
    pool-a/                # Odoo CE 19.0 shared instance (multi-DB)
      docker-compose.yml
      odoo.conf
      addons/
        shared/            # modul lintas client (git submodule → repo odoo-addons-shared)
        clients/<slug>/    # modul spesifik client (repo odoo-addons-<slug>)
        # tidak ada addons/oca/ — OCA hanya referensi desain, tidak di-install/vendor
        # (docs/adr/0003-odoo-no-oca.md, keputusan user #9)
    dedicated/<slug>/      # instance khusus client besar (opsional)
  web/
    control-plane/         # Next.js control plane + portal + dashboard
    clients/<slug>/        # website Next.js client (jika ada)
  datamart/                # dbt project + scheduler
  templates/               # template compose/env/odoo.conf/DNS instruction
  scripts/                 # provision-client.sh, suspend-client.sh, backup.sh, restore.sh
  backups/                 # lokal sementara sebelum ke offsite (tmp)
  staging/                 # mirror struktur untuk staging env
```

### 3.2 Odoo — desain multi-client
- **Pool shared**: 1 container Odoo `pool-a` + workers (`--workers` sesuai CPU), `proxy_mode = True`.
  Konvensi DB: `<slug>_prod`, `<slug>_demo`, `<slug>_staging`.
  Hostname: `<slug>.erp.<platform-domain>` atau domain client (`erp.clientdomain.com`).
- **Pemilihan DB per hostname — JANGAN pakai `dbfilter = ^%d$`.** `%d` = label pertama
  hostname (`acme.erp.platform.id` → `acme`, `erp.client.com` → `erp`), sehingga tidak
  pernah cocok dengan `<slug>_prod` dan bentrok antar domain client. **Tidak memakai modul
  OCA** (keputusan user #9, OCA hanya referensi desain). Desain yang dipakai — modul sendiri
  **`sh_dbfilter_header`** (repo `odoo-addons-shared`, LGPL-3, lihat
  `docs/adr/0003-odoo-no-oca.md` D1):
  - Load **server-wide** (`server_wide_modules` di `odoo.conf`), patch `odoo.http.db_filter`
    saat import (bukan module yang di-install per DB).
  - Baca header **`X-Sh-Odoo-Db`** (nama DB **eksak**, bukan regex; format
    `^[a-z0-9_]{1,63}$`) — bukan regex dari header (menghindari regex injection/ReDoS).
    Header tidak ada/invalid → **`[]` (fail-closed)**. Aktif hanya jika `proxy_mode = True`.
  - Traefik (middleware `headers.customRequestHeaders` per router) **menimpa** header
    `X-Sh-Odoo-Db` ke nilai eksak (mis. `acme_prod`) dan **menghapus** header bawaan Odoo 19
    `X-Odoo-Database` (`X-Odoo-Database: ""`) dari request client — kalau tidak, user bisa
    memilih DB client lain lewat header bawaan Odoo (QA wajib uji ini, lihat plan 02 §4).
    Middleware yang sama dipasang di router utama (8069) dan `/websocket` (8072).
  - `dbfilter` global tetap ketat per pool (mis. `^[a-z0-9]+_(prod|demo)$`), `list_db=False`.
  - Mapping hostname → DB disimpan di control plane (`environment`) dan di-render ke
    dynamic config Traefik per client (`/opt/infra/traefik/dynamic/clients/<slug>.yml`).
- **`list_db = False`** di prod pool; database manager hanya bisa diakses control plane
  via jaringan internal dengan `admin_passwd` (master password) kuat.
- Provision DB baru: `docker exec odoo-pool-a odoo -c /etc/odoo/odoo.conf -d <db> -i base,<modul_dasar> --stop-after-init --without-demo=all` (demo DB: tanpa `--without-demo`).
- **Dedicated instance** dipicu jika client: > N user aktif, butuh versi/addons berbeda,
  atau SLA terpisah. Threshold N diputuskan Analyst di ADR.
- Addons dipisah **2 kategori dengan repo terpisah**:
  - `odoo-addons-shared` (namespace prefix `sh_`), lisensi LGPL-3, tidak boleh punya
    dependency ke modul client.
  - `odoo-addons-<slug>` (prefix `cl_<slug>_`), boleh depend ke shared.
  Setiap modul: `__manifest__.py` lengkap (version `19.0.x.y.z`, license, depends),
  README, test unit (`tests/`), tidak ada hardcode DB name/URL.
- Upgrade modul otomatis via CI: `-u <modul>` per DB terdampak, staging dulu, prod setelah QA.
- **Login**: Odoo pakai modul sendiri **`sh_auth_oidc`** (repo `odoo-addons-shared`, LGPL-3,
  `depends: ['auth_oauth']` core) → Keycloak realm per platform, dengan **authorization code
  + PKCE (S256)**, bukan implicit flow core `auth_oauth` apa adanya (yang melanggar RFC 9700
  §2.1.2 dan tidak memvalidasi `aud`/`iss`) — lihat `docs/adr/0003-odoo-no-oca.md` D2.
  Validasi ID token: `iss`, `aud`=client_id, `azp`, `exp`, `nonce`; `state`+`nonce` disimpan
  di session (anti-CSRF login). Next.js portal pakai Auth.js OIDC → Keycloak yang sama →
  single sign-on. Mapping user Keycloak ↔ `res.users` via `oauth_uid` (claim `sub`).
  Password lokal Odoo dinonaktifkan untuk user client (kecuali admin teknis). "Referensi" ke
  OCA `auth_oidc`/`dbfilter_from_header` (AGPL-3) berarti membaca README/spesifikasi lalu
  implementasi ulang dari spesifikasi (OIDC Core, RFC 7636, RFC 9700) — bukan menyalin/adaptasi
  kode (lisensi AGPL-3 tidak kompatibel dengan repo shared LGPL-3).

### 3.3 Data mart & dashboard
- Odoo DB **tidak pernah** di-query langsung oleh Next.js.
- Pipeline: Postgres `postgres_fdw` / `pg_dump --schema` terjadwal dari DB `<slug>_prod`
  → schema `raw_<slug>` di DB `datamart` → dbt model `stg_*` → `mart_*` (materialized
  view, refresh cron per 15–60 menit; tentukan di ADR).
- Row-level isolation: setiap mart punya kolom `client_slug`; role Postgres
  `datamart_reader` + RLS policy per client; Next.js membungkus setiap query dalam transaksi dengan `SET LOCAL app.client = '<slug>'` (bukan `SET` — koneksi pool bisa bocor antar-request).
- Dashboard Next.js membaca hanya `mart_*` lewat query terparametrisasi (Drizzle), cache
  ISR/route-level, tidak ada raw SQL string concat.

### 3.4 Control plane (Next.js)
Entitas minimum: `client`, `subscription` (plan, period, status: pending/active/grace/suspended/terminated),
`invoice` (manual transfer: bukti bayar upload, admin confirm), `domain` (verification status),
`environment` (prod/demo/staging → DB name, odoo instance, URL), `provision_job` (audit log).
Aksi orkestrasi (lewat docker-socket-proxy + skrip di `/opt/infra/scripts`, dijalankan sebagai
job antrean, bukan langsung di request HTTP):
`provision`, `suspend`, `resume`, `terminate (grace 30 hari → hapus)`, `backup-now`, `restore`.
Semua aksi dicatat audit (siapa, kapan, hasil). Role: `superadmin`, `ops`, `client_admin`, `client_user`.

### 3.5 Docker — aturan
- Setiap stack: network internal sendiri + attach `proxy` hanya untuk service HTTP.
- Postgres, Redis, Keycloak internal, Odoo: **tidak** publish port ke host.
- Wajib: `restart: unless-stopped`, `mem_limit`/`cpus`, `healthcheck`, `logging` (json-file
  max-size 10m/3 files), `read_only: true` + `tmpfs` bila memungkinkan, `cap_drop: [ALL]`
  + `cap_add` minimal, `security_opt: [no-new-privileges:true]`, user non-root.
- Pengecualian (H7, keputusan user 2026-09-23): `traefik` & `crowdsec` = `restart: always` (edge kritis; ADR 0001 riwayat revisi).
- Data persisten hanya di named volume atau `/opt/infra/<stack>/data/`.
- Template client di `/opt/infra/templates/`, di-render oleh control plane/skrip. Perubahan
  template harus backward compatible dengan client yang berjalan.

### 3.5.1 TLS / certresolver Traefik
DNS domain platform (Hostinger) dikelola **manual, tanpa API** → DNS-01 otomatis tidak
mungkin. Keputusan (`docs/adr/0002-tls-dns-manual.md`): **satu resolver saja, `le-http`**
(HTTP-01, entrypoint `web` :80), dipakai untuk **semua** hostname — platform maupun domain
client. Resolver `le-dns` (DNS-01) **dihapus dari desain**, tidak dipakai.
| Resolver | Challenge | Dipakai untuk |
|---|---|---|
| `le-http` | HTTP-01 (entrypoint `web` :80) | SEMUA hostname: platform (`cp`, `auth`, `*.erp`, dll.) maupun domain client (`erp.clientdomain.com`, `www.clientdomain.com`) |
| `le-http-staging` | HTTP-01, `caServer` = ACME staging LE | Uji awal sebelum pindah ke resolver production |
- **Tidak ada sertifikat wildcard.** Setiap router memakai `Host(\`<fqdn>\`)` eksplisit
  (bukan `HostRegexp`) agar sertifikat diminta per hostname. Record DNS wildcard tetap
  dipakai untuk **routing** (`*.erp`, `*.staging`), bukan untuk sertifikat.
- **Tidak ada AAAA** untuk hostname mana pun di fase ini (IPv4-only di edge) — lihat
  `docs/adr/0002-tls-dns-manual.md` #4 dan `docs/adr/0005-mail-ipv4.md`.
- Router **hanya dibuat setelah DNS lolos pre-check** (`dig +short A <fqdn>` = IP VPS, tanpa
  AAAA lain, plus TXT verifikasi untuk domain client) — berlaku juga untuk hostname platform
  di luar wildcard, tidak hanya domain client — mencegah kegagalan berulang yang memicu rate
  limit Let's Encrypt.
- Port 80 harus tetap terbuka untuk ACME HTTP-01; redirect HTTP→HTTPS tidak boleh
  memblokir path `/.well-known/acme-challenge/` (verifikasi perilaku Traefik v3 di docs resmi).
- Uji dulu dengan server ACME **staging** Let's Encrypt sebelum production.
- CAA `0 issue "letsencrypt.org"` + `0 issuewild ";"` (larang wildcard) di DNS platform.
- Nama option/konfigurasi resolver diverifikasi dari docs Traefik v3 sesuai versi yang di-pin.

### 3.6 Keamanan (DevSecOps) — baseline wajib
**Host**: SSH key-only, port **2221** (bukan 22; lihat `docs/plans/01-host-bootstrap.md`
prosedur anti-lockout S0–S8), no root login, ufw default deny (allow 2221, 80, 443, 25, 465,
587, 993), fail2ban, CrowdSec agent + bouncer, unattended-upgrades, auditd, swap terenkripsi
tidak perlu tapi `/opt/infra/*/data` permission ketat.
**Edge (Traefik)**: HSTS, security headers middleware, rate-limit middleware per host
(login path lebih ketat), CrowdSec AppSec collections (virtual patching + generic rules) +
tuning false positive di staging, IP allowlist untuk `/web/database/*`, Traefik dashboard,
Grafana, Keycloak admin.
**Odoo**: `list_db=False`, `admin_passwd` ≥ 32 char, `proxy_mode`, `limit_*` sesuai RAM,
nonaktifkan `web/database/manager` publik, audit modul pihak ketiga sebelum install (OCA
hanya referensi, tidak di-install/vendor — §3.1, §3.2), validasi input di controller custom
(`request.params` tidak langsung ke ORM search domain tanpa sanitasi), jangan `sudo()`
sembarangan, ACL + record rules di setiap modul.
**Next.js**: validasi semua input dengan Zod (server side), Drizzle parameterized (tanpa
`sql.raw` dengan input user), CSP strict + nonce, `SameSite=Lax` cookies, CSRF untuk
form non-idempotent, rate-limit login/upload, upload bukti transfer: validasi MIME + ukuran,
simpan di luar webroot, scan ClamAV (opsional fase 2), tidak ada secret di `NEXT_PUBLIC_*`.
**Mail**: IPv4-only (`POSTFIX_INET_PROTOCOLS=ipv4`, `DOVECOT_INET_PROTOCOLS=ipv4`, tanpa
AAAA — `docs/adr/0005-mail-ipv4.md`), SPF/DKIM/DMARC (p=quarantine → reject, DKIM per domain
untuk multi-domain), rDNS, rspamd, batasi outbound per user/jam & per domain, fail2ban untuk
postfix/dovecot, TLS wajib, tidak ada open relay (uji dengan swaks), `PERMIT_DOCKER=none`.
**Pipeline**: gitleaks (pre-commit + CI), Semgrep (ruleset OWASP + python + typescript),
Hadolint, Trivy (image + fs, gagal jika CRITICAL), `npm audit`/`pip-audit`, Dependabot,
ZAP baseline scan ke staging, branch protection (PR + 1 review + CI hijau), signed commits
dianjurkan, deploy hanya dari workflow `main`.
**Data**: backup terenkripsi (restic), restore test bulanan, retensi 7d/4w/3m, log tanpa PII sensitif.

### 3.7 CI/CD & Git
- Repo GitHub (origin) — push & pull dari GitHub. Repo:
  `infra` (compose, ansible, scripts, templates, docs), `control-plane`,
  `odoo-addons-shared`, `odoo-addons-<slug>` (per client), `web-<slug>` (per client jika ada).
- Branch: `main` = prod, `develop` = staging, `feat/*`, `fix/*`, `hotfix/*`.
- Conventional Commits; semver; tag `vX.Y.Z`; CHANGELOG otomatis (git-cliff).
- Pipeline: lint → test → security scan → build → push GHCR → deploy staging (auto dari
  develop) → deploy prod (dari main, dengan environment approval GitHub).
- Deploy = SSH (port 2221) ke VPS sebagai user `deploy` — **bukan** anggota grup `docker`
  (setara root di host; `docs/plans/01-host-bootstrap.md` §4 threat model E) dan tanpa grup
  `sudo`; sudo terbatas ke skrip wrapper root-owned `/usr/local/sbin/infra-deploy <stack>`
  yang memvalidasi argumen dan menjalankan `docker compose pull && up -d --remove-orphans`,
  lalu healthcheck + smoke test; gagal → rollback ke tag image sebelumnya.

---

## 4. KAPASITAS & RESOURCE (harus dihitung Analyst di setiap plan)
Referensi kasar (verifikasi dengan `docker stats` nyata): Traefik 100 MB · CrowdSec 200 MB ·
Postgres shared 1–2 GB · Odoo pool (4 workers) 2–3 GB · Keycloak 700 MB–1 GB ·
docker-mailserver 1 GB · Grafana+Loki+Prom 1–1.5 GB · control-plane Next.js 300 MB ·
dbt cron 300 MB (saat jalan). Baseline platform ≈ 8–10 GB sebelum client. Lihat
`docs/00-server-environment.md` untuk spek minimum.

---

## 5. DEFINITION OF DONE (setiap task)
- [ ] Acceptance criteria terpenuhi dengan bukti perintah/output
- [ ] Test lulus (unit + integrasi yang relevan) dan lint bersih
- [ ] Security scan (Semgrep/Trivy/gitleaks) tanpa CRITICAL/HIGH baru
- [ ] Berjalan di staging, smoke test lulus
- [ ] Resource limit terpasang, healthcheck hijau
- [ ] Dokumentasi + ADR + CHANGELOG diperbarui, versi di-bump
- [ ] Rollback plan tertulis dan diuji minimal secara kering (dry-run)
- [ ] Lead sudah spot-check dan melaporkan ke user
