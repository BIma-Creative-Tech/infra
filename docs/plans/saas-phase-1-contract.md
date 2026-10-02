# SaaS Fase 1 — Kontrak job, skrip, dan model data (acuan bersama tim)

Status 2026-10-03: **KONTRAK v1.2 (Lead)** — v1.1: hasil uji gabungan (lihat §4); v1.2: temuan QA (lihat §5). Mengikat: dispatcher `scripts/infra-job/infra_job.py` (infra-engineer), skrip
`scripts/kc-*.sh`, `scripts/odoo-user.sh`, `scripts/tenant-state.sh` (infra-engineer), helper Odoo
`scripts/lib/odoo_user_ensure.py` (odoo-developer), control-plane `src/lib/job-contract.ts` + migrasi `0004`
(nextjs-developer). Perubahan kontrak = ubah dokumen ini dulu (Lead), lalu fixture `scripts/infra-job/contract/fixtures.json`.
Dasar: ADR 0009 (amandemen 2026-10-02), ADR 0017, ADR 0018, `saas-phase-1.md`. Urutan kerja Fase 1 diubah: **Users dulu**
(W3 data user + W4 job user + W5 halaman Users), lalu tenant/billing/portal.

## 0. Prinsip (berlaku untuk semua tipe baru)

1. Format file job tetap v1: `{v, job_id, type, slug, env, dry_run, actor, requested_at, args}`. Tidak ada field baru di
   level atas. `slug` = slug tenant; tenant internal = **`platform`** (slug reserved; CP menolak membuat client bernama
   `platform` lewat form).
2. Pemetaan host-side: realm dari env (`prod|demo` → `platform`, `staging` → `platform-staging`); **tenant_id dari slug
   diambil dari Organization Keycloak** (`name` = slug, `alias` = tenant_id) — host tidak pernah mempercayai tenant_id
   dari job tanpa mencocokkannya ke org. Job yang membawa `tenant_id` (hanya `kc_org_ensure`, `kc_user_ensure`) ditolak
   skrip bila org `slug` sudah ada dengan alias berbeda.
3. **Tidak pernah memberi hak lebih** (ADR 0009 BUG-J5-01): role CP `superadmin`/`ops` hanya untuk slug `platform`;
   `client_admin`/`client_user` hanya untuk slug ≠ `platform`. Skrip menolak mengubah user yang atribut `tenant_id`-nya
   ≠ tenant slug job (lintas tenant), dan menolak menonaktifkan user ber-role `superadmin` kecuali slug `platform` dan
   aktor bukan dirinya sendiri (CP yang menegakkan aktor; skrip menegakkan role).
4. Setiap skrip: root, idempoten, `--dry-run` (rencana tanpa menulis), baris terakhir `RESULT k=v ...` dengan kunci
   allowlist, tanpa mencetak secret/token. Kredensial Keycloak: `identity/keycloak/secrets/cp-admin-<realm>.secret`
   (client `cp-admin`) dan `kc-realm-sync-<realm>.secret` (client `kc-realm-sync`), dibaca lewat `scripts/lib/keycloak-admin.sh`
   (perluas: pilih client via env `KC_ADMIN_CLIENT`, default `automation` agar skrip lama tidak berubah).
5. Allowlist tipe **per instance**: kunci baru `job_types` (array string) di `/etc/infra-jobs/<inst>.conf`; tidak ada →
   default = 5 tipe lama. Tipe di luar allowlist instance → `rejected_validation` "tipe tidak diizinkan di instance ini".
   Fase 1: `staging.conf` memuat semua tipe; `prod.conf` tidak diubah.

## 1. Tipe job baru

Regex yang dipakai: `SLUG_RE`, `EMAIL_RE`, `LOGIN_RE`, `UUID_RE` (sudah ada di dispatcher; CP menyalin persis).
`NAME_RE` baru = `[A-Za-z0-9À-ɏ .,'-]{1,100}` → **ASCII saja** untuk dispatcher: `[A-Za-z0-9 .,'-]{1,100}`, tidak diawali
spasi/`-`. Nilai boolean wajib `true|false` JSON.

