# Runbook — SSO Keycloak untuk tenant Odoo (onboard, user, rotasi, offboard)

- **Kapan dipakai:** tenant Odoo baru di pool `odoo-pool-a`/`odoo-staging` harus login lewat Keycloak; menambah/mencabut
  user SSO; merotasi secret client; menonaktifkan SSO tenant; login SSO gagal.
- **Terkait:** ADR 0008 (`docs/adr/0008-odoo-sso-multitenant.md`), ADR 0003 D2, plan 04
  (`docs/plans/04-odoo-sso-prod-multitenant.md`), `docs/03-operations/odoo.md` §SSO, `keycloak.md` §Client Odoo per tenant,
  `crowdsec.md` §Pengecualian CRS `attack-sqli` back-channel, `traefik.md` §Rate limit SSO Odoo, README modul
  `odoo/pool-a/addons/shared/sh_auth_oidc/README.md`.
- **Prasyarat:**
  - root di VPS (`ssh -p 2221 admin@31.97.50.221` → `sudo -i`).
  - Pool sudah memuat `sh_auth_oidc` ≥ 19.0.1.2.0 dan compose plan 04 (env `SH_OIDC_SECRET_DIR=/run/sh-oidc`,
    `SH_OIDC_TRUSTED_ISSUERS`, mount `secrets/oidc`) — benar untuk kedua pool sejak 2026-09-25.
  - Secret client `automation` realm terkait ada di `/opt/infra/identity/keycloak/secrets/automation-<realm>.secret`.
  - Realm: env `prod`/`demo` → `platform`; `staging` → `platform-staging`. Client = `odoo-<slug>-<env>`, DB = `<slug dengan - → _>_<env>`.

**Dua jalur, skrip yang sama.** Sejak 2026-09-25 (plan 05, ADR 0009) langkah A–E bisa dijalankan dari control plane
(`cp.bimacreative.tech` untuk env `prod`/`demo`, `cp.staging.bimacreative.tech` untuk `staging`) — §CP di bawah. Control plane
hanya menulis job; dispatcher root `infra-job` menjalankan skrip di bawah ini dengan argumen tervalidasi, jadi hasil dan
idempotensi sama dengan jalur manual. Jalur manual (root) tetap berlaku untuk: domain client sendiri, `--first-name/--last-name`,
troubleshooting, dan saat jembatan dimatikan. **`res.users` tetap dibuat manual di Odoo** di kedua jalur.

Semua skrip: idempoten, baris terakhir `RESULT …`, exit ≠ 0 bila gagal, `--dry-run` hanya membaca. **Jangan** jalankan dengan
`bash -x` (token Admin REST ada di variabel). Jangan menampilkan isi file secret (`cat`) — cek dengan `stat`/hash saja.

## CP. Jalur control plane (ops/superadmin)

- **Prasyarat:** akun Keycloak dengan client role `control-plane` `ops` atau `superadmin` (realm `platform` / `platform-staging`);
  client + environment ada di CP (superadmin: `/clients` → "Tambah client" → `/clients/<slug>` → "Tambah environment"; `demo` wajib
  host). Iterasi 1: hanya host subdomain platform (`<label>.erp.bimacreative.tech`, `<label>.staging.bimacreative.tech`).
- Semua tombol ada di `/environments/<id>`; setiap klik = satu job (antre, bukan langsung). Hasil di "Job terbaru" dan `/jobs/<id>`
  (status, `error_code`, `RESULT`, `tail` teredaksi). Tombol ganda saat job sejenis aktif → `?r=duplicate` tanpa job baru.

