# Runbook — Onboarding ProyekKas client DRMS (Postgres, Traefik staging, Keycloak, backup)

- **Kapan dipakai:** menerapkan branch `feat/proyekkas-f1-infra` di `/opt/infra` (F1 ProyekKas: Payload CMS +
  APK Flutter untuk client DRMS, di luar Odoo). Dijalankan **infra Lead**; branch ini tidak menyentuh container live.
- **Terkait:** desain ProyekKas (repo app) `/opt/src/proyekkas/docs/proyekkas/architecture.md` §3, §6, §15 dan ADR
  ProyekKas `0002` (hosting/kapasitas), `0003` (Keycloak), `0004` (media), `0006` (DB/role); platform
  `docs/03-operations/{postgres,traefik,keycloak,backup}.md`, `docs/adr/0002-tls-dns-manual.md`, `docs/adr/0006-backup.md`,
  CLAUDE.md §3.5, §3.5.1, §3.6.
- **Prasyarat:** branch sudah di-review & di-merge ke `main` di `/opt/infra`; akses root di VPS; akses admin Keycloak
  untuk membaca secret client (`keycloak.md` §Akses admin console); jendela downtime Keycloak ±5 menit (langkah 3) dan
  restart singkat Postgres ±10–30 detik (langkah 1); langkah 0 (commit infra Lead) sudah diterapkan.

## Status penerapan

| Langkah | Status | Tanggal | Bukti ringkas |
|---|---|---|---|
| 0. Prasyarat infra Lead | **DONE** | 2026-09-23 | network `drms-kas-edge` 10.100.7.0/24 (traefik anggota, host tetap 10.100.0.1); `backup.sh` membaca `MEDIA_VOLUMES` (diuji volume dummy); `max_connections` 200 — branch `feat/infra-drms-apply` |
| 1. Postgres | **DONE** | 2026-09-23 | 2 DB + 6 role; pg_hba 0 error; login `pk_drms_app`→`pk_drms` OK, →`control_plane`/`pk_drms_stg` ditolak; `pk_drms_stg_app`→`pk_drms` ditolak; Odoo/Keycloak/cp pulih |
| 2. Traefik | **DONE** | 2026-09-23 | router `drms-pk-stg-{web,api-v1,api-rest}` & `auth-drms-token` termuat tanpa error; cert `(STAGING)`; host staging 502 (app belum ada); token realm `platform` tetap `auth-login` |
| 3. Keycloak | belum | — | dikerjakan Lead (jendela downtime) |
| 4. Backup | sebagian | 2026-09-23 | loop media aktif; dump `pk_drms*` & volume media nyata diverifikasi setelah app naik |

Catatan penerapan: Postgres di-**recreate** (`docker compose up -d`, bukan `restart`) karena `command` berubah
(`max_connections`); ini sekaligus memuat inode baru `pg_hba.conf`. Traefik di-recreate di langkah 0 (join network) →
file `dynamic/clients/drms-proyekkas-*.yml` sudah termuat & sertifikat staging diterbitkan saat start; HUP langkah 2
tetap dikirim (tanpa efek tambahan).

## Nama yang ditetapkan (sumber: arsitektur §3.1–§3.4 + keputusan branch ini)