| Tipe | Skrip & argv | `args` (wajib / opsional) | Aturan validator dispatcher | `dry_run` | Timeout |
|---|---|---|---|---|---|
| `kc_realm_sync` | `kc-realm-sync.sh platform <env> [--approve] [--dry-run]` | wajib `{}` ; opsional `approve: bool` | `slug == "platform"`; `approve` wajib `true` bila env ∈ {prod, demo} dan `dry_run=false`; alert bila apply | ya | 300 |
| `kc_org_ensure` | `kc-org.sh <slug> <env> --tenant-id <uuid> [--dry-run]` | `{tenant_id}` | slug ≠ `platform` **atau** slug = `platform` (org internal juga dibuat) — keduanya boleh | ya | 120 |
| `kc_user_ensure` | `kc-user.sh ensure <slug> <env> --email <e> --tenant-id <uuid> [--name <n>] [--no-invite] [--adopt] [--dry-run]` | `{email, tenant_id, invite}` ; opsional `name`, `adopt` (v1.2) | `invite` bool → `--no-invite` bila false; `adopt` bool (default false) → `--adopt` bila true; `adopt=true` apply → alert | ya | 120 |
| `kc_user_set_roles` | `kc-user.sh roles <slug> <env> --email <e> --cp-role <r> [--odoo <none|user|admin>] [--dry-run]` | `{email, cp_role}` ; opsional `odoo` | `cp_role` ∈ `none, superadmin, ops, client_admin, client_user` dengan aturan §0.3; `odoo` ∈ `none,user,admin`, **dilarang** bila slug = `platform`; role Odoo berlaku untuk client `odoo-<slug>-<env>` (env job) | ya | 120 |
| `kc_user_set_enabled` | `kc-user.sh enabled <slug> <env> --email <e> --enabled <true|false> [--dry-run]` | `{email, enabled}` | `enabled=false` → `alert_reason` | ya | 120 |
| `kc_user_action_email` | `kc-user.sh email <slug> <env> --email <e> --action <A> [--dry-run]` | `{email, action}` | `action` ∈ `UPDATE_PASSWORD, VERIFY_EMAIL, CONFIGURE_TOTP` | ya | 120 |
| `odoo_user_ensure` | `odoo-user.sh <slug> <env> --email <e> [--login <l>] [--name <n>] --role <user|admin> --active <true|false> [--dry-run]` | `{email, role, active}` ; opsional `login`, `name` | slug ≠ `platform`; env harus punya DB (skrip cek) | ya | 300 |
| `odoo_tenant_config` | `odoo-tenant-config.sh <slug> <env> --tenant-check <off|compat|strict> [--dry-run]` | `{tenant_check}` | slug ≠ `platform`; `strict` → alert | ya | 300 |
| `tenant_suspend` | `tenant-state.sh <slug> <env> --suspend [--dry-run]` | `{}` | slug ≠ `platform`; alert | ya | 60 |
| `tenant_resume` | `tenant-state.sh <slug> <env> --resume [--dry-run]` | `{}` | slug ≠ `platform` | ya | 60 |

Semua tipe baru memakai **pre dry-run** otomatis (seperti `odoo_sso_provision`): dispatcher menjalankan `--dry-run` dulu,
lanjut apply hanya bila exit 0.

### 1.1 Perilaku skrip (ringkas, mengikat)

