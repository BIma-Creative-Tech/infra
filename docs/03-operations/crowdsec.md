# Operasional — CrowdSec (IPS + WAF AppSec, T05)

- **Stack:** `/opt/infra/security/crowdsec/` · image `crowdsecurity/crowdsec:v1.8.1` (tag + digest, ADR 0001)
- **Bouncer Traefik:** plugin `github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin` **v1.7.1**
  (`traefik/traefik.yml` → `experimental.plugins.bouncer`, `hash` di-pin), middleware `crowdsec`
  di `traefik/dynamic/middlewares/crowdsec.yml`, mode `stream` (sinkron 30 s) + AppSec.
- **Bouncer host:** paket `crowdsec-firewall-bouncer-nftables` **0.0.36** (hold), role Ansible
  `crowdsec_bouncer` (`--tags crowdsec_bouncer`). Set nftables `table ip crowdsec` / `ip6 crowdsec6`,
  hook `input` + `forward` prioritas `filter - 10` → blok SSH 2221 **dan** port publish Docker.
  **H6 (2026-09-23):** decision dari scenario AppSec (`crowdsecurity/appsec-*`) **tidak** diterapkan di host — lihat
  §Kebijakan firewall bouncer.
- **Terkait:** ADR 0001 (AppSec menggantikan Coraza), plan 02 §3–§5, CLAUDE.md §3.6

## Arsitektur & jaringan

| Komponen | Listen | Dicapai oleh |
|---|---|---|
| LAPI | `:8080` di container; publish **`127.0.0.1:8080`** saja | firewall bouncer host; Traefik via network `crowdsec` |
| AppSec | `:7422` di container, **tidak** di-publish | Traefik via network `crowdsec` |
| Prometheus | `:6060` di container, tidak di-publish | Prometheus (T14a) via network internal **`metrics`** (10.100.5.0/24) |

- Network **`crowdsec`**: bridge `10.100.2.0/24` (bukan `--internal`: CrowdSec butuh egress ke hub &
  CAPI), anggota hanya `crowdsec` + `traefik`. Container lain di `proxy` **tidak** bisa ke LAPI/AppSec.
- Network **`metrics`** (T14a): `--internal` `10.100.5.0/24`, anggota prometheus + traefik + crowdsec + keycloak — hanya
  untuk scrape metrics. Gateway crowdsec tetap `crowdsec` (network internal tidak punya gateway; diverifikasi `ip route`).
- Traefik join `proxy` (gw_priority 1) + `crowdsec`. **`gw_priority: 1` pada `proxy` wajib** — tanpa itu
  Docker memilih `crowdsec` sebagai gateway sehingga port 80/443 di-DNAT via bridge crowdsec dan akses
  dari host/SSH tunnel terlihat sebagai `10.100.2.1` (bukan `10.100.0.1` di `ipallowlist-admin`).
- Docker memasang `raw PREROUTING -d 127.0.0.1 ! -i lo --dport 8080 -j DROP` → LAPI tidak bisa dicapai dari luar host.

## Acquisition (`security/crowdsec/acquis.d/`, di-mount read-only)

| File | Sumber | Label | Parser |
|---|---|---|---|
| `traefik.yaml` | `/var/log/traefik/access.log` (= `traefik/logs/`, ro) | `type: traefik` | `crowdsecurity/traefik-logs` |
| `sshd.yaml` | `/var/log/host/auth.log` (= `/var/log` host, ro) | `type: syslog` | `syslog-logs` → `sshd-logs` |
| `mail.yaml` (T11) | `/var/log/host/mailserver/dms/mail.log` (log docker-mailserver) | `type: syslog` | `syslog-logs` → `postfix-logs`/`postscreen-logs`/`dovecot-logs` — lihat `mail.md` §CrowdSec |
| `appsec.yaml` | listener AppSec `0.0.0.0:7422` | `type: appsec` | configs `appsec-default` + `crs-inband` + `local/odoo-crs-exclusions` (T10) + `local/keycloak-admin-exclusions` (H4) + `local/controlplane-crs-exclusions` (H6) + `local/drms-payload-crs-exclusions` (H7(a)) + `local/oidc-backchannel-exclusions` (plan 04 BUG-S5-01) |

- sshd → **`/var/log/auth.log`** (rsyslog aktif di host; journald tidak dipakai karena image alpine tanpa `journalctl`).
- Permission: container jalan sebagai root **tanpa capability** (tidak bisa bypass DAC). Membaca log lewat
  grup **`adm` (gid 4)**: `auth.log` = `syslog:adm 640`; `traefik/logs/` = `65532:adm 750` (diset
  `traefik/scripts/bootstrap.sh` & `security/crowdsec/scripts/bootstrap.sh`).

## Collections (env `COLLECTIONS`, dipasang entrypoint saat start)