| Langkah manual | Tombol CP (`/environments/<id>`) | Role | Catatan |
|---|---|---|---|
| A1 DB | "1. Provision DB" (host, wajib untuk demo) | ops, superadmin | tanpa dry-run; kuota 3 DB/24 jam per instance |
| A2 SSO sebelum route | "3. Aktifkan SSO" + centang "skip smoke (host default, sebelum route)" | ops, superadmin | hanya host default `<slug>.<erp\|staging>.bimacreative.tech` |
| A3 route | "2. Render route" (host) | ops, superadmin | DNS pre-check di skrip |
| A4 SSO + smoke | "3. Aktifkan SSO" (opsional "dry-run saja" dulu) | ops, superadmin | host SSO = host route aktif environment; dispatcher menjalankan dry-run pendahulu, `blockers>0` → `blocked_dry_run` tanpa perubahan |
| B tambah user | form "Pengguna SSO": email, login Odoo (opsional), "admin tenant (TOTP)", "buat user Keycloak + undangan", "dry-run" → "Undang" | ops, superadmin | `res.users` harus sudah ada; kalau belum → `blocked_dry_run`, tanpa user Keycloak/email |
| B undangan ulang | baris user → "Kirim ulang" | ops, superadmin | hanya baris `active`; `RESULT invite=sent\|none` di detail job |
| C cabut | baris user → "Cabut" | ops, superadmin | status baris → `revoked`; tombol "Kirim ulang"/"Cabut" hilang |
| D rotasi | "Rotasi secret SSO" (ketik slug) | superadmin | email alert; kuota 5/24 jam |
| E nonaktifkan | "Nonaktifkan SSO" (ketik slug) | superadmin | email alert |
| E hapus route | "Hapus route" (ketik slug) | superadmin | email alert |

- **Verifikasi:** job `succeeded`; `environments` `db/route/sso` status berubah (diisi dari hasil job); `RESULT changed=0` saat
  diulang (idempoten). Verifikasi teknis tambahan = bagian G (root).
- **Gagal:** `blocked_dry_run`/`locked` → perbaiki prasyarat lalu "Ulangi (job baru)" di `/jobs/<id>`. `timeout_state_unknown` →
  **jangan langsung ulang**: jalankan "dry-run saja" / skrip `--dry-run` dan cek `docker top <pool>` (proses `odoo` di container
  bisa masih hidup, `infra-jobs.md` §Keterbatasan), ulang hanya superadmin. `no_result` → cek `systemctl status
  infra-job-<inst>.path` dan `journalctl -t infra-job`. `rejected_*` → sudah ada email alert; laporkan ke Lead.
  `inconsistent` pada baris user → cabut atau undang ulang secara eksplisit.
- **Rollback:** sama dengan jalur manual (C/E), lewat tombol atau skrip root. Mematikan jembatan: `infra-jobs.md` §Rollback.

## A. Onboard SSO tenant baru

### Langkah A1. DB tenant

```bash
/opt/infra/scripts/provision-odoo-db.sh <slug> <prod|demo|staging> [--host <fqdn>]     # demo: --host wajib
```
**Verifikasi:** `RESULT … ` exit 0; `docker exec postgres psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='<db>'"` → `1`.

### Langkah A2. SSO sebelum router ada (`--skip-smoke`)

Router Traefik belum dibuat → smoke HTTP pasti gagal, maka dilewati. Cek rencana dulu, lalu terapkan:
```bash
/opt/infra/scripts/provision-odoo-sso.sh <slug> <env> --host <fqdn> [--host <fqdn2>…] --dry-run
/opt/infra/scripts/provision-odoo-sso.sh <slug> <env> --host <fqdn> [--host <fqdn2>…] --skip-smoke
```
Skrip: client Keycloak + default scopes + role `odoo_access` + mapper klaim literal → secret ke `<pool>/secrets/oidc/<db>`
(dicek terbaca di container) → install `auth_oauth,sh_auth_oidc` (one-off) → ICP `b2b`/`authorization_header` → provider lain
OFF → provider platform (sumber `file`, role gate). `--host` = daftar host **lengkap** tenant-env (redirect URI eksak per host).

**Verifikasi:**
```bash
stat -c '%a %U:%G %n' /opt/infra/<odoo/pool-a|staging/odoo>/secrets/oidc/<db>      # 440 root:messagebus (gid 101 = odoo di container)
tail -c1 /opt/infra/<pool-dir>/secrets/oidc/<db> | xxd -p                          # bukan 0a (tanpa newline)
```
STOP bila skrip berhenti dengan "secret file belum terbaca di container" (pool belum memakai compose plan 04) atau
"kode sh_auth_oidc … < 19.0.1.2.0" — jangan ubah provider manual.

