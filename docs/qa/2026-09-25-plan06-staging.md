# QA N4 — Plan 06 (segmentasi network) · gerbang STAGING · 2026-09-25

- **Penguji:** QA & Security · **Waktu:** 18:46–19:05 WIB (11:46–12:05 UTC) · **Versi:** infra `main` 2cc5f9e
  (addons staging 4bd278a, `sh_dbfilter_header` 19.0.1.1.0, `SH_DBFILTER_TRUSTED_PROXIES=10.100.13.0/24`).
- **Acuan:** `docs/plans/06-network-isolation.md` §8, §9 (AC-06-*), `docs/03-operations/network-segmentation-runbook.md`
  §"Gerbang QA staging (N4)", `scripts/net-matrix.sh`.
- **Scope:** staging saja (S1–S6 selesai; prod S7–S9 belum → jalur prod lama masih terbuka, tidak dinilai).
- **Hasil ringkas:** 8/8 butir gerbang **PASS**. Satu temuan alat uji: **BUG-N4-01 (Medium)** `net-matrix.sh` melaporkan
  target yang TERBUKA sebagai tertutup (false negative) pada container Node di network internal → hasil `--check` tidak
  dapat dipakai sebagai bukti "tertutup" sampai diperbaiki; matriks diverifikasi ulang dengan probe independen.
  **Sign-off jendela prod S7–S9: YA, bersyarat** (lihat §Sign-off).

## Anggota network (bukti `docker network inspect`)

| Network (subnet, internal) | Anggota |
|---|---|
| `db-odoo-staging` 10.100.22.0/24, int | postgres .2, odoo-staging .3 |
| `odoo-edge-stg` 10.100.13.0/24 | traefik .2, odoo-staging .3 |
| `db-cp-stg` 10.100.24.0/24, int | postgres .2, control-plane-staging .3, control-plane-staging-worker .4 |
| `db-drms-stg` 10.100.26.0/24, int | postgres .2, drms-pk-stg .4, drms-pk-stg-worker .3 |
| `drms-kas-edge` 10.100.7.0/24 / `drms-kc-admin-stg` 10.100.9.0/24, int | traefik + drms-pk-stg(+worker) |
| `kc-edge` 10.100.12.0/24 | traefik (keycloak belum — S8) |
| `db-keycloak`/`db-odoo-pool-a`/`db-cp` 10.100.20/21/23.0/24, int | postgres saja (prod belum dipindah) |
| `db` 10.100.1.0/24 (lama) | postgres, odoo-pool-a, keycloak, control-plane(-worker) — tanpa container staging |
| `proxy` 10.100.0.0/24 | traefik, keycloak, control-plane, **control-plane-staging** (R1), grafana, uptime-kuma |

## 1. Matriks jangkauan (sumber staging)

### 1a. `net-matrix.sh --check` (alat resmi) — TIDAK DAPAT DIPAKAI (BUG-N4-01)

```
NET_MATRIX_SOURCES="odoo-staging control-plane-staging control-plane-staging-worker drms-pk-stg drms-pk-stg-worker" scripts/net-matrix.sh --check
[odoo-staging] - - O O - - O - - - - - ~
[control-plane-staging] - - - - - - - - - - - - ~     SELISIH: postgres:5432(want=O,got=-/timeout) … grafana … uptime-kuma …
[control-plane-staging-worker] … SELISIH: postgres:5432(want=O,got=-/timeout) control-plane-staging:3000(want=O,got=-/timeout)
[drms-pk-stg] / [drms-pk-stg-worker] … SELISIH: postgres:5432(want=O,got=-/timeout) drms-pk-stg:3000(want=O,got=-/timeout)
RESULT: SELISIH terhadap plan 06 §8.2   (exit 1)
```
Semua sel sumber Node = `timeout`, termasuk `postgres` yang pasti terjangkau (app healthy, login DB berhasil). Lihat BUG-N4-01.

### 1b. Probe independen (per target satu proses, DNS lalu TCP terpisah, timeout 6 s)

