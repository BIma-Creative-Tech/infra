# Runbook — erajaya-loyalty STAGING (Next.js 16 + Payload CMS 3 + Postgres)

- **Host:** `https://erajaya-loyalty.staging.bimacreative.tech` — satu container melayani portal member (`/`, `/login`,
  `/member/*`), CMS (`/admin`), API POS HMAC (`/api/pos/v1/*`), API member (`/api/member/*`), REST Payload (`/api/<collection>`),
  job harian `/api/cron/expire`.
- **App:** repo `/opt/src/erajaya-loyalty` (impor zip client, 78ebc87; infra tidak mengubahnya). Image dibangun lokal dari
  `Dockerfile` app: target `runner` → `erajaya-loyalty:<tag>`, target `seed` → `erajaya-loyalty-seed:<tag>`.
  **TEMPORARY(2026-10-07):** image lokal (tanpa GHCR/CI) seperti situs staging lain.
- **Pola:** ProyekKas DRMS staging (`staging/drms-proyekkas/`, `docs/runbooks/proyekkas-drms-onboarding.md`).
- **Terkait:** ADR 0004 (kapasitas), ADR 0010 (segmentasi), `docs/03-operations/{postgres,traefik,crowdsec,backup,web-clients}.md`,
  CLAUDE.md §3.5–§3.7.
- **Disetujui user:** deploy staging + `OTP_DEV_MODE=true` (demo saja).

## Status (branch `feat/infra-erajaya-loyalty-staging`, belum di-merge)

| Langkah | Status | Bukti ringkas |
|---|---|---|
| Postgres: network, role/DB, pg_hba | **LIVE** 2026-10-07 | §1 — login dari subnet sendiri + DDL OK; dari `db-drms-stg`/`db-umami` ditolak pg_hba |
| Edge network `erajaya-edge-stg` | **LIVE** 2026-10-07 | traefik 10.100.19.2, gateway tetap 10.100.0.1 |
| Stack `.env` + `secrets/` | **dibuat** (live, tidak di git) | `compose config -q` OK dengan `WEB_IMAGE`; tanpa `WEB_IMAGE` gagal (disengaja) |
| Container app | **BELUM** (Lead) | §3 |
| CrowdSec exclusions | **disiapkan**, belum diterapkan | `crowdsec -t` exit 0; §4 |
| Router Traefik | **disiapkan** di `staging/erajaya-loyalty/traefik/`, belum di `dynamic/` | uji Traefik sekali pakai; §5 |
| Cron expiry | **disiapkan** (role default `absent`) | `--check` changed=0; §7 |
| Backup | DB otomatis; volume media di `MEDIA_VOLUMES` (aktif setelah merge) | §8 |
| Uptime Kuma | **BELUM** (password di user) | §9 |

## Objek

| Objek | Nilai | Catatan |
|---|---|---|
| Hostname | `erajaya-loyalty.staging.bimacreative.tech` | wildcard `*.staging` → A 31.97.50.221, tanpa AAAA (dicek @1.1.1.1, @8.8.8.8, @153.92.2.6, authoritative `apollo.dns-parking.com`, 2026-10-07); CAA `0 issue "letsencrypt.org"` → `le-http` langsung |
| Stack | `/opt/infra/staging/erajaya-loyalty/` | project compose `erajaya-loyalty-staging` |
| Container | `erajaya-staging-web` (:3000) | uid 1001, read-only, 512m / 0.75 CPU |
| Seed (opsional) | service `erajaya-staging-seed` (profile `seed`) | image `SEED_IMAGE`, network DB saja |
| Network edge | `erajaya-edge-stg` 10.100.19.0/24 `--internal` | anggota: traefik + app saja; **tanpa egress** |
| Network DB | `db-erajaya-stg` 10.100.29.0/24 `--internal` | anggota: postgres (10.100.29.2) + app |
| DB / role | `erajaya_loyalty_stg` / `erajaya_loyalty_stg` (OWNER DB) | `CONNECTION LIMIT 10`, NOSUPERUSER NOCREATEDB NOCREATEROLE; CONNECT PUBLIC dicabut |
| pg_hba | `host erajaya_loyalty_stg erajaya_loyalty_stg 10.100.29.0/24 scram-sha-256` | baris 38; total 20 aturan / 0 error |
| Password DB | `PG_ERAJAYA_LOYALTY_STG_PASSWORD` di `postgres/.env` | 48 alnum (logika `bootstrap.sh`), tidak pernah dicetak |
| Volume media | `erajaya_loyalty_media_stg` → `/data/media` | dibuat saat `compose up` pertama; image men-set owner 1001 |
| Secrets | `secrets/{database_uri,payload_secret,app_encryption_key,member_session_secret,cron_secret,seed_admin_password}.secret` | 1001:1001 0400, tanpa newline; dir root 0750 |
| Router | `erajaya-stg-{cron,cron-deny,otp,admin-auth,pos,api,web}` | file `traefik/dynamic/clients/erajaya-loyalty-staging.yml` (setelah §5) |
| AppSec | `local/erajaya-payload-crs-exclusions` + `local/erajaya-payload-server-action-json` (19105/19106) | §4 |
| Timer | `erajaya-staging-expire.timer` 00:00 Asia/Jakarta | role Ansible `erajaya_staging_cron` |

