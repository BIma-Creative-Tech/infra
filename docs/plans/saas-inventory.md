# SaaS Fase 0 — Inventaris kondisi nyata vs brief platform SaaS

Status 2026-10-02: **SELESAI (read-only, FREEZE DEMO berlaku)**. Sumber: brief owner "Platform SaaS Odoo 19 CE"
(2026-10-02) §3.1. Tidak ada yang diubah di host/prod; semua angka dari pembacaan file, `docker inspect`, `systemctl`,
`journalctl`, dan `SELECT` pada `information_schema`/tabel metadata. Tidak ada nilai secret yang dibaca atau dicetak.

Catatan konvensi: brief menulis `docs/plan/`; repo memakai `docs/plans/` — dokumen ditaruh di sini.

---

## 0. Ringkasan untuk owner (≤ 1 layar)

1. **Sebagian besar fondasi sudah ada**, dengan nama berbeda dari brief: tenant = tabel `clients` (+ `environments`
   per prod/demo/staging), `plans`/`subscriptions`/`invoices`/`domains`/`mailboxes` **sudah ada sebagai tabel kosong**
   tanpa kode, job = `provision_jobs` + jembatan spool ke dispatcher root (ADR 0009) dengan 5 tipe job Odoo.
2. **Keycloak Organizations sudah tersedia di image** (default KC 26.7.4; tabel `org` ada) — yang mati hanya setelan
   realm `organizationsEnabled=false`. **Restart R1 (§6a brief) kemungkinan tidak diperlukan**; mengaktifkan cukup
   ubah atribut realm (butuh `manage-realm`).
3. **Konflik desain dengan ADR yang ada** — perlu ADR baru sebelum Fase 1 (bukan menyimpang diam-diam):
   - ADR 0008: Organizations ditunda, service account `automation` tanpa `manage-realm`, isolasi tenant lewat client
     OIDC per tenant-env (bukan klaim `tenant_id`).
   - ADR 0009: **control-plane tidak memegang secret/Docker**; eksekusi oleh dispatcher root yang di-allowlist.
     Brief §5.3 mengasumsikan worker CP yang mengeksekusi job dengan kredensial `cp-admin`. **Rekomendasi: pertahankan
     ADR 0009** — job baru (org/user/realm/mail/web) ditambahkan sebagai tipe dispatcher; kredensial `cp-admin` hidup
     di host, bukan di container CP.
   - ADR 0016: datamart = satu skema `mart` bersama + RLS `client_slug`, dibaca langsung oleh CP. Brief = mart per
     tenant + API. Diputuskan di Fase 3, tidak memblokir Fase 1.
4. **Temuan operasional yang perlu tindakan (setelah freeze)**: restore-test restic **gagal** sejak 10-01 karena
   stale lock (prune Minggu 10-04 03:00 akan ikut gagal); repo `web-expomedia` dan `odoo-data-expomedia` **tanpa
   remote dan tidak ter-backup** (`/opt/src` di luar cakupan restic); image prod `drms-pk-web` tidak bertag.
5. **Gate Fase 0 belum lulus penuh**: disk `/` 62 % (target < 50 % butuh penghapusan — ditunda sampai freeze dicabut,
   daftar siap di §11). Penyebab OOM sudah diketahui dan sudah diperbaiki sebelumnya (§11.4).

Detail keputusan yang dibutuhkan: `docs/plans/saas-progress.md` bagian **Butuh keputusan**.

---

## 1. ADR 0001–0016 vs arsitektur target (brief §2)

Huruf dampak: a=CP sumber kebenaran+job, b=KC Organizations/`cp-admin`, c=Odoo pool+dedicated, d=insight per tenant,
e=mail via job, f=Payload per site, g=router Traefik digenerate, h=dua VPS/Ansible, i=backup per DB.