| Objek | Prod | Staging | Catatan |
|---|---|---|---|
| Hostname | `drms-kas.bimacreative.tech` | `drms-kas.staging.bimacreative.tech` | prod: record A **belum ada** → router prod belum dibuat |
| Container web | `drms-pk-web:3000` | `drms-pk-stg:3000` | dibuat kelak oleh compose app (`web/clients/drms-proyekkas/`, `staging/drms-proyekkas/`) |
| Volume media | `drms_pk_media_prod` | `drms_pk_media_stg` | mount `/data/media` (ADR 0004) |
| DB | `pk_drms` | `pk_drms_stg` | tidak cocok regex pg_hba pool Odoo |
| Role DB | `pk_drms_{owner,app,ro}` | `pk_drms_stg_{owner,app,ro}` | limit koneksi 2/25/3 · 2/10/2 (ESTIMASI) |
| Var `.env` postgres | `PG_PK_DRMS_{OWNER,APP,RO}_PASSWORD` | `PG_PK_DRMS_STG_{OWNER,APP,RO}_PASSWORD` | dibangkitkan `postgres/scripts/bootstrap.sh` |
| Realm Keycloak | `drms` | `drms-staging` | `identity/keycloak/realm-export/drms*.json` |
| Router Traefik | (menyusul) | `drms-pk-stg-{auth,api-v1,api-rest,web}` | arsitektur: `pk-auth/pk-api-v1/pk-web`; `api-rest` ditambah (buffering hanya di route upload); prefix env agar unik |
| Network edge | `drms-kas-edge` `10.100.7.0/24` gw `10.100.7.1` | sama | dibuat infra Lead (Langkah 0) |

Realm export dibuat dari `platform-staging.json` (Keycloak 26.7.4 partial export) — nama realm diganti, **semua UUID
diganti** (uuid5 deterministik per realm; tidak ada tabrakan PK dengan realm lain, dicek) — lalu ditambah: role
realm `pk-staff|pk-pm|pk-finance|pk-owner|pk-admin`; client `proyekkas-web` (confidential, code+PKCE S256,
redirect/post-logout eksak; **back-channel logout NONAKTIF** — tanpa `backchannel.logout.url`, keputusan Lead: app
memeriksa `web-sessions`/`devices` sendiri di setiap request dan menjangkau Keycloak lewat issuer publik
`https://auth.bimacreative.tech` (hairpin), bukan `keycloak:8080`),
`proyekkas-mobile` (public, PKCE S256, redirect App Link eksak, optional scope `offline_access`),
`proyekkas-admin-api` (confidential, service account saja); semua `fullScopeAllowed=false` + scope mapping eksplisit;
mapper `realm roles` juga ke ID token; realm: `revokeRefreshToken=true` (setelan realm, bukan per client — docs
server_admin `sessions/timeouts.adoc`), offline idle 14 hari, offline max 30 hari. Satu-satunya "user" di file =
service account `service-account-proyekkas-admin-api` (tanpa kredensial) pembawa role `realm-management`
`view-users` + `manage-users`. **Tanpa secret**: Keycloak membangkitkan secret client confidential saat import
(source 26.7.4 `RepresentationToModel.determineNewSecret`).

## Langkah 0. Prasyarat yang dikerjakan infra Lead (commit terpisah, di luar branch ini)

- **Network `drms-kas-edge`** (pola `odoo-edge`, H1): `10.100.7.0/24`, gw `10.100.7.1`, bukan `--internal` (app butuh
  egress: FCM, issuer publik Keycloak); anggota hanya `traefik` + container web ProyekKas (bukan `proxy`).
  App tidak menjangkau `keycloak:8080` (sengaja) — server-side OIDC/JWKS/Admin REST lewat
  `https://auth.bimacreative.tech`; token call melewati router `auth-drms-token`. **Sejak H5 (2026-09-23) bukan hairpin
  lagi:** app juga join network internal `drms-kc-admin{,-stg}` (alias `auth.bimacreative.tech` → Traefik) — §Network Admin API.
- **`scripts/backup.sh`**: loop `MEDIA_VOLUMES` (root volume, tanpa `filestore/`) setelah loop `FILESTORE_VOLUMES`,
  urutan tetap DB dulu lalu file (ADR 0006); volume yang belum ada dilewati dengan log info. (DONE 2026-09-23)
- **Postgres `max_connections` 150 → 200** (lihat Catatan §Limit koneksi).

## Network Admin API Keycloak (H5, keputusan user infra 2026-09-23)

