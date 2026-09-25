# ADR 0008 — SSO Odoo multi-tenant: satu realm, satu client per tenant-env, secret per DB dari file platform

- **Status:** accepted (GATE 1 plan 04, user 2026-09-25: semua rekomendasi §8 + perubahan CLAUDE.md §3.2)
- **Tanggal:** 2026-09-25
- **Penulis:** Analyst (FASE 0/1 plan 04)
- **Terkait:** CLAUDE.md §3.2 (Login), §3.4, §3.6; ADR 0003 D1/D2 + riwayat revisi 2026-09-23 (secret dari env
  `SH_OIDC_*`, tanpa auto-create); `docs/plans/04-odoo-sso-prod-multitenant.md`; `docs/03-operations/odoo.md` §SSO;
  `docs/03-operations/keycloak.md`; repo `odoo-addons-shared` `sh_auth_oidc` 19.0.1.1.0 (`5fa8b70`).

## Context

Fakta (diverifikasi 2026-09-25, perintah di plan 04 §2):

1. `sh_auth_oidc` menyimpan konfigurasi **per DB** di `auth.oauth.provider` (client_id, issuer, token/JWKS URL,
   `sh_oidc_client_secret_env`, `sh_oidc_allow_signup`). `redirect_uri` = `request.httprequest.url_root +
   'sh_auth_oidc/callback'` (host publik per request, `proxy_mode`), tidak ada hostname/DB yang di-hardcode
   (`grep` modul: hanya `author`).
2. Sumber secret client saat ini (`models/auth_oauth_provider.py` `_sh_oidc_client_secret`):
   (a) env var bernama bebas `SH_OIDC_[A-Z0-9_]{1,100}` yang **dipilih oleh record provider** + issuer harus ada di
   env `SH_OIDC_TRUSTED_ISSUERS`; atau (b) `ir.config_parameter` `sh_auth_oidc.client_secret.<provider id>`.
   Staging memakai (a): `.env` pool staging berisi `SH_OIDC_ODOO_DEMO_STAGING_SECRET` + `SH_OIDC_TRUSTED_ISSUERS`.
   ADR 0003 (riwayat 2026-09-23) memutuskan (a), "bukan ICP di DB".
3. Env var bersifat **global per pool**: (i) menambah tenant / merotasi secret = ubah `.env` + `docker compose up -d
   --force-recreate` pool → **semua tenant di pool terputus sebentar**; (ii) record provider di DB mana pun di pool
   boleh menyebut env var tenant lain (tidak ada pengikatan env-name ↔ DB). Dampak (ii) terbatas karena redirect URI
   Keycloak eksak per client, tetapi melanggar least privilege antar-tenant. Inilah celah "per-tenant env-name mapping".
4. Validasi ID token: `iss` eksak, `aud` ∋ client_id, `azp` = client_id, `exp/iat/nbf`, `nonce` (session), signature
   JWKS RS256/384/512. Login hanya untuk `res.users` dengan (`oauth_provider_id`, `oauth_uid`=`sub`); signup hanya bila
   `sh_oidc_allow_signup` **dan** `auth_signup.invitation_scope=b2c` (core `_signup_create_user`), dan user hasil signup
   dibuat dari template **portal** (`base.template_portal_user_id`) — tidak berguna untuk user ERP internal.
5. Keycloak 26.7.4: realm `platform` (prod) 1 user, client `automation` (roles `view-realm`, `manage-users`,
   `manage-clients`; **tanpa** `manage-realm` → tidak bisa membuat authentication flow / mengubah setelan realm),
   `control-plane` (client role `superadmin|ops|client_admin|client_user`). `organizationsEnabled=false`.
   Control plane: tabel `users` unik per `keycloak_sub` dengan satu `client_id` → model "satu identitas platform,
   milik satu client" sudah ada.
6. Panggilan back-channel token dari container (Odoo pool, control plane) tiba di Traefik sebagai **`10.100.0.1`**
   (hairpin) dan masuk router `auth-login` (`ratelimit-login` 10/menit, burst 10) — satu bucket untuk semua tenant
   (access log 2026-09-23..25: 25× `platform-staging/.../token` dari 10.100.0.1).