### Keputusan

- **Satu role OWNER (bukan owner/app/ro seperti DRMS).** Payload menjalankan `prodMigrations` di DALAM container app
  setiap start (`src/payload.config.ts`, tanpa container migrate terpisah), jadi role yang dipakai app harus bisa DDL. Pola
  yang sama dengan `umami` (aplikasi memigrasi dirinya sendiri) di `init-roles.sh` `APPS`. Pemisahan owner/app baru berguna
  bila app punya langkah migrate terpisah — catat sebagai syarat sebelum prod.
- **Nama DB `_stg`, bukan `_staging`:** regex pg_hba pool Odoo staging `/^[a-z0-9_]+_staging$` tidak cocok (dibuktikan
  `pg-hba-validate.sh` pasangan `erajaya_loyalty_stg odoo_staging -` = REJECT).
- **Edge khusus per client, bukan `web-edge` bersama:** app memegang PII member + API POS + CMS; di `web-edge` semua
  website saling menjangkau `:3000` (sisa risiko `traefik.md` §web-edge). `--internal`: staging tidak butuh egress
  (`OTP_DEV_MODE=true`, tanpa SMTP/API eksternal; `fetch` server-side app hanya `otpSender.ts` yang mati di dev mode).
  Konsekuensi: gambar `next/image` dengan URL remote (`remotePatterns: https://**`) tidak bisa dioptimasi (fetch keluar
  gagal) — pakai media lokal. Prod dengan gateway OTP butuh edge **non-internal** sendiri.
- **Header:** middleware `security-headers` platform dipakai apa adanya. Diuji di Traefik sekali pakai: nilai edge
  **menimpa** `Strict-Transport-Security` app (`max-age=63072000; includeSubDomains; preload` → platform, tanpa
  includeSubDomains/preload — benar untuk subdomain staging) dan `Permissions-Policy` (`camera=(self)` → `camera=()`; app tidak
  memakai kamera). CSP + COOP app lolos tanpa diubah. Tidak ada header ganda.
- **TZ container = UTC** (tidak di-set): app memformat tanggal dengan zona `Asia/Jakarta` eksplisit; cron dijadwalkan di host.

## Kapasitas (ADR 0004)

- `mem_limit 512m`, `cpus 0.75`, `NODE_OPTIONS=--max-old-space-size=320` (V8 GC sebelum OOM cgroup; sisa untuk sharp/libvips
  native, buffer RSC, tmpfs `/tmp` + `/app/.next/cache` masing-masing **64m**, dihitung ke cgroup). Perkiraan admin Payload
  300–450 MiB; pembanding NYATA 2026-10-07 `docker stats`: `drms-pk-stg` 111 MiB, `drms-pk-web` 155 MiB (Payload, beban ringan).
