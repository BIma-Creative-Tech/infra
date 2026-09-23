# ADR 0003 — Odoo tanpa OCA: pemilihan DB per hostname & SSO Keycloak

- **Status:** accepted (2026-09-23, GATE 1)
- **Tanggal:** 2026-09-23
- **Terkait:** CLAUDE.md §3.1, §3.2; ADR 0001; keputusan user #9

## Context

Keputusan user #9: OCA **hanya referensi**; tidak meng-install/vendor addon OCA. CLAUDE.md §3.2
bergantung pada dua modul OCA: `dbfilter_from_header` (server-tools) dan `auth_oidc` (server-auth).

### Fakta yang diverifikasi (source Odoo 19.0, di-fetch 2026-09-23)

Sumber: `https://raw.githubusercontent.com/odoo/odoo/19.0/odoo/http.py`, `.../odoo/tools/config.py`,
`.../addons/auth_oauth/**`, docs `https://raw.githubusercontent.com/odoo/documentation/19.0/content/administration/on_premise/deploy.rst`.

1. `odoo/http.py` → `def db_filter(dbs, host=None)`: jika `config['dbfilter']` diset, regex dibentuk
   dengan substitusi `%h` (host tanpa port, tanpa prefix `www.`) dan `%d` (label pertama host), lalu
   `[db for db in dbs if dbfilter_re.match(db)]`. Jika tidak ada `dbfilter` tetapi `db_name` diset →
   irisan dengan `db_name`. Host diambil dari `request.httprequest.environ['HTTP_HOST']`.
2. `db_filter` dipanggil sebagai **nama global modul** `odoo.http` di `Request._get_session_and_dbname`,
   `db_list`, dan `auth_oauth/controllers/main.py` (`http.db_filter([dbname])`) → mengganti
   atribut `odoo.http.db_filter` saat load (monkey-patch) berlaku ke semua pemanggil tersebut.
3. `Application.__call__`: `_request_stack.push(request)` dilakukan **sebelum** `request._post_init()`
   → di dalam `db_filter` objek `odoo.http.request.httprequest` sudah tersedia (header bisa dibaca).
4. **Odoo 19.0 punya header bawaan `X-Odoo-Database`**: di `_get_session_and_dbname`, bila tidak ada
   session DB, `header_dbname = httprequest.headers.get('X-Odoo-Database')` dipakai (stateless,
   `session.can_save = False`) **asal lolos `db_filter`**. → Header ini dari client **harus dibuang**
   di Traefik, dan `db_filter` kita harus membatasi ke satu DB per hostname.
5. `proxy_mode` + `HTTP_X_FORWARDED_HOST` → ProxyFix `x_for=1, x_proto=1, x_host=1` (host efektif
   berasal dari `X-Forwarded-Host` yang di-set Traefik).
6. `config.py`: opsi `--load` → dest `server_wide_modules`; `DEFAULT_SERVER_WIDE_MODULES = ['base', 'rpc', 'web']`;
   `REQUIRED_SERVER_WIDE_MODULES = ['base', 'web']` (ditambahkan otomatis). Opsi `--db-filter` → `dbfilter`;
   `--no-database-list` → `list_db`; `--proxy-mode` → `proxy_mode`.
7. `auth_oauth` (core, `license: LGPL-3`, depends `base, web, base_setup, auth_signup`):
   - `list_providers()` membangun URL dengan **`response_type='token'`** (implicit flow); `nonce`
     **dikomentari** (`# nonce=...`).
   - `state` = JSON polos `{d: db, p: provider_id, r: redirect, t?}` — **tidak ditandatangani dan tidak
     diikat ke session** (tidak ada anti-CSRF login).
   - Validasi token: `_auth_oauth_validate` memanggil `validation_endpoint` ("UserInfo URL") dengan
     access token (Bearer bila `ir.config_parameter` `auth_oauth.authorization_header` di-set, selain itu
     **query string `access_token=`**). Tidak ada pemeriksaan `aud`/`azp`/`iss`/signature — token apa pun
     yang diterima endpoint userinfo diterima.
   - User dicocokkan via `oauth_uid` (+`oauth_provider_id`); access token disimpan di `res.users.oauth_access_token`.