| ADR | Judul | Keputusan (1 baris) | Terdampak |
|---|---|---|---|
| 0001 | Stack & pin versi | Pin Traefik 3.7.13, PG 16.15, KC 26.7.4, Odoo 19.0-20260908, DMS 16.0.1, restic 0.19.1, Next 16.3.6 | ya (d,f): pin baru Payload, insight-api |
| 0002 | TLS HTTP-01 & DNS manual | Satu resolver `le-http`, tanpa wildcard, router hanya setelah DNS pre-check | ya (g,h): IP VPS hard-coded di `scripts/lib/traefik-route.sh:6` → harus parametrik untuk VPS kedua |
| 0003 | Odoo tanpa OCA, DB per hostname | `sh_dbfilter_header` + header `X-Sh-Odoo-Db` per router, fail-closed | ya (c,g): dedicated butuh service/route sendiri; pola header tetap |
| 0004 | Kapasitas | `mem_limit` per service; satu pool prod + staging; dedicated/VPS-2 = keputusan user saat ambang | ya (c,d,f,h) |
| 0005 | Mail IPv4 & multi-domain | DMS IPv4-only, DKIM rspamd per domain, `ACCOUNT_PROVISIONER=FILE` | ya (e): domain/mailbox manual (`mail/scripts/mailbox-add.sh`) |
| 0006 | Backup restic | Repo lokal + B2; `pg_dumpall --globals-only` + `pg_dump -Fc` per DB; file + mail | ya (i,h): sudah dekat target; daftar volume filestore/media statis |
| 0007 | UI website client | Next.js 16 + Tailwind; **tanpa CMS** | ya (f): Payload = keputusan baru |
| 0008 | SSO Odoo multi-tenant | Realm `platform`/`-staging`, client `odoo-<slug>-<env>`, role `odoo_access`, secret per DB; **Organizations ditunda**; SA `automation` | **ya (b) — konflik langsung** |
| 0009 | Jembatan job CP → skrip root | CP tanpa Docker/SSH/sudo/secret; spool → `.path` → dispatcher root; allowlist 5 tipe | **ya (a,b,e,f,g) — konflik dengan "worker mengeksekusi"** |
| 0010 | Segmentasi network | Network `--internal` `db-<konsumen>` + pg_hba per subnet (pool 10.100.20–39.0/24) | ya (c,d,f): tiap dedicated/site/API butuh subnet; tersisa ±10 slot |
| 0011 | Hostname mail per client (SNI) | Alias `mail.<client>`, router dummy di `dynamic/platform/mail-clients.yml` | ya (e,g) |
| 0012 | Webmail Roundcube | Roundcube 1.7.4 `webmail.<client>` | ya (e): route ditulis tangan |
| 0013 | Umami | Satu instance, admin di :8443 | minor (f) |
| 0014 | CI runner self-hosted | Ephemeral sysbox, 1 job | tidak (catatan: `mem_limit 4g` usang, kini 5g) |
| 0015 | Addons platform di pool | Submodule `platform` ter-pin di pool-a + staging | ya (c): dedicated harus pin yang sama |
| 0016 | Data mart pipeline | Ingest COPY per tenant → dbt 1.12.5 → **satu skema `mart` + RLS** → dibaca CP | **ya (d) — beda desain** |

Plans 00–19 dan `docs/03-operations/*`: lihat daftar di laporan inventaris (plan 03/04/05/06/12 EXECUTED; 13–19 tenant
expomedia; 09 web-tambang dihapus 10-01).

---

## 2. Control-plane (`/opt/src/control-plane`)

**Stack**: satu paket (bukan monorepo), Next.js 16.3.6, React 19.3.0, **Drizzle 0.45.3** (drizzle-kit 0.31.11),
**next-auth 5.0.0-beta.32**, pg-boss 12.33.6 (skema `pgboss`), zod 4, pino. v0.8.0 = HEAD `3d4aa7c` = image yang jalan
di prod dan staging (`control-plane:3d4aa7c`). Remote `bctech-adm/control-plane`.

**Skema** (`src/db/schema.ts`, migrasi `drizzle/0000`–`0003`; prod dan staging identik, 12 tabel):

| Target brief §5.2 | Kondisi | Catatan |
|---|---|---|
| tenant | **ada** = `clients` (slug CHECK `^[a-z0-9-]{3,30}$`) + `environments` (kind prod/demo/staging, db_name, host, db/route/sso status) | tidak ada `status`, `isolation`, `kc_org_id`, `brand` |
| tenant_domain | **tabel ada** = `domains` (fqdn, status pending_dns/verified/active/failed, verification_token, verified_at…) | tanpa kode/UI/job; host aktif disimpan di `environments.host` |
| plan | **tabel ada**, 0 baris, tanpa kode | `max_users/environments/mailboxes`, `features jsonb` |
| subscription | **tabel ada**, 0 baris | enum `pending/active/grace/suspended/terminated` — **tanpa** `implementation`, `warranty`; `grace` ≈ `past_due` brief |
| invoice | **tabel ada**, 0 baris | status `unpaid/awaiting_confirmation/paid/void`, proof_file, confirmed_by; tanpa `kind` |
| tenant_user | **sebagian**: `users` (keycloak_sub, client_id, role cache) + `tenant_user_access` (akses SSO per environment) | `users` prod **kosong** (lihat §2.1) |
| job | **sebagian** = `provision_jobs` | tanpa `idempotency_key`; pengganti: unique index 1 job aktif per (environment, type) |
| audit_log | **ada** = `audit_logs` | `actor_user_id` NULL di prod |
| dashboard_config | **tidak ada** | dashboard membaca `mart.mart_user_access` via RLS |
| mail_domains, mailboxes | tabel placeholder, tanpa kode | |

