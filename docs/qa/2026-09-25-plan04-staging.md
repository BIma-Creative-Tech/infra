# QA S5 — Plan 04 SSO Odoo multi-tenant (STAGING)

- **Tanggal:** 2026-09-25 · **Agent:** QA & Security Engineer · **Task:** plan 04 S5
- **Scope:** realm `platform-staging`, pool `odoo-staging`, tenant A `demo_staging`
  (host `demo.staging.bimacreative.tech`, client `odoo-demo-staging`, provider id 4) +
  tenant B `ssotest_staging` (host `ssotest.staging.bimacreative.tech`, client `odoo-ssotest-staging`, provider id 4).
- **Uji dari:** container `curlimages/curl:8.22.0` di network `proxy` IP fix `10.100.0.251`
  (klien "internet"), semua host di-resolve ke Traefik `10.100.0.7`. Diverifikasi Traefik melihat
  `ClientHost=10.100.0.251` (bukan hairpin `10.100.0.1`).
- **TIDAK diuji ulang** (sudah diverifikasi Lead di S4): AC-S1/S3/S4/S5/S6/S7.
- **Prod TIDAK disentuh** (odoo-pool-a, realm `platform`, host demo.erp) — sesuai constraint.
- Referensi: `docs/plans/04-odoo-sso-prod-multitenant.md` §4/§5, ADR 0008, `docs/03-operations/{odoo.md,keycloak.md}`.

## Ringkasan PASS/FAIL

| AC | Uji | Hasil |
|---|---|---|
| Role claim | `resource_access.<client>.roles` di example id-token (u_a ada, u_norole absen) | **PASS** |
| AC-Q1 | Login lintas host (u_a host A → sesi; host B → ditolak tanpa sesi) | **PASS** |
| AC-Q2 | Injeksi code/state client A ke callback tenant B | **PASS** |
| AC-Q3 | Authorize client A + redirect_uri host B → Keycloak tolak | **PASS** |
| AC-Q4 | Forge `X-Odoo-Database` / `X-Sh-Odoo-Db` / `X-Forwarded-Host` | **PASS** |
| AC-Q5 | Cookie `session_id` host A dipakai di host B | **PASS** |
| AC-Q6 | Provider DB B → client A, lalu REVERT + bukti | **PASS** |
| AC-Q7 | `sub` tak tertaut (email_verified=true) → tidak ada `res.users` baru | **PASS** |
| AC-Q8 | `/auth_oauth/signin` tolak + 1 provider enabled + password lokal user tertaut ditolak (web+RPC) + admin lokal OK | **PASS** |
| AC-Q9 | ≥ 20 login SSO: 0 AppSec 403 …; `redirect=//evil` dibuang | **FAIL** (BUG-S5-01) |
| AC-Q10 | User tertaut TANPA role `odoo_access` → ditolak | **PASS** |

**Sign-off DITAHAN.** 1 temuan **High** terbuka (**BUG-S5-01**): AppSec (CRS inband) memblok 403 secara
intermiten pada back-channel token OIDC (hairpin `10.100.0.1`) → login SSO gagal non-deterministik untuk
semua tenant pool. 10 dari 11 kriteria PASS. Satu catatan non-blocking (kode `oauth_error` AC-Q1) di bawah.
Perbaikan kode/config **tidak** dikerjakan QA (constraint) — diarahkan ke infra-engineer.

## Pra-uji: baseline (dipulihkan saat cleanup)

Kedua DB, provider id 4: `enabled=t`, `sh_oidc_enabled=t`, `sh_oidc_secret_source=file`,
`sh_oidc_client_secret_env=''`, `sh_oidc_required_client_role=odoo_access`, `sh_oidc_allow_signup=f`,
client_id = tenant sendiri; provider 1–3 disabled; ICP `auth_oauth.authorization_header=True`,
`auth_signup.invitation_scope=b2b`; 0 user tertaut. Modul `sh_auth_oidc` `19.0.1.2.0` (kode + DB).
Secret file `440 root:messagebus` (=gid 101 `odoo` di container), dir `750 root:messagebus`.

## Identitas uji (staging, dibuat + dibersihkan)

Dibuat via Admin REST client `automation` (`--resolve …:8443:127.0.0.1`) — setara operasi
`odoo-sso-user.sh` tetapi dengan password non-interaktif + `requiredActions=[]` (skrip sengaja tidak
menyetel password dan tidak membuat `res.users`). Password disimpan di luar repo (mode 600), tidak dicetak.