- Σ `mem_limit` container berjalan NYATA 2026-10-07 = **13 472 MiB** (30 container, tanpa `ci-runner-job` 5 120 = anggaran
  CI terpisah §9 ADR 0004). Aturan perencanaan: 15 992 − (13 472 + 512) − 384 (dbt) − 2 048 (cadangan host) = **−424 MiB** →
  **overcommit** di bawah kebijakan "overcommit terkendali" (keputusan user 2026-09-27, ADR 0004 riwayat revisi).
  Pemakaian NYATA saat itu: `free -m` used 7 237, available 8 754 MiB; **swap terpakai 1 201 MiB** (sudah di atas ambang
  alert 1 GiB sebelum app ini).
- Evaluasi: 7 hari data `container-metrics` (Prometheus) → bila p95 < 250 MiB turunkan ke 384m; bila OOM (`oom_kill`) naikkan.
- **Postgres:** Σ `CONNECTION LIMIT` 196 → **206** > 197 slot pakai (`max_connections` 200 − 3 superuser reserved). Limit =
  plafon, bukan reservasi (NYATA 28 koneksi klien saat penambahan). Tindak lanjut: `max_connections` 200 → 230 pada recreate
  Postgres terjadwal berikutnya (±6 s, `postgres.md`), atau turunkan pool app. Sampai itu: bila semua konsumen memakai
  plafonnya, koneksi baru gagal `too many clients` (bukan crash).

## 1. Postgres — DITERAPKAN LIVE 2026-10-07 (tanpa restart)

Urutan `postgres.md` §Konsumen DB baru, setara skrip (skrip dijalankan dari worktree akan menulis `.env` worktree, jadi
langkahnya dijalankan setara-manual):
```bash
docker network create --driver bridge --internal --subnet 10.100.29.0/24 --gateway 10.100.29.1 --label infra.stack=postgres db-erajaya-stg
# PG_ERAJAYA_LOYALTY_STG_PASSWORD ditambahkan ke postgres/.env (openssl rand, 48 alnum, logika bootstrap.sh; tidak dicetak)
docker network connect db-erajaya-stg postgres                       # postgres 10.100.29.2
cp -p postgres/conf/pg_hba.conf /root/pg_hba.conf.pre-erajaya          # salinan rollback
cat <pg_hba branch> > postgres/conf/pg_hba.conf                        # DI TEMPAT, inode 855055 tetap (host = container)
docker exec postgres psql -U postgres -X -At -c "select count(*), count(error) from pg_hba_file_rules"   # 20|0
docker exec postgres psql -U postgres -X -At -c 'SELECT pg_reload_conf()'                                # t
# role + DB: pernyataan APPS init-roles.sh untuk entri erajaya saja (password via stdin \set)
```
Validasi sebelum terap: `scripts/pg-hba-validate.sh postgres/conf/pg_hba.conf final` (branch, sumber `db-erajaya-stg` +
4 pasangan baru) → `cells checked: 336, mismatches: 0, RESULT: OK`.

Uji live (container `postgres:16.15-bookworm` sekali pakai, password dari env proses, bukan argv):

| Sumber | Login | Hasil |
|---|---|---|
| `db-erajaya-stg` (10.100.29.3) | `erajaya_loyalty_stg` → `erajaya_loyalty_stg` + `BEGIN; CREATE TABLE; DROP; ROLLBACK` | OK, `ddl-ok` |
| `db-drms-stg` (10.100.26.5) | `erajaya_loyalty_stg` → `erajaya_loyalty_stg` (password benar) | `pg_hba.conf rejects connection` |
| `db-umami` (10.100.28.4) | idem | `pg_hba.conf rejects connection` |
| `db-erajaya-stg` | `pk_drms_stg_app` → `pk_drms_stg` | ditolak |
| `db-erajaya-stg` | `postgres` → `postgres` | ditolak |
| `db-erajaya-stg` | `erajaya_loyalty_stg` → `umami` | ditolak |

Log reload: hanya baris OBS-N4-01 yang sudah dikenal (`max_connections`/`shared_buffers cannot be changed…`).

## 2. Merge (Lead) — urutan WAJIB karena pg_hba bind-mount file tunggal