- **`kc-realm-sync.sh`** → `scripts/lib/kc_realm_sync.py` (stdlib): baca `identity/keycloak/realm/platform.json` +
  `identity/keycloak/realm/<realm>.overrides.json`; GET kondisi live; hitung diff untuk: atribut realm terkelola
  (allowlist kunci: `organizationsEnabled`, `resetPasswordAllowed`, `bruteForceProtected`, `passwordPolicy`, …), user
  profile (atribut `tenant_id`), client scope `tenant` + mapper, default scope `tenant` (BUKAN `organization`, S1) pada client terkelola
  (`control-plane` + semua `odoo-*` yang ada), requirement sub-flow `Organization` di flow `browser` = DISABLED (S1.3), role client `control-plane` dan `odoo_admin` pada setiap `odoo-*`, client SA `cp-admin`
  (keberadaan + role realm-management allowlist `manage-organizations, manage-users, view-users, query-users, query-groups`). Tidak pernah menyentuh user, secret client, client yang tidak tercantum.
  RESULT: `realm`, `changed` (jumlah perubahan), `mode` (`plan|apply`).
- **`kc-org.sh`**: cari org `name=<slug>`; tidak ada → buat (`alias=<tenant_id>`, atribut `slug`); ada dengan alias sama →
  no-op/atribut; alias beda → exit 3 `ERROR: org slug sudah terikat tenant lain`. RESULT `realm org created changed`.
- **`kc-user.sh ensure`**: cari user by email (exact); tidak ada → buat (username=email, `emailVerified=false`, atribut
  `tenant_id`, required action `UPDATE_PASSWORD`, kirim `execute-actions-email` kecuali `--no-invite`); ada → bila
  `tenant_id` kosong isi, bila beda → exit 3 (lintas tenant); pastikan member org slug. RESULT `realm kc_user created
  changed invite`. v1.2: user lama (tenant_id kosong) dengan penanda hak lama → exit 3 kecuali `--adopt`; staf platform
  dari slug ≠ platform → exit 3 (§5).
- **`kc-user.sh roles`**: set **persis** client role `control-plane` = `{cp_role}` (atau kosong untuk `none`); bila `--odoo`:
  client `odoo-<slug>-<env>` → `none`: hapus `odoo_access`+`odoo_admin`; `user`: `odoo_access` saja; `admin`: keduanya.
  Role `odoo_admin` dibuat di client bila belum ada. RESULT `kc_user roles changed`.
- **`kc-user.sh enabled`**: set `enabled`; saat `false` juga `POST /users/{id}/logout`. RESULT `kc_user enabled changed`.
- **`kc-user.sh email`**: `PUT execute-actions-email [action]`. RESULT `kc_user action invite`.
- **`odoo-user.sh`** → `docker exec <pool> odoo shell` menjalankan `scripts/lib/odoo_user_ensure.py` (odoo-developer):
  cari `res.users` by `oauth_uid` (= id user KC) lalu by `login`; buat bila tidak ada (internal user, `share=False`, tanpa
  password lokal), set group: `user` → `base.group_user` (+ group paket menyusul Fase 2), `admin` → `base.group_system`;
  link `oauth_provider_id` = provider `sh_auth_oidc` aktif, `oauth_uid`; `active` sesuai flag. Tidak pernah menyentuh
  `base.user_admin`/`base.user_root`. RESULT `db odoo_user kc_user created changed`.
- **`odoo-tenant-config.sh`**: ICP `sh_auth_oidc.expected_tenant_id` = alias org slug, `sh_auth_oidc.tenant_check` = mode.
  RESULT `db mode changed`.
- **`tenant-state.sh`**: render ulang route `<slug>-<env>.yml` lewat `render-client-route.sh` dengan flag baru
  `--suspended` (router main/login/oidc/websocket memakai middleware `tenant-suspended@file` → redirect 302 ke
  `https://<cp-host>/suspended/<slug>`) atau tanpa flag (resume, host dibaca dari route yang ada). Middleware didefinisikan
  di `traefik/dynamic/middlewares/tenant-suspended.yml`. RESULT `route state changed`.

### 1.2 Tambahan konstanta dispatcher

- `RESULT_KEYS` += `org roles enabled state tenant`.
- Kuota baru (`DEFAULT_QUOTA`, bisa dioverride conf): `kc_user_per_hour: 60`, `kc_user_disable_per_hour: 20`,
  `kc_action_email_per_hour: 20`, `kc_realm_sync_per_day: 10`, `tenant_state_per_day: 20`, `odoo_user_per_hour: 60`.