Baris (staging/prod): clients 3/1, environments 3/1, provision_jobs 32/8 (prod: 8 succeeded), tenant_user_access 5/2,
audit_logs 77/19, plan/subscription/invoice/domain/mail 0/0.

**Role & otorisasi**: client role Keycloak `control-plane`: `superadmin, ops, client_admin, client_user` dari klaim
`resource_access.control-plane.roles`; permission map default-deny (`src/lib/roles.ts:28-40`), dicek server-side di
tiap page/action (`requirePermission`). Akses tenant di dashboard dari `mart_user_access` + `sub` (RLS datamart).

**UI**: `/dashboard*` (read-only datamart: SPK, quotation, dokumen), `/clients` (buat tenant — superadmin),
`/environments/[id]` (provision DB, route, SSO provision/rotate/disable, user grant/revoke/resend), `/jobs` (+ retry).
**Belum ada**: domain kustom, billing/plan, edit/hapus tenant, portal client, halaman Users.

**Keycloak**: hanya login OIDC (Auth.js, PKCE+state+nonce, sesi JWT 8 jam). **Tidak ada** panggilan Admin API,
service account, atau Organizations di kode CP.

**CI/deploy**: workflow `security.yml` (lint/test/scan/build image untuk scan) — **tanpa push registry, tanpa deploy**.
Deploy manual di VPS: `git archive | docker build -t control-plane:<sha>` → pin tag di compose infra → `compose run
migrate && up -d` (`docs/03-operations/control-plane.md:169-198`). 14 tag lama tersimpan untuk rollback.

### 2.1 Temuan: tabel `users` prod kosong

Upsert `users` saat login (`src/auth.ts:55-62`) gagal diam-diam (hanya warn) atau belum pernah terpanggil sejak kode
dideploy. Log container prod 72 jam: **tidak ada** warn "upsert users saat login gagal". Akibat: `audit_logs` prod tanpa
`actor_user_id` (aktor tetap tercatat di kolom teks `actor`). **Penyebab TIDAK TERVERIFIKASI** — diperiksa di Fase 1
(login uji di staging + cek baris `users`).

---

## 3. Worker, spool, dan executor host (ADR 0009)

- **Worker CP** (`control-plane-worker`, uid 950/951, rootfs read-only, no-new-privileges): pg-boss queue
  `infra-job-dispatch` (`retryLimit 0`), `batchSize 1`; **tidak mengeksekusi apa pun** — menulis
  `spool/tmp/<uuid>.json` (O_EXCL|O_NOFOLLOW, 0600, fsync) → rename ke `spool/new/`, membaca `results/<uuid>.json`
  (≤ 64 KiB) tiap 5 dtk + watchdog. Format v1: `{v, job_id, type, slug, env, dry_run, actor, requested_at, args}`.
  Tanpa metrics Prometheus (hanya log + heartbeat file).
- **Executor host**: `infra-job-{prod,staging}.path` (`DirectoryNotEmpty`) → `infra-job@<inst>.service` (oneshot,
  **root**, hardening systemd lengkap, `ProtectSystem=full`, capability terbatas) → `/usr/local/sbin/infra-job`
  (= `scripts/infra-job/infra_job.py` v1.0.0, stdlib). Validasi ketat (pemilik file, nlink, ukuran, JSON ketat, allowlist
  tipe, regex argumen, binding instance→env, kuota dari `/etc/infra-jobs/<inst>.conf`), argv tetap tanpa shell,
  `flock` serial per instance, ledger idempoten, kill switch `/etc/infra-jobs/<inst>.disabled`.