| User KC (realm platform-staging) | emailVerified | role `odoo_access` | res.users |
|---|---|---|---|
| `u_a` | true | client A | `demo_staging` id 6 (internal, tertaut prov 4) + password lokal |
| `u_norole` | true | — (tidak ada) | `demo_staging` id 7 (internal, tertaut prov 4) |
| `u_unlinked` | true | client A | tidak dibuat (uji Q7) |

## Verifikasi role claim (prasyarat Q4/Q10)

`GET …/clients/<uuid A>/evaluate-scopes/generate-example-id-token?userId=<id>`:
- `u_a`  → `aud=azp=odoo-demo-staging`, `resource_access={"odoo-demo-staging":{"roles":["odoo_access"]}}` ✓
- `u_norole` → `resource_access=null` (klaim role absen) ✓

Membuktikan role gate mendapat data yang benar walau `fullScopeAllowed=false` (risiko UNVERIFIED plan §7 tertutup).

## AC-Q1 — login lintas host

Positif — `u_a` @ host A (provider 4), alur `authorize→KC form→POST kredensial→callback`:
```
POST creds -> HTTP 302 ; callback=…/sh_auth_oidc/callback?state=…&code=REDACTED
callback -> HTTP 303 ; Location=https://demo.staging.bimacreative.tech/odoo
session -> db=demo_staging uid=6 login=u_a
```
Negatif — `u_a` @ host B: `callback -> 303 Location=…/web/login?oauth_error=2` (tanpa sesi).
Suplemen (buktikan isolasi berbasis tautan, bukan hanya role gate): setelah `u_a` diberi role
`odoo_access` pada **client B** tetapi TIDAK ditautkan di `ssotest_staging` → `oauth_error=3`
(role gate lolos, lookup user gagal); role B lalu dicabut (verifikasi `[]`).

> Catatan (non-blocking): AC-Q1 menuliskan `oauth_error=3` untuk host B. Dengan role gate (Q4) aktif —
> disetujui SETELAH teks AC ditulis — `u_a` tanpa role di client B ditolak lebih dini di role gate
> (`oauth_error=2`) sebelum lookup user. Properti keamanan (tidak ada sesi lintas tenant) tetap
> terpenuhi; suplemen di atas menunjukkan jalur `oauth_error=3` persis seperti AC bila role hadir.

## AC-Q2 — injeksi code/state ke callback tenant lain

- **Skenario A** (code sah client A → callback B, state acak/asing): B tidak punya state di sesi →
  `303 …/web/login?oauth_error=2`; log Odoo B: `OIDC login refused: missing, unknown or already used state`.
- **Skenario B** (state VALID di sesi B via authorize B + code asing client A): state lolos, exchange
  code client-A memakai kredensial client B → `token endpoint: HTTP 400` (invalid_grant) →
  `303 …/web/login?oauth_error=2`. Substitusi lintas client ditolak (`aud`/kredensial/PKCE).

## AC-Q3 — redirect_uri host B dengan client A di Keycloak

`GET …/realms/platform-staging/protocol/openid-connect/auth?client_id=odoo-demo-staging&redirect_uri=https://ssotest.staging…/sh_auth_oidc/callback&…`
→ **HTTP 400**, halaman `Invalid parameter: redirect_uri` / `We are sorry`. Kontrol (client A + redirect host A) → 200 (form login).

## AC-Q4 — header palsu tidak mengubah tenant

Authorize @ host B dengan `X-Odoo-Database: demo_staging`, `X-Sh-Odoo-Db: demo_staging`,
`X-Forwarded-Host: demo.staging…`:
```
303 redirect: client_id=odoo-ssotest-staging ; redirect_uri=https://ssotest.staging.bimacreative.tech/sh_auth_oidc/callback
```
Identik dengan kontrol tanpa forgery. Traefik menimpa `X-Sh-Odoo-Db=ssotest_staging`, menghapus
`X-Odoo-Database`, dan `url_root` memakai Host asli (X-Forwarded-* klien tidak dipercaya). DB tidak berpindah.

## AC-Q5 — reuse cookie session_id lintas host

`u_a` login @ host A → `db=demo_staging uid=6`. Nilai cookie `session_id` host A dikirim ke host B:
`get_session_info` → `db=None uid=None`; `GET /odoo` → `303 …/web/login` (tidak terautentikasi).
Tambahan (fail-safe): setelah replay ke B, cookie yang sama TIDAK lagi valid di host A
(`db=None uid=None`) — Odoo me-`logout` sesi saat `session.db` gagal `db_filter` host B (F8).

## AC-Q6 — provider DB B menunjuk client A, lalu revert

