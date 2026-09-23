# Plan 02 — Urutan bring-up platform FASE 2 (dependency graph)

- **Status:** proposed (menunggu GATE 1) · **Tanggal:** 2026-09-23 · **Penulis:** Analyst
- **Terkait:** ADR 0001–0006; plan 01; CLAUDE.md §1.1, §3, §3.5; docs/00 §5

## 0. Catatan agent

`.claude/agents/` hanya berisi analyst, odoo-developer, nextjs-developer, qa-security, docs-versioning.
**Tidak ada agent untuk infra (Ansible/compose/Traefik/Postgres/mail).** Tabel memakai label `infra`.
Opsi untuk Lead/user: (a) **disarankan** — buat agent baru `infra-engineer.md` (Ansible, compose,
Traefik, CrowdSec, Postgres, Keycloak ops, mail, observability, backup); (b) Lead mendelegasikan ke
qa-security — ditolak karena QA lalu menguji pekerjaannya sendiri (konflik peran). Perubahan `.claude/`
di luar wewenang Analyst → pertanyaan GATE 1.

## 1. Prasyarat (sebelum task apa pun)

| ID | Prasyarat | Pemilik |
|---|---|---|
| U1 | GATE 1 disetujui (ADR 0001–0006, plan 01–02) | user |
| U2 | Reboot host (kernel 6.8.0-142) | Lead (keputusan #2) |
| U3 | Akses konsol Hostinger terverifikasi + snapshot sebelum bootstrap | user |
| U4 | Koreksi DNS (ADR 0002): hapus AAAA apex, perbaiki MX, tambah `grafana`, `_spf`, `mail` SPF, CAA `issuewild`, ubah DMARC rua | user |
| U5 | PTR `31.97.50.221 → mail.bimacreative.tech` | user (sebelum T11 kirim keluar) |
| U6 | Keputusan agent infra (§0) | user/Lead |

## 2. Dependency graph

| ID | Task | Agent | depends_on | File/dir disentuh | Paralel dengan |
|---|---|---|---|---|---|
| T01 | Ansible skeleton + role `base`,`users`,`ssh`,`firewall`,`fail2ban` + prosedur S0–S8 (plan 01) — **dengan user hadir** | infra | U1–U3 | `ansible/**` | T18 |
| T02 | Role `auditd`,`sysctl_swap`,`docker`,`unattended`,`layout`,`crowdsec_repo` | infra | T01 (site.yml & inventory dibuat T01) | `ansible/roles/{auditd,sysctl_swap,docker,unattended,layout,crowdsec_repo}/**`, `ansible/site.yml` (append) | T18 |
| T03 | Traefik v3.7.13: entrypoints `web`/`websecure`, redirect, resolver `le-http` (+ staging CA dulu), **file provider saja** (tanpa docker socket), middlewares `security-headers`, `ratelimit-default`, `ratelimit-login`, `ipallowlist-admin`, strip header; dashboard tidak publik (akses via SSH tunnel) | infra | T02, U4 (A `cp`/`auth`, CAA) | `traefik/**` | T04, T08, T09 |
| T04 | Postgres 16.15 shared: compose, init roles/DB (`keycloak`, `control_plane`, `datamart`, role per env), `pg_hba` jaringan internal, tuning ADR 0004 | infra | T02 | `postgres/**` | T03, T08, T09 |
| T05 | CrowdSec v1.8.1 container (acquis: access log Traefik, auth.log host), AppSec, plugin bouncer v1.7.1 di Traefik, firewall bouncer host (API di 127.0.0.1) | infra | T03 | `security/crowdsec/**`, `traefik/dynamic/middlewares/crowdsec.yml`, `ansible/roles/crowdsec_bouncer/**` | T06 |
| T06 | Keycloak 26.7.4: DB `keycloak`, hostname `auth.bimacreative.tech`, realm `platform` + `platform-staging`, admin console via allowlist, realm export ke git (tanpa secret) | infra | T03, T04 | `identity/keycloak/**`, `traefik/dynamic/platform/auth.yml` | T05, T08, T09 |
| T07 | ukur `docker stats` baseline T03–T06 → revisi ADR 0004 | analyst | T06 | `docs/adr/0004-capacity.md` | T10 |
| T08 | Modul `sh_dbfilter_header` (+unit test di container Odoo 19.0-20260908) | odoo-developer | T02 (Docker untuk test) | repo `odoo-addons-shared/sh_dbfilter_header/**` | T03–T06, T09 |
| T09 | Modul `sh_auth_oidc` (code+PKCE; unit test mock) | odoo-developer | T02; integrasi butuh T06 | repo `odoo-addons-shared/sh_auth_oidc/**` | T08 (dir berbeda) |
| T10 | Odoo pool-a prod + pool staging: compose, `odoo.conf` (workers, limit_*, `dbfilter`, `server_wide_modules`, `list_db=False`, `proxy_mode`), router 8069 + `/websocket`→8072, template `templates/traefik-client.yml` (header `X-Sh-Odoo-Db`, hapus `X-Odoo-Database`) | infra + odoo-developer (review odoo.conf) | T03, T04, T08 | `odoo/pool-a/**`, `staging/odoo/**`, `templates/traefik-client.yml` | T11, T12 |
| T11 | Mail DMS 16.0.1 (ADR 0005): IPv4-only, Rspamd, DKIM multi-domain, ratelimit, kuota; ufw buka 25/465/587/993; router dummy sertifikat `mail.` | infra | T03 (sertifikat), T05 (opsional collection postfix), U4, U5 | `mail/**`, `traefik/dynamic/platform/mail.yml`, `ansible/roles/firewall` (tambah port mail) | T10, T12 |
| T12 | Control plane scaffold Next.js 16 + Node 24 (ADR 0001 rekomendasi) + Auth.js OIDC ke Keycloak + docker-socket-proxy v0.5.0 (permission minimal) — entitas §3.4 + catatan `mail_domain`/`mailbox` untuk plan berikut | nextjs-developer (+infra untuk compose) | T04, T06 | repo `control-plane/**`, `web/control-plane/**` | T10, T11 |
| T13 | Backup (ADR 0006): restic 0.19.1 binary terverifikasi, `scripts/backup.sh`, `restore.sh`, timers, repo lokal, placeholder remote, alert "REMOTE NOT CONFIGURED" | infra | T04, T10, T11 | `scripts/backup.sh`, `scripts/restore.sh`, `ansible/roles/backup/**` | T14 |
| T14 | Observability ringan (ADR 0004): Prometheus v3.13.3, node-exporter, Loki 3.7.8 (7 hari), Alloy v1.19.2, Grafana 13.2.2, Uptime Kuma 2.5.5; cAdvisor opsional | infra | T03, U4 (`grafana`) | `observability/**`, `traefik/dynamic/platform/{grafana,status}.yml` | T13 |
| T15 | Integrasi SSO Odoo: pasang `sh_auth_oidc` di DB uji, client Keycloak per env | odoo-developer | T09, T10, T06 | repo addons + `identity/keycloak/realm-*.json` (client baru) | T16 |
| T16 | Staging control plane (`cp.staging`) | nextjs-developer + infra | T12 | `staging/control-plane/**` | T15 |
| T17 | QA: security baseline host (plan 01 §7) + edge (§4 di bawah) + tenant crossing Odoo + open relay mail + scan port eksternal | qa-security | T01, T02 (host); T05, T10, T11 (edge/app) | `docs/qa/**`, test scripts | — |
| T18 | Docs: README, CHANGELOG (git-cliff), runbook akses darurat konsol, runbook onboarding domain client | docs-versioning | U1 | `README.md`, `CHANGELOG.md`, `docs/runbooks/**` | T01–T16 |
| T19 | Ukur ulang kapasitas setelah semua up → revisi ADR 0004 + keputusan jumlah client | analyst | T10–T16 | `docs/adr/0004-capacity.md` | — |
| (tunda) | Datamart dbt | odoo-developer + nextjs-developer | client nyata ada | `datamart/**` | — |

Konflik file yang perlu dijaga Lead:
- `ansible/site.yml`: T01 membuat, T02/T05/T11/T13 menambah role → **serial** atau T01 membuat
  `site.yml` dengan semua role stub sekaligus sehingga task lain hanya menyentuh `roles/<nama>/`.
- `ansible/roles/firewall`: T01 dan T11 → T11 setelah T01 (sudah serial).
- `traefik/dynamic/**`: tiap task menulis **file sendiri** di `traefik/dynamic/platform/<svc>.yml` — tidak konflik.

Jalur kritis: U1–U3 → T01 → T02 → T03 → T06 → T09/T10 → T15 → T17.
Gelombang paralel: [T01‖T18] → [T02] → [T03‖T04‖T08‖T09] → [T05‖T06] → [T10‖T11‖T12‖T07] → [T13‖T14‖T15‖T16] → T17 → T19.

## 3. Aturan bring-up per service (berlaku semua task infra)

- Satu service → satu verifikasi (§0.6): `docker compose ps` healthy, `docker stats --no-stream`, `curl -I`.
- Semua compose: `restart: unless-stopped`, `mem_limit`/`cpus` dari ADR 0004, `healthcheck`, logging
  10m×3, `cap_drop: [ALL]` + `cap_add` minimal, `no-new-privileges`, non-root bila image mendukung,
  tidak publish port kecuali Traefik (80/443) dan mail (25/465/587/993) — dan firewall bouncer API di `127.0.0.1` saja.
- Sertifikat pertama kali lewat resolver staging LE; pindah ke production setelah semua router sukses.
- Router hostname di luar wildcard hanya dibuat setelah `dig` pre-check (ADR 0002 #5).

## 4. Threat model ringkas (STRIDE) — edge Traefik

Aset: sertifikat & kunci (`acme.json`), session cookie Odoo/control plane, pemilihan DB tenant,
admin UI (Traefik dashboard, Keycloak admin, Grafana, `/web/database/*`), ketersediaan layanan.
Entry point: :80, :443 (semua hostname), header HTTP dari client, katalog plugin Traefik saat start.

| STRIDE | Ancaman | Mitigasi | Verifikasi QA |
|---|---|---|---|
| S | Client memalsukan `X-Sh-Odoo-Db`/`X-Odoo-Database` untuk memilih DB tenant lain | Middleware per router menimpa `X-Sh-Odoo-Db` & menghapus `X-Odoo-Database` (ADR 0003); modul fail-closed | `curl -H 'X-Sh-Odoo-Db: other_prod' https://acme.erp.bimacreative.tech/web/login` → tetap DB acme; header `X-Odoo-Database` diabaikan |
| S | Memalsukan `X-Forwarded-For`/`-Host` untuk lolos allowlist/ratelimit | `forwardedHeaders.trustedIPs` **tidak** diset (tidak ada proxy di depan Traefik) → header forwarded dari client tidak dipercaya (perilaku default persis **UNVERIFIED** — implementer baca `entrypoints.md` §forwardedHeaders v3.7 dan uji); allowlist berbasis IP sumber | kirim `X-Forwarded-For: <IP allowlist>` dari luar → tetap 403 |
| S | Domain orang lain diarahkan ke VPS untuk mendapat sertifikat/konten | Router hanya untuk hostname terverifikasi (TXT); default router 404 | `curl -H 'Host: random.example' https://31.97.50.221 -k` → 404 |
| T | MITM/downgrade | redirect HTTP→HTTPS, HSTS (mulai `max-age` pendek, naik setelah stabil), TLS ≥1.2 | `curl -I http://cp…` → 301/308; header `Strict-Transport-Security` |
| T | Plugin katalog berubah/terkompromi | pin versi plugin; evaluasi `localPlugins` + `hash` (opsi `hash` ada di docs plugins.md) | review static config |
| R | Tidak ada jejak akses | access log JSON Traefik → CrowdSec + Loki (retensi 7 hari) | `docker logs traefik` / query Loki |
| I | Dashboard/admin terekspos | dashboard tanpa router publik; Keycloak admin, Grafana, `/web/database` via `ipallowlist-admin`; Odoo `list_db=False` | `curl -I https://auth…/admin/` dari IP luar → 403; `/web/database/manager` → 403/404 |
| I | Kebocoran `acme.json` | 600, di volume Traefik, masuk backup terenkripsi; DMS mount read-only | `stat -c %a traefik/acme.json` = 600 |
| D | Flood/brute force login | `ratelimit-default` & `ratelimit-login` (opsi `average`,`period`,`burst` — docs ratelimit.md v3.7), CrowdSec ban + firewall bouncer | uji burst → 429; decision CrowdSec muncul (`cscli decisions list`) |
| D | Rate limit LE habis → sertifikat gagal | pre-check DNS, staging CA, pantau error ACME di log | log Traefik tanpa error ACME berulang |
| E | Eksploit aplikasi (SQLi/XSS/CVE) lewat edge | CrowdSec AppSec (virtual patching + generic rules) sebagai lapisan tambahan; patch aplikasi tetap utama | payload uji aman (ZAP baseline ke staging) terblokir/terlog |
| E | Traefik mengakses Docker socket → root host | **file provider saja**, tanpa mount socket; control plane memakai docker-socket-proxy terpisah | `docker inspect traefik` tanpa mount `/var/run/docker.sock` |

## 5. Acceptance criteria FASE 2 (tingkat platform)

- `docker compose ps` semua stack: healthy; `docker stats --no-stream` ≤ `mem_limit` ADR 0004.
- `ss -tlnp` hanya: 80, 443, 2221, 25, 465, 587, 993 publik; 127.0.0.1:<crowdsec-lapi>.
- `curl -sI https://cp.bimacreative.tech` → 200/302 dengan sertifikat LE (`openssl s_client -connect cp.bimacreative.tech:443 -servername cp.bimacreative.tech </dev/null | openssl x509 -noout -issuer`).
- Uji STRIDE §4 lulus; plan 01 §7 lulus; ADR 0005 QA (swaks open relay, SPF/DKIM/DMARC pass) lulus.
- Backup: `restic snapshots` menampilkan snapshot harian; satu restore test sukses tercatat.

## 6. Rollback umum

Setiap stack independen: `docker compose down` di direktori stack (data volume tetap) → kembalikan
tag image/konfigurasi sebelumnya dari git → `up -d`. Traefik: simpan salinan `acme.json` sebelum
perubahan resolver. Host: plan 01 §9. Snapshot Hostinger sebelum T01 dan sebelum perubahan besar.