### Langkah A3. Router Traefik (DNS pre-check di dalam skrip)

```bash
/opt/infra/scripts/render-client-route.sh <slug> <env> [--host <fqdn>]
```
Template memuat router `<r>-oidc` (`/sh_auth_oidc/`, `ratelimit-oidc`). Domain client sendiri: ikuti dulu
`docs/runbooks/client-domain-onboarding.md` (A1/A2, TXT verifikasi).

### Langkah A4. Jalankan ulang dengan smoke

```bash
/opt/infra/scripts/provision-odoo-sso.sh <slug> <env> --host <fqdn> [--host …]
```
**Verifikasi:** `RESULT … changed=0` (run kedua tidak mengubah apa pun) dan log `smoke <host>: /web/login memuat link; authorize → 303
https://auth.bimacreative.tech/realms/<realm> client_id=odoo-<slug>-<env>`. Tanpa restart pool (AC-S3/S4 diverifikasi di staging).

Referensi nyata: `ssotest_staging` (staging, 2026-09-25) dan `demo_demo` (prod, `--host demo.erp.bimacreative.tech`).

## B. Tambah user

`res.users` **dibuat dulu** oleh admin tenant/ops di Odoo (user internal, hak akses sesuai kebutuhan bisnis) — skrip tidak pernah
membuat `res.users` dan tidak menautkan `admin` tenant (break-glass).

```bash
# user biasa: buat user Keycloak + undangan email + role odoo_access + tautan res.users (login default = email)
/opt/infra/scripts/odoo-sso-user.sh <slug> <env> --email <email> [--login <odoo login>] --create-kc --dry-run
/opt/infra/scripts/odoo-sso-user.sh <slug> <env> --email <email> [--login <odoo login>] --create-kc
# admin tenant (milik client): sama + TOTP wajib (required action CONFIGURE_TOTP)
/opt/infra/scripts/odoo-sso-user.sh <slug> <env> --email <email> --create-kc --admin
# orang yang sudah punya akun Keycloak (tenant lain / portal): cukup grant + tautan
/opt/infra/scripts/odoo-sso-user.sh <slug> <env> --email <email> [--login <odoo login>]
# undangan hilang / kedaluwarsa (hanya bila required action masih tertunda; user harus masih punya akses — lihat Catatan)
/opt/infra/scripts/odoo-sso-user.sh <slug> <env> --email <email> [--login <odoo login>] --resend-invite
```
- Undangan = email Keycloak `execute-actions-email` (set password [+ TOTP]); user tanpa `--first-name/--last-name` mengisi nama
  sendiri saat login pertama.
- Satu identitas per orang di realm; user yang sama bisa diberi akses ke beberapa tenant (satu `--grant` per tenant).
- Setelah tertaut, password lokal Odoo user itu **ditolak** (web + RPC) — login hanya lewat tombol "Masuk dengan SSO".
- "Forgot password" realm `platform` **belum aktif** (menunggu user mengaktifkan di console). Sampai itu, reset password user
  dilakukan ops lewat admin console Keycloak (tunnel, `keycloak.md` §Akses admin console).

**Verifikasi:** `RESULT … kc_user=<uuid> odoo_user=<id> action=grant`; di DB:
```bash
docker exec postgres psql -U postgres -d <db> -tAc "SELECT id, oauth_provider_id, oauth_uid IS NOT NULL FROM res_users WHERE login='<login>'"
```
Uji login E2E oleh user (atau ops dengan user uji yang dihapus sesudahnya, pola QA S7).

## C. Cabut user

