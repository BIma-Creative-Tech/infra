# Changelog

Semua perubahan penting pada repo `infra` dicatat di file ini.

Format mengikuti [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), dan proyek ini
memakai [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Versi saat ini ada di
file `VERSION`.

## [Unreleased]

### Added
- webmail (ADR 0012, plan 08, keputusan user 2026-09-25): Roundcube 1.7.4 `apache-nonroot` (digest ter-pin) di
  `https://webmail.expomedia.id` — stack `webmail/` (SQLite, uid 33, rootfs ro + tmpfs, cap_drop ALL, 256m, tanpa egress),
  login hanya `@expomedia.id` (`login_username_filter` + `username_domain_forced`), IMAP/SMTP ke `mail.expomedia.id`
  lewat network internal `webmail-mail` dengan verifikasi sertifikat; network `webmail-edge` (`--internal`, traefik);
  router `traefik/dynamic/clients/webmail-expomedia.yml` (POST login → `ratelimit-login`, `webmail-security-headers`
  SAMEORIGIN + CSP minimal). Ganti password self-service: helper `pwhelper` (Python stdlib) di container mailserver via
  `mail/config/user-patches.sh` — token, allowlist (admin@/info@/sales@), verifikasi password lama via IMAP, kebijakan +
  deny list password default, rate limit, `setup email update` via STDIN, audit tanpa password
  (`mail/scripts/pwhelper-secrets.sh`). Ops: `docs/03-operations/webmail.md`.
- mail: mailbox teknis `noreply@expomedia.id` (200M) — kredensial SMTP form kontak website expomedia prod & staging
  (sebelumnya info@); re-provision `provision-web-client.sh --smtp-user/--smtp-from noreply@expomedia.id`.
- mail (ADR 0011, keputusan user 2026-09-25): hostname klien email per domain client via TLS SNI — `mail.expomedia.id`
  (IMAP 993, SMTP 465/587, juga 25) menyajikan sertifikat LE sendiri; tanpa SNI/SNI lain tetap `mail.bimacreative.tech`;
  HELO/PTR/MX tidak berubah. Router `traefik/dynamic/platform/mail-clients.yml` (`mail-cert-expomedia`, `le-http`);
  `tls-export.py --sni-domain` (allowlist, `data/tls/<fqdn>/`, 26 unit test); `tls_server_sni_maps` inline
  (`mail/config/postfix-main.cf`) + `local_name` Dovecot 2.4 (`mail/config/dovecot.cf`, disinkron `bootstrap.sh`); role
  `mail_tls_export` `mail_tls_export_sni_domains` + unit `mail-tls-reload.{path,service}` (reload Postfix/Dovecot saat renew).
  ADR 0005 #9 direvisi. Runbook `docs/03-operations/mail.md` §Hostname mail per domain client.
- Client Expomedia Indo Karya (plan 07, discovery `docs/discovery/2026-09-25-expomedia.md`): website staging
  `https://expomedia.staging.bimacreative.tech` (`web-expomedia:dev-0e87369`, image lokal TEMPORARY, form kontak via
  `info@expomedia.id`), route `traefik/dynamic/clients/web-expomedia-staging.yml`; domain mail `expomedia.id` (DKIM `mail`,
  5 mailbox 2G + alias abuse, `0997824`). Prod menunggu DNS client (zona Dewaweb belum dilayani — REFUSED).
- infra-job (plan 05, ADR 0009, `8340a4d`): dispatcher root `/usr/local/sbin/infra-job <prod|staging>` 1.0.0 (Python stdlib) —
  jembatan job control plane → skrip root lewat spool file: validasi ketat (uid/nlink/mode/ukuran, JSON ketat, allowlist 5 tipe
  job, regex, binding instance→env, host SSO harus ada di file route tenant), kuota, dry-run pendahulu, argv tetap tanpa shell,
  env bersih, timeout per tipe, hasil JSON (RESULT allowlist + tail teredaksi), journal tanpa email, email alert; 233 unit test.
- ansible (plan 05, `c63201b`): role `infra_jobs` (user `cpjob-prod` 950 / `cpjob-staging` 951, `/var/lib/infra-jobs/<inst>`,
  `/var/log/infra-jobs`, `infra-job@.service` hardened + `infra-job-<inst>.path`, tmpfiles retensi, `/etc/infra-jobs/<inst>.conf`,
  kill switch, `infra_jobs_state=absent`); auditd watch dispatcher + `/etc/infra-jobs`. Diterapkan 2026-09-25 ±13:00 WIB.
- control plane (plan 05): worker staging (`84f8246`) dan prod (`682e32b`) uid 951/950 + bind spool rw / results ro + env
  `INFRA_JOBS_*`; web `INFRA_JOBS_INSTANCE`. `infra-job-staging.path` (J4) dan `infra-job-prod.path` (J6) enabled.
- scripts (plan 05 OBS-J5-01, `8226b7b`): `odoo-sso-user.sh` `RESULT invite=<sent|none>`; dispatcher meng-allowlist kunci `invite`.
- docs: `docs/03-operations/infra-jobs.md` (final), `control-plane.md` §Jembatan infra-job, runbook `odoo-sso-tenant.md` §CP (jalur
  control plane), laporan QA `docs/qa/2026-09-25-plan05-staging.md` (J5 + regresi J5R).
- traefik (plan 04 S3, F10/AC-S6): router `auth-oidc-backchannel` (prio 96, websecure) — `ClientIP(10.100.0.1/32)` + token/
  certs/userinfo realm `platform`/`platform-staging` → middleware baru `ratelimit-oidc-backchannel` (300/menit, burst 100);
  back-channel pool Odoo tidak lagi berbagi `ratelimit-login` dengan login manusia.
- traefik (plan 04 S3, F9/AC-S7): router tenant `<r>-oidc` (`PathPrefix(/sh_auth_oidc/)`, prio 200) di
  `templates/traefik-client.yml` + middleware `ratelimit-oidc` (20/menit, burst 20 per IP). Router tenant yang sudah ada
  mendapatkannya setelah render ulang (`render-client-route.sh`).
- scripts (plan 04 S2, `129a195`): `provision-odoo-sso.sh` (client Keycloak `odoo-<slug>-<env>`, role `odoo_access`, mapper klaim
  literal, secret file per DB, modul/ICP/provider Odoo, smoke; `--rotate-secret`, `--disable`, `--dry-run`, `--skip-smoke`; baris
  `RESULT`), `odoo-sso-user.sh` (user Keycloak + undangan, TOTP admin tenant, grant/revoke role, tautan `res.users` yang sudah ada),
  `lib/keycloak-admin.sh`, `lib/odoo_sso_kc.py`, `lib/odoo-exec.sh`.
- odoo (plan 04 S2, `08739f4`): kedua pool — env `SH_OIDC_SECRET_DIR=/run/sh-oidc`, `SH_OIDC_TRUSTED_ISSUERS`, bind ro
  `./secrets/oidc` → `/run/sh-oidc` (`create_host_path: false`); `odoo-pool-bootstrap.sh` membuat `secrets/oidc`.
- SSO Odoo prod aktif (plan 04 S6, `e169add`): tenant `demo_demo` (`demo.erp.bimacreative.tech`, client `odoo-demo-demo`, realm
  `platform`); staging: tenant regresi permanen `ssotest_staging` (`b966958`).
- docs: runbook `docs/runbooks/odoo-sso-tenant.md` (onboard, user, rotasi, offboard, troubleshooting); `keycloak.md` §Client Odoo
  per tenant; laporan QA `docs/qa/2026-09-25-plan04-{staging,prod}.md`.

### Changed
- control plane prod & staging: image `control-plane:4fc3828` → `6d94d2b` (kode = repo control-plane `v0.2.0`, tag lokal `31411f0`; staging lewat `7b85a78`
  di J4). Migrasi additive 0001–0003. Backup `control_plane_staging-20260925-130346-pre-7b85a78`,
  `control_plane_staging-20260925-134933-pre-6d94d2b`, `control_plane-20260925-135715-pre-6d94d2b`. Prod tidak tersedia ±4 s
  (13:57:18–13:57:22 WIB); pool Odoo/Traefik/Keycloak tidak di-restart. Image masih build lokal (TEMPORARY, tanpa GHCR).
- scripts (plan 05, `c63201b`): `infra-healthcheck.sh --unit-failed` menerima unit `.path` (OnFailure unit path infra-job).
- docs: plan 05 → EXECUTED (hasil, acceptance, open items); ADR 0009 §Hasil + riwayat revisi.
- odoo: submodule `addons/shared` kedua pool → `35e6a99` (`sh_auth_oidc` 19.0.1.2.0: secret per DB dari file, role gate) —
  staging `18d0b5d` (recreate 10:07 WIB ±11 s), prod `e169add` (recreate 11:05:47–11:05:55 WIB ±8 s). Backup
  `demo_staging-20260925-100640-pre-plan04`, `demo_demo-20260925-110513-pre-plan04`.
- odoo: provider `demo_staging` dimigrasi dari secret env ke sumber `file` + role gate `odoo_access` (S4).
- traefik: route tenant `demo-demo`, `demo-staging` dirender ulang dengan router `<r>-oidc` (`18d0b5d`).
- docs: `odoo.md` §SSO ditulis ulang untuk multi-tenant; plan 04 → EXECUTED (hasil + acceptance, AC-Q1 dikoreksi ke perilaku role
  gate); ADR 0008 hasil; ADR 0003 catatan revisi (secret env per tenant digantikan ADR 0008).

### Fixed
- scripts (plan 05 BUG-J5-01 High, `3ca5501`): `odoo-sso-user.sh --resend-invite` menjadi aksi tersendiri yang tidak pernah memberi
  role/membuat user/menautkan; saling eksklusif dengan `--grant`/`--revoke`, `--create-kc` ditolak; user tanpa role `odoo_access`
  atau tautan aktif → blocker. Sebelumnya resend memulihkan akses user yang sudah dicabut. `RESULT action=resend_invite`.
- crowdsec (plan 04 BUG-S5-01, `1c2a528`): false positive CRS SQLi (942100) pada POST token back-channel OIDC (±1/22 login SSO
  gagal `oauth_error=2`) — exclusion sempit `local/oidc-backchannel-exclusions`; recreate crowdsec 10:50:07–10:50:54 WIB.
- observability: `mem_limit` grafana 256m → 384m (GOMEMLIMIT 320MiB), uptime-kuma 192m → 320m (pemakaian 72–81%); ADR 0004 diperbarui.

### Security
- Orkestrasi host dari control plane tanpa Docker API/SSH/sudo/secret (ADR 0009): worker menulis job ke spool dengan uid khusus
  (bukan 1001 = `deploy`); dispatcher root = batas keamanan. QA J5: 52 kasus negatif live ditolak, 0 kebocoran secret (AC-J10),
  staging CP tidak bisa memicu job prod (AC-J9). Keterbatasan: timeout job tidak menghentikan proses `odoo` di dalam container
  (AC-J8, `infra-jobs.md` §Keterbatasan).
- SSO Odoo multi-tenant (ADR 0008): satu client Keycloak per tenant-env dengan redirect URI eksak; secret client per DB di file
  `0440 root:101` di luar git/env (tidak lagi terlihat di `docker inspect` pool prod); file dipilih dari `cr.dbname` sehingga tenant
  tidak bisa merujuk secret tenant lain; role gate `odoo_access`; signup `b2b`, provider bawaan lain OFF. QA lintas tenant 11/11
  PASS (staging) + prod smoke PASS.
- WAF: exclusion `attack-sqli` hanya untuk POST token endpoint realm `platform(-staging)` dari `10.100.0.1`; SQLi dari sumber lain
  tetap 403 (diuji).

## [0.2.0] - 2026-09-25

Rilis bertag pertama repo `infra`: mencakup semua perubahan sejak bootstrap (FASE 0/1, T01–T16, H1–H7, plan 03 web client template). `VERSION` 0.1.0 sebelumnya tidak pernah di-tag.

### Plan 03 W5 — dokumentasi & versi web client template (2026-09-25, branch `docs/docs-versioning-w5`)

#### Added
- `docs/adr/0007-web-client-ui-stack.md` (accepted): library UI website client (`motion` 13.4.3, `animejs` 4.5.0,
  `iconsax` 0.1.1 resmi — `iconsax-react`/`iconsax-reactjs` ditolak), komponen 21st.dev bersumber upstream Magic UI
  (MIT, commit `d7207e5`) karena registry 21st.dev butuh autentikasi, skill `ui-ux-pro-max` (pin `dcc40ff`, tanpa MCP
  config), tabel lisensi, CSP (`style-src 'unsafe-inline'` khusus style), form kontak Route Handler tanpa Server Action,
  network `web-edge`.
- `docs/03-operations/web-clients.md`: lokasi file, upgrade tag image, rollback, monitoring, catatan image lokal sementara
  demo `starter.staging` (`web-starter:dev-d5f6148`, TEMPORARY sampai token baca GHCR).

#### Changed
- `docs/plans/03-web-client-template.md`: status EXECUTED (W1–W4) + tabel acceptance §8 dan open items (CI GitHub belum
  terkonfirmasi, token GHCR, PageSpeed Insights final, HSTS platform `max-age=300`).
- `docs/adr/0001-stack.md` riwayat revisi → rujukan ADR 0007; `README.md` peta dokumen (ADR 0007, plan 03, runbook web client,
  `03-operations/`).

### Plan 03 W4 — demo website `starter.staging.bimacreative.tech` (2026-09-25, `ecdafb8`)

#### Added
- `staging/web-clients/starter/` + `traefik/dynamic/clients/web-starter-staging.yml` (hasil `provision-web-client.sh`).
  Image lokal `web-starter:dev-*` (TEMPORARY sampai VPS punya token baca GHCR); saat ini `web-starter:dev-d5f6148`.

### Keycloak `drms-staging` — direct access grants `proyekkas-mobile` (2026-09-25, `a6024cd`, `5b27540`)

#### Changed
- Client `proyekkas-mobile` realm `drms-staging`: direct access grants ON (login password APK native) — **staging saja**, realm prod `drms` tidak berubah, keputusan user; langkah hosts
  Windows untuk tunnel admin di docs Keycloak.

### Plan 03 W2b — network `web-edge` untuk website client (2026-09-25, branch `feat/infra-web-edge`)

#### Added
- Network `web-edge` (bridge 10.100.11.0/24, gw 10.100.11.1, bukan `--internal`) di `traefik/scripts/bootstrap.sh`;
  traefik join tanpa `gw_priority` (`traefik/docker-compose.yml`). Dokumentasi `docs/03-operations/traefik.md` §Network web-edge.

#### Changed
- `templates/web-client/docker-compose.yml`: website hanya di `web-edge` (bukan `proxy`).
- `scripts/provision-web-client.sh`: gagal jelas bila network `web-edge` tidak ada atau traefik belum terhubung.
- Runbook `web-client-onboarding.md` (prasyarat + catatan keamanan, sisa risiko antar-website di `web-edge`).

### Plan 03 W2 — template website Next.js client (2026-09-25, branch `feat/infra-web-client-template`)

#### Added
- `templates/web-client/` (`docker-compose.yml`, `docker-compose.contact.yml`, `.env.example`, `.gitignore`): service `web`
  `web-<slug>-<env>`, image tag/digest pin dari `.env`, uid 1001, `read_only` + tmpfs `/tmp` 16m & `/app/.next/cache` 64m,
  `cap_drop: [ALL]`, `no-new-privileges`, 256m / 0.5 CPU / 128 pids, healthcheck `/api/health`, json-file 10m×3, hanya
  network `proxy`, tanpa port publik. Form kontak (secret `smtp_password`) hanya lewat override `COMPOSE_FILE`.
- `templates/traefik-web-client.yml`: router `Host()` eksplisit, `crowdsec → security-headers → ratelimit-default`,
  router `POST /contact|/api/contact` dengan ratelimit 5/menit/IP, opsional `www.<host>` → 301 host kanonik, `le-http`.
- `scripts/provision-web-client.sh <slug> <prod|staging> --host --image [--www] [--contact …] | --remove`: validasi
  (slug, FQDN, image tanpa `latest`), DNS pre-check, hostname unik, render stack + route, `compose up -d`, tunggu healthy,
  HUP Traefik (`docker exec`, H7), smoke test TLS, idempoten (`changed=no`), `--remove` tanpa hapus data.
- `scripts/lib/traefik-route.sh`: `dns_precheck` + `traefik_hup` (dipindah dari `render-client-route.sh`).
- `docs/runbooks/web-client-onboarding.md`.

#### Changed
- `scripts/render-client-route.sh`: memakai `lib/traefik-route.sh` (perilaku sama; diverifikasi `demo staging` →
  `changed=no`) + menolak menimpa/menghapus file route yang bukan hasil render-nya.
- `docs/runbooks/client-domain-onboarding.md` bagian A → tautan runbook website; `docs/03-operations/traefik.md` tabel struktur.

### CI security workflows (2026-09-24, branch `ci/security-workflows`)

#### Added
- `.github/workflows/security.yml` (push `main`, PR, mingguan, manual): `actionlint`, `gitleaks` (full history,
  `.gitleaks.toml`), `semgrep` (gagal pada ERROR/HIGH/CRITICAL), `trivy-fs-config`, `hadolint`, `shellcheck`.
  Semua action di-pin commit SHA, tool = container tag+digest, `permissions: contents: read`. Menutup QA-T17A-04 (CI).
- `docs/04-development.md` — CI, cara membaca hasil, langkah branch protection untuk user.

#### Changed
- `identity/keycloak/Containerfile`: `USER 1000` eksplisit (sama dengan default base; Trivy DS-0002). Image live tidak di-rebuild.
- `scripts/lib/odoo-pools.sh`: `# shellcheck disable=SC2034` per-file (variabel dipakai skrip pemanggil via `source`).

### T11 — Mail docker-mailserver 16.0.1 (2026-09-23, branch `feat/infra-t11-mail`, diterapkan live)

#### Added
- Stack `mail/`: DMS 16.0.1 IPv4-only (`POSTFIX/DOVECOT_INET_PROTOCOLS=ipv4`), `PERMIT_DOCKER=none`, `SPOOF_PROTECTION=1`,
  Rspamd (DKIM multi-domain `allow_username_mismatch=false`, ratelimit outbound per mailbox 30/jam & per domain 200/jam),
  ClamAV/Amavis/SpamAssassin OFF, kuota 2 GiB, TLS dari `acme.json` Traefik; skrip `bootstrap.sh`, `mailbox-add.sh`.
  Mailbox `postmaster@`, `dmarc@`, alias `abuse@`; DKIM `mail._domainkey.bimacreative.tech`. Pengiriman keluar DITAHAN
  (`defer_transports`, TEMPORARY) sampai PTR diset.
- Traefik router dummy `dynamic/platform/mail.yml` (sertifikat LE `mail.bimacreative.tech`, redirect ke cp).
- CrowdSec: collections `crowdsecurity/postfix` + `crowdsecurity/dovecot`, acquisition `acquis.d/mail.yaml`, skenario lokal
  `infra/mail-postfix-sasl-bf`.
- ufw 25/465/587/993 (IPv4) via role `firewall`; monitor Uptime Kuma TCP 25 & 993; `templates/mail-client-dns.txt`;
  `docs/03-operations/mail.md`; riwayat revisi ADR 0005 (brute force via CrowdSec, bukan fail2ban DMS).

### ProyekKas client DRMS — infra F1 (2026-09-23, branch `feat/proyekkas-f1-infra`, belum diterapkan)

#### Added
- Realm Keycloak `drms` & `drms-staging` (`identity/keycloak/realm-export/drms*.json`, tanpa secret):
  role `pk-*`, client `proyekkas-web` / `proyekkas-mobile` / `proyekkas-admin-api` (ADR ProyekKas 0003); back-channel logout nonaktif.
- Postgres: DB `pk_drms`, `pk_drms_stg` + role `*_owner/_app/_ro` (`init-roles.sh`, var password di
  `bootstrap.sh`/`.env.example`), baris `pg_hba` per DB (ADR ProyekKas 0006).
- Traefik: route staging `drms-kas.staging.bimacreative.tech` (`le-http-staging`; router auth/api-v1/
  api-rest/web, buffering hanya di route upload), middleware `ratelimit-pk-api`, `buffering-pk`
  (request 10 MiB, response 16 MiB), `strip-authorization`, router token realm drms dengan
  `ratelimit-drms-kc-token` (`traefik/dynamic/clients/drms-proyekkas-*.yml`).
- `MEDIA_VOLUMES` di `scripts/lib/restic-common.sh` (butuh perubahan `backup.sh`, lihat runbook).
- Runbook `docs/runbooks/proyekkas-drms-onboarding.md`.

### FASE 1 — Planning & GATE 1 (2026-09-23)

#### Added
- ADR 0001–0006 (`docs/adr/`): pin versi stack & lisensi, TLS HTTP-01 per hostname + DNS
  manual, Odoo tanpa modul OCA (`sh_dbfilter_header` + `sh_auth_oidc`), kapasitas RAM/CPU,
  mail IPv4-only multi-domain, strategi backup restic.
- `docs/plans/00-gate1-summary.md`, `01-host-bootstrap.md` (prosedur anti-lockout SSH S0–S8),
  `02-platform-bringup.md` (dependency graph FASE 2).
- Agent baru `.claude/agents/infra-engineer.md` (Ansible, Docker Compose per stack, Traefik,
  Postgres, Keycloak, mail, CrowdSec, backup, observability).
- `docs/runbooks/emergency-console-access.md`, `docs/runbooks/client-domain-onboarding.md`.
- `docs/_templates/{adr,runbook,bug-report,plan}.md`.
- `VERSION` (`0.1.0`).

#### Changed
- **GATE 1 disetujui user (2026-09-23)** untuk seluruh ADR 0001–0006 dan plan 00–02,
  termasuk semua "Perubahan CLAUDE.md yang diusulkan" — status ADR: `proposed` → `accepted`.
- `CLAUDE.md`: pin versi §3 (Next.js 16 + Node 24, CrowdSec AppSec menggantikan Coraza,
  Grafana Alloy menggantikan Promtail, `sh_auth_oidc`/`sh_dbfilter_header` menggantikan
  modul OCA), §0.10 lisensi GPL untuk tool host, §1 tabel tim (tambah `infra-engineer`),
  §3.1 hapus `addons/oca/`, §3.2 desain ulang pemilihan DB & SSO Odoo tanpa OCA, §3.5.1
  resolver TLS hanya `le-http` (hapus `le-dns`), §3.6/§3.7 SSH port 2221 & `deploy` bukan
  anggota grup `docker`.
- `docs/00-server-environment.md`: bagian yang bertentangan dengan ADR yang disetujui
  ditandai `> UPDATED 2026-09-23` dan diperbaiki (DNS manual tanpa API, tanpa
  wildcard/DNS-01, tanpa `DNS_API_TOKEN`, owner `/opt/infra` bukan `deploy:docker`, port SSH
  2221, observability Alloy, WAF CrowdSec AppSec).
- `README.md`: diperbarui untuk mencerminkan bahwa repo ini berjalan langsung sebagai
  `/opt/infra` (bukan paket untuk disalin), plus peta dokumen lengkap.
- `.claude/agents/odoo-developer.md`, `.claude/agents/nextjs-developer.md`,
  `.claude/agents/analyst.md`: disesuaikan minimal agar konsisten dengan ADR yang disetujui
  (tanpa OCA; Next.js 16/Node 24).

### FASE 0 — Discovery (2026-09-23)

#### Added
- `docs/discovery/2026-09-23.md`: fakta environment VPS nyata (OS, jaringan, keamanan host,
  software terpasang) sebelum bootstrap apa pun.

[Unreleased]: https://github.com/bctech-adm/infra/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/bctech-adm/infra/releases/tag/v0.2.0