## Decision

1. **Realm:** satu realm `platform` (prod & demo) dan `platform-staging` (staging) untuk semua tenant. Tidak ada realm
   per client.
2. **Client:** satu client OIDC confidential per tenant-env: `odoo-<slug>-<env>` (slug apa adanya, mis. `odoo-acme-co-prod`,
   `odoo-acme-co-demo`), representasi identik `odoo-demo-staging` (standard flow saja, PKCE S256, RS256,
   `fullScopeAllowed=false`, default scopes `basic profile email acr`, web origins kosong, redirect URI **eksak**
   `https://<host>/sh_auth_oidc/callback` untuk **setiap** host tenant-env (subdomain platform + domain client terverifikasi).
3. **Otorisasi tenant:** gerbang utama = tautan Odoo (`oauth_provider_id` + `oauth_uid`=`sub`) di DB tenant;
   `sh_oidc_allow_signup=False`, `auth_signup.invitation_scope=b2b`, provider bawaan lain (Odoo.com, Google, Facebook)
   nonaktif. Pertahanan berlapis (bila disetujui, GATE 1 Q4): client role `odoo_access` pada client tenant +
   mapper klaim literal `resource_access.<clientId>.roles` di ID token + field provider `sh_oidc_required_role`
   (kosong = nonaktif) yang ditolak bila role tidak ada di klaim. User A yang tidak tertaut di DB B tetap bisa
   *mengautentikasi* ke Keycloak untuk client B (Keycloak tidak memblok), tetapi Odoo B menolak (`oauth_error=3`),
   dan dengan role gate ditolak sebelum lookup user.
4. **Secret per DB dari file platform** (menggantikan env-var per tenant, mengubah riwayat ADR 0003 2026-09-23):
   modul `sh_auth_oidc` 19.0.1.2.0 menambah sumber secret "platform file": env pool tetap `SH_OIDC_SECRET_DIR`
   (mis. `/run/secrets/sh_oidc`, direktori host di-mount **ro**) → file `<SH_OIDC_SECRET_DIR>/<dbname>` dengan
   `dbname` = `self.env.cr.dbname` (divalidasi `^[a-z0-9_]{1,63}$`), **bukan** nilai yang bisa diisi admin tenant;
   issuer tetap wajib ada di `SH_OIDC_TRUSTED_ISSUERS`. File dibaca saat token exchange (tanpa cache, atau cache ≤ 60 s)
   → tenant baru & rotasi tanpa restart pool. Pool prod **tidak** memuat env `SH_OIDC_*_SECRET` apa pun.
   Nama field/opsi final ditentukan odoo-developer dan dicatat di README modul (pseudo-desain, bukan final).
5. **Otomasi:** `scripts/provision-odoo-sso.sh <slug> <env> [--host <fqdn>]... [--disable]` (idempoten) memakai client
   `automation` (Admin REST via entrypoint `admin` :8443) untuk client Keycloak + secret file, lalu `odoo shell` untuk
   modul/parameter/provider; `scripts/odoo-sso-user.sh` untuk membuat/menautkan user. Baris `RESULT …` untuk control plane.
   Control plane (nanti) hanya memanggil skrip ini lewat job antrean (§3.4) — tidak memegang secret client Odoo.
6. **Edge:** router Traefik token back-channel realm `platform`/`platform-staging` dari `ClientIP(10.100.0.1/32)`
   dengan limit sendiri (pola `auth-drms-token`), dan `/sh_auth_oidc/` tenant dengan middleware rate-limit sendiri.

## Alternatives

| Alternatif | Ditolak karena |
|---|---|
| Realm per client | Isolasi user paling keras dan branding/kebijakan per client, tetapi: `automation` tidak bisa membuat realm (butuh admin master) → setiap tenant butuh sesi admin/downtime SA sementara; control plane (Auth.js, satu issuer) kehilangan SSO lintas portal↔Odoo; staf ops/konsultan butuh akun di tiap realm; N× realm export, N× konfigurasi SMTP/brute-force. Tinjau ulang bila client meminta IdP sendiri (lebih baik via identity brokering per client). |
| Gate per client di Keycloak (authentication flow override + `conditional-user-role` + `deny-access-authenticator`; keduanya ada di daftar authenticator realm `platform`) | Kondisi role per client → satu flow per client, pembuatan flow butuh `manage-realm` (tidak dimiliki `automation`). Bisa ditambah kemudian untuk client tertentu via console. |
| Keycloak Organizations (`organization` authenticator ada; `organizationsEnabled=false`) | Perilaku klaim/scope `organization:<alias>` untuk non-anggota **UNVERIFIED** di sesi ini; butuh `manage-realm` untuk mengaktifkan; tidak menambah jaminan dibanding tautan Odoo + role klaim. Kandidat fase berikut. |
| Pertahankan env var per tenant (status quo) | Tiap onboarding/rotasi = recreate pool = semua tenant prod terputus; env var bisa dirujuk lintas DB; secret terlihat di `docker inspect`/`/proc/1/environ`. |
| Secret di `ir.config_parameter` per DB (sudah didukung modul, tanpa ubah kode) | Tanpa restart dan terikat DB, tetapi terbaca admin tenant (`base.group_system`), ikut dump DB/restore ke env lain, dan membalik keputusan ADR 0003. Cadangan bila GATE 1 menolak perubahan modul. |
| Auto-signup (b2c + `sh_oidc_allow_signup`) | Membuat user **portal** dari template, bukan user internal; membuka pendaftaran publik; tidak ada pemetaan tenant. |

## Consequences

- (+) Onboarding tenant SSO & rotasi secret tanpa restart pool setelah satu kali recreate (mount + env).
- (+) Tenant tidak bisa merujuk secret tenant lain; secret keluar dari env container.
- (+) Satu identitas per orang di platform (portal control plane + Odoo) — cocok dengan skema `users` control plane.
- (−) Perubahan modul (19.0.1.2.0) + test; staging `demo_staging` dimigrasi dari env ke file.
- (−) Isolasi user bergantung pada tautan Odoo (+ role klaim bila disetujui), bukan batas realm; admin realm `platform`
  melihat user semua client → delegasi admin ke client hanya lewat control plane, tidak lewat console Keycloak.
- (−) Satu recreate pool prod (≈10–30 s, estimasi — diukur di staging) untuk mount direktori secret + env baru.

### Hasil (plan 04 dieksekusi 2026-09-25)

- Modul `sh_auth_oidc` **19.0.1.2.0** (addons `ed7feaf`/`35e6a99`) di kedua pool. Nama final: field provider
  `sh_oidc_secret_source` (`file` default | `env` legacy) dan `sh_oidc_required_client_role`; env pool `SH_OIDC_SECRET_DIR=/run/sh-oidc`
  + `SH_OIDC_TRUSTED_ISSUERS` (wajib untuk semua sumber); sumber ICP `sh_auth_oidc.client_secret.<id>` **dihapus**. File dibaca
  setiap token exchange, tanpa cache.
- Decision #3 role gate **diaktifkan** (GATE 1 Q4): client role `odoo_access` + mapper klaim literal; role gate dievaluasi sebelum
  lookup user → user tanpa role ditolak `oauth_error=2`; user dengan role tetapi tanpa tautan → `oauth_error=3` (QA S5 AC-Q1/Q7/Q10).
  Klaim role muncul di ID token walau `fullScopeAllowed=false` (QA S5, `generate-example-id-token`).
- Owner file secret: `root:101` (gid `odoo` di container; di host bernama `messagebus`, tanpa anggota) — file `0440`, dir `0750`.
- Downtime nyata (satu kali): `odoo-staging` ±11 s (10:07 WIB; + satu restart staging tambahan ±10 s), `odoo-pool-a` ±8 s
  (11:05:47–11:05:55 WIB) — di bawah estimasi 10–30 s. Onboarding tenant kedua (`ssotest_staging`) tanpa recreate (AC-S3).
- Edge Decision #6 berlaku, plus satu konsekuensi yang tidak diperkirakan: **BUG-S5-01** — CRS inband (rule 942100, SQLi)
  kadang memblok POST token back-channel (authorization_code acak cocok pola SQLi, ±1/22 login). Ditutup dengan exclusion sempit
  `local/oidc-backchannel-exclusions` (`security/crowdsec/appsec-configs/oidc-backchannel-exclusions.yaml`, commit `1c2a528`,
  disetujui user): hanya tag `attack-sqli`, hanya in-band POST ke token endpoint realm `platform`/`platform-staging` dari
  `10.100.0.1`. Regresi 42/42 (staging) dan 12/12 (prod) login tanpa 403; SQLi dari IP lain tetap 403 (`crowdsec.md`).
- QA: staging 11/11 PASS (`docs/qa/2026-09-25-plan04-staging.md`), prod smoke PASS (`docs/qa/2026-09-25-plan04-prod.md`).
  Tenant SSO aktif: `demo_demo` (prod pool, client `odoo-demo-demo`), `demo_staging`, `ssotest_staging` (tenant regresi permanen).
- Belum: "Forgot password" realm `platform` (aksi user via console); integrasi control plane (S9, plan terpisah); env lama
  `SH_OIDC_ODOO_DEMO_STAGING_SECRET` masih ada di `.env` staging (tidak dipakai). Operasional: `docs/03-operations/odoo.md` §SSO,
  `docs/runbooks/odoo-sso-tenant.md`.

## Security implications

- File secret: host `/opt/infra/<pool>/secrets/oidc/<db>` `0440 root:101`, direktori `0750 root:101`, di luar git,
  ditulis `printf '%s'` (tanpa newline — lesson 2026-09-23). Catatan: gid 101 di host = `messagebus` (tanpa anggota);
  alternatif owner `100` (host `dhcpcd`) — **dipilih gid 101** (`ODOO_GID=101`, `scripts/lib/odoo-pools.sh`, plan 04 S2).
- Exclusion WAF back-channel (BUG-S5-01): CRS SQLi tidak diperiksa pada POST token endpoint realm `platform(-staging)` dari
  `10.100.0.1` saja; kompensasi = autentikasi client + code sekali pakai + PKCE di endpoint itu; SQLi dari sumber lain tetap diblok.
- `dbname` dari cursor, bukan input; regex menolak path traversal. Issuer tetap harus terpercaya (mencegah admin tenant
  mengarahkan token endpoint ke server sendiri untuk mengekstrak secret tenant-nya).
- Admin tenant (`base.group_system`) masih bisa mengubah provider/tautan di DB-nya sendiri (bukan batas keamanan terhadap
  admin tenant — sama seperti ADR 0003); dampaknya tidak menyeberang ke tenant lain.
- Token substitution lintas tenant ditolak oleh `aud`/`azp`; code lintas client ditolak Keycloak (redirect URI eksak +
  kredensial client); session cookie host-only + `db_filter` header → session DB lain di-logout (`odoo/http.py` baris 1844).

## Rollback

- Modul: provider kembali ke sumber env (`sh_oidc_client_secret_env`; sumber ICP sudah dihapus di 19.0.1.2.0); submodule kembali ke `5fa8b70`
  + `-u sh_auth_oidc` per DB terdampak; recreate pool.
- Per tenant: provider *Allowed* OFF, lalu `sh_auth_oidc.password_login_policy=allow` atau hapus tautan user
  (`odoo.md` §Rollback). Client Keycloak di-*disable* (bukan dihapus) oleh `provision-odoo-sso.sh --disable`.
- Edge: hapus router token/`/sh_auth_oidc/` baru (file provider Traefik hot-reload).

## Perubahan CLAUDE.md yang diusulkan (butuh persetujuan user; penulis ADR tidak mengedit)

- §3.2 Login: tambahkan "satu client Keycloak `odoo-<slug>-<env>` per tenant-env di realm `platform`/`platform-staging`;
  secret client per DB dari file platform (`SH_OIDC_SECRET_DIR/<db>`), bukan env per tenant (ADR 0008)".

## Riwayat revisi

- 2026-09-25 (S8 docs-versioning): §Consequences → Hasil (plan 04 EXECUTED), gid 101 dicatat, BUG-S5-01 exclusion dirujuk.
  Perubahan CLAUDE.md §3.2 di atas sudah diterapkan (`9069772`).