`/opt/infra` (main) saat ini **dirty** di `postgres/conf/pg_hba.conf` (isi = blob branch, ditulis di tempat). Merge langsung
akan gagal ("local changes would be overwritten"); `git checkout/stash` membuat inode baru. Pola runbook plan 06 §0.1:
```bash
cd /opt/infra
git diff --stat                                   # hanya postgres/conf/pg_hba.conf (+1 baris)
git add postgres/conf/pg_hba.conf
git commit -m "chore(postgres): erajaya-loyalty staging pg_hba line applied in place" -m "<trailer>"
git merge --no-ff feat/infra-erajaya-loyalty-staging        # blob identik → file tidak ditulis ulang
stat -c %i postgres/conf/pg_hba.conf; docker exec postgres stat -c %i /etc/postgresql/pg_hba.conf   # 855055 / 855055
git worktree remove /opt/infra-wt/erajaya
```
Lalu hapus 2 baris erajaya di `/opt/infra/.git/info/exclude` (pengaman sementara `secrets/` sebelum `.gitignore` stack ada).
Drift compose yang diketahui (tidak menambah risiko): `postgres` dan `traefik` `--dry-run` = Recreate (network di-connect live;
traefik sudah drift sebelumnya) → ikut recreate terjadwal berikutnya.

## 3. Deploy app

```bash
cd /opt/infra/staging/erajaya-loyalty
docker image inspect erajaya-loyalty:<tag> -f '{{.Id}} {{.Config.User}}'          # image ada, User 1001:1001
sed -i 's/^WEB_IMAGE=.*/WEB_IMAGE=erajaya-loyalty:<tag>/' .env && stat -c '%a %U' .env   # 600 root
docker compose config -q && docker compose --dry-run up -d
docker compose up -d
until [ "$(docker inspect -f '{{.State.Health.Status}}' erajaya-staging-web)" = healthy ]; do sleep 5; done; date
docker logs --tail 50 erajaya-staging-web                    # migrasi Payload sukses, tanpa error env
docker exec erajaya-staging-web sh -c 'id; ls -ld /data/media'   # uid=1001; /data/media milik 1001
docker inspect erajaya-staging-web -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}} {{end}}'   # 2 network saja
docker exec postgres psql -U postgres -X -c "select usename, client_addr, count(*) from pg_stat_activity where usename='erajaya_loyalty_stg' group by 1,2"   # 10.100.29.x
docker stats --no-stream erajaya-staging-web
```
Seed (opsional, SEKALI, setelah healthy):
```bash
sed -i 's/^SEED_IMAGE=.*/SEED_IMAGE=erajaya-loyalty-seed:<tag>/; s/^SEED_ADMIN_EMAIL=.*/SEED_ADMIN_EMAIL=<email admin>/' .env
docker compose --profile seed run --rm erajaya-staging-seed
```
**Perhatian seed:** `scripts/seed.ts` app juga membuat user CS `cs@erajaya.local` dengan password yang tertulis di repo app
(README). URL staging publik → nonaktifkan/ganti password user itu di `/admin` segera setelah seed. Password superadmin =
`secrets/seed_admin_password.secret` (baca sendiri di terminal, jangan tempel ke chat).

## 4. CrowdSec AppSec (sebelum router, agar admin tidak ter-ban saat pertama dipakai)

File (git): `security/crowdsec/appsec-configs/erajaya-payload-crs-exclusions.yaml`,
`security/crowdsec/appsec-rules/erajaya-payload-server-action.yaml`, baris `local/erajaya-payload-crs-exclusions` di
`acquis.d/appsec.yaml` (dir di-mount → terlihat setelah merge), 2 mount di `docker-compose.yml` (berlaku sejak recreate
berikutnya). **File terpisah** (bukan menambah host ke regex DRMS): cakupan, review dan rollback per client; DRMS tidak
tersentuh. Isi: hanya 920420 untuk POST `/admin/*` Server Action (Next-Action hex + text/plain, body dipaksa JSON 19105 dan
ditolak bila bukan JSON 19106) dan hanya 911100 untuk PATCH/DELETE `/api/*` **kecuali** `/api/pos/`, `/api/member/`,
`/api/cron/`; host persis staging. PUT tidak dibuka (Payload 3 REST tanpa PUT).