`crowdsecurity/linux`, `crowdsecurity/sshd`, `crowdsecurity/traefik`, `crowdsecurity/http-cve`,
`crowdsecurity/appsec-virtual-patching`, `crowdsecurity/appsec-generic-rules`,
**`crowdsecurity/appsec-crs-inband`** (OWASP CRS blocking), **`crowdsecurity/postfix`**, **`crowdsecurity/dovecot`** (T11).

Skenario lokal (T11): `scenarios/mail-postfix-sasl-bf.yaml` (mount ro, nama `infra/mail-postfix-sasl-bf`) — brute force SASL
submission (`mail.md` §CrowdSec). T11 memasang collection + acquisition + skenario **live** (`cscli collections install` +
reload SIGHUP: 403 fail-closed 18:03:48–18:03:55 WIB, ±8 s — reload kini **hanya** `docker exec crowdsec kill -HUP 1`, H7); compose sudah memuat perubahan yang sama →
recreate berikutnya tidak mengubah perilaku.

> `appsec-virtual-patching` + `appsec-generic-rules` (daftar ADR 0001) **tidak** memblok SQLi/XSS generik —
> hanya CVE spesifik + beberapa rule generik (diuji: `?q=<script>` → 200). `appsec-crs-inband` ditambahkan
> agar payload generik → 403; **perlu ratifikasi ADR 0001 oleh Lead**. Uji false positive sudah dilakukan
> pada form login Keycloak (password dengan `' -- ; < > & #`) → tidak terblok. Tuning FP lanjutan di staging
> (Odoo, T10). Rollback CRS: hapus dari `COLLECTIONS` + `crs-inband` di `acquis.d/appsec.yaml` →
> `docker exec crowdsec cscli collections remove crowdsecurity/appsec-crs-inband` → `docker compose up -d`.

### Pengecualian CRS untuk Odoo (T10)

`appsec-configs/odoo-crs-exclusions.yaml` (di-mount ro ke `/etc/crowdsec/appsec-configs/`, nama
`local/odoo-crs-exclusions`): hook `pre_eval` → `RemoveInBandRuleByTag("attack-xss")` hanya untuk POST ke
endpoint JSON-RPC Odoo yang membawa HTML (`/web/dataset/call_kw/`, `/mail/message/`, …). Alasan & uji: `odoo.md`
§AppSec. Verifikasi dimuat: `docker exec crowdsec cscli appsec-configs list` → `local/odoo-crs-exclusions  enabled,local`.

### Pengecualian CRS 911100 untuk Admin REST Keycloak (H4, disetujui user 2026-09-23)

`appsec-configs/keycloak-admin-exclusions.yaml` (mount ro, nama `local/keycloak-admin-exclusions`): hook `pre_eval` →
`RemoveInBandRuleByID(911100)` **hanya** bila semua syarat terpenuhi: in-band, `req.Host` ∈ {`auth.bimacreative.tech`,
`auth.bimacreative.tech:8443`} (bentuk ber-port = admin via SSH tunnel; plugin bouncer meneruskan `Host` apa adanya),
`req.URL.Path` diawali `/admin/realms/`, dan `req.RemoteAddr` ∈ {`127.0.0.1`, `10.100.0.1`} (= isi `ipallowlist-admin`).
- Alasan: CRS 911100 "Method is not allowed by policy" (default `GET HEAD POST OPTIONS`) memblok setiap PUT/DELETE Admin REST
  API (ubah/hapus user, client, role) — termasuk admin console via tunnel.
- `req.RemoteAddr` = IP **tanpa port**: plugin v1.7.1 `pkg/ip.GetRemoteIP` (`net.SplitHostPort` pada RemoteAddr koneksi,
  tanpa `forwardedHeadersTrustedIPs`) → header `X-Crowdsec-Appsec-Ip` → crowdsec v1.8.1 `pkg/appsec/request.go`
  `originalHTTPRequest.RemoteAddr = clientIP`. Helper diverifikasi di `pkg/appsec/waf_helpers.go` (`GetPreEvalEnv`).
- Rule CRS lain tetap aktif di path admin (XSS/SQLi/RCE/…); 911100 tetap aktif di host/path lain (mis. `/realms/<r>/`).
- Rollback: hapus file + barisnya di `acquis.d/appsec.yaml` + mount di `docker-compose.yml` → `docker compose up -d`
  (recreate = fail-closed; terukur H4: 403 di semua router ber-`crowdsec` 17:00:43–17:01:22 WIB, ±40 s).