| Sumber | OPEN | Tertutup (alasan) |
|---|---|---|
| odoo-staging | odoo-staging:8069/8072 (self), postgres (10.100.22.2), traefik:8082 (10.100.13.2, `~`) | odoo-pool-a, keycloak, control-plane(-staging), drms-pk-stg, grafana, uptime-kuma, web-starter-staging, mailserver: `DNS EAI_AGAIN` |
| control-plane-staging | postgres (10.100.24.2), control-plane / control-plane-staging / grafana / uptime-kuma (R1, `proxy`), **keycloak:8080/9000 (10.100.0.4)**, traefik:8082 | odoo-pool-a, odoo-staging, drms-pk-stg, web-starter, mailserver: DNS |
| control-plane-staging-worker | postgres (10.100.24.2), control-plane-staging:3000 (10.100.24.3, trust boundary sama) | semua lainnya: DNS |
| drms-pk-stg / -worker | postgres (10.100.26.2), drms-pk-stg:3000 (self), traefik:8082 (10.100.7.3) | odoo-pool-a, odoo-staging, keycloak, control-plane(-staging), grafana, uptime-kuma: DNS |

Selisih terhadap §8.2 hanya `control-plane-staging → keycloak:8080/9000` — **diharapkan** menurut runbook (Keycloak masih di
`proxy` sampai S8). **PASS.**

### 1c. Probe per-IP (lintas subnet tanpa DNS, 25 alamat: semua IP odoo-pool-a, odoo-staging, keycloak, postgres ×7 subnet, CP, DRMS, web-starter, mail, grafana)

| Sumber | OPEN (sisanya timeout / ENETUNREACH) |
|---|---|
| odoo-staging | 10.100.13.3:8069 & 10.100.22.3:8069 (self), postgres 10.100.22.2 |
| control-plane-staging | keycloak 10.100.0.4:8080 (R1/S8), postgres 10.100.24.2, CP 10.100.0.5, CP-stg 10.100.0.6/10.100.24.3, grafana 10.100.0.2 |
| control-plane-staging-worker | postgres 10.100.24.2, CP-stg 10.100.24.3 (lainnya ENETUNREACH — network internal tanpa route) |
| drms-pk-stg / -worker | postgres 10.100.26.2, drms 10.100.7.4 / 10.100.26.4 / 10.100.9.4 (self) |

Jalur yang diminta ditutup, terbukti juga per IP: DRMS → odoo-staging (10.100.13.3, 10.100.22.3) timeout; CP-staging →
odoo-staging timeout; **odoo-staging → odoo-pool-a via odoo-edge (10.100.3.3:8069/8072) dan via db (10.100.1.10) timeout**;
staging → postgres subnet lain (10.100.1.4, .20/.21/.23/.2x) timeout. **PASS.**

## 2. pg_hba silang (AC-06-04)

`pg_hba_file_rules`: 26 baris, kolom `error` kosong; baris per subnet 10.100.20–27; baris transisi `10.100.1.0/24` masih ada
(diharapkan sampai S10, prod belum pindah); `postgres` via host = reject; default `reject`.

Container `postgres:16.15-bookworm` sekali pakai (`--rm --read-only --cap-drop ALL`) di tiap network, `PGPASSWORD` salah, `-w`:
`HBA-OK` = lolos pg_hba lalu `password authentication failed`; `REJECT` = `pg_hba.conf rejects connection`.

| Network \ role@db | odoo_staging@ssotest_staging | control_plane_staging | pk_drms_stg_app@pk_drms_stg | odoo_pool_a@demo_demo | control_plane | keycloak | pk_drms_app@pk_drms |
|---|---|---|---|---|---|---|---|
| db-odoo-staging | **HBA-OK** | REJECT | REJECT | REJECT | REJECT | REJECT | REJECT |
| db-cp-stg | REJECT | **HBA-OK** | REJECT | REJECT | REJECT | REJECT | REJECT |
| db-drms-stg | REJECT | REJECT | **HBA-OK** | REJECT | REJECT | REJECT | REJECT |
| db-cp | REJECT | REJECT | REJECT | REJECT | **HBA-OK** | REJECT | REJECT |
| db-keycloak | REJECT | REJECT | REJECT | REJECT | REJECT | **HBA-OK** | REJECT |
| db-odoo-pool-a | REJECT | REJECT | REJECT | **HBA-OK** | REJECT | REJECT | REJECT |