8. RFC 9700 (OAuth 2.0 Security BCP, Jan 2025) §2.1.2: "Clients SHOULD NOT use the implicit grant
   (response type `token`) …"; §2.1.1: PKCE "RECOMMENDED" untuk confidential client, "MUST" untuk public client.
9. OIDC Core 1.0 §3.1.3.7: ID Token yang diterima langsung dari token endpoint boleh memakai validasi
   TLS server sebagai ganti cek signature; `iss` MUST cocok, `aud` MUST memuat client_id, `exp` MUST
   dicek, `nonce` MUST dicek bila dikirim.
10. Referensi OCA (TIDAK dipakai): `OCA/server-tools/19.0/dbfilter_from_header` (v19.0.1.0.0, **AGPL-3**,
    membaca `HTTP_X_ODOO_DBFILTER` sebagai regex, aktif hanya jika `proxy_mode` dan modul ada di
    `server_wide_modules`) dan `OCA/server-auth/19.0/auth_oidc` (v19.0.1.0.0, **AGPL-3**, depends
    `auth_oauth`, external dependency `python-jose`, mendukung code flow & implicit).
11. Image `odoo:19.0` (Dockerfile resmi) berbasis `ubuntu:noble`; `debian/control` Odoo 19.0 menyertakan
    `python3-cryptography`, `python3-requests`, `python3-openssl`. **PyJWT/python-jose tidak tercantum** —
    keberadaannya di image UNVERIFIED (cek `docker run --rm odoo:19.0-20260908 python3 -c "import jwt"` saat implementasi).

## Decision

### D1. Modul sendiri `sh_dbfilter_header` (repo `odoo-addons-shared`, LGPL-3)

Desain minimal (pseudo-desain, **bukan kode final**):
- `__manifest__.py`: `version 19.0.1.0.0`, `license LGPL-3`, `depends: ['web']`, tanpa data/view.
- Load **server-wide**: `odoo.conf` → `server_wide_modules = base,rpc,web,sh_dbfilter_header`
  (sertakan `rpc` karena itu default 19.0; hapus `rpc` hanya jika diputuskan XML-RPC/JSON-RPC tidak dipakai —
  catat di ADR terpisah). Modul **tidak perlu di-install** di tiap DB; patch terjadi saat import (post_load / import `__init__`).