- **H5 (keputusan user 2026-09-23) — hook `pre_eval` kedua** untuk app ProyekKas via network `--internal` DRMS (router
  `traefik/dynamic/clients/drms-proyekkas-kc-admin.yml`): tetap **hanya** 911100, in-band, `req.Host ==
  "auth.bimacreative.tech"`, dan pasangan eksak `IpInRange(req.RemoteAddr, "10.100.8.0/24")` × path `/admin/realms/drms/`
  **atau** `IpInRange(req.RemoteAddr, "10.100.9.0/24")` × `/admin/realms/drms-staging/`. `IpInRange(ip, cidr)` diverifikasi
  dari source v1.8.1 (`pkg/exprhelpers/expr_lib.go`, `helpers.go`; hook dikompilasi dengan `exprhelpers.GetExprOptions` di
  `pkg/appsec/appsec.go`). Uji kompilasi sebelum recreate: `crowdsec -t` di container sementara (salinan `data/`) → exit 0;
  kontrol negatif (nama helper salah) → `fatal … unknown name IpInRangeX`. Recreate H5: 403 fail-closed
  17:20:43–17:21:27 WIB (±44 s). Rollback H5 saja: hapus entri hook kedua → `docker compose up -d --force-recreate`.

Uji H5 (2026-09-23, container sementara `curlimages/curl:8.22.0` di `drms-kc-admin-stg` 10.100.9.3 / `drms-kc-admin`
10.100.8.3, token service account `proyekkas-admin-api` realm env masing-masing):

| Request | Harapan | Hasil (stg / prod) |
|---|---|---|
| `PUT …/admin/realms/<realm env>/users/<uuid acak>` | 404 Keycloak (bukan 403 911100) | 404 `User not found` / 404 |
| `DELETE …/users/<uuid acak>` | 404 Keycloak | 404 / 404 |
| `GET …/users?search=<script>alert(1)</script>` | 403 AppSec | 403 (alert `xss: 40`) / 403 |
| `PUT …/users/<uuid>` body `<script>` | 403 AppSec | 403 (alert `xss: 20`) / 403 |
| `GET …/<realm env>/..%2Fplatform/users` | 403 | 403 (alert `lfi: 15`) / 403 |

### Pengecualian CRS 920420 untuk Server Action control plane (H6, disetujui user 2026-09-23)

Insiden 2026-09-23 20:23 WIB: tombol "Masuk" `https://cp.bimacreative.tech/login` = Server Action Next.js 16 (`POST /login`,
header `Next-Action: <id>`, `Content-Type: text/plain;charset=UTF-8`, body JSON `[]`) → CRS **920420** (content type tidak
diizinkan) → 949110/980170 → 403 → `crowdsecurity/appsec-native` ban 4 jam → firewall host memblok IP user termasuk SSH 2221.

Dua file (mount ro), keduanya wajib:
- `appsec-configs/controlplane-crs-exclusions.yaml` (`local/controlplane-crs-exclusions`): `pre_eval` →
  `RemoveInBandRuleByID(920420)` **hanya** bila semua: in-band, POST, `req.Host` ∈ {`cp.bimacreative.tech`,
  `cp.staging.bimacreative.tech`}, path **bukan** `/api/*` / `/_next/*`, header `Next-Action` tepat satu nilai hex kecil
  40–64 char (Next 16.3.6: 42), `Content-Type` tepat satu nilai diawali `text/plain`.
- `appsec-rules/controlplane-server-action.yaml` (`local/controlplane-server-action-json`, dirujuk `inband_rules` config
  di atas): seclang **19100** (phase 1) → `ctl:requestBodyProcessor=JSON` untuk request yang sama (Next-Action hex +
  text/plain + Host cp); **19101** (phase 2) → 403 bila `REQBODY_ERROR` (body bukan JSON valid).
  Alasan: tanpa processor, Coraza tidak mem-parse body text/plain menjadi ARGS → setelah 920420 dilepas payload XSS di body
  **lolos** (terukur: `["<script>alert(1)</script>"]` + Next-Action → 404 dari app). Body Server Action text/plain = JSON
  (React `encodeReply`; argumen FormData/Blob dikirim multipart). Dengan 19100 rule CRS 941/942/93x memeriksa `ARGS.json.*`.
- Path tidak didaftar per halaman: Server Action di-POST ke URL halaman tempat form dirender (`loginAction` → `/login`,
  `logoutAction` di `Nav` → `/dashboard`, `/clients`, halaman baru ber-Nav); daftar eksak akan diam-diam mematahkan logout.
  Yang dilepas hanya cek content-type; isi body justru kini diperiksa sebagai JSON.
- Akses header di `pre_eval` memakai operator expr standar (`"Next-Action" in req.Header`, `req.Header["Next-Action"][0]`),
  bukan method `Header.Get`; `req.Header` = header asli klien (plugin v1.7.1 menyalin semua header; crowdsec v1.8.1
  `request.go` `r.Clone`). Uji kompilasi `crowdsec -t` di container sementara (salinan `data/`) → exit 0; kontrol negatif
  `req.Headerz` → `type http.Request has no field Headerz`; nama rule salah → `no appsec-rules found`; `chainX` → `invalid action`.
- Recreate: #1 23:02:19–23:02:58 WIB (±39 s, exclusion saja), #2 23:06:44–23:07:24 WIB (±40 s, + rule 19100/19101) — 403
  fail-closed di semua router ber-`crowdsec`.
