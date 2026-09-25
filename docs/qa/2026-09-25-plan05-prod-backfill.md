# QA — Plan 05 backfill tenant ke control plane + AC-P1 prod (UI) · 2026-09-25

- **Penguji:** QA & Security · **Versi:** infra `main` cc07738 (dispatcher = `/usr/local/sbin/infra-job`, `cmp` sama) ·
  CP prod + staging `control-plane:6d94d2b` · `infra-job-prod.path` dan `infra-job-staging.path` active.
- **Hasil ringkas:** backfill prod (`demo`/`demo`) dan staging (`ssotest`, `demo` / `staging`) lewat form + job CP — **semua job
  no-op di host** (baseline sebelum = sesudah). AC-P1 prod lewat UI **PASS**. Tidak ada perubahan prod yang tidak diharapkan;
  tidak ada STOP.
- **Metode:** container sekali pakai `qa-p1-client` (`python:3.12.11-slim-bookworm`, network `proxy`, IP tetap `10.100.0.254`,
  read-only, cap_drop ALL; host → Traefik 10.100.0.7). Login Auth.js OIDC nyata; mutasi = Server Action tanpa JS (form HTML +
  `$ACTION_ID`, Origin = AUTH_URL), request berurutan dengan jeda. Operator sementara via Admin REST `automation` :8443:
  `qap1-super` (realm `platform`, role CP `superadmin`), `qap1s-super` (realm `platform-staging`, `superadmin`).

## Pra-cek read-only (prediksi no-op sebelum job non-dry-run)

| Skrip | Cek | Hasil (demo_demo · demo_staging · ssotest_staging) |
|---|---|---|
| `provision-odoo-db.sh` (tanpa `--dry-run`) | owner DB, `base`/`sh_dbfilter_header` installed, ACL tanpa PUBLIC, `web.base.url(.freeze)`, hash password admin = file `secrets/tenants/<db>.admin-password` (passlib di container, tanpa mencetak nilai), tidak ada user dengan password = login | semua sesuai → prediksi `changed=0` |
| `render-client-route.sh` (tanpa `--dry-run`) | render template ke file sementara (sed yang sama dengan skrip) lalu `cmp` dengan file route; DNS A = 31.97.50.221, tanpa AAAA | identik ×3 → prediksi `changed=no` (tanpa HUP) |
| `provision-odoo-sso.sh --dry-run` (root) | — | `changed=0 blockers=0` ×3; client KC prod `odoo-demo-demo` redirect hanya `https://demo.erp…/sh_auth_oidc/callback` (= host yang dikirim CP) |

Baseline (`base-before`): md5 per provider (`to_jsonb(row) - write_*/create_*`) + md5 ICP (`auth_signup.invitation_scope`,
`auth_oauth.authorization_header`, `web.base.url*`) + jumlah `res_users`/tertaut per DB, stat file secret OIDC + admin-password,
sha256 route `demo-demo`, `demo-staging`, `ssotest-staging`, StartedAt `odoo-pool-a`, `odoo-staging`, `traefik`, `keycloak`,
`control-plane(-worker)`. `demo_demo`: `res_users` 6, tertaut 0; provider 4 md5 `9f4ac79e…`; secret mtime 1790309226; route
`2c23e54d…`.

## A. Backfill

### Prod (`cp.bimacreative.tech`, DB `control_plane`, sebelumnya 0 client)

Form superadmin: client `demo` ("Demo tenant") → environment `kind=demo`, host `demo.erp.bimacreative.tech` → CP mengisi
`odoo_instance=pool-a`, `db_name=demo_demo`, `url=https://demo.erp…` (env id 52d4cbcc…).

| Job (non-dry-run, UI) | id | Hasil | Cek host |
|---|---|---|---|
| `odoo_db_provision` | 7abb6890 | succeeded, `created=no changed=0`, 7,3 s | `diff base-before base-now` → kosong |
| `odoo_route` (host demo.erp…) | 538e0299 | succeeded, `changed=no`, 0,6 s | route sha256 sama, kosong |
| `odoo_sso_provision` | 45d4799f | succeeded, `changed=0 provider=4`, 9,0 s; smoke 303 ke realm `platform` | kosong |

Status akhir environment: `db_status=provisioned route_status=active sso_status=active sso_client_id=odoo-demo-demo
sso_provider_id=4`. Aktor semua job `user:952ac6ea-…` (= sub Keycloak `qap1-super`), `actor_user_id` terisi.

### Staging (`cp.staging…`)

- `ssotest`/`staging` (sudah ada, env 60ffff1e…) dan **baru**: client `demo` ("Demo tenant staging") + environment `staging`
  (env f964dc70…, `db_name=demo_staging`, url `https://demo.staging…`).