- `DEFAULT_TIMEOUTS` += tipe di tabel §1.
- `VERSION = "1.1.0"`.

## 2. Control-plane

### 2.1 Migrasi Drizzle `0004` (aditif)

- `job_type` enum += 10 tipe §1.
- `clients` += `status` (enum `tenant_status`: `active|suspended|terminated`, default `active`), `isolation` (enum
  `tenant_isolation`: `shared|dedicated`, default `shared`), `brand` text null, `kc_org_id` text null, `is_platform` bool
  default false + partial unique index `WHERE is_platform`.
- `users` += `status` (enum `user_status`: `invited|active|disabled`, default `active`), `invited_by` uuid null FK users,
  `disabled_at` timestamptz null; partial unique index `users_one_tenant_admin_uq (client_id) WHERE role='client_admin' AND
  status IN ('invited','active')`.
- `provision_jobs` += `idempotency_key` text null unique, `after_job_id` uuid null FK `provision_jobs` (rantai: dispatch
  hanya bila job sebelumnya `succeeded`; bila `failed|cancelled` → job ini `cancelled` dengan error `chain_aborted`),
  `chain_id` uuid null (grup tampilan "status per langkah"). CHECK error_code += `chain_aborted`.
- Fase 1 berikutnya (W6/W7, migrasi `0005`): subscription/invoice/plans/domains sesuai ADR 0018 — **bukan** bagian 0004.

### 2.2 Kontrak TypeScript

- `BRIDGE_JOB_TYPES` += 10 tipe; schema Zod `.strict()` per tipe = tabel §1 (regex sama persis dengan dispatcher);
  `JOB_TIMEOUT_SECONDS` sama; `RESULT_KEYS` sama. Fixture lintas bahasa: tambahkan kasus valid/invalid ke
  `scripts/infra-job/contract/fixtures.json` (sumber kebenaran) dan salin ke `tests/fixtures/infra-job/` CP.
- `idempotency_key` = `<type>:<slug>:<env>:<target>` (target = email untuk tipe user, `org` untuk org, `realm` untuk sync).
- Permission baru di `roles.ts`: `users:manage` (superadmin: semua tenant; ops: baca), `users:manage_own` (client_admin:
  hanya tenant sendiri, hanya role `client_user`/`client_admin` dengan aturan satu admin), `realm:sync` (superadmin).

### 2.3 Halaman Users (prioritas pertama)

`/users` (superadmin/ops) dengan filter tenant (termasuk `platform`); aksi: **Tambah user** (email, nama, tenant, role CP,
akses Odoo per environment tenant: none/user/admin) → rantai job: `kc_user_ensure` → `kc_user_set_roles` → per env
dengan akses ≠ none: `odoo_user_ensure`; **Nonaktifkan/Aktifkan** (`kc_user_set_enabled` + `odoo_user_ensure
active=false/true`), **Ubah role**, **Kirim reset password** (`kc_user_action_email UPDATE_PASSWORD`). Status rantai per langkah
terlihat (chain_id). Baris `users` dibuat/diupdate dari RESULT `kc_user` (id KC = `sub`) — memperbaiki juga temuan "users
prod kosong" untuk user yang dibuat lewat CP.

## 3. Uji wajib (gate kode, sebelum deploy staging)

- Dispatcher: unit test tiap validator (valid + ≥ 3 negatif per tipe, termasuk lintas tenant/role terlarang/slug platform),
  allowlist per instance (tipe baru ditolak bila conf prod tidak memuatnya), argv persis, kuota; ruff; tes lama tetap hijau.
- Skrip: `bash -n`, shellcheck, mode `--dry-run` terhadap **mock** Admin API (server HTTP lokal di container uji) — tidak
  ada panggilan tulis ke Keycloak sungguhan sebelum freeze dicabut.