- Rollback: hapus kedua file + barisnya di `acquis.d/appsec.yaml` + dua mount di `docker-compose.yml` → `docker compose up -d`.

Uji H6 (2026-09-23, dari host = 10.100.0.1 privat → alert tanpa decision; total 8 POST; id acak = 42 hex):

| Request | Harapan | Hasil (Downstream / Origin) |
|---|---|---|
| (sebelum H6) `POST cp/login` NA acak + text/plain `[]` | 403 (920420) | 403 / 0, alert `anomaly: 5` |
| `POST cp/login` NA acak + text/plain `[]` | bukan 403 AppSec | 404 / 404 (Next.js: action id tidak dikenal) |
| `POST cp/login` tanpa NA + text/plain | 403 (920420 tetap) | 403 / 0 |
| `POST cp/login` NA + `["<script>alert(1)</script>"]` (hanya exclusion) | 403 | **404 / 404 — lolos** → alasan rule 19100 |
| idem setelah 19100/19101 | 403 | 403 / 0, rule 941100/941110/941160/941390 pada `ARGS.json.0` → 949110 |
| `POST cp.staging/login` NA + `[]` | bukan 403 | 404 / 404 |
| `POST cp.staging/login` NA + body `not-json <b>x` | 403 (19101) | 403 / 0, rule 19101 (`REQBODY_ERROR`) |
| Alur nyata: `GET /login` → id `$ACTION_ID_…` → `POST /login` NA + `[]` | redirect Keycloak | GET 200; POST 200 + `x-action-redirect: https://auth.bimacreative.tech/realms/platform/protocol/openid-connect/auth?…;push`, cookie `__Secure-authjs.{state,pkce.code_verifier,nonce,callback-url}` |

`cscli decisions list` setelah uji: tidak ada `10.100.*` / `103.108.130.9`.

### Pengecualian CRS 920420 untuk Server Action admin Payload ProyekKas (H7(a), disetujui user 2026-09-23)

Pemicu: ban 20:55 WIB (`POST /admin/collections/users/create` drms-kas.staging) — admin Payload CMS memakai Server Action
Next.js 16.3.6 (`serverFunction` di `app/(payload)/layout.tsx` + satu action `@payloadcms/next` Root layout; id 42 hex dari
`.next/server/server-reference-manifest.json` image `proyekkas-web:0.1.0-stg-f8529e6`), di-POST ke URL halaman `/admin/...`
dengan `text/plain` → 920420 → 403. Pola sama persis dengan H6, file terpisah (host/path berbeda, rollback terpisah):
- `appsec-configs/drms-payload-crs-exclusions.yaml` (`local/drms-payload-crs-exclusions`): `pre_eval` →
  `RemoveInBandRuleByID(920420)` hanya bila: in-band, POST, `req.Host` ∈ {`drms-kas.staging.bimacreative.tech`,
  `drms-kas.bimacreative.tech`} (prod: router belum ada), path diawali `/admin/`, `Next-Action` tepat satu nilai hex kecil
  40–64, `Content-Type` tepat satu nilai diawali `text/plain`. Multipart (upload File) tidak disentuh (sudah diizinkan CRS).
- `appsec-rules/drms-payload-server-action.yaml` (`local/drms-payload-server-action-json`): **19102** (phase 1,
  `ctl:requestBodyProcessor=JSON`) + **19103** (phase 2, 403 bila `REQBODY_ERROR`), kondisi sama (+ `REQUEST_FILENAME
  @beginsWith /admin/`).
- **19104** (2026-10-05, file yang sama): POST token endpoint realm `drms` / `drms-staging` (host `auth.bimacreative.tech`)
  dengan `client_id=admin-cli` → 403. Alasan: Keycloak 26 menolak mengubah client bawaan `admin-cli` (403 juga untuk
  admin master; konsol juga), sehingga password grant-nya ditutup di edge. Diuji: admin-cli → 403, `proyekkas-mobile`
  → `invalid_grant` (tidak terpengaruh). Diterapkan dengan edit in-place (inode sama) + `docker exec crowdsec kill -HUP 1`
  (403 fail-closed ±9 s, 10:53:50–10:53:59 WIB). Catatan YAML: hindari ": " di dalam `msg:'…'` (rule gagal dimuat).
- Uji kompilasi sebelum recreate: `crowdsec -t` di container sementara (salinan `data/`) → exit 0; kontrol negatif
  (`@beginsWithX`) → `fatal … operator beginsWithX not found`.
- Recreate (bersamaan dengan `restart: always` H7): 403 fail-closed 23:26:00–23:26:38 WIB (±38 s).
- Rollback: hapus kedua file + barisnya di `acquis.d/appsec.yaml` + dua mount di `docker-compose.yml` → `docker compose up -d`.

Uji H7(a) (2026-09-23, dari host = 10.100.0.1 → alert tanpa decision; 6 POST; id acak 42 hex):