Sejak H5, Admin REST Keycloak **tidak bisa** dicapai lewat IP publik :443 (hairpin → 403 `auth-admin-deny`). App ProyekKas
(web **dan** worker) memanggil Admin REST realm env-nya lewat network `--internal` khusus:

| Env | Network (external) | Subnet | Yang diizinkan (router, prioritas 120) |
|---|---|---|---|
| prod | `drms-kc-admin` | 10.100.8.0/24 | `/admin/realms/drms/…` saja (`drms-kc-admin-prod`) |
| staging | `drms-kc-admin-stg` | 10.100.9.0/24 | `/admin/realms/drms-staging/…` saja (`drms-kc-admin-stg`) |

- Dibuat `traefik/scripts/bootstrap.sh` (sudah ada di VPS). Traefik join dengan alias **`auth.bimacreative.tech`** → di dalam
  container app nama itu me-resolve ke IP Traefik di network tsb (mis. `10.100.9.2`), jadi **URL app tidak berubah**:
  issuer/token/JWKS/Admin REST tetap `https://auth.bimacreative.tech/...` (sertifikat LE valid, tanpa `--resolve`).
- Compose app (web + worker, milik ProyekKas) menambahkan network external itu **selain** `drms-kas-edge` (ingress + egress;
  network internal tidak punya egress/DNS publik) dan `db`:
  ```yaml
  services:
    web:            # juga worker
      networks: [drms-kas-edge, db, drms-kc-admin-stg]   # prod: drms-kc-admin
  networks:
    drms-kc-admin-stg:
      external: true
      name: drms-kc-admin-stg
  ```
  Jangan menetapkan IP statis; jangan join network env lain (subnet staging tidak bisa ke realm prod dan sebaliknya).
- Batasan: path admin lain (`/admin/realms/<realm lain>/`, `/admin/realms/<realm>` tanpa `/` akhir, `/admin/master/…`,
  `/realms/master/…`) → 403; karakter ter-encode ambigu di path (`%2F`, `%25`, …) → ditolak; rate limit 20 req/s burst 40
  per container (ESTIMASI, `ratelimit-drms-kc-admin`); WAF CRS aktif penuh kecuali 911100 (PUT/DELETE) untuk subnet×realm
  ini (`crowdsec.md` §Pengecualian CRS 911100). Body/query berisi `<script>`, SQLi, `${…}` → 403 AppSec.
- Verifikasi (container sementara, tanpa app; secret dari stdin, tidak ditampilkan) — hasil 2026-09-23:
  ```bash
  docker run --rm -i --network drms-kc-admin-stg --entrypoint sh curlimages/curl:8.22.0 -c '
    A=https://auth.bimacreative.tech; getent hosts auth.bimacreative.tech          # -> 10.100.9.2 (traefik)
    curl -s -o /dev/null -w "%{http_code}\n" $A/admin/realms/drms-staging/users    # 401 (sampai Keycloak)
    T=$(curl -s $A/realms/drms-staging/protocol/openid-connect/token -d grant_type=client_credentials \
        -d client_id=proyekkas-admin-api --data-urlencode client_secret@- \
        | sed -n "s/.*\"access_token\":\"\([^\"]*\)\".*/\1/p")
    curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $T" "$A/admin/realms/drms-staging/users?max=1"   # 200
    curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $T" $A/admin/realms/platform/users               # 403
  ' < /opt/infra/identity/keycloak/secrets/drms-staging-proyekkas-admin-api.secret
  ```
  Hasil lengkap (stg & prod): tanpa token 401; dengan token GET users 200; PUT/DELETE user id acak 404 `User not found`
  (Keycloak, bukan WAF); realm `platform` / realm env lain / realm tanpa `/` / `/admin/master/console/` /
  `/realms/master/.well-known/…` → 403; `/realms/<realm env>/.well-known/openid-configuration` → 200; XSS → 403 AppSec;
  `traefik:8443` (entrypoint admin) dari subnet ini → 403.