- `odoo_user_ensure.py` + `sh_auth_oidc` 19.0.1.3.0: `test/run-tests.sh` (Postgres + `odoo:19.0-20260908` sekali pakai).
- CP: unit (kontrak, authz Users, lintas tenant), typecheck, lint, build; migrasi `0004` diuji ke Postgres sekali pakai.

## 4. Perubahan v1.1 (2026-10-03, setelah implementasi + uji Keycloak/Traefik sekali pakai)

- `odoo_user_ensure`: role `admin` = `base.group_user` + `base.group_system`; role `user` mencabut grup eksplisit yang
  mengimplikasikan `base.group_erp_manager` (Access Rights). User portal dengan login sama **ditolak** (exit 3), tidak
  dikonversi. Tidak ada user + `active=false` = no-op. Antarmuka helper: env `ODOO_USER_{EMAIL,LOGIN,NAME,ROLE,ACTIVE,
  KC_ID,DRY_RUN,OIDC_CLIENT_ID}` lewat `docker exec -e NAME` (nama saja); wrapper **selalu** mengisi
  `ODOO_USER_OIDC_CLIENT_ID=odoo-<slug>-<env>`; exit 0/2 (input/prasyarat)/3 (ditolak)/1 (tak terduga); baris `ERROR:` di stdout.
- Format nilai RESULT: `org`/`kc_user` = UUID Keycloak (dry-run sebelum objek ada: `-`); `created`/`enabled`/`invite`
  = `0|1`; `changed` = jumlah; `roles` = daftar nama role dipisah koma; `route` = basename file; `blockers=N` hanya pada
  dry-run; `mode` hanya `kc_realm_sync` (`plan|apply`) dan `odoo_tenant_config` (`off|compat|strict`).
- Hak SA: `cp-admin` + `view-clients`; `kc-realm-sync` + `manage-users` (ADR 0017 D6).
- Undangan/reset: `execute-actions-email` dengan `lifespan=259200` (72 jam); undangan hanya dikirim saat user dibuat —
  kirim ulang lewat `kc_user_action_email`.
- `sh_auth_oidc.tenant_check`: kosong = `off`; nilai tak dikenal = `strict` + ERROR; alasan log tambahan `invalid_expected`.
- Dispatcher: alert untuk `kc_user_set_roles cp_role=superadmin|ops` (apply); undangan apply ikut kuota
  `kc_action_email_per_hour`; dry-run skrip baru tetap exit 3 untuk pelanggaran aturan.
- Urutan deploy W2 (staging, setelah "FREEZE DICABUT"): bootstrap `kc-realm-sync` → `kc_realm_sync` (sub-flow `Organization`
  DISABLED, scope `tenant`, `cp-admin`) → uji live S1 → ubah override staging `organizationsEnabled: true` → `kc_realm_sync`
  → HUP Traefik sekali (middleware `tenant-suspended`) → job org/user.

## 5. Perubahan v1.2 (QA, 2026-10-03)

Temuan QA atas integrasi Fase 1 (branch `feat/infra-saas-p1`). Mengikat dispatcher, skrip, dan CP (fixture
`scripts/infra-job/contract/fixtures.json` diperbarui — CP menyalin ulang).

- **F1a — arg baru `adopt` pada `kc_user_ensure`:** opsional, boolean JSON, default `false`. Validator dispatcher menolak
  nilai non-bool (`rejected_validation` "args.adopt harus boolean"); argv `--adopt` (setelah `--no-invite`) hanya bila
  `true`; `adopt=true` + `dry_run=false` → `alert_reason` `"kc_user_ensure adopt"`. Tipe user lain tetap menolak kunci
  `adopt`. CP: hanya **superadmin** yang boleh mengirim `adopt=true` (UI adopsi/backfill), `idempotency_key` tidak berubah.
  Fixture: valid `kc_user_ensure_platform_adopt`, `kc_user_ensure_adopt_false`, `kc_user_ensure_tenant_adopt_dry_run`;
  invalid `kc_user_ensure_adopt_string`, `kc_user_ensure_adopt_int`, `kc_user_ensure_adopt_null`.