Diuji (branch): `crowdsec -t -no-api` (v1.8.1, container sekali pakai, salinan config tanpa kredensial, `--network none`) →
exit 0, log `loading /etc/crowdsec/appsec-configs/erajaya-payload-crs-exclusions.yaml` + `loading inband rule
local/erajaya-payload-server-action-json`; kontrol negatif (`@beginsWithX`, `req.URL.Pathz`) → fatal.

Terapkan (pola `crowdsec.md` §Kebijakan ban — salinan ke `data/config` + HUP, tanpa recreate). **Gangguan: semua router
ber-`crowdsec` 403 ±10 s** (fail-closed) → jam sepi:
```bash
L=/opt/infra/security/crowdsec
install -m 0644 -o root -g root $L/appsec-configs/erajaya-payload-crs-exclusions.yaml $L/data/config/appsec-configs/
install -m 0644 -o root -g root $L/appsec-rules/erajaya-payload-server-action.yaml  $L/data/config/appsec-rules/
grep -n erajaya $L/acquis.d/appsec.yaml                       # baris ada (dari merge)
date; docker exec crowdsec kill -HUP 1                         # H7: JANGAN docker kill
docker logs --since 2m crowdsec 2>&1 | grep -iE 'erajaya|fatal|SIGHUP'
docker exec crowdsec cscli appsec-configs list | grep erajaya  # local/erajaya-payload-crs-exclusions  enabled,local
docker inspect -f '{{.State.Health.Status}}' crowdsec           # healthy
# Bila config baru TIDAK termuat lewat HUP (belum pernah diuji untuk entri acquis baru): `cd $L && docker compose up -d`
# (recreate dengan mount baru, ±40 s 403 fail-closed — crowdsec.md).
for h in cp.bimacreative.tech drms-kas.staging.bimacreative.tech; do curl -sS -o /dev/null -w "$h %{http_code}\n" --resolve $h:443:127.0.0.1 https://$h/; done   # 307 / 404 (normal)
```
Rollback: hapus kedua file dari `data/config/…` + baris di `acquis.d/appsec.yaml` → HUP (setelah recreate: juga 2 mount).

Uji setelah router live (§5; dari host = 10.100.0.1 → alert tanpa decision; id acak 42 hex; bedakan WAF vs app lewat
`OriginStatus` di access log: WAF = 0):

| # | Request (`https://erajaya-loyalty.staging.bimacreative.tech`) | Harapan |
|---|---|---|
| 1 | `POST /admin/login` `Next-Action: <hex42>` + `text/plain` body `[]` | bukan 403 WAF (404/500 dari app: action tidak dikenal) |
| 2 | idem tanpa `Next-Action` | 403 (920420) |
| 3 | idem + body `["<script>alert(1)</script>"]` | 403 (xss pada `ARGS.json.0`) |
| 4 | idem + body `not-json <b>x` | 403 (19106) |
| 5 | `PATCH /api/members/999999` `{}` (tanpa login) | bukan 403 WAF (401/403/404 app, OriginStatus ≠ 0) |
| 6 | `PATCH /api/pos/v1/earn` | 403 WAF (911100 tetap) |
| 7 | `DELETE /api/cron/expire` dari host | 403 WAF (911100) |
| 8 | Alur nyata: login `/admin`, ubah & simpan 1 dokumen (mis. Tier), upload 1 gambar Media | sukses, `cscli alerts list` tanpa alert baru |

## 5. Router Traefik