| # | Request (`https://drms-kas.staging.bimacreative.tech`) | Harapan | Hasil (Downstream / Origin, rule) |
|---|---|---|---|
| 1 | `POST /admin/collections/users/create` NA acak + text/plain `[]` | bukan 403 WAF | 404 / 404 (Next.js: action id tidak dikenal) |
| 2 | idem tanpa `Next-Action` | 403 (920420 tetap) | 403 / 0, `native_rule:920420` |
| 3 | idem NA + `["<script>alert(1)</script>"]` | 403 | 403 / 0, `xss: 20` pada `ARGS.json.0` (19102 aktif) |
| 4 | idem NA + body `not-json <b>x` | 403 (19103) | 403 / 0, `native_rule:19103` (`REQBODY_ERROR`) |
| 5 | `POST /` NA + `[]` (di luar `/admin/`) | 403 (920420) | 403 / 0, `native_rule:920420` |
| 6 | Alur nyata: action id asli `4016d1f3…4c00` (`serverFunction`) + `[{"name":"h7-noop","args":{}}]` | sampai ke app, tanpa data dibuat | 500 / 500, log app `Error: Unknown Server Function: h7-noop` (content-type `text/x-component`) |

`cscli decisions list` setelah uji: tidak ada `10.100.*`.

> Celah platform (di luar H6, belum ditangani): CRS/base-config crowdsec tidak punya rule `REQBODY_ERROR` global — body
> `application/json` yang rusak tidak di-parse dan tidak ditolak. H6 hanya menutupnya untuk Server Action cp (19101).

Uji H4 (2026-09-23, dari host = 10.100.0.1, `--resolve …:443:127.0.0.1`, token service account `automation` realm
`platform-staging`):

| Request | Harapan | Hasil |
|---|---|---|
| `PUT /admin/realms/platform-staging/users/<id>` `{"enabled":false}` | 204 (sebelumnya 403, alert 911100) | 204, user `enabled=false` |
| `DELETE /admin/realms/platform-staging/users/<id>` → `GET` | 204 → 404 | 204 → 404 |
| `GET /admin/realms/…/users?search=<script>alert(1)</script>` | 403 AppSec | 403, alert `xss: 40` (Origin 0) |
| `GET /admin/realms/…/users?search=' OR 1=1--` | 403 AppSec | 403, alert `sql_injection: 10` |
| `PUT /admin/realms/…/users/<id>` body `<script>` | 403 AppSec | 403, rule 941100/941110/941160/941390 — **tanpa** 911100 |
| `TRACE`/`PROPFIND https://status.bimacreative.tech/` | 403 (911100) | 403, alert `native_rule:911100` |
| `TRACE`/`PROPFIND https://auth.bimacreative.tech/realms/platform/` | 403 (911100) | 403, alert `native_rule:911100` |
| `PUT https://auth.bimacreative.tech/realms/platform-staging/` | 403 (911100) | 403, alert `native_rule:911100` |
| Odoo: POST HTML ke `/web/dataset/call_kw/…` vs `/web/session/get_session_info` | 200 vs 403 | 200 vs 403 (T10 utuh) |
| cp / cp.staging / auth discovery / demo.erp / demo.staging / status | 307/307/200/200/200/200 | sesuai |

Alert uji (`waf`, 10.100.0.1) tidak menghasilkan decision (parser whitelist IP privat) — `cscli decisions list -i 10.100.0.1`
→ `No active decisions`.

### Pengecualian CRS `attack-sqli` untuk back-channel token OIDC (plan 04 BUG-S5-01, disetujui user 2026-09-25)

Pemicu: QA S5 (`docs/qa/2026-09-25-plan04-staging.md` §BUG-S5-01, High) — 1 dari 22 login SSO Odoo gagal
(`oauth_error=2`, log Odoo `token endpoint: HTTP 403`): POST token endpoint dari pool (hairpin `10.100.0.1`, router
`auth-oidc-backchannel`) diblok AppSec, alert `anomaly score block: sql_injection: 5, anomaly: 5` (rule 942100, libinjection
SQLi) — `authorization_code` acak Keycloak kadang cocok pola SQLi. Non-deterministik, berlaku untuk semua tenant.
- `appsec-configs/oidc-backchannel-exclusions.yaml` (mount ro, nama `local/oidc-backchannel-exclusions`, commit `1c2a528`):
  `pre_eval` → `RemoveInBandRuleByTag("attack-sqli")` hanya bila: in-band, `POST`, `req.Host == auth.bimacreative.tech`, path
  **eksak** `/realms/platform/protocol/openid-connect/token` atau `/realms/platform-staging/protocol/openid-connect/token`,
  `req.RemoteAddr == 10.100.0.1`. Realm `drms*`/`master`, `/auth`, `/login-actions` tidak tercakup; XSS/RCE/LFI/protocol,
  virtual patching & generic rules tetap aktif di path itu. Endpoint tetap mewajibkan autentikasi client + code sekali pakai + PKCE.