- **F1b — adopsi user lama (`kc-user.sh ensure`):** user yang SUDAH ADA dengan atribut `tenant_id` kosong ditolak exit 3
  ("user lama tanpa tenant_id — butuh adopt oleh superadmin") bila punya salah satu penanda: role client **efektif**
  (endpoint `role-mappings/clients/{c}/composite`: langsung + grup + role komposit) di `control-plane` atau client
  `odoo-*` mana pun, role efektif `realm-management`, atau keanggotaan Organization mana pun
  (`GET /organizations/members/{id}/organizations`). Dengan `--adopt` → diikat. Walau dengan `--adopt`: slug ≠ `platform`
  dan role `control-plane` efektif memuat `superadmin`/`ops` → exit 3 (aturan ini juga berlaku untuk user yang sudah
  terikat). User baru (dibuat run itu) dan user lama tanpa penanda tidak terpengaruh. `--adopt` tidak pernah menimpa
  `tenant_id` yang sudah terisi (beda → lintas tenant, exit 3).
- **F1c — staf platform dari slug tenant (`kc-user.sh roles|enabled|email`):** slug ≠ `platform` dan role
  `control-plane` **efektif** user memuat `superadmin`/`ops` → exit 3, apa pun atribut `tenant_id`-nya (dicek sebelum
  aturan lintas tenant). Drift (user tenant dengan role platform) diperbaiki manual di console.
- **F1d — prosedur adopsi/backfill:** `docs/03-operations/keycloak.md` §Adopsi user lama — langkah pertama setelah
  `kc_realm_sync` pertama di sebuah realm: ikat setiap staf platform dengan `kc_user_ensure` slug `platform`
  `adopt=true` (superadmin, dari CP); user SSO tenant lama (era `odoo-sso-user.sh`) diadopsi per tenant oleh superadmin
  dengan `adopt=true`.
- **F3 — mode uji lib Keycloak:** `INFRA_TEST_MODE=1` + `KC_TEST_BASE_URL` mewajibkan `KC_SECRETS_DIR` eksplisit yang
  realpath-nya di bawah `/tmp/`, dan setiap file secret harus ber-realpath di bawah `/tmp/` (else die) — secret
  sungguhan tidak pernah terkirim ke listener uji loopback.
- **F4 — `odoo-tenant-config.sh`:** alias org kosong/bukan UUID dan mode ≠ `off` → dry-run BLOKIR (`blockers=1`), apply
  exit 3; tidak pernah menulis `compat`/`strict` dengan `expected_tenant_id` kosong. Mode `off` → expected dikosongkan.
- **F5 — log tanpa email:** skrip job baru (`kc-user.sh`, `odoo-user.sh`) tidak menulis email/login mentah ke log/tail;
  yang dicatat `email#<8 hex pertama sha256(email huruf kecil)>` (`email_ref`, `scripts/lib/kc-tenant.sh`) atau id user
  Keycloak. Format RESULT tidak berubah.
- **F7 — `odoo_user_ensure.py`:** target ditemukan by `login` dengan `oauth_uid` kosong (tautan otomatis user lokal) yang
  punya `base.group_system` (langsung/implikasi) dan role ≠ `admin` → exit 3 ("user lokal admin; tautkan dengan role admin
  atau tangani manual").
- **F6 — risiko diterima:** ICP `sh_auth_oidc.tenant_check`/`expected_tenant_id` bisa diubah user `group_system` DB itu;
  lapis kedua saja, deteksi drift = pekerjaan mendatang (`docs/03-operations/odoo.md` §Cek tenant lapis kedua).
- Dispatcher `VERSION` tetap `"1.1.0"` (perubahan aditif dan kompatibel ke belakang: job tanpa `adopt` = perilaku v1.1).