File disiapkan: `staging/erajaya-loyalty/traefik/erajaya-loyalty-staging.yml`. Pasang **setelah** container healthy:
```bash
cd /opt/infra
git mv staging/erajaya-loyalty/traefik/erajaya-loyalty-staging.yml traefik/dynamic/clients/erajaya-loyalty-staging.yml
stat -c '%a %U' traefik/dynamic/clients/erajaya-loyalty-staging.yml          # 644 root (traefik uid 65532 hanya membaca)
docker exec traefik kill -HUP 1
sleep 3; docker logs --since 1m traefik 2>&1 | grep -iE 'erajaya|error' | grep -v 'Cannot retrieve the ACME challenge for (www.)?bimacreative'
H=erajaya-loyalty.staging.bimacreative.tech
sleep 30; echo | openssl s_client -connect 31.97.50.221:443 -servername $H 2>/dev/null | openssl x509 -noout -issuer -dates   # Let's Encrypt (bukan TRAEFIK DEFAULT)
curl -sS -o /dev/null -w '%{http_code}\n' https://$H/api/health                       # 200
curl -sSI https://$H/ | grep -iE '^(HTTP|strict-transport|content-security|permissions|x-frame)'   # 200, HSTS platform, CSP app
curl -sS -o /dev/null -w '%{http_code}\n' https://$H/admin                            # 200/302
git commit -m "feat(traefik): place erajaya-loyalty staging router" -m "<trailer>"
```
Uji router (sudah lulus di Traefik sekali pakai `traefik:v3.7.13`, crowdsec di-stub): 7 router + 4 middleware `enabled`, tanpa
tabrakan nama dengan `dynamic/`; cron dari sumber lain 403 / dari sumber diizinkan 200; OTP 5×200 lalu 429; login admin
10×200 lalu 429; POS body 2 MiB → 413; `/api` 11 MiB → 413. Uji live tambahan (sumber bukan host): container di `proxy`
dengan IP tetap → `GET /api/cron/expire` = 403:
```bash
TIP=$(docker inspect traefik -f '{{(index .NetworkSettings.Networks "proxy").IPAddress}}')
docker run --rm --network proxy --ip 10.100.0.250 curlimages/curl:8.11.1 -sk -o /dev/null -w '%{http_code}\n' \
  --resolve $H:443:$TIP https://$H/api/cron/expire                                   # 403
```
Rollback router: `git mv` kembali (atau hapus file) → `docker exec traefik kill -HUP 1` (host → 404).

## 6. Verifikasi isolasi

```bash
docker network inspect erajaya-edge-stg -f '{{range .Containers}}{{.Name}} {{end}}'   # traefik erajaya-staging-web
docker network inspect db-erajaya-stg  -f '{{range .Containers}}{{.Name}} {{end}}'   # postgres erajaya-staging-web
docker exec erajaya-staging-web node -e "fetch('https://example.com').then(r=>console.log(r.status)).catch(e=>console.log('egress blocked', e.cause?.code||e.message))"   # egress blocked
for t in keycloak:8080 control-plane:3000 drms-pk-stg:3000 odoo-staging:8069; do docker exec erajaya-staging-web node -e "const [h,p]=process.argv[1].split(':');const s=require('net').connect(+p,h);s.setTimeout(2000);s.on('connect',()=>{console.log('OPEN',process.argv[1]);process.exit()});s.on('error',e=>{console.log('closed',process.argv[1],e.code);process.exit()});s.on('timeout',()=>{console.log('closed',process.argv[1],'timeout');process.exit()})" $t; done   # semua closed
```
Tindak lanjut: tambahkan `erajaya-staging-web` ke `scripts/net-matrix.sh` (sumber + target, QA B15) dan
`healthcheck_stacks` (`ansible/group_vars/all.yml` + `--tags healthcheck`) **setelah** container ada.

## 7. Cron expiry (aktifkan setelah §3–§5 lulus)

Kontrak app: `GET /api/cron/expire` + `Authorization: Bearer <CRON_SECRET>` (`src/app/(frontend)/api/cron/expire/route.ts`;
`vercel.json` `0 17 * * *` UTC = 00:00 WIB). Mekanisme platform = timer systemd yang dikelola role Ansible (pola
`datamart_refresh`), bukan `infra-job` (spool khusus control plane). Skrip `staging/erajaya-loyalty/cron/expire.sh`:
`curl --resolve <host>:443:127.0.0.1` (tanpa DNS — resolver VPS tidak stabil) → tiba di Traefik sebagai 10.100.0.1 → router
`erajaya-stg-cron` (ClientIP 10.100.0.1/32; sumber lain 403). Header Bearer dikirim ke curl lewat **stdin** (`-H @-`), tidak
di argv. **Tanpa `--retry`**: `runExpiry` membaca lot yang kedaluwarsa sebelum mengunci member, jadi dua run yang tumpang
tindih bisa meng-expire lot yang sama dua kali (temuan app, laporkan ke tim app). Gagal → `OnFailure=infra-unit-failure@`
(email).
```bash
/opt/infra/staging/erajaya-loyalty/cron/expire.sh; echo rc=$?          # uji manual: {"ok":true,...} rc=0
cd /opt/infra/ansible
/opt/ansible-venv/bin/ansible-playbook site.yml --tags erajaya_staging_cron -e erajaya_staging_cron_state=present --check --diff
/opt/ansible-venv/bin/ansible-playbook site.yml --tags erajaya_staging_cron -e erajaya_staging_cron_state=present
# lalu set `erajaya_staging_cron_state: present` di ansible/group_vars/all.yml + commit (agar run berikutnya tidak menghapus)
systemctl list-timers erajaya-staging-expire.timer                     # NEXT = 00:00 WIB berikutnya
journalctl -u erajaya-staging-expire -n 20 --no-pager                  # setelah run pertama
```
Rollback: `-e erajaya_staging_cron_state=absent`.

