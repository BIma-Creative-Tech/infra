# Changelog

Semua perubahan penting pada repo `infra` dicatat di file ini.

Format mengikuti [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), dan proyek ini
memakai [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Versi saat ini ada di
file `VERSION`.

## [Unreleased]

### Fixed
- observability: `mem_limit` grafana 256m → 384m (GOMEMLIMIT 320MiB), uptime-kuma 192m → 320m (pemakaian 72–81%); ADR 0004 diperbarui.

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