Tambahan: `odoo_staging@demo_demo` dan `odoo_staging@keycloak` dari db-odoo-staging → REJECT; `postgres` dari db-odoo-staging
dan db-cp-stg → REJECT; `pk_drms_stg_app@pk_drms` → REJECT; `pk_drms_stg_owner@pk_drms_stg` → HBA-OK. **PASS.**

## 3. SSO Odoo nyata + back-channel (AC-06-07, staging)

User uji Keycloak `postmaster+qa06@…` (realm platform-staging, password via Admin REST `automation` :8443) + `res.users`
`qa06-user` di `demo_staging` (id 10) dan `ssotest_staging` (id 6) via `odoo shell`; grant lewat **UI cp.staging** (job
5bf9095a, 688d4bf9: `action=grant`, `invite=none`). Klien: container `qa-n4-client` (network `proxy`, IP tetap 10.100.0.254).

| Host | Hasil | Access log Traefik (baris baru) |
|---|---|---|
| demo.staging | `callback 303 /odoo`, sesi `db=demo_staging uid=10` | `10.100.0.1 auth-oidc-backchannel@file POST …/platform-staging/…/token 200 python-requests/2.31.0` + `GET …/certs 200` |
| ssotest.staging | `callback 303 /odoo`, sesi `db=ssotest_staging uid=6` | sama (10.100.0.1, `auth-oidc-backchannel@file`, token 200, certs 200) |

Front-channel dari 10.100.0.254 lewat `odoo-<t>-staging-oidc@file` dan `auth-login@file`. **PASS.**

## 4. D-i-D header palsu (AC-06-14)

Container `python:3.12.11-slim-bookworm` di `db-odoo-staging` (peer 10.100.22.4, di luar 10.100.13.0/24) →
`http://odoo-staging:8069` dengan `X-Sh-Odoo-Db: ssotest_staging` / `demo_staging` / tanpa header:
`/web/login` → `303 /web/database/selector` (tanpa DB) ×3; `version_info` 200 (endpoint tanpa DB). Log Odoo:
`WARNING … sh_dbfilter_header.dbfilter: X-Sh-Odoo-Db header from untrusted peer 10.100.22.4 ignored (peer not in
SH_DBFILTER_TRUSTED_PROXIES): no database selected (fail-closed)`. Via Traefik login normal (§3). **PASS.**
(Container sah lain tidak bisa mencapai odoo-staging sama sekali — §1.)

## 5. Cetak PDF bergaya (hairpin wkhtmltopdf)

`report.url` tidak diset di `demo_staging`/`ssotest_staging` (`web.base.url` = host publik). Sesi SSO `qa06-user` →
`GET https://demo.staging…/report/pdf/web.preview_externalreport/1` → **200 `application/pdf` 15 097 byte** (`%PDF-`, font
Lato tertanam, 2 gambar). Access log saat render: dari **10.100.0.1** ke `odoo-demo-staging@file`, UA WebKit wkhtmltopdf,
semua **200**: `web.report_assets_common…css`, `web.report_assets_pdf…css`, `Lato-{Reg,Lig,Hai,Bol,Bla}-webfont.woff`.
Log Odoo: `The PDF report has been generated for model: res.company, records [1]`. **PASS.**

## 6. cp.staging

Login SSO `qa06-ops` (role ops, realm platform-staging) → `/dashboard` 200, `session.roles=['ops']`. Job dry-run
`odoo_sso_provision` (demo/staging) d5910adc → **succeeded** `mode=dry-run changed=0 blockers=0` (web → DB lewat db-cp-stg,
worker → spool → dispatcher). Aktor `user:1042b343…` (= sub KC), `actor_user_id` terisi. **PASS.**

## 7. DRMS staging (`drms-kas.staging.bimacreative.tech`)

- `/api/v1/health` → 200 `application/json`.
- Login web: `/auth/login` → 302 ke `auth.bimacreative.tech/realms/drms-staging/…/auth` (client `proyekkas-web`, PKCE S256) →
  halaman login Keycloak 200 (`kc-form-login`).
- Admin REST read-only dari dalam `drms-pk-stg` (env app sendiri; token tidak dicetak): token client credentials 200,
  `GET /admin/realms/drms-staging/users/count` 200. Access log: `10.100.9.4 auth-drms-token@file POST …/token 200`,
  `10.100.9.4 drms-kc-admin-stg@file GET /admin/realms/drms-staging/users/count 200`. **PASS.**

## 8. Log Postgres