- Uji config di container sementara (`crowdsec -t`) sebelum recreate; recreate crowdsec 10:50:07–10:50:54 WIB (±47 s, semua host
  ber-CrowdSec 403 fail-closed).
- Verifikasi dimuat: `docker exec crowdsec cscli appsec-configs list` → `local/oidc-backchannel-exclusions  enabled,local`.
- Rollback: hapus file + barisnya di `acquis.d/appsec.yaml` + mount di `docker-compose.yml` → `docker compose up -d`
  (recreate, 403 ±40–50 s).

Uji regresi (QA S5 03:52–04:04 UTC staging; QA S7 prod realm `platform`):

| Request | Harapan | Hasil |
|---|---|---|
| 42 login SSO penuh `demo.staging` (paced 15 s) | 0 kegagalan WAF | 42/42 sukses; 0× 403 dari 47 request `auth-oidc-backchannel`; tanpa alert baru |
| 12 login SSO penuh `demo.erp` (prod) | 0 kegagalan WAF | 12/12 sukses; `platform` 200 ×17, 0× 403; tanpa alert baru |
| `POST …/platform-staging/…/token` `code=1' OR '1'='1 --` dari IP uji `10.100.0.251` (bukan hairpin) | 403 (SQLi tetap aktif) | 403 (router `auth-login`), alert 214 `sql_injection: 5` |
| idem `code=abc` (kontrol benign) | bukan WAF | 401 dari Keycloak |

## Start / stop

```bash
cd /opt/infra/security/crowdsec
./scripts/bootstrap.sh            # sekali / idempoten: network crowdsec, data/, traefik/secrets, grup logs
docker compose up -d
docker compose ps                 # crowdsec: (healthy)  — healthcheck `cscli lapi status`
./scripts/materialize-data.sh     # SEKALI setelah start pertama (lihat catatan read_only)
docker compose down               # stop (data/ tetap)
```
- `read_only: true`: entrypoint image membuat symlink datafile ke `/staging` (layer image) → `cscli hub
  upgrade` gagal (`chtimes …: read-only file system`). `materialize-data.sh` mengganti symlink dengan salinan
  nyata di `data/db` (idempoten).
- State: `data/config` (= `/etc/crowdsec`, termasuk kredensial machine & CAPI) dan `data/db` (SQLite +
  datafile) — mode 700 root, di-ignore git (`**/data/`). Masuk backup (ADR 0006).
- Urutan start: crowdsec **sebelum** traefik bila keduanya mati (plugin `streamStartupBlock: true` menunggu
  LAPI; `crowdsecAppsecUnreachableBlock: true` → selama AppSec tidak terjangkau semua request ke router ber-
  middleware `crowdsec` = **403 (fail-closed)**). Restart crowdsec = gangguan singkat ±20–40 s.
- Firewall bouncer: `systemctl status crowdsec-firewall-bouncer`, log `/var/log/crowdsec-firewall-bouncer.log`.

## Perintah harian

```bash
docker exec crowdsec cscli metrics show acquisition parsers appsec bouncers
docker exec crowdsec cscli bouncers list          # traefik-bouncer & host-firewall-bouncer, "Last API pull"
docker exec crowdsec cscli alerts list -l 20
docker exec crowdsec cscli decisions list          # decision lokal (cscli/crowdsec)
docker exec crowdsec cscli decisions list -a       # termasuk blocklist CAPI
nft list table ip crowdsec                         # set yang diterapkan firewall bouncer
```

### Ban / unban manual
```bash
docker exec crowdsec cscli decisions add --ip <IP> --duration 4h --reason "<alasan>"
docker exec crowdsec cscli decisions delete --ip <IP>
```
Efek: Traefik ≤ 30 s (sinkron stream), nftables ≤ 10 s (`update_frequency`).

### Kebijakan firewall bouncer (H6, keputusan user 2026-09-23)

- Firewall host menerapkan decision ban **kecuali** yang scenario-nya mengandung `crowdsecurity/appsec-`
  (`appsec-native`, `appsec-vpatch`, `appsec-generic-test`). Blocklist CAPI (scenario `http:scan`), sshd, `http-*`
  (dari access log Traefik), mail, dan decision manual `cscli` tetap host-wide. **Sejak 2026-10-01** skenario HTTP
  tingkat soft juga dikecualikan — lihat §Kebijakan ban berbasis perilaku.
- Bouncer Traefik (plugin) tetap menerapkan **semua** decision termasuk AppSec → IP yang memicu WAF tetap 403 di HTTP
  selama ban, tetapi SSH 2221/mail tidak terputus.