- **Tipe job yang ada (5)**: `odoo_db_provision`, `odoo_route`, `odoo_sso_provision`, `odoo_sso_disable`,
  `odoo_sso_user`. Enum CP juga punya `provision/suspend/resume/terminate/backup_now/restore` **tanpa handler**.
- **Host yang diizinkan**: hanya `*.erp.bimacreative.tech` / `*.staging.bimacreative.tech` → domain milik client
  (mis. `erp.expomedia.id`) tetap lewat skrip manual.
- **Retry**: manual saja (tombol "Ulangi" = job baru dengan `parent_job_id`).
- **Kemampuan executor**: `docker`/`docker exec` (termasuk `mailserver setup`, `postgres psql`) dan tulis
  `/opt/infra/traefik/dynamic/clients` **sudah bisa** tanpa hak baru — yang perlu hanya tipe job + validator + kontrak.
  Tulis `/etc`, `systemctl`, `/root` **tidak bisa** (sandbox).

Katalog brief §5.3 vs yang ada:

| Target | Ada? |
|---|---|
| realm.sync, org.create | tidak |
| user.create / enable / disable / set_role | sebagian — `odoo_sso_user` (grant+`create_kc` membuat user KC; revoke = cabut role per tenant-env, bukan disable user; hanya flag admin) |
| odoo.db.create | **ya** — `odoo_db_provision` |
| odoo.db.install | sebagian (hanya `base,sh_dbfilter_header` saat create) |
| odoo.db.backup | tidak (backup host-wide restic) |
| odoo.db.suspend / resume | sebagian (`odoo_route remove=true/false` + `odoo_sso_disable/provision`) |
| odoo.instance.create | tidak (`odoo-pool-bootstrap.sh` manual) |
| traefik.router.write | sebagian (`odoo_route`, hanya subdomain platform) |
| dns.verify | sebagian (`dns_precheck` di dalam `odoo_route`) |
| mail.*, web.site.*, insight.*, monitor.add, tenant.suspend/resume/archive | tidak |

---

## 4. Modul Odoo SSO (`/opt/src/odoo-addons-shared`, commit `4bd278a`)

**Nama modul yang benar: `sh_auth_oidc`** (brief menyebut `sh_oidc`), 19.0.1.2.0; `sh_dbfilter_header` 19.0.1.1.0;
`sh_session_cookie` 19.0.1.0.0. Tes: 73 / 45 / 17 metode, dijalankan manual (`test/run-tests.sh`), tidak di CI.

- **Alur**: authorization code + PKCE S256, client confidential `client_secret_basic`; state sekali pakai; validasi ID
  token lengkap (iss persis, aud/azp = client_id, exp/nbf/iat, nonce, RS256+ RSA ≥ 2048).
- **Secret**: file per DB `/run/sh-oidc/<cr.dbname>` (dibaca tiap exchange, rotasi tanpa restart). File ada:
  pool-a `demo_demo`, `expomedia_prod`; staging `demo_staging`, `expomedia_staging`, `ssotest_staging`.
- **Klaim yang dibaca**: `sub`, `email`, `name`, `email_verified`, `resource_access.<client_id>.roles`. **Tidak**
  membaca `tenant_id`, `organization`, `groups`, `realm_access`.
- **Pencocokan user**: `(oauth_provider_id, oauth_uid == sub)`; tanpa fallback email. **Auto-create mati**
  (`sh_oidc_allow_signup=false`, `invitation_scope=b2b` di 5 DB) — user Odoo dibuat manual, lalu di-link oleh
  `odoo-sso-user.sh`. **Tidak ada pemetaan role → group Odoo.**
- **Pengikatan tenant↔DB**: tidak eksplisit lewat klaim, tetapi **fail-closed secara implisit**: `aud` harus client
  per tenant-env, secret dipilih dari `cr.dbname`, gate role `odoo_access` pada client itu, dan `sub` harus ter-link
  ke `res.users` aktif di DB itu.
- **Provisioning hari ini**: `provision-odoo-sso.sh` (client KC + role + mapper + secret file + provider Odoo + smoke)
  dan `odoo-sso-user.sh` (user KC + invite email + role + link `res.users` yang sudah ada).

Implikasi: kebutuhan brief §5.1 langkah 4–5 (verifikasi `tenant_id`, pembuatan user Odoo saat login pertama, role →
group) **semuanya pekerjaan baru** di `sh_auth_oidc`.

---

## 5. Keycloak (`/opt/infra/identity/keycloak`)