- Patch `odoo.http.db_filter` dengan wrapper:
  1. `dbs = original_db_filter(dbs, host)` (hormati `dbfilter` global);
  2. jika tidak ada request HTTP aktif → kembalikan `dbs` (jalur non-HTTP, cron);
  3. baca header **`X-Sh-Odoo-Db`** (nama DB **eksak**, bukan regex — menghindari regex injection/ReDoS);
     validasi format `^[a-z0-9_]{1,63}$`;
  4. header ada & valid → `[db for db in dbs if db == header]`; header tidak ada/invalid → **`[]` (fail-closed)**
     + log warning.
  5. Aktif hanya jika `proxy_mode` True (konsisten dengan fakta #5; tanpa proxy header tak dapat dipercaya).
- `odoo.conf` pool prod: `dbfilter = ^[a-z0-9]+_(prod|demo)$`, `list_db = False`, `proxy_mode = True`.
  Pool staging: `dbfilter = ^[a-z0-9]+_staging$`. (Konvensi DB `<slug>_<env>` dari §3.2; slug `[a-z0-9]+`.)
- **Traefik** (dynamic config per client `traefik/dynamic/clients/<slug>.yml`), middleware
  `headers.customRequestHeaders` per router:
  - `X-Sh-Odoo-Db: "<slug>_prod"` (atau `_demo`/`_staging`) — **menimpa** nilai dari client;
  - `X-Odoo-Database: ""` — **menghapus** header bawaan Odoo dari client (docs Traefik v3.7
    `middlewares/headers.md`: nilai `""` = "Removes");
  - Middleware yang sama dipasang di router `/websocket` (gevent port 8072) dan router utama (8069).
- Unit test modul: tanpa header → tidak ada DB; header DB lain → tidak ada DB; header benar → 1 DB;
  header regex (`.*`) → ditolak format.
- **Uji QA wajib** (dari luar): `curl -s -H 'X-Sh-Odoo-Db: other_prod' https://acme.erp.bimacreative.tech/web/login`
  harus tetap menampilkan DB `acme_prod`; `-H 'X-Odoo-Database: other_prod'` tidak berpengaruh;
  akses Odoo langsung tanpa Traefik tidak mungkin (tidak ada port publish).

### D2. SSO: modul sendiri `sh_auth_oidc` (authorization code + PKCE), dibangun di atas core `auth_oauth`

Perbandingan:

| Aspek | (a) core `auth_oauth` apa adanya | (b) `sh_auth_oidc` (usulan) |
|---|---|---|
| Flow | Implicit (`response_type=token`) — fakta #7 | Authorization code + PKCE (S256), confidential client |
| Token di URL/browser | Access token di fragment → masuk history/log/Referer | Hanya `code` sekali pakai; token lewat back-channel TLS |
| Validasi token | Panggil userinfo; **tanpa cek `aud`/`iss`** → token dari client lain di realm yang sama diterima (token substitution) | Validasi ID token: `iss`, `aud`=client_id, `azp`, `exp`, `nonce` (OIDC §3.1.3.7); signature via JWKS **atau** validasi TLS token endpoint (diizinkan OIDC §3.1.3.7) |
| CSRF login / state | `state` JSON tanpa tanda tangan, tidak diikat session | `state` acak disimpan di session + dibandingkan; `nonce` disimpan di session |
| Kepatuhan BCP | Melanggar RFC 9700 §2.1.2 (SHOULD NOT) | Sesuai RFC 9700 |
| Keycloak | Butuh implicit flow diaktifkan di client | Standard flow saja; implicit dimatikan |
| Dependensi | Tidak ada | Tanpa dependensi baru bila signature dicek dengan `python3-cryptography` (ada di deps Odoo) atau mengandalkan TLS back-channel; PyJWT UNVERIFIED |
| Usaha | Konfigurasi saja | ± modul kecil (controller signin + override `_auth_oauth_validate`), unit test |

**Rekomendasi: (b)**. `sh_auth_oidc` `depends: ['auth_oauth']` (core, LGPL-3 — boleh), menambah field
provider (issuer, token endpoint, JWKS URI, flow), controller redirect → Keycloak dengan
`response_type=code`, `code_challenge_method=S256`, `state`+`nonce` di session; callback menukar code
di token endpoint (client secret dari `ir.config_parameter`/env, **bukan** hardcode), memvalidasi ID
token, lalu memakai mekanisme login `auth_oauth` yang ada (`oauth_uid` = claim `sub`).
Pengaturan: `auth_oauth.authorization_header` di-set agar token tidak lewat query string pada panggilan userinfo.
Nama opsi client Keycloak ("Standard flow", "Implicit flow", PKCE method) **UNVERIFIED** — odoo-developer
wajib memverifikasi di docs Keycloak 26.7 sebelum menulis realm export.

**Lisensi:** OCA `auth_oidc` dan `dbfilter_from_header` = AGPL-3. Menyalin/mengadaptasi kodenya
menjadikan modul kita karya turunan AGPL-3 dan tidak kompatibel dengan kebijakan repo shared
LGPL-3 (§3.2). "Referensi" = membaca README/desain, lalu **implementasi ulang dari spesifikasi**
(OIDC Core, RFC 7636, RFC 9700) dan source core Odoo (LGPL-3). Aturan kerja untuk odoo-developer:
tidak membuka file source OCA saat menulis kode (clean-room ringan); cantumkan referensi spesifikasi
di README modul. (Catatan analisis, bukan nasihat hukum.)

### D3. Folder `addons/oca/` dihapus dari desain

`addons_path` pool: `/mnt/extra-addons/shared,/mnt/extra-addons/clients/<slug>` (plus addons core
image). Dependensi pihak ketiga baru hanya lewat ADR + audit (§3.6 "audit modul pihak ketiga").

## Alternatives

| Alternatif | Ditolak karena |
|---|---|
| Install OCA `dbfilter_from_header` / `auth_oidc` (tersedia di 19.0) | Keputusan user #9; AGPL-3; ketergantungan eksternal |
| `dbfilter = ^%h$` dengan nama DB = hostname ternormalisasi | Nama DB terikat hostname (ganti domain client = rename DB); `%h` hanya mengganti host, hostname mengandung `.` yang harus di-escape; kurang fleksibel untuk demo/staging; tetap perlu buang `X-Odoo-Database` |
| Satu instance Odoo per client (tanpa dbfilter) | RAM tidak cukup (ADR 0004) |
| `auth_oauth` implicit + hardening Keycloak (audience mapper) | Tetap implicit (RFC 9700), state tanpa CSRF, token di URL; `auth_oauth` tidak memeriksa `aud` walau token memuatnya |
| Memakai header OCA `X-Odoo-dbfilter` (regex) di modul sendiri | Regex dari header memperbesar permukaan serangan; nama DB eksak cukup |

## Consequences

- Dua modul baru wajib dikembangkan & diuji sebelum client pertama live (masuk graph FASE 2, plan 02).
- Sebelum `sh_auth_oidc` siap, login Odoo memakai password lokal (admin teknis) — client belum boleh live.
- Upgrade minor Odoo (tag tanggal baru) wajib menjalankan test `sh_dbfilter_header` karena
  bergantung pada internal `odoo.http.db_filter` / `_get_session_and_dbname` (bukan API publik).

## Security implications

- Ancaman utama: pemilihan DB client lain (tenant crossing). Mitigasi berlapis: Traefik menimpa
  `X-Sh-Odoo-Db` + menghapus `X-Odoo-Database`, modul fail-closed, `dbfilter` global ketat per pool,
  `list_db=False`, Odoo tidak publish port.
- Session cookie Odoo per hostname; session dari DB lain ditolak `db_filter` (fakta #2: "dbfilter rejects it; logging session out").
- SSO: code+PKCE+state+nonce menutup CSRF login, token substitution, dan kebocoran token via URL.
- Client secret Keycloak disimpan di `.env` 600 / system parameter, tidak di git.

## Rollback

- `sh_dbfilter_header`: hapus dari `server_wide_modules` + set `dbfilter` eksak sementara
  (mis. hanya satu client) → restart pool. Tidak ada perubahan skema DB.
- `sh_auth_oidc`: uninstall modul per DB; login kembali via password lokal admin teknis.

## Perubahan CLAUDE.md yang diusulkan

- §3 tabel SSO: "Odoo via modul OCA `auth_oidc`" → "Odoo via modul sendiri `sh_auth_oidc` (code+PKCE) di atas core `auth_oauth`".
- §3.1: hapus `addons/oca/`.
- §3.2: ganti blok `dbfilter_from_header` dengan desain D1 (header `X-Sh-Odoo-Db` eksak, fail-closed,
  Traefik menghapus `X-Odoo-Database`); ganti "Login: … OCA `auth_oidc`" dengan D2.
- §1.1 contoh paralel "Odoo addon `auth_oidc` config" → "`sh_auth_oidc`".
- `.claude/agents/analyst.md` butir 8 (verifikasi OCA) → "OCA hanya referensi; jangan install".