- Mekanisme: `scenarios_not_containing` di `crowdsec-firewall-bouncer.yaml.local` (var Ansible
  `crowdsec_fw_bouncer_scenarios_not_containing`, role `crowdsec_bouncer`) → query LAPI
  `/v1/decisions/stream?…&scenarios_not_containing=crowdsecurity%2Fappsec-`. Kunci diverifikasi: go-cs-bouncer v0.0.21
  (tertanam di binary 0.0.36) `StreamBouncer.ScenariosNotContaining yaml:"scenarios_not_containing"`; LAPI v1.8.1
  `pkg/database/decisionfilter.go` = `NOT(scenario ILIKE %v% OR …)`. `crowdsec-firewall-bouncer -T` menampilkan kunci.
- Uji (2026-09-23): `cscli decisions add -i 203.0.113.77 -R crowdsecurity/appsec-native` → **tidak** ada di
  `nft list table ip crowdsec`; `-i 203.0.113.78 -R crowdsecurity/ssh-bf` → ada di set `crowdsec-blacklists-cscli`; keduanya
  dihapus → set kosong. (`cscli decisions add` tidak punya `--scenario`; `--reason` disimpan di kolom `scenario`.)
- Restart otomatis: unit paket sudah `Restart=always` + `RestartSec=10` (bouncer keluar fatal bila LAPI belum siap lalu
  pulih sendiri). Role memeriksa `Restart` ∈ {always, on-failure}; drop-in `on-failure` sengaja tidak dipasang (lebih sempit).

### Kebijakan ban berbasis perilaku (keputusan user 2026-10-01)

Latar: IP kantor Expomedia (dinamis: seluler + Wi-Fi kantor → allowlist tidak praktis) ter-ban 4 jam karena false positive
CRS di Odoo (`appsec-native`, lalu `LePresidente/http-generic-403-bf` menghitung ulang 403 buatan WAF). Prinsip baru: ban
ditentukan oleh **apa** yang dilakukan + **seberapa sering**; blok WAF per request (403 in-band) tidak berubah.
Kalibrasi access log 23 Sep–1 Okt: pengguna Odoo asli puncak 109 req/menit & ±5 blok WAF/menit; scanner 52–210 blok
WAF/menit (tetapi sering hanya ±50 req/menit — tertangkap oleh *apa* yang diakses, bukan laju).

| Tingkat | Skenario | Durasi (profil) | Firewall host |
|---|---|---|---|
| 1 hard | `http-sensitive-files`, `http-admin-interface-probing`, `http-cve-probing`, `http-bad-user-agent`, vpatch, `ssh-bf`, CAPI, dll. | 4h, +4h per ulang dalam 7 hari, maks 24h (`default_ip_remediation`) | ya |
| 2 soft | `infra/appsec-block-burst` (>30 blok WAF/menit), `infra/http-flood` (>1000 req/menit), `http-probing`, `http-crawl-non_statics` | 15m → 1h → 4h (ulang dalam 24 jam, `soft_ip_remediation`) | **tidak** (hanya Traefik) |
| 2 soft (mail) | `dovecot-spam`, `infra/mail-postfix-sasl-bf` | 15m → 1h → 4h | ya (port mail tidak lewat Traefik) |
| simulasi | `crowdsecurity/appsec-native`, `LePresidente/http-generic-403-bf`, `infra/http-flood` | alert saja | — |

File (git, di-mount ro sejak recreate berikutnya; penerapan pertama = salinan ke `data/config` + HUP):
`security/crowdsec/profiles.yaml`, `simulation.yaml`, `scenarios/appsec-block-burst.yaml`, `scenarios/http-flood.yaml`;
filter firewall = `crowdsec_fw_bouncer_scenarios_not_containing` (ansible `group_vars/all.yml`, host file disamakan manual).
Karena di-mount ro, `cscli simulation enable/disable` tidak dipakai — ubah `simulation.yaml` → `kill -HUP 1`.

Uji 2026-10-01: `crowdsec -t` di container sementara (salinan config+db) lolos; kontrol negatif (nama fungsi salah di
`duration_expr`) → `fatal … failed to compile profiles`. Alert sintetis via LAPI `POST /v1/alerts` (TEST-NET):
`http-probing` ×3 → 15m / 1h / 4h; `http-sensitive-files` ×2 → 4h / 8h. Firewall: `decisions add -R crowdsecurity/http-probing`
→ tidak ada di `nft list table ip crowdsec`; `-R crowdsecurity/http-sensitive-files` → ada. Reload HUP: 403 ±10 dtk.

Tindak lanjut: tinjau `cscli alerts list -s infra/http-flood` (simulasi) beberapa hari; bila tidak ada IP sah, hapus
`infra/http-flood` dari `simulation.yaml`.

> **JANGAN** bersihkan data uji dengan `cscli alerts delete --ip <ip>`: di v1.8.1 perintah itu juga menghapus alert
> agregat blocklist komunitas/lists (tanpa IP sumber) beserta seluruh decision-nya (insiden 2026-10-01 11:49 UTC: 85 alert
> CAPI/lists terhapus, blocklist kosong sampai pull berikutnya ±2 jam; alert lokal utuh). Pakai `cscli decisions delete --ip`
> saja; alert uji yang tersisa tidak berbahaya. Blocklist komunitas diganti penuh tiap pull (`added 15000, deleted ~14950`).