## Langkah 1. Postgres — DB, role, pg_hba

```
cd /opt/infra
./postgres/scripts/bootstrap.sh     # menambah 6 var PG_PK_DRMS*_PASSWORD (48 char) ke postgres/.env; nilai lama tidak diubah
./postgres/scripts/init-roles.sh    # idempoten; juga menjalankan ulang ALTER ROLE untuk role lama (password sama)
```
Setelah merge, `git` menulis `postgres/conf/pg_hba.conf` sebagai **inode baru** → bind mount file tunggal tetap
melihat versi lama; `pg_reload_conf()` tidak cukup (`postgres.md` §Start/stop):
```
cd /opt/infra/postgres && docker compose restart postgres && docker compose ps   # tunggu (healthy); Keycloak/Odoo/cp reconnect
```
**Verifikasi** (STOP bila ada yang tidak sesuai):
```
docker exec postgres psql -U postgres -c '\l pk_drms*'          # 2 DB, owner pk_drms_owner / pk_drms_stg_owner, ACL tanpa "=c/" PUBLIC
docker exec postgres psql -U postgres -c '\du pk_drms*'         # 6 role, tanpa atribut selain limit koneksi
docker exec postgres psql -U postgres -AtX -c "select line_number,database,user_name,error from pg_hba_file_rules where error is not null or database::text like '%pk_drms%'"
#   → 2 baris pk_drms / pk_drms_stg, kolom error kosong
docker exec postgres psql -U postgres -AtX -c "select r,d,has_database_privilege(r,d,'CONNECT') from unnest(array['pk_drms_app','pk_drms_stg_app','odoo_pool_a','odoo_staging','control_plane','keycloak','datamart']) r, unnest(array['pk_drms','pk_drms_stg']) d"
#   → t hanya untuk pk_drms_app@pk_drms dan pk_drms_stg_app@pk_drms_stg
IMG=postgres:16.15-bookworm@sha256:efedf3595f1d6f415c08568ba171029bf54052e754cc9f030e3f2412b21f3d67
pw() { printf 'PGPASSWORD=%s\n' "$(grep "^$1=" /opt/infra/postgres/.env | cut -d= -f2-)"; }
docker run --rm --network db --env-file <(pw PG_PK_DRMS_STG_APP_PASSWORD) $IMG psql -h postgres -U pk_drms_stg_app -d pk_drms_stg -AtX -c 'select current_user'   # → pk_drms_stg_app
docker run --rm --network db --env-file <(pw PG_PK_DRMS_STG_APP_PASSWORD) $IMG psql -h postgres -U pk_drms_stg_app -d pk_drms -AtX -c 'select 1'              # → FATAL pg_hba reject
docker run --rm --network db --env-file <(pw PG_ODOO_STAGING_PASSWORD)    $IMG psql -h postgres -U odoo_staging -d pk_drms_stg -AtX -c 'select 1'               # → FATAL pg_hba reject
docker exec postgres psql -U postgres -d pk_drms_stg -AtX -c "select has_schema_privilege('pk_drms_stg_app','public','CREATE')"   # → f
```
Hak per tabel (`ALTER DEFAULT PRIVILEGES`, DELETE eksplisit, REVOKE UPDATE/DELETE/TRUNCATE, trigger append-only) =
**migrasi aplikasi** sebagai `*_owner` (ADR ProyekKas 0006 §1–§2), bukan skrip ini. DSN app: web/worker memakai `*_app`;
`*_owner` hanya di service migrate.

## Langkah 2. Traefik — route staging + token router realm drms