- Image `infra/keycloak:26.7.4-optimized` dari `quay.io/keycloak/keycloak:26.7.4@sha256:…`, `kc.sh build` **tanpa**
  `--features`/`--features-disabled`; `show-config` tanpa override fitur → **fitur default 26.7.4, Organizations
  tersedia**. Bukti: tabel `org` ada (0 baris), scope `organization`/`saml_organization` dengan
  `oidc-organization-membership-mapper` ada di kedua realm.
- Realm `platform` & `platform-staging`: `organizationsEnabled=false`, tanpa grup, realm role hanya default.
  Client: `automation` (SA: `view-realm`, `manage-clients`, `manage-users`; **tanpa `manage-realm`**),
  `control-plane`, `odoo-<slug>-<env>` (platform: demo-demo, expomedia-prod; staging: demo-staging,
  expomedia-staging, ssotest-staging). Tidak ada mapper `tenant_id`; tabel `user_attribute` kosong.
  User non-SA: platform 1, platform-staging 4.
- Kebijakan: password `length(12)…passwordHistory(5)`, brute force ON (5 gagal, 60 s → 900 s), registrasi off,
  `resetPasswordAllowed=false`, SMTP terkonfigurasi, event login/admin ON.
- **Realm export di repo** (`realm-export/*.json`, 2026-09-25): partial, **usang** (sebelum client Odoo tenant
  dibuat); export penuh butuh `manage-realm`.
- Administrasi: console hanya via SSH tunnel `:8443`; client non-Odoo dan setelan realm dibuat manual di console.

---

## 6. Datamart / insight

Satu proyek dbt global `/opt/infra/datamart/dbt` (`platform_datamart`, dbt-core 1.12.5). Ingest root `COPY` per
tenant → skema `raw_<slug>_<env>` → `stg` (24 view) → **`mart` bersama (13 tabel) + RLS `client_slug`/`keycloak_sub`**
untuk `datamart_reader` (hanya dari `db-cp`/`db-cp-stg`). Timer tiap 2 menit, skip bila fingerprint tidak berubah;
run penuh 29–41 s, 47/47 tes, 0 gagal 24 jam. Konsumen satu-satunya: control-plane `/dashboard*`. Grafana tidak
membaca datamart. Catatan: `datamart.env` tidak ada (fallback ke `.example`); RLS ENABLE tanpa FORCE (owner dbt
dikecualikan, sengaja).

---

## 7. Web profile

web-starter, web-expomedia, bct-website, web-tambang: Next.js 16.3.6 + Tailwind 4, **tanpa CMS**; konten di
`src/config/{brand,content}.ts` (bct: `content/*.ts`) → ganti konten = rebuild image. Overlay compose
`contact/umami/turnstile/odoo` dari `templates/web-client/`; provisioning `scripts/provision-web-client.sh` (idempoten,
DNS pre-check, render compose + route, smoke TLS) dijalankan manual. **Payload 3.90.1 sudah dipakai di proyekkas/drms**
(OIDC ke Keycloak, adapter Postgres `push:false` + container migrate) — dapat dijadikan pola, bukan paket.

## 8. CI/CD

| Repo | Remote | CI | Deploy |
|---|---|---|---|
| control-plane | bctech-adm | security.yml (tanpa push) | manual build lokal di VPS |
| web-starter, bct-website | bctech-adm | ci.yml → GHCR | manual `provision-web-client.sh` |
| web-expomedia, web-tambang | **tidak ada remote** | ci.yml inert | build lokal `dev-<sha>` |
| proyekkas (drms) | bctech-adm/drms | ci.yml + deploy-prod.yml (INERT) + runner self-hosted | manual pull GHCR |
| odoo-addons-shared | bctech-adm | security.yml | submodule ter-pin |
| odoo-addons-athera / -expomedia, odoo-data-expomedia | **tidak ada remote** | — | submodule URL path lokal |

`/usr/local/sbin/infra-deploy` (v1): `compose pull && up -d` untuk stack apa pun di `/opt/infra` yang cocok regex —
**tanpa allowlist stack**, tanpa rollback/healthcheck; belum dipakai CI. GitHub-hosted minutes habis 2026-09-28.

## 9. Backup

