# Changelog

Semua perubahan penting pada repo `infra` dicatat di file ini.

Format mengikuti [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), dan proyek ini
memakai [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Versi saat ini ada di
file `VERSION`.

## [Unreleased]

### Fixed
- crowdsec AppSec rule **19104** (2026-10-05): password grant client `admin-cli` di realm `drms`/`drms-staging` diblok di
  edge (403) — Keycloak 26 tidak mengizinkan mengubah client bawaan itu. `docs/03-operations/crowdsec.md`.
- ci_runner supervisor (2026-10-05): watchdog **job diterima tapi tidak pernah mulai** — `Acknowledging runner request`
  tanpa `Running job:` dalam `CI_ACK_GRACE` (600 s) → container dibuang + registrasi ulang + metrik stuck (alert). Insiden
  01:25 WIB: runner tergantung ±5,7 jam, image prod 0.6.0 tertahan. Runbook `docs/03-operations/ci-runner.md`.
- ci_runner image **build 4** (2026-10-02): dockerd dalam memakai DNS `1.1.1.1` + `9.9.9.9`. Container bersarang
  (buildkitd, trivy, `docker run` di job) sebelumnya jatuh ke fallback Docker 8.8.8.8/8.8.4.4; dari VPS ini 8.8.8.8 gagal
  14/40 lookup A (1.1.1.1 & 9.9.9.9: 0/40) → Go hanya punya AAAA → `dial tcp [v6]:443: network is unreachable`; job image
  `drms` gagal 2× (bff95ac, 3dd8a96). Runbook `docs/03-operations/ci-runner.md` §1.

### Added
- erajaya-loyalty STAGING (2026-10-07, branch `feat/infra-erajaya-loyalty-staging`; runbook
  `docs/runbooks/erajaya-loyalty-staging.md`):
  - live: network `db-erajaya-stg` 10.100.29.0/24 + `erajaya-edge-stg` 10.100.19.0/24 (keduanya `--internal`), DB/role owner
    `erajaya_loyalty_stg` (limit 10), baris pg_hba (di tempat + reload, tanpa restart);
  - stack `staging/erajaya-loyalty/` (512m, read-only, secrets `*_FILE`), router Traefik + exclusion AppSec 920420/911100
    (19105/19106) + timer expiry 00:00 WIB (role `erajaya_staging_cron`, default absent) — disiapkan, belum diterapkan;
  - backup: `erajaya_loyalty_media_stg` di `MEDIA_VOLUMES`.
- plan 14 (2026-09-29): Expomedia pindah ke **alur standar Odoo**:
  - CRM → PNW → SPK (sale.order) → task per lokasi → milestone/DP → invoice → payment; timesheet = absensi per SPK;
  - `cl_expomedia_sale` (AE tanpa harga, nomor PNW/SPK, menu SPK); `cl_expomedia_spk` dipensiunkan;
  - platform `custom_doc_numbering` 19.0.1.0.1 (konfirmasi ulang + TZ);
  - agen `odoo-functional` + fit-gap.
- data mart (ADR 0016):
  - `datamart/` (ingest COPY, dbt 1.12.5, mart ber-RLS), network `db-datamart`, role `datamart_reader`
    (Σ limit tetap 196), timer `datamart-refresh` (role Ansible);
  - control-plane staging v0.3.0 dengan dashboard SPK (Owner/Finance nilai, PM status, AE miliknya).
- odoo (plan 13, ADR 0015, 2026-09-29): **modul platform Athera** — submodule `staging/odoo/addons/platform`
  (`odoo-addons-athera` v19.0.1.1.0, 52 modul, subset terkurasi arsip `addons-full-20260928T231052Z`), `addons_path` +
  `platform`, pylib (httpx, xmlschema) `PYTHONPATH=/mnt/extra-python`. Tenant **`expomedia_staging`**
  (`expomedia-erp.staging.bimacreative.tech`, SSO `platform-staging`): company PT Expomedia, COA PSAK, AI off. Pool-a belum.
- web client: `provision-web-client.sh --odoo-url <https>` (hanya bersama `--contact`) + template
  `docker-compose.odoo.yml` → lead CRM Odoo dari form kontak (`ODOO_LEADS_ENABLED`, secret `odoo_api_key`).
  Staging expomedia → `web-expomedia:dev-a173509` dengan lead ke `expomedia_staging`.
- traefik (2026-09-29): domain tambahan `expomedia.co.id` + `www.expomedia.co.id` → 301 permanen ke
  `https://expomedia.id` (path & query dipertahankan) — `traefik/dynamic/clients/web-expomedia-prod-coid.yml`, file
  manual (provision-web-client.sh belum punya flag domain tambahan; tidak ditimpa saat provision ulang), sertifikat SAN
  `le-http` (HTTP-01). DNS: zona di mysrsx (A @ & www → IP VPS); catatan: delegasi registrar masih
  `ns1/ns2/ns3.mysrsx.com` (ns3 tidak ada, ns2 timeout) — owner diminta menyamakan dengan expomedia.id.
- web expomedia (2026-09-29): prod & staging → image `web-expomedia:dev-22be3cd` (v0.3.0: logo resmi, foto event asli;
  prod tetap mode coming soon). Re-render dari template terkini: env opsional `LEAD_WEBHOOK_URL` (kosong), router
  kontak + `/api/lead`, override `docker-compose.{turnstile,umami}.yml` (tidak dimuat — COMPOSE_FILE tidak berubah).
- ci_runner (plan 12 R12, 2026-09-29): watchdog container job macet di supervisor (insiden 2026-09-28 23:48 WIB: zombie
  `runc:[2:INIT]` milik sysbox-fs, container tak keluar ±3 j) — guard timeout job `ci_runner_job_timeout` 3 j, stop → kill →
  restart `sysbox-fs` (hanya bila tidak ada container sysbox lain) → rm; metrik `ci_runner_stuck_total`,
  `ci_runner_stuck_unresolved`, `ci_runner_last_stuck_timestamp_seconds`, `ci_runner_job_timeouts_total`,
  `ci_runner_job_running_seconds`; healthcheck `ci-runner-stuck` + `ci-runner-job-timeout`. Ops `docs/03-operations/ci-runner.md`
  (operasi, rotasi PAT, runbook container macet, reset cache, disk, upgrade).
- analytics (ADR 0013, plan 11 U1–U6/U10, 2026-09-27): Umami 3.4.0 (MIT, digest ter-pin) di `analytics.bimacreative.tech` —
  stack `analytics/umami/` (uid 1001, rootfs ro, tanpa egress, 256m), DB/role `umami` di Postgres shared (limit 10, total 196),
  network `db-umami` 10.100.28.0/24 + `analytics-edge` 10.100.17.0/24 (`--internal`, attach live), router
  `traefik/dynamic/platform/analytics.yml` (publik hanya `/insight.js` + `/api/send`, admin :8443), template
  `docker-compose.umami.yml` + flag `provision-web-client.sh --umami-script-url/--umami-website-id`, monitor Kuma (kode),
  ops `docs/03-operations/analytics.md`.
- network (plan 06, ADR 0010, QA-T17B-01): network Postgres per konsumen `db-keycloak`, `db-odoo-pool-a`, `db-odoo-staging`,
  `db-cp`, `db-cp-stg`, `db-drms-stg` (`--internal`, 10.100.20–26.0/24; `db-drms`/`db-datamart` cadangan) via
  `postgres/scripts/bootstrap.sh` (`da68a83`); edge `kc-edge` (10.100.12.0/24, Traefik + Keycloak) dan `odoo-edge-stg`
  (10.100.13.0/24, Traefik + odoo-staging) via `traefik/scripts/bootstrap.sh`; `drms-kas-edge-prod` (10.100.14.0/24) cadangan.
- scripts (plan 06, `3a66cb8`, `d8417b2`): `scripts/net-matrix.sh [--check]` (matriks jangkauan TCP read-only, target plan 06 §8.2)
  dan `scripts/pg-hba-validate.sh <file> transition|final` (Postgres sementara `--network none`).
- odoo (plan 06 N2, D-i-D ADR 0010 #5a): submodule `addons/shared` kedua pool → `4bd278a` (`sh_dbfilter_header` 19.0.1.1.0,
  `X-Sh-Odoo-Db` hanya dari peer tepercaya); env `SH_DBFILTER_TRUSTED_PROXIES` = `10.100.3.0/24` (prod) / `10.100.13.0/24`
  (staging). Staging `2cc5f9e` (S4), prod `dc993ce` (S9).
- docs (plan 06): runbook `docs/03-operations/network-segmentation-runbook.md` (S0–S10, kini SELESAI/referensi); laporan QA
  `docs/qa/2026-09-25-plan06-staging.md` (N4) dan `docs/qa/2026-09-26-plan06-prod.md` (N7).
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
- ci_runner (plan 12 R12b, 2026-09-29): image `ci-runner:2.337.0-3` — sisa milik root dari container dalam (Trivy cache di
  `/cache/trivy` / `_work/_temp/trivy-cache`) di-chown ke uid 1001: entrypoint saat start/keluar + janitor root yang dipicu hook
  job-completed (menghilangkan "permission denied" pembersihan temp di akhir job). Diuji di container sysbox sekali pakai.
- ci_runner (plan 12 R12): entrypoint image `ci-runner:2.337.0-2` keluar dengan kode hasil job (0/10 Failed/11 Canceled/12/13
  tanpa job) → `ci_runner_jobs_total{result=success|failure|cancelled|none|error}` akurat (sebelumnya selalu rc 0);
  path unit `PathChanged` (bukan `PathExists`), preflight menolak credential PAT kosong, supervisor reload sendiri di titik aman
  saat PAT/skrip/env/unit berubah — handler Ansible tidak lagi me-restart paksa; supervisor `Wants=sysbox.service` (bukan
  `Requires`); mkfs `-E nodiscard` + pengisian hole `disk.img` (`ci_runner_fill_disk_holes`) + cek `/srv/ci` di luar fstrim.
- network (plan 06, ADR 0010, `06f0f6b`): compose 8 stack pindah dari network `db` bersama ke `db-*` per konsumen; Keycloak
  keluar dari `proxy`/`db` → `kc-edge` (gw_priority 1) + `db-keycloak` + `metrics`; odoo-staging → `odoo-edge-stg`. Downtime
  terukur: staging Odoo ±3 s (18:42:18–21 WIB), staging DRMS ±33 s, prod CP ±4 s (22:02:31–35), Traefik ±5 s (22:03:36–41),
  Keycloak ±27 s discovery tidak tersedia (22:06:09–36), prod Odoo ±7 s (22:09:24–31), 2026-09-25.
- postgres (plan 06): `pg_hba.conf` per subnet konsumen — transisi 26 aturan (S2 `09c9045`, ditulis di tempat), final **16
  aturan** tanpa `10.100.1.0/24` (S10 `0ccfce2`, 2026-09-26 16:08 WIB, recreate postgres). Network `db` (10.100.1.0/24)
  **dihapus**, subnet pensiun; bootstrap tidak lagi membuatnya. S10 dijalankan sebelum 24 jam soak (keputusan user, belum ada client).
- traefik (plan 06): recreate di jendela prod (drift `networks:`) mengaktifkan `metrics.prometheus.manualRouting` QA-T17B-03 —
  `traefik:8082/metrics` 403 dari semua network kecuali `metrics`.
- traefik (`0ccfce2`): resolver `le-http` kini memakai `email: postmaster@bimacreative.tech`; akun ACME `acct/3793253016`
  stabil melewati `--force-recreate` (ADR 0002 #15b, `ac70310`).
- docs: plan 06 → EXECUTED (§15 hasil, AC, bug/insiden, item terbuka); ADR 0010 §Results + riwayat revisi; `traefik.md`,
  `postgres.md`, `keycloak.md`, `odoo.md`, `control-plane.md`, `observability.md`, runbook `proyekkas-drms-onboarding.md`
  (prod: `db-drms`, `drms-kas-edge-prod`) diperbarui ke topologi final (tanpa `db`).
  Follow-up pemecahan `proxy` dinomori ulang **plan 10** (07–09 terpakai).
- docs (ADR 0002 #15b, `569c1b1`, `3a93354`): CAA `accounturi` dilepas (2026-09-26 ±00:20 WIB) — zona kembali
  `0 issue "letsencrypt.org"`; pin ulang ke akun baru = opsional, keputusan user.
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
- scripts (plan 06 BUG-N4-01 Medium, `e90fd9a`, merge `f39c794`): `net-matrix.sh` melaporkan target TERBUKA sebagai tertutup
  pada container Node di network internal (lookup menggantung ±10 s memakan timeout TCP, threadpool libuv 4). Kini DNS
  di-resolve dulu per nama (3 s), TCP 2 s ke IP, kegagalan DNS (`n`) dan probe (`?`) dilaporkan terpisah, mode per-IP
  `NET_MATRIX_TARGETS`.
- traefik (insiden CAA 2026-09-25/26): resolver `le-http` tanpa `email` mendaftarkan akun ACME baru setelah recreate Traefik
  plan 06 → CAA `accounturi` (akun lama) memblok penerbitan sertifikat baru (403). Akar diperbaiki dengan email ACME
  (`0ccfce2`); CAA sementara tanpa `accounturi`.
- scripts (plan 05 BUG-J5-01 High, `3ca5501`): `odoo-sso-user.sh --resend-invite` menjadi aksi tersendiri yang tidak pernah memberi
  role/membuat user/menautkan; saling eksklusif dengan `--grant`/`--revoke`, `--create-kc` ditolak; user tanpa role `odoo_access`
  atau tautan aktif → blocker. Sebelumnya resend memulihkan akses user yang sudah dicabut. `RESULT action=resend_invite`.
- crowdsec (plan 04 BUG-S5-01, `1c2a528`): false positive CRS SQLi (942100) pada POST token back-channel OIDC (±1/22 login SSO
  gagal `oauth_error=2`) — exclusion sempit `local/oidc-backchannel-exclusions`; recreate crowdsec 10:50:07–10:50:54 WIB.
- observability: `mem_limit` grafana 256m → 384m (GOMEMLIMIT 320MiB), uptime-kuma 192m → 320m (pemakaian 72–81%); ADR 0004 diperbarui.

### Security
- Segmentasi network (ADR 0010, menutup QA-T17B-01 High): tidak ada container selain Traefik yang menjangkau Odoo
  `:8069/:8072` atau Keycloak `:8080/:9000` (kecuali Prometheus → `keycloak:9000`); role Postgres hanya bisa login dari network
  konsumennya sendiri (uji silang 6 network × 10 role@db); prod dan staging tidak berbagi edge. D-i-D: `sh_dbfilter_header`
  trusted proxy (header palsu dari peer lain → tanpa DB + WARNING) dan Keycloak `KC_PROXY_TRUSTED_ADDRESSES=10.100.12.0/24`
  (opsi runtime; `X-Forwarded-For` palsu dari `metrics` diabaikan). QA N7: AC-06-01..16 PASS, 0 Critical/High/Medium baru.
  Residual: `proxy` (R1, plan 10), `metrics` → `keycloak:8080` (R2), entri bouncer CrowdSec usang `traefik-bouncer`
  10.100.2.3 (Low, investigasi sebelum hapus — mungkin berbagi API key dengan bouncer aktif).
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