Pre-check DNS ulang tepat sebelum HUP (ADR 0002 #5): `dig +short A drms-kas.staging.bimacreative.tech @1.1.1.1` dan
`@8.8.8.8` → `31.97.50.221`; `dig +short AAAA …` kosong (2026-09-23: lulus, termasuk NS otoritatif).
```
docker kill --signal=HUP traefik      # file baru di dynamic/clients/ (subdir tidak di-watch)
```
**Verifikasi:**
```
docker logs --since 2m traefik 2>&1 | grep -E '"level":"(error|fatal)"'            # → kosong
curl -sk -o /dev/null -w '%{http_code}\n' --resolve drms-kas.staging.bimacreative.tech:443:127.0.0.1 https://drms-kas.staging.bimacreative.tech/   # → 502 (router cocok, app belum ada)
echo | openssl s_client -connect 31.97.50.221:443 -servername drms-kas.staging.bimacreative.tech 2>/dev/null | openssl x509 -noout -issuer   # → "(STAGING)"
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://auth.bimacreative.tech/realms/drms-staging/protocol/openid-connect/token   # 404 sebelum langkah 3, 400/401 sesudahnya
tail -n 50 /opt/infra/traefik/logs/access.log | grep -o '"RouterName":"[^"]*drms[^"]*"' | sort | uniq -c    # auth-drms-token@file, drms-pk-stg-web@file
curl -sk -o /dev/null -w '%{http_code}\n' --resolve drms-kas.staging.bimacreative.tech:443:127.0.0.1 https://drms-kas.staging.bimacreative.tech/api/users   # → 502, RouterName drms-pk-stg-api-rest@file
```
Uji offline yang sudah dijalankan (Traefik v3.7.13 sementara, salinan config, `--network none`, backend stub whoami):
token `drms`/`drms-staging` → `auth-drms-token` (31×200 lalu 429 pada 35 request), realm `platform` tetap
`auth-login` (10×200), `/token/introspect` → `auth-public`. Routing host staging: `/auth/*`, `/api/v1/auth/*` →
`auth`; `/api/v1/*` → `api-v1`; `/api/<slug>` → `api-rest`; `/admin`, `/` → `web`. `Authorization` sampai backend
hanya di `/api/v1/*` & `/auth/*`, dihapus di `/api/<slug>`, `/admin`. Body 11 MB → 413 di `api-v1` & `api-rest`,
tidak dibatasi Traefik di `web` (tanpa buffering). Response 20 MiB via `api-rest` → 500 (`maxResponseBodyBytes`
16 MiB), via `web` → 200. Hasil persis: laporan commit branch.
`/api/v1/auth/*` tetap `ratelimit-login`: satu-satunya endpoint di katalog v1 = `/api/v1/auth/backchannel-logout`
(kini tidak dipakai); APK tidak memanggil `/api/v1/auth/*` rutin (registrasi perangkat = `/api/v1/devices/register`).
Pindah ke `le-http` nanti: `traefik.md` §Pindah staging → production (termasuk hapus entri cert staging).

## Langkah 3. Keycloak — import realm (jendela downtime ±5 menit)

Sebelum jendela: `/opt/infra/scripts/backup.sh run` (dump DB `keycloak` terbaru di restic).
```
cd /opt/infra/identity/keycloak
docker compose stop keycloak
docker compose run --rm --no-deps -v /opt/infra/identity/keycloak/realm-export:/import:ro keycloak \
  import --optimized --file /import/drms-staging.json --override false
docker compose run --rm --no-deps -v /opt/infra/identity/keycloak/realm-export:/import:ro keycloak \
  import --optimized --file /import/drms.json --override false
docker compose up -d && docker compose ps       # (healthy)
```
`--override false`: realm yang sudah ada dilewati (default `true` = menimpa; docs `importExport.adoc` 26.7.4 — import
wajib saat server berhenti). `bootstrap-admin` **tidak** diperlukan bila `platform-admin` (TOTP) bisa login lewat
tunnel; hanya fallback bila akses admin hilang (`keycloak.md` §Pemulihan admin, BELUM diuji). Alternatif tanpa
downtime: admin console → *Create realm* → unggah JSON (tidak diuji di sesi ini).

Secret client (out-of-band, tidak pernah ke git; dibangkitkan Keycloak saat import): dibaca infra Lead dalam
jendela downtime (admin console → Clients → Credentials, atau Admin REST `GET …/clients/{id}/client-secret`) — **tanpa
Regenerate** — dan disimpan tanpa newline (`printf '%s'`) di
`/opt/infra/identity/keycloak/secrets/drms{,-staging}-{proyekkas-web,proyekkas-admin-api}.secret`
(dir 700, file 600 root; `secrets/` di-ignore git, ikut backup restic `/opt/infra`). Compose app menyalinnya ke `.env` (600).

**Verifikasi** (dari VPS; sejak H5 `/admin` hanya lewat entrypoint `admin` → `:8443` + `--resolve …:8443:127.0.0.1`;
uji dari network app: §Network Admin API):
```
R=https://auth.bimacreative.tech:8443; K=(--resolve auth.bimacreative.tech:8443:127.0.0.1)
curl -s "${K[@]}" $R/realms/drms-staging/.well-known/openid-configuration | python3 -c 'import json,sys;print(json.load(sys.stdin)["issuer"])'
TOK=$(curl -s "${K[@]}" $R/realms/drms-staging/protocol/openid-connect/token -d grant_type=client_credentials \
  -d client_id=proyekkas-admin-api --data-urlencode client_secret@/opt/infra/identity/keycloak/secrets/drms-staging-proyekkas-admin-api.secret | python3 -c 'import json,sys;print(json.load(sys.stdin)["access_token"])')
H="Authorization: Bearer $TOK"
curl -s -o /dev/null -w 'GET users drms-staging  %{http_code} (200)\n' "${K[@]}" -H "$H" "$R/admin/realms/drms-staging/users?max=1"
curl -s -o /dev/null -w 'PUT realm drms-staging  %{http_code} (403)\n' "${K[@]}" -H "$H" -X PUT -H 'Content-Type: application/json' -d '{}' $R/admin/realms/drms-staging
curl -s -o /dev/null -w 'GET users drms          %{http_code} (403)\n' "${K[@]}" -H "$H" "$R/admin/realms/drms/users?max=1"
curl -s -o /dev/null -w 'GET users platform      %{http_code} (403)\n' "${K[@]}" -H "$H" "$R/admin/realms/platform/users?max=1"
unset TOK H
```
Ulangi untuk realm `drms` bila secret prod sudah disiapkan. Uji offline yang sudah dijalankan (Keycloak 26.7.4
sementara, dev-file, `--network none`): kedua realm ter-import tanpa error; token SA `resource_access.realm-management`
= `manage-users, view-users, query-groups, query-users`; GET/POST users 200/201, mapping role `pk-staff`/`pk-admin`
204, `users/{id}/logout` 204, `PUT users/{id}` enabled=false 204, `DELETE sessions/{sid}?isOffline=true` 204,
PUT realm 403, GET clients 403, realm lain/master 403, mapping `realm-management/realm-admin` ke user 403; contoh
token user `pk-staff`: web `realm_access.roles=[pk-staff]` (access & ID token), mobile `[offline_access, pk-staff]`;
access token memuat `sid`. `execute-actions-email` → **500** karena SMTP realm belum ada.

## Langkah 4. Backup

Setelah loop `MEDIA_VOLUMES` di `backup.sh` (Langkah 0) diterapkan dan volume media ada: `/opt/infra/scripts/backup.sh run` → log `pg pk_drms: ok`,
`pg pk_drms_stg: ok` (daftar DB dinamis, `backup.sh` L44) dan path volume media di snapshot `files`
(`restic ls latest --tag files | grep drms_pk_media`). Catat: repo lokal di disk yang sama (bukan backup sejati
terhadap kehilangan host) sampai remote S3 diisi (ADR 0006).

## Rollback

- **Postgres:** `git revert` commit postgres → `docker compose restart postgres` (pg_hba tanpa baris pk_drms → login
  ditolak). DB/role dibiarkan (tidak berbahaya: tanpa baris hba). Hapus DB/role = **destruktif**, hanya dengan
  konfirmasi eksplisit: `DROP DATABASE pk_drms_stg; DROP DATABASE pk_drms; DROP ROLE …` (6 role). Var `.env` boleh tetap.
- **Traefik:** `git revert` commit traefik → `docker kill --signal=HUP traefik` → verifikasi host staging 404 dan
  token `drms*` kembali lewat `auth-login` (access log).
- **Keycloak:** admin console → realm → *Enabled* OFF (reversibel), atau hapus realm `drms`/`drms-staging`
  (**destruktif**, konfirmasi). Realm lain tidak tersentuh (`--override false`, UUID baru). Kegagalan import di
  tengah jendela: `docker compose up -d` tetap bisa dijalankan; restore DB `keycloak` dari restic hanya bila realm
  lain rusak (`backup.md` §Restore).
- **Backup:** hapus baris `MEDIA_VOLUMES` (aditif; loop di `backup.sh` milik commit infra Lead).

## Catatan

- **Usulan menunggu konfirmasi user:** offline session **max 30 hari** (`offlineSessionMaxLifespanEnabled=true`,
  `offlineSessionMaxLifespan=2592000`). Idle 14 hari sudah diputuskan user (2026-09-23).
- **Set role minimal `proyekkas-admin-api`** (`view-users`, `manage-users`) sedang diverifikasi di spike app F1 dan bisa
  berubah (mis. `view-events` bila login failure diimpor, ADR 0003 §7). Uji offline di atas menunjukkan set ini cukup
  untuk semua panggilan ADR 0003 §2/§5 kecuali `execute-actions-email` (butuh SMTP realm).
- **SMTP realm** belum dikonfigurasi (`smtpServer` kosong, sama dengan `platform`); onboarding/reset password via
  `execute-actions-email` belum jalan sampai mail (T11) siap. `resetPasswordAllowed=false`.
- `proyekkas-mobile` `post.logout.redirect.uris` diisi Keycloak dengan `+` (= redirect URI yang sama, eksak) saat import.
- Locale login Indonesia: ADR 0003 tidak menyebutnya → `internationalizationEnabled=false` (sama dengan platform).
- **RAM (ADR ProyekKas 0002 §6, platform ADR 0004):** branch ini tidak menambah container. Keycloak: +2 realm di heap
  1360m (dampak belum diukur — `docker stats` setelah import). Postgres: 2 DB kosong. **Traefik `buffering-pk`**
  hanya di `api-v1` & `api-rest` (bukan catch-all web): body/response > 1 MiB dibuffer ke `/tmp` (tmpfs, dihitung ke
  `mem_limit 256m`); per response maks 16 MiB (`maxResponseBodyBytes`, lebih besar → 500); ±20 upload 10 MiB
  paralel ≈ 200 MiB. Pantau `docker stats traefik`. App (menyusul): 1 472 MiB steady (57 % budget client).
- **Limit koneksi:** jumlah `CONNECTION LIMIT` role = 132 lama + 30 prod + 14 staging = 176; infra Lead menaikkan
  `max_connections` 150 → 200 (commit Lead). Limit = plafon, bukan reservasi. Target app **prod ≤ 15 koneksi aktual**
  (web + worker + migrate; `pk_drms_app` limit 25 = plafon), staging ≤ 10 — ukur dengan `pg_stat_activity` di F1.
- `ratelimit-login` (10/menit/IP) tetap berlaku untuk `/auth/*` web dan login APK (`/protocol/openid-connect/auth`,
  login-actions); login massal dari satu IP NAT bisa kena 429 — offline token membuat login jarang.
- File `dynamic/clients/drms-proyekkas-*.yml` BUKAN hasil `render-client-route.sh`; jangan pakai slug Odoo `drms-proyekkas`.