restic harian 01:30: seluruh `/opt/infra` (kecuali `backups/`, `traefik/logs/`, `ansible/collections/`) → termasuk
`mail/data/config` (DKIM) dan `traefik/acme`; `pg_dumpall --globals-only` + **`pg_dump -Fc` per DB** (13 DB, daftar
dinamis); filestore `odoo_pool_a_data`/`odoo_staging_data` + media drms (daftar statis). Repo lokal
`/opt/infra/backups/restic` (disk yang sama) + copy ke B2. Retensi lokal 7d/4w/3m, remote 7d/8w/12m.
**Tidak di-backup: `/opt/src/*`**, Prometheus/Loki.

- **Restore-test 2026-10-01 GAGAL** pada `restic check`: stale lock PID 435014 (2026-09-27 14:30, proses sudah tidak
  ada — diverifikasi `ps`). DB compare dan filestore OK. Backup harian tetap OK (`dbs_ok=13 remote=ok`).
  `restic-prune` Minggu 2026-10-04 03:00 kemungkinan gagal karena lock yang sama.

## 10. Ansible

Inventory tunggal (`inventories/local` & `remote`, host `srv2001692`), satu `group_vars/all.yml`, `site.yml` 19 role:
base host (users, firewall, ssh, sysctl_swap, docker, auditd, fail2ban, unattended, crowdsec bouncer) + unit host
(backup, infra_jobs, healthcheck, container_metrics, mail_tls_export, datamart_refresh, ci_runner). **Tidak
mentemplate compose/.env/config aplikasi**, tidak menaikkan stack; `community.docker` terpasang tapi tidak dipakai.
Tidak ada inventory athera/bct.

---

## 11. Pekerjaan rumah §3.2 — data siap, **eksekusi ditunda sampai freeze dicabut**

### 11.1 Image (`docker image prune -a --filter until=168h` **tidak aman apa adanya**)

25 image tak terpakai > 168 jam, ±9,0 GB unik (+1–3 GB blob content store). **Harus dikecualikan**:
`python:3.12-slim-bookworm` (dipakai `datamart-refresh` tiap 2 menit via `docker run --rm` — prune `-a` akan
menghapusnya di sela run), `node:24-alpine`, `quay.io/keycloak/keycloak:26.7.4`, `ghcr.io/actions/actions-runner`
(basis image aktif, hemat ±0). Usulan: `docker rmi` per ID terhadap 21 sisanya:

| Image | Unik | Image | Unik |
|---|---|---|---|
| mcr.microsoft.com/playwright:v1.55.0-noble | 3,64 GB | proyekkas-migrate:0.1.0-stg-3b05b83 (repo lokal lama) | 1,58 GB |
| semgrep/semgrep (untagged) | 1,56 GB | ghcr.io/dbt-labs/dbt-postgres:1.9.0 (tak dipakai) | 0,88 GB |
| aquasec/trivy:0.74.0 | 241 MB | node:24(.21.0)-bookworm-slim | 219 MB |
| proyekkas-web:0.1.0-stg-3b05b83 | 99 MB | grafana/k6:latest | 99 MB |
| zricethezav/gitleaks (untagged) | 77 MB | hadolint/hadolint:v2.15.1 | 68 MB |
| control-plane:6d94d2b, :7b85a78 | 131 MB | python:3.12-slim, python:3-alpine | 123 MB |
| web-expomedia:dev-148b002 | 47 MB | axllent/mailpit:v1.31.2 | 38 MB |
| curlimages/curl:8.22.0/latest, :8.11.1 | 67 MB | koalaman/shellcheck(-alpine) v0.11.0/v0.10.0 | 72 MB |

Tidak ada target rollback di daftar (control-plane `8b0bf5e`/`0def3c7`, web-expomedia `dev-2e38c3f` < 168 jam).
**Perhatian**: rollback drms `proyekkas-web:0.3.0`/`proyekkas-migrate:0.3.0` melewati 168 jam pada **2026-10-04** —
pin/tag sebelum prune rutin. Prod `drms-pk-web` berjalan dari image **tanpa tag** (`42682f7f2d09`, seharusnya `0.4.1`)
→ tag ulang setelah freeze.

**Build cache**: 291 record, 15,7 GB; `builder prune --filter until=72h` ≈ 3–6 GB.

### 11.2 Volume anonim (21, 3,41 GB, tidak dipasang container mana pun)

19 berisi PGDATA (VOLUME bawaan `postgres:16.15` dari container Postgres sekali pakai tanpa `--rm`, waktu cocok dengan
sesi agent 09-27…10-02), 2 kosong (pasangan VOLUME image odoo). Bukan dari CI runner. `docker volume prune` (anonim
saja) ≈ 3,4 GB — **butuh persetujuan**.