- `odoo_db_provision`: **ditolak kuota CP** `?r=quota` untuk keduanya (3 job DB/24 j sudah terpakai QA J5; reset ± 2026-09-26
  06:10 UTC) → dilewati; tidak ada file ke spool.
- `odoo_route`: 6f04f0ed (ssotest) / a7a169a0 (demo) → `changed=no`. `odoo_sso_provision`: 47c8cbe9 / 3064d79f → `changed=0`.
- Status akhir: keduanya `db_status=absent` (**belum sesuai kenyataan** — DB ada; jalankan `odoo_db_provision` dari UI setelah
  kuota pulih, akan no-op), `route_status=active`, `sso_status=active`.
- Setelah semua job staging: `diff base-before base-now` → kosong.

## B. AC-P1 prod (tenant `demo`, UI CP)

`res.users` uji `qap1-user` (id 8, email `postmaster+qap1@bimacreative.tech`, grup Internal User) dibuat via `odoo shell` di
`odoo-pool-a` (res.users tetap manual).

| # | Langkah | Hasil | Status |
|---|---|---|---|
| P1 | grant (create_kc) 46e7cafb | succeeded `action=grant invite=sent changed=4 kc_user=ae1e1850… odoo_user=8`; `tenant_user_access=active`; `res_users.oauth_provider_id=4`, oauth_uid terisi; undangan terkirim ke mailbox lokal (LMTP, tidak diteruskan) | PASS |
| P2 | login SSO E2E demo.erp (password uji diset via Admin REST, required actions dikosongkan) | `authorize 303 → KC 200 → creds 302 → callback 303 /odoo`; sesi `db=demo_demo uid=8` | PASS |
| P3 | resend pada row `active` 3280aa83 | succeeded `action=resend_invite changed=0 invite=none`; role KC tetap `['odoo_access']`; row tetap `active` | PASS |
| P4 | revoke 53a64b8c | succeeded `action=revoke changed=1`; role KC `[]`; row `revoked` | PASS |
| P5 | resend tidak ditawarkan / tidak diterima | halaman environment: 0 form revoke/resend untuk user itu; POST resend palsu → 303 `?r=precondition`, `provision_jobs` 6 → 6, audit `rejected precondition user_not_active` (aktor + `actor_user_id` terisi) | PASS |
| P6 | SSO ditolak | `callback 303 /web/login?oauth_error=2`; log pool `OIDC login refused: required client role 'odoo_access' missing from the ID token` | PASS |
| P7 | aktor | `provision_jobs` 6/6 dan audit aksi user 9/9: `actor=user:952ac6ea-0ae7-400d-9f13-306012ddf0c7` (= sub KC) + `actor_user_id` terisi; journal `inst=prod` 12 baris `actor=user:952ac6ea-…` | PASS |
| P8 | tanpa secret | nilai secret OIDC `demo_demo`, admin-password `demo_demo`, `automation-platform`, `AUTH_SECRET`/`AUTH_KEYCLOAK_SECRET` CP prod vs `provision_jobs`+`audit_logs`+`tenant_user_access`+8 `results/*.json` prod → 0 hit (kecocokan satu-satunya = `AUTH_KEYCLOAK_ISSUER`, URL publik, bukan secret); pola `secret=/password=/"token":` → 0 | PASS |

## Cleanup

- Keycloak: `qap1-super`, `postmaster+qap1@…` (realm `platform`) dan `qap1s-super` (`platform-staging`): `DELETE` → 204, `GET` → 404.
  `platform` users/count = 1 (akun asli yang sudah ada sebelumnya), `platform-staging` = 0.
- `res.users` `qap1-user` di `demo_demo` di-unlink → `res_users` 6, tertaut 0 (= baseline).
- Baris `users` CP sementara dihapus (prod 1, staging 1). Container `qa-p1-client` dihapus; spool prod/staging `new/`, `tmp/` kosong.
- **Dipertahankan (data nyata):** client/environment backfill prod `demo/demo`, staging `ssotest/staging`, `demo/staging`;
  job backfill + AC-P1 dan audit sebagai jejak; baris `tenant_user_access` `postmaster+qap1@…` (status `revoked`, user KC sudah dihapus).
- Akhir: `diff base-before base-after` → **kosong** (provider/ICP/res_users/secret mtime/route sha256/StartedAt untuk
  demo_demo, demo_staging, ssotest_staging tidak berubah); `cp.bimacreative.tech` 307 → `/login`.

## Catatan

- Staging `db_status=absent` untuk `ssotest` dan `demo` sampai `odoo_db_provision` dijalankan setelah kuota pulih (±2026-09-26 06:10 UTC).
- Kuota `odoo_db_provision` prod terpakai 1/3 (24 j) oleh backfill.