```bash
/opt/infra/scripts/odoo-sso-user.sh <slug> <env> --email <email> --revoke     # cabut role odoo_access tenant ini
```
Login ke tenant itu lalu ditolak (`oauth_error=2`). Tautan `res.users` **dibiarkan** (melepasnya mengaktifkan lagi password
lokal); arsipkan `res.users` di Odoo bila orang keluar dari tenant. Keluar dari **semua** tenant: disable user di Keycloak
(console / Admin REST) — bukan lewat skrip ini.

## D. Rotasi secret client

```bash
/opt/infra/scripts/provision-odoo-sso.sh <slug> <env> --host <fqdn> [--host …] --rotate-secret
```
Regenerasi di Keycloak → file ditulis atomik. **Tanpa restart pool**; login yang sedang di tengah exchange bisa gagal sekali
(ulangi). **Verifikasi:** `RESULT … changed=` ≥ 1, login SSO berhasil, `stat` file berubah mtime; mode tetap `440 root:messagebus`.

## E. Offboard / nonaktifkan SSO tenant

```bash
/opt/infra/scripts/provision-odoo-sso.sh <slug> <env> --host <fqdn> [--host …] --disable   # provider OFF + client KC enabled=false
/opt/infra/scripts/render-client-route.sh <slug> <env> --remove                            # bila tenant di-suspend/terminate
```
`--disable` tidak menghapus client, role, file secret, atau tautan user. User tertaut tidak bisa login password selama
tautan ada → bila tenant tetap dipakai tanpa SSO: `sh_auth_oidc.password_login_policy=allow` (`odoo.md` §SSO) atau hapus tautan
per user. Aktifkan kembali: jalankan `provision-odoo-sso.sh` tanpa `--disable`. Hapus client/file secret permanen hanya saat
terminate (destruktif, konfirmasi Lead).

**Verifikasi:** smoke di skrip "link provider tidak tampil (disabled)" (bila router masih ada).

## F. Troubleshooting

| Gejala | Arti / penyebab umum | Cek |
|---|---|---|
| `/web/login?oauth_error=2` | kegagalan apa pun sebelum lookup user: role `odoo_access` tidak ada di ID token (role gate), `state` tidak ada/terpakai (tab lama, cookie host lain), token endpoint 4xx/403, file secret hilang/tak terbaca, issuer tidak di `SH_OIDC_TRUSTED_ISSUERS`, provider disabled | `docker logs --since 10m <pool> 2>&1 \| grep 'OIDC login refused'` — pesan menyebut alasan (mis. `required client role 'odoo_access' missing from the ID token`, `missing, unknown or already used state`, `token endpoint: HTTP 403`), tanpa secret |
| `/web/login?oauth_error=3` | token valid (+ role ada) tetapi tidak ada `res.users` tertaut (`oauth_provider_id` + `oauth_uid` = `sub`) di DB ini; tidak ada auto-create | jalankan B untuk tenant itu; cek `res_users.oauth_uid` |
| Keycloak "Invalid parameter: redirect_uri" | host tidak ada di redirect URI client (host baru / domain client) | jalankan ulang A4 dengan daftar `--host` lengkap |
| `token endpoint: HTTP 403` di log pool | WAF AppSec pada back-channel (BUG-S5-01) — exclusion tidak termuat atau realm/path di luar cakupan | `docker exec crowdsec cscli appsec-configs list \| grep oidc-backchannel` → `enabled,local`; `docker exec crowdsec cscli alerts list -l 20` (src `10.100.0.1`, `sql_injection`); `grep '"RouterName":"auth-oidc-backchannel@file"' /opt/infra/traefik/logs/access.log \| grep -c '"DownstreamStatus":403'` |
| 429 di `/sh_auth_oidc/*` | `ratelimit-oidc` 20/menit burst 20 per IP (router `<r>-oidc`) — banyak user di balik satu NAT atau retry beruntun | access log `RouterName` `<r>-oidc@file`, `DownstreamStatus` 429; tuning = keputusan Lead (`traefik.md`) |
| 429 di halaman login Keycloak | `ratelimit-login` 10/menit burst 10 per IP (`/login-actions`, `/auth`) | router `auth-login@file`; brute force realm tetap ON (5 gagal) |
| 429 di back-channel | `ratelimit-oidc-backchannel` 300/menit burst 100, satu bucket untuk semua tenant kedua pool (hairpin `10.100.0.1`) | router `auth-oidc-backchannel@file` 429 |
| Tombol SSO tidak tampil | provider Allowed OFF / `sh_oidc_enabled` OFF / modul belum ter-install di DB | `provision-odoo-sso.sh … --dry-run` (daftar PLAN) |
| Semua login gagal karena Keycloak down | — | per DB `sh_auth_oidc.password_login_policy=allow` (`odoo.md` §SSO), cabut setelah pulih; `admin` tenant tetap bisa login password |