### 11.3 `/tmp` 9,5 GB dan `/root` 3,8 GB

`/tmp/claude-0`: 27 scratchpad sesi Claude > 3 hari = **7,7 GB** (terbesar `-root/7dc51e32…` 5,8 GB: trivy-cache
4,2 GB); 14 sesi aktif ≤ 3 hari 1,7 GB (jangan dihapus). `/root`: `.cache/trivy` 1,4 GB, `.local/share/claude/versions`
1,2 GB (5 versi CLI), `.pub-cache` 456 MB, `.dartServer` 247 MB.

### 11.4 OOM 2026-09-28 — **penyebab diketahui, sudah diperbaiki**

`oom_memcg=/system.slice/docker-ff829b03….scope` = container **ci-runner-job** (sysbox, UID 232073 = mapping userns).
Build APK Flutter drms: `java` (Gradle/Kotlin daemon, anon-rss 2,37 GiB) dibunuh pada limit container **4 GiB tanpa
swap**. Bukan Keycloak, bukan OOM host. Sudah ditangani commit `1673916` (`ci_runner_memory: 5g`); tidak ada OOM
sesudahnya. Sisa: ADR 0014 baris 30 masih menulis `4g` (dokumen usang); usulan cap JVM di CI drms
(`org.gradle.jvmargs=-Xmx2g`, `kotlin.daemon.jvmargs=-Xmx768m`) daripada menaikkan limit lagi.

### 11.5 Memori

Jumlah `mem_limit` 29 container **19,2 GiB vs RAM 15 GiB** (ci-runner-job 5 G, pool-a 2,5 G, postgres 2 G, keycloak
1,33 G, staging 1,25 G, mailserver 1 G). Swap 1,4 GiB tersebar (next-server ×10, rspamd ×5) — tidak ada proses
dominan. **`vm.swappiness` sudah 10** (usulan brief sudah terpenuhi lewat role `sysctl_swap`).

### 11.6 Disk & proyeksi

`/` 119/193 GB (62 %). Terbesar: `/var/lib/containerd` 48 GB (snapshotter containerd), `/var/lib/ci-runner/disk.img`
41 GB teralokasi penuh, volume docker 4,6 GB. `ci-runner-gc` hanya membersihkan `/srv/ci`, **tidak** image/cache host.

| Langkah (setelah freeze) | Hemat | `/` sesudah |
|---|---|---|
| `docker rmi` 21 image (§11.1) + `builder prune --filter until=72h` | 12–17 GB | ≈ 54 % |
| + `docker volume prune` (anonim) | 3,4 GB | |
| + hapus scratchpad Claude > 3 hari | 7,7 GB | |
| + `/root/.cache/trivy` + versi CLI lama | 2,4 GB | **≈ 46–48 %** (gate < 50 %) |

### 11.7 Restic

Cakupan DKIM (`mail/data/config`) dan `traefik/acme`: **sudah tercakup**. Dump per DB: **sudah ada**. Masalah:
stale lock (§9) dan `/opt/src` tidak tercakup.

### 11.8 DMARC `expomedia.id`

Saat ini `v=DMARC1; p=none; adkim=s; aspf=s; rua=mailto:dmarc@expomedia.id`. Usulan (dilakukan owner di DNS, setelah
demo): `v=DMARC1; p=quarantine; pct=25; adkim=s; aspf=s; rua=mailto:dmarc@expomedia.id` → seminggu bersih → hapus
`pct=25` (sama dengan `bimacreative.tech`).

### 11.9 `ci-runner-gc` + prune host

Usulan: unit terpisah `docker-host-gc.timer` (bukan menumpang `ci-runner-gc` yang sandbox-nya hanya `/srv/ci`) yang
menjalankan `builder prune --filter until=72h` dan `rmi` image dangling + allowlist "jangan hapus"
(`python:3.12-slim-bookworm`, basis image, tag yang dipakai container, N tag terakhir per repo lokal). Dikerjakan via
role Ansible setelah freeze.

---

## 12. Asumsi brief §9