## 8. Backup

- DB `erajaya_loyalty_stg` ikut dump dinamis `backup.sh` (`datallowconn` = t) — tanpa perubahan skrip.
- `.env` + `secrets/` stack di bawah `/opt/infra` → snapshot `files`.
- Volume `erajaya_loyalty_media_stg` ditambahkan ke `MEDIA_VOLUMES` (`scripts/lib/restic-common.sh`, berlaku setelah merge);
  sebelum `compose up` pertama volume belum ada → log `dilewati`.
- Cek setelah backup 01:30 pertama: `journalctl -u restic-backup -n 50 | grep -iE 'erajaya|RESULT'`.

## 9. Uptime Kuma (user — password Kuma dipegang user)

Lewat tunnel admin (`traefik.md` §Akses admin): `https://status.bimacreative.tech:8443/dashboard` → monitor HTTP(s) – Keyword,
URL `https://erajaya-loyalty.staging.bimacreative.tech/api/health`, keyword `"ok":true`, interval 60 s, notifikasi sama dengan
monitor staging lain, tidak dipasang di halaman status publik.

## Rollback total (urut terbalik; langkah bertanda ⚠ destruktif = konfirmasi eksplisit user)

1. Router: hapus file `dynamic/clients/erajaya-loyalty-staging.yml` → `docker exec traefik kill -HUP 1`.
2. Cron: `-e erajaya_staging_cron_state=absent`.
3. CrowdSec: hapus 2 file dari `data/config/…` + baris acquis → HUP.
4. App: `cd /opt/infra/staging/erajaya-loyalty && docker compose down` (volume tetap).
5. ⚠ `docker volume rm erajaya_loyalty_media_stg`; ⚠ `DROP DATABASE erajaya_loyalty_stg; DROP ROLE erajaya_loyalty_stg;`
   (backup dulu: `backup.sh run` atau `pg_dump`).
6. pg_hba: tulis isi tanpa baris erajaya **di tempat** (`cat … > postgres/conf/pg_hba.conf`, salinan `/root/pg_hba.conf.pre-erajaya`)
   → `pg_reload_conf()` → commit.
7. Network: `docker network disconnect db-erajaya-stg postgres && docker network rm db-erajaya-stg`;
   `docker network disconnect erajaya-edge-stg traefik && docker network rm erajaya-edge-stg`; revert baris bootstrap/compose.

## Risiko & catatan

- **OTP_DEV_MODE=true**: kode OTP tampil di UI dan di log container (json-file 30 MB + Loki via Alloy). Siapa pun yang membuka
  URL staging bisa login sebagai nomor HP mana pun → **hanya data fiktif** di staging. `TEMPORARY(2026-10-07)` di compose.
- User CS seed dengan password tertulis di repo app (§3).
- Overcommit RAM (−424 MiB terhadap aturan) + swap 1,2 GiB sudah terpakai; Σ connection limit Postgres 206 > 197.
- Rate limiter & nonce anti-replay POS app ada di memori proses: restart container = nonce lama bisa diputar ulang dalam
  jendela 5 menit (README app) — terima untuk staging; prod butuh store bersama.
- Batas `runExpiry` 5 000 lot per run dan race lock (§7) — temuan app.
- `erajaya-edge-stg` = subnet edge terakhir di blok 10.100.0–19.0/24; edge berikutnya butuh blok baru (ADR 0010 tabel).