Pra: `4|odoo-ssotest-staging|t|t|file|odoo_access|f` (fingerprint md5 `cc6f5dc7…`).
Ubah `client_id → odoo-demo-staging` (simulasi admin B nakal) → authorize @ host B mengirim
`client_id=odoo-demo-staging` + `redirect_uri=host B` → Keycloak `Invalid parameter: redirect_uri`
(login mustahil). Secret exchange di DB B tetap dibaca dari `SH_OIDC_SECRET_DIR/ssotest_staging`
(dipilih `cr.dbname`, bukan `client_id`) → secret tenant lain tak dapat dirujuk.
**REVERT** `client_id → odoo-ssotest-staging`; fingerprint pasca = `cc6f5dc7…` (**MATCH=YES**).

## AC-Q7 — user tak tertaut tidak membuat res.users

`u_unlinked` (email_verified=true, punya role client A, TIDAK ditautkan) login @ host A:
`count res_users demo_staging` sebelum=6, sesudah=6; `callback 303 …/web/login?oauth_error=3`
(lolos role gate → `_sh_oidc_signin` `AccessDenied` karena `sh_oidc_allow_signup=False` + tanpa tautan).
Tidak ada auto-create walau `email_verified=true`.

## AC-Q8 — implicit flow / password lokal / admin

- `/auth_oauth/signin?state={p:4,d:demo_staging}&access_token=forged` → `303 …/web/login?oauth_error=3`,
  tanpa sesi (`db=None uid=None`). Implicit-flow core tidak bisa memberi sesi untuk provider OIDC.
- Provider enabled per DB = **1** (kedua DB; provider 1–3 disabled).
- Password lokal user **tertaut** `u_a` (`demo_staging`): web `/web/session/authenticate` →
  `AccessDenied`; XML-RPC `/xmlrpc/2/common authenticate` → `False`.
- Admin tenant `admin` (id 2, tidak tertaut, password dari `staging/odoo/secrets/tenants/demo_staging.admin-password`,
  tidak dicetak): web → `uid=2`, XML-RPC → `uid=2`. Kontrol password salah → `AccessDenied`.

## AC-Q9 — beban login + AppSec + open-redirect

- Open-redirect: login `u_a` @ host A dengan `redirect=//evil.example` → final `303 …/odoo`
  (bukan `evil.example`); link authorize di `/web/login?redirect=//evil.example` tanpa parameter redirect
  (`safe_local_redirect` membuang `//…`).
- **22 login SSO penuh** (kredensial fresh tiap login, `u_a` @ host A, dari IP uji 10.100.0.251,
  paced 15 s agar tidak kena rate-limit): **21 sukses / 22**. Baseline CrowdSec sebelum: 0 decision +
  0 alert utk IP uji, access.log 6574 baris.
- **IP uji (10.100.0.251) BERSIH:** post-run tidak ada decision (tidak di-ban), 0 alert baru untuk IP uji,
  **0 respons 403** di access log Traefik untuk IP uji. Breakdown front-channel IP uji: `oidc` 303×70 /
  200×32 / 400×2 (dua 400 = injeksi Q2), `kc` 302×31. → klausa "IP uji" AC-Q9 terpenuhi.