- 11:00–11:50:44 UTC (S3 live s/d awal uji QA): `pg_hba` / `password authentication failed` = **0**.
- Setelah 11:50:44: semua `rejects`/`password authentication failed` berasal dari IP container uji §2/§4
  (10.100.20.3, .21.3, .22.4, .23.3, .24.5, .26.5); **0 dari IP konsumen sah** (10.100.22.3, .24.3/.4, .26.3/.4, 10.100.1.x).
- App staging: healthy, `restarts=0`, 0 baris `OperationalError|ECONNREFUSED|ENOTFOUND|EAI_AGAIN|pg_hba|Traceback` sejak S4.
- Info (bukan dari plan 06): setiap SIGHUP Postgres mencatat `max_connections`/`shared_buffers … cannot be changed without
  restarting` dan `postgresql.conf contains errors` — nilai file default (100/128MB) berbeda dengan argumen command line compose
  (200/512MB, `source=command line`); tidak berdampak. Disarankan menyelaraskan agar log reload bersih (OBS-N4-01, Low). **PASS.**

## Temuan

### BUG-N4-01 · Medium · `scripts/net-matrix.sh` false negative (OPEN dilaporkan tertutup)
- **Langkah:** `docker exec control-plane-staging-worker node -e "$NODE_PROBE" odoo-pool-a:8069 … postgres:5432 control-plane-staging:3000`
  → semua `timeout`; target tunggal `postgres:5432` → `OPEN`; dengan `UV_THREADPOOL_SIZE=64` → `postgres`/`control-plane-staging` `OPEN`.
- **Akar:** di network `internal`, lookup nama yang tidak ada butuh ±10 s (`getent hosts odoo-pool-a` → rc 2 setelah 10,4 s);
  `net.connect({timeout:2000})` menghitung waktu DNS; `dns.lookup` memakai threadpool libuv (4) sehingga lookup nama yang ter-resolve
  mengantre di belakang lookup yang menggantung → semua `timeout`.
- **Dampak:** sel yang diharapkan tertutup bisa tampil `-` walau sebenarnya OPEN → `--check` dapat lulus palsu di jendela prod S7–S9.
- **Rekomendasi:** resolve dulu per target (sekuensial atau `UV_THREADPOOL_SIZE` ≥ jumlah target), timeout koneksi dimulai setelah
  DNS, laporkan `DNS:<code>` terpisah dari `timeout`; tambahkan probe per-IP. **Agent:** infra-engineer (skrip) — perbaikan kecil.

### OBS-N4-01 · Low · `postgresql.conf` vs command line (lihat §8).

### Tidak diuji di N4
AC-06-09 (SMTP egress/mail DRMS), -10 (Prometheus), -11 (Kuma), -12 (backup), -15 (drift compose) — di luar 8 butir gerbang.

## Cleanup

- Revoke SSO lewat UI cp.staging (d1619bfe, c2203a7c) → role dicabut; user Keycloak `qa06-ops`, `postmaster+qa06@…`:
  `DELETE` 204, `GET` 404 (realm platform-staging users/count = 0).
- `res.users` `qa06-user` di-unlink di `demo_staging` dan `ssotest_staging` (0 tersisa); baris `users` CP `qa06-ops` dihapus.
- Container `qa-n4-client` dan semua container uji `--rm` hilang; file uji dihapus.
- Snapshot tenant (md5 provider/ICP, `res_users` 6/4/4 tertaut 0, stat secret, sha256 route demo-demo/demo-staging/ssotest-staging,
  StartedAt traefik/keycloak) identik dengan baseline 16:35 WIB (container yang di-recreate Lead di S4–S6 dikecualikan;
  `odoo-pool-a` StartedAt 10:57 UTC — sebelum N4, bukan oleh QA).
- Jejak yang dibiarkan: job CP staging uji (grant/dry-run/revoke) + audit, baris `tenant_user_access` `postmaster+qa06@…` (revoked).

## Sign-off

Gerbang staging N4: 8/8 PASS, 0 Critical/High. **Sign-off jendela prod S7–S9: YA, dengan syarat** BUG-N4-01 diperbaiki
(atau matriks prod dibuktikan dengan probe independen per target + per IP seperti §1b/§1c) sebelum AC-06-01/02 prod
dinyatakan PASS.