### Terkunci dari SSH (IP admin ter-ban)
Firewall bouncer menerapkan decision ban (kecuali AppSec, H6), termasuk blocklist komunitas (CAPI) dan skenario sshd.
IP admin **tidak** di-whitelist (keputusan Lead: belum). Pemulihan: login via **konsol VPS Hostinger**
(bukan SSH) → `docker exec crowdsec cscli decisions delete --ip <IP-admin>` (atau `--all` bila perlu) →
cek `nft list table ip crowdsec`. Darurat terakhir: `systemctl stop crowdsec-firewall-bouncer` lalu pastikan dengan
`nft list tables` bahwa tabel `crowdsec`/`crowdsec6` hilang (perilaku saat stop BELUM diuji; bila masih ada:
`nft delete table ip crowdsec` dan `nft delete table ip6 crowdsec6`) — nyalakan lagi setelah pulih.

## Rotasi API key bouncer

**Traefik** (key di `traefik/secrets/crowdsec-bouncer.key`, 600 uid 65532, di-ignore git):
```bash
docker exec crowdsec cscli bouncers delete traefik-bouncer
K=/opt/infra/traefik/secrets/crowdsec-bouncer.key; umask 077
docker exec crowdsec cscli bouncers add traefik-bouncer -o raw | tr -d '\n' > "$K"
chown 65532:65532 "$K"; chmod 600 "$K"
docker compose -f /opt/infra/traefik/docker-compose.yml restart traefik
docker exec crowdsec cscli bouncers list   # Last API pull baru
```
**Firewall host** (key di `/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.key`, 600 root; dirender ke
`crowdsec-firewall-bouncer.yaml.local` oleh Ansible):
```bash
docker exec crowdsec cscli bouncers delete host-firewall-bouncer
rm /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.key
cd /opt/infra/ansible && /opt/ansible-venv/bin/ansible-playbook site.yml --tags crowdsec_bouncer   # key baru, daftar, restart
```

## Verifikasi yang sudah dijalankan (2026-09-23)

- Ban memakai IP koneksi asli, bukan `X-Forwarded-For`: container uji sementara di network `proxy` dengan IP
  tetap `10.100.0.250` → langsung ke Traefik. Decision `10.100.0.250` → 403 (juga dengan `X-Forwarded-For:
  1.2.3.4`); dari host (10.100.0.1) dengan `X-Forwarded-For: 10.100.0.250` / `203.0.113.50` (ter-ban) → 200.
  Setelah `decisions delete` → 200.
- Firewall bouncer: decision `10.100.0.250` → elemen muncul di set `crowdsec-blacklists-cscli`, request dari
  IP itu timeout (drop L3); setelah delete → set kosong, 200.
- AppSec: `/?q=<script>alert(1)</script>`, `/?id=1' OR 1=1--`, `/.env`, path traversal → 403; normal → 200.

## Catatan

- **Crowdsec mati = semua router ber-`crowdsec` 403.** Insiden 2026-09-23: reboot 21:03 WIB → crowdsec tidak start → 403 di
  semua host publik hingga 22:54 WIB (±1 j 51 m); firewall bouncer restart-loop (LAPI mati). Akar masalah (H7): reload
  `docker kill --signal=HUP crowdsec` men-set `HasBeenManuallyStopped=true` walau container tetap berjalan (Docker v29.8.1
  `daemon/kill.go`, sinyal apa pun) → `unless-stopped` tidak start saat reboot. **Sejak H7:** reload hanya
  `docker exec crowdsec kill -HUP 1` (diuji 23:33:59 WIB: log `SIGHUP received, reloading`, 403 ±8.5 s, flag tetap
  `False`, `StartedAt`/`RestartCount` tidak berubah) dan `restart: always` (start saat daemon start walau flag `True`).
  `docker stop crowdsec` tidak bertahan melewati reboot → mematikan permanen: `docker compose down`. `infra-healthcheck`
  (5 menit) mengirim email bila crowdsec tidak running/healthy atau ada container ber-flag manual-stop
  (`observability.md` §Healthcheck). Setelah reboot/pemulihan: cek `cscli decisions list` untuk IP admin.

- CAPI aktif (default image): sinyal serangan dikirim ke CrowdSec dan blocklist komunitas ditarik. Console
  (`app.crowdsec.net`) **tidak** di-enroll (log `Machine is not enrolled in the console` = normal).
- Parser whitelist bawaan (`crowdsecurity/whitelists`) mengabaikan IP privat untuk alert/skenario — serangan
  dari host sendiri / 10.100.x.x tidak menghasilkan ban otomatis (decision manual tetap berlaku).
- Upgrade plugin: ubah `version` + `hash` di `traefik.yml` (hash = sha256 zip dari katalog; bandingkan isi zip
  dengan arsip tag GitHub sebelum mem-pin).