- **Namun 1 login gagal** (#17) karena **AppSec 403 pada back-channel token** — lihat **BUG-S5-01**. Ini
  melanggar klausa "≥20 login SSO → 0 AppSec 403": walau front-channel IP uji bersih, satu exchange token
  server-side (pool → Keycloak, hairpin 10.100.0.1) di-403 oleh CRS inband → `oauth_error=2`.
- AppSec engine aktif inline untuk router ini (`crowdsecAppsecEnabled: true`, koleksi `crowdsecurity/crs-inband`),
  jadi hasil "front-channel bersih" bermakna (bukan karena WAF mati): engine memproses 21,47k request.

## BUG-S5-01 (High) — AppSec (CRS inband) memblok back-channel token OIDC secara intermiten

- **Severity:** High · **Komponen:** CrowdSec AppSec (CRS inband) @ router `auth-oidc-backchannel` (edge) ·
  **Agent tujuan:** infra-engineer (config CrowdSec/Traefik — **bukan** kode modul).
- **Langkah reproduksi:** jalankan 22 login SSO penuh `u_a` @ `demo.staging` lewat edge (skrip S5). Amati.
- **Hasil aktual:** ~1/22 login gagal (`…/web/login?oauth_error=2`). Log Odoo:
  `sh_auth_oidc … OIDC login refused: token endpoint: HTTP 403`. Traefik access log (`10.100.0.1`,
  router `auth-oidc-backchannel@file`, path `/realms/platform-staging/protocol/openid-connect/token`) →
  `DownstreamStatus 403`, body kosong. CrowdSec alert baru `src=10.100.0.1`
  `anomaly score block: sql_injection: 5, anomaly: 5` (events=3) pada detik yang sama.
- **Akar masalah:** `authorization_code` Keycloak (mis. `8c47…-….nZ-05…-….9db8…`) yang dikirim di body POST
  token kadang cocok dengan pola CRS SQLi (score 5 = ambang block). Bergantung data (isi code acak) →
  **non-deterministik**, dapat mengenai **semua tenant** pool (back-channel = satu IP hairpin `10.100.0.1`).
- **Hasil diharapkan:** exchange token back-channel (server-to-server, client-authenticated, tidak dapat
  dijangkau penyerang eksternal) **tidak** boleh diinspeksi/di-block CRS inband → 0 kegagalan login akibat WAF.
- **Dampak:** kegagalan autentikasi SSO intermiten (~4,5% pada sampel ini) di produksi untuk seluruh user
  ber-SSO; sulit didiagnosis (tampak seperti "SSO kadang gagal, coba lagi berhasil"). **Memblok GATE Q5/S6/S7.**
- **Rekomendasi (infra-engineer, butuh persetujuan — plan §3.6 "exclusion sempit terpisah"):** nonaktifkan
  inspeksi body CRS inband (atau rule SQLi terkait) **hanya** untuk router `auth-oidc-backchannel`
  (`ClientIP 10.100.0.1/32` + path `…/protocol/openid-connect/token`), pola `pre_eval` sempit seperti
  `local/keycloak-admin-exclusions`/`odoo-crs-exclusions` — bukan mematikan AppSec global. Lalu ulang AC-Q9
  (regresi ≥ 20 login → 0 403 back-channel). Front-channel `/sh_auth_oidc/*` tetap diinspeksi penuh.
- **Bukan** kerentanan keamanan (fail-closed: login gagal, tanpa sesi); ini cacat availability/keandalan +
  false positive tooling. Front-channel dari IP uji tetap bersih; isolasi lintas-tenant (Q1–Q8, Q10) tidak terpengaruh.

## AC-Q10 — user tertaut tanpa role ditolak

`u_norole` (tertaut di `demo_staging`, TANPA role `odoo_access`) login @ host A →
`callback 303 …/web/login?oauth_error=2` (role gate menolak; log
`required client role 'odoo_access' missing from the ID token`). Tanpa sesi.

## Cleanup

- **Keycloak** (realm `platform-staging`): `u_a`, `u_norole`, `u_unlinked` → `DELETE` 204, `GET` 404;
  `users/count` = **0**. Role `odoo_access` client B pada `u_a` dicabut (verifikasi `[]`) sebelum hapus.
- **Odoo** `demo_staging`: `res.users` `u_a`(6), `u_norole`(7) **dihapus** (`unlink`); `res_users_total` kembali **4**
  (= pra-uji), `oauth_uid IS NOT NULL` = **0**. Admin tenant (id 2) tidak disentuh.
- **Provider (kedua DB) = pra-uji:** `id 4 | client_id tenant sendiri | enabled=true | sh_oidc_enabled=true |
  secret_source=file | required_role=odoo_access | allow_signup=false`; `enabled_count=1`; ICP
  `invitation_scope=b2b`, `authorization_header=True`. Provider B fingerprint pasca-Q6 = pra-Q6 (`cc6f5dc7…`).
- **Container uji** `s5test` dihapus (`docker rm -f`, confirmed absent). File password uji di-`shred` (di luar repo).
- **Tidak menyentuh:** prod (odoo-pool-a, realm `platform`, host demo.erp), config Traefik/CrowdSec/Keycloak,
  client Keycloak (tidak ada yang dibuat/dihapus). Secret file OIDC tidak diubah. IP uji tidak di-ban (tidak ada
  decision untuk dihapus).
- **Catatan sisa:** alert CrowdSec `sql_injection` untuk `10.100.0.1` (03:33:27) adalah rekaman deteksi sah
  (bukti BUG-S5-01), dibiarkan apa adanya.

## Metode & artefak

Skrip uji (di luar repo, session scratchpad): driver login curl-in-container (authorize→form KC→POST
kredensial→callback→`get_session_info`), helper Admin REST. Semua request dari `10.100.0.251` di network
`proxy`, host di-resolve ke Traefik `10.100.0.7`. Tidak ada secret/password/token yang dicetak/di-commit.