| # | Asumsi | Hasil | Bukti / koreksi |
|---|---|---|---|
| A1 | Worker mengeksekusi job via supervisor host yang bisa docker & psql | **sebagian** | Worker CP hanya menulis spool; eksekusi oleh dispatcher root oneshot (`infra-job@`) yang hanya menjalankan 5 tipe allowlist. Docker ya; psql hanya `docker exec postgres psql` (tidak ada psql di host) |
| A2 | tenant & job ada; subscription/invoice/plan belum | **sebagian salah** | `clients`/`environments`/`provision_jobs` ada & dipakai; `plans`/`subscriptions`/`invoices`/`domains`/`mailboxes` **ada sebagai tabel kosong** tanpa kode; enum status tidak sesuai siklus brief |
| A3 | `dynamic/clients/*.yml` ditulis manual | **sebagian** | 10/18 dirender skrip (`render-client-route.sh` ×5, `provision-web-client.sh` ×5, header "DIRENDER OTOMATIS") tapi dijalankan manual; 8 tulisan tangan (drms ×5, `expomedia-staging-alias`, `web-expomedia-prod-coid`, `webmail-expomedia`); belum ada yang ditulis lewat CP |
| A4 | `sh_oidc` belum verifikasi tenant/org | **benar (dengan nuansa)** | Modul = `sh_auth_oidc`; tidak membaca klaim tenant/org, tetapi pengikatan DB implisit fail-closed (aud per client, secret per DB, role gate, link `res.users`) |
| A5 | Image KC belum `--features=organization` | **salah** | Organizations default aktif di 26.7.4 (tabel `org`, scope `organization`); yang off hanya `organizationsEnabled` per realm → **R1 tidak perlu restart** |
| A6 | `datamart-refresh` = dbt satu proyek global | **benar** | `/opt/infra/datamart/dbt`; ingest per tenant ke `raw_<slug>_<env>`, mart bersama + RLS |
| A7 | `web-starter` tanpa CMS | **benar** | konten di TypeScript; Payload 3.90.1 hanya di proyekkas |
| A8 | restic belum `pg_dump` per DB | **salah (sudah ada)** | `backup.sh:45-57` `pg_dump -Fc` per DB, tag `db:<db>`; namun restore-test gagal (stale lock) |
| A9 | Ansible hanya base | **benar** | base + unit host; tidak ada compose/config aplikasi; satu inventory |

## 13. Usulan perubahan terhadap brief

1. **Eksekusi job tetap lewat dispatcher root (ADR 0009)**, bukan worker CP. Kredensial Keycloak `cp-admin` disimpan
   di host (`identity/keycloak/secrets/cp-admin-<realm>.secret`), dipakai skrip job. Alasan: CP terekspos internet; ADR
   0009 sengaja menjaga CP tanpa secret/Docker. Konsekuensi: setiap tipe job baru = perubahan `infra_job.py` +
   kontrak CP (pola sudah teruji, ±1 hari per keluarga job).
2. **Nama tabel & role yang ada dipertahankan** (brief §6a "tidak di-rename"): `clients` = tenant, `domains` =
   tenant_domain, `users` diperluas menjadi tenant_user, `provision_jobs` = job; role CP `superadmin/ops/client_admin/
   client_user` dipetakan ke `platform-admin/platform-viewer/tenant-admin/tenant-user` — **butuh keputusan** (Q7).
3. **Nama tipe job mengikuti konvensi kontrak yang ada** (`snake_case`, regex di dispatcher): `kc_org_ensure`,
   `kc_user_ensure`, `kc_user_set_enabled`, `kc_user_set_roles`, `kc_user_reset`, `kc_realm_sync`, `tenant_suspend`, …
4. **R1 dihapus dari §6a** (cukup atribut realm, tanpa restart) — dengan syarat verifikasi di staging bahwa
   mengaktifkan Organizations pada realm tidak mengubah token/sesi client yang ada.
5. **Siklus subscription**: tambah nilai enum `implementation`, `warranty`, `past_due` ke `subscription_status`
   (nilai lama `pending`/`grace` tidak bisa di-drop di Postgres; ditandai usang).
6. **Insight (Fase 3)**: pertimbangkan mempertahankan mart bersama + RLS (ADR 0016) dengan API yang men-set
   `app.client` dari token — isolasi setara, operasi lebih ringan dari skema per tenant. Diputuskan saat plan Fase 3.
7. **Modul Odoo**: semua rujukan `sh_oidc` → `sh_auth_oidc`.
8. **Tambahan Fase 0 di luar brief**: unlock restic, remote/backup untuk repo tanpa remote, tag ulang image drms prod.