## G. Verifikasi (read-only)

```bash
# rencana tanpa perubahan (0 PLAN = sesuai)
/opt/infra/scripts/provision-odoo-sso.sh <slug> <env> --host <fqdn> --dry-run
# env pool (nama saja, bukan secret)
docker exec <odoo-pool-a|odoo-staging> printenv SH_OIDC_SECRET_DIR SH_OIDC_TRUSTED_ISSUERS
# provider per DB
docker exec postgres psql -U postgres -d <db> -tAc "SELECT id, client_id, enabled, sh_oidc_enabled, sh_oidc_secret_source, sh_oidc_required_client_role, sh_oidc_allow_signup FROM auth_oauth_provider ORDER BY id"
docker exec postgres psql -U postgres -d <db> -tAc "SELECT count(*) FROM auth_oauth_provider WHERE enabled"          # 1
docker exec postgres psql -U postgres -d <db> -tAc "SELECT key, value FROM ir_config_parameter WHERE key IN ('auth_signup.invitation_scope','auth_oauth.authorization_header')"
# smoke front-channel dari host
curl -sS --resolve <host>:443:127.0.0.1 https://<host>/web/login | grep -o '/sh_auth_oidc/authorize?provider=[0-9]*'
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' --resolve <host>:443:127.0.0.1 "https://<host>/sh_auth_oidc/authorize?provider=<id>"   # 303 ke realm, client_id benar
curl -sS -o /dev/null -w '%{http_code}\n' --resolve <host>:443:127.0.0.1 https://<host>/web/signup                                   # 404
```
Klaim role tanpa login: Admin REST `GET /admin/realms/<realm>/clients/<uuid>/evaluate-scopes/generate-example-id-token?userId=<id>`
(`keycloak.md` §Client Odoo per tenant).

## Rollback

- Per tenant: bagian E (`--disable`), lalu bila perlu `password_login_policy=allow` atau hapus tautan user.
- Per user: bagian C (`--revoke`).
- Modul/pool/edge: `odoo.md` §SSO → Nonaktifkan / rollback (submodule `5fa8b70` + sumber env, router Traefik, exclusion WAF).
- Backup sebelum plan 04: `/opt/infra/backups/odoo/demo_{staging-20260925-100640,demo-20260925-110513}-pre-plan04.{dump,filestore.tgz}`.

## Catatan

- Logout Odoo tidak mengakhiri sesi Keycloak: di komputer bersama, klik SSO bisa masuk lagi tanpa password (RP-initiated logout
  = backlog).
- Integrasi control plane: **selesai** di plan 05 (§CP di atas; `docs/03-operations/infra-jobs.md`,
  `docs/03-operations/control-plane.md` §Jembatan infra-job).
- `--resend-invite` sejak `3ca5501` (BUG-J5-01) adalah aksi tersendiri (tidak bisa digabung `--grant`/`--create-kc`): hanya
  mengirim ulang email bila user masih punya role `odoo_access` + tautan aktif; user yang sudah dicabut → blocker (pulihkan hanya
  lewat `--grant`). `RESULT` memuat `invite=sent|none` (`8226b7b`).
- Realm-export git tidak memuat client `odoo-*` (`automation` tanpa `manage-realm`).
- Perintah `password_login_policy` via `odoo shell` belum dijalankan di plan 04 (hanya semantiknya diuji di test modul T15).
