# Runbook eksekusi — Plan 06 segmentasi network (ADR 0010, QA-T17B-01)

- **Plan:** `docs/plans/06-network-isolation.md` (§3 desain, §6 S0–S11, §8 verifikasi, §9 AC) · **ADR:** `docs/adr/0010-network-segmentation.md`
- **Disiapkan:** N1 infra-engineer, branch `feat/infra-network-segmentation` (2026-09-25). Langkah live dijalankan Lead (N3/N5/N6).
- **Alat (read-only, di branch ini):**
  - `scripts/net-matrix.sh [--check]` — matriks jangkauan TCP (§8.1), `--check` = bandingkan dengan target §8.2.
  - `scripts/pg-hba-validate.sh <file> transition|final` — Postgres sementara `--network none` + matriks pg_hba.
- Semua perintah sebagai root di VPS. `WIB` = jendela waktu dari plan §6 (prod 22:00–23:00 WIB, staging siang).
- Satu langkah → satu verifikasi (CLAUDE.md §0.6). Gagal → rollback langkah itu, STOP, laporkan.

## 0. Fakta yang membentuk urutan ini (diverifikasi 2026-09-25)

1. **pg_hba = bind mount FILE TUNGGAL.** `git merge`/`checkout` selalu menulis inode baru (diuji di repo sementara:
   merge `--no-ff` dengan file dirty → `error: Your local changes … would be overwritten`; bila `main` sudah
   meng-commit isi yang identik, merge tidak menyentuh file dan inode tetap). Karena itu **S2 dijalankan SEBELUM merge**:
   tulis di tempat → reload → commit isi itu di `main` → baru merge branch. Live 2026-09-25: inode host = inode container
   (855162), `pg_hba_file_rules` 16 baris, 0 error.
2. **Compose menghitung `config-hash` termasuk `networks:`.** `docker network connect` live TIDAK memperbarui label hash →
   compose yang sudah menyebut network baru tetap menandai container untuk **Recreate**. Bukti: baseline `--dry-run` di
   `main` sekarang: `traefik` = **Recreate** (drift lama sejak `web-edge` di-connect live, W2b), stack lain `Running`.
   Jadi Postgres dan Traefik **butuh satu recreate terjadwal** agar AC-06-15 (tanpa drift) terpenuhi — lihat §S10.
3. Sampai network baru dibuat (S1), setiap `docker compose up`/`--dry-run` di 8 stack yang berubah gagal
   `network … declared as external, but could not be found`. **Jalankan S1 segera setelah merge**, dan jangan jalankan
   `infra-deploy`/`docker compose up` di stack itu di antara merge dan S1.
4. DNS Docker (moby v29.8.1 `daemon/libnetwork/sandbox.go`, `Endpoint.Less` + `ResolveName`): nama di-resolve melalui
   endpoint milik **peminta** berurutan gw_priority ↓, non-internal dulu, lalu nama network. Traefik: `proxy` (prio 1) →
   `crowdsec`, `drms-kas-edge`, `kc-edge`, `odoo-edge`, `odoo-edge-stg`, `web-edge` → internal. Akibatnya:
   selama Keycloak masih di `proxy`, Traefik tetap memakai IP `proxy`; setelah S8, `keycloak` → IP `kc-edge` (bukan `metrics`).
5. Keycloak 26.7.4 `proxy-trusted-addresses` = opsi **runtime** (§S8). Tidak perlu rebuild image.

Variabel yang dipakai di bawah:
```bash
WT=/opt/infra-wt/n1            # worktree branch (sebelum merge)
I=/opt/infra
STACKS="postgres traefik identity/keycloak odoo/pool-a staging/odoo web/control-plane staging/control-plane staging/drms-proyekkas"
PRE=$(git -C $I rev-parse main)   # catat SEBELUM S2 → titik rollback compose
dryrun() { for s in ${1:-$STACKS}; do echo "== $s"; (cd $I/$s && docker compose --dry-run up -d 2>&1 | grep -E 'Recreate|Create|Running|error' ); done; }
```

## S0 — Baseline (0 downtime)

```bash
$WT/scripts/net-matrix.sh --check | tee $I/docs/qa/$(date +%F)-plan06-matrix-before.txt   # SELISIH = jalur yang akan ditutup
dryrun                                           # harap: semua Running, KECUALI traefik Recreate (drift web-edge, fakta 2)
docker exec postgres psql -U postgres -X -At -c "select count(*), count(error) from pg_hba_file_rules"   # 16|0
stat -c %i $I/postgres/conf/pg_hba.conf; docker exec postgres stat -c %i /etc/postgresql/pg_hba.conf      # sama
grep '"RouterName":"auth-oidc-backchannel@file"' $I/traefik/logs/access.log | tail -3                   # ClientHost 10.100.0.1
docker exec prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=up' | tr '}' '\n' | grep -oE '"job":"[a-z-]+".*"value":\[[^]]*' 
for n in kc-edge odoo-edge-stg db-keycloak db-odoo-pool-a db-odoo-staging db-cp db-cp-stg db-drms-stg; do
  docker network inspect $n >/dev/null 2>&1 && echo "ADA: $n (STOP)" || echo "bebas: $n"; done
ip -4 route | grep -E '10\.100\.(1[2-4]|2[0-7])\.' || echo "subnet 10.100.12-14/20-27 bebas"
```

## S2 — pg_hba transisi, di tempat (0 downtime) — SEBELUM merge

```bash
$WT/scripts/pg-hba-validate.sh $WT/postgres/conf/pg_hba.conf transition | tail -3   # error rows: 0 … RESULT: OK
cp -p $I/postgres/conf/pg_hba.conf /root/pg_hba.conf.pre-plan06                     # salinan rollback (600 root)
ino=$(stat -c %i $I/postgres/conf/pg_hba.conf)
cat $WT/postgres/conf/pg_hba.conf > $I/postgres/conf/pg_hba.conf                   # tulis DI TEMPAT (inode tetap)
[[ $(stat -c %i $I/postgres/conf/pg_hba.conf) == "$ino" && $(docker exec postgres stat -c %i /etc/postgresql/pg_hba.conf) == "$ino" ]] && echo inode-OK
docker exec postgres sha256sum /etc/postgresql/pg_hba.conf; sha256sum $WT/postgres/conf/pg_hba.conf  # sama
docker exec postgres psql -U postgres -X -At -c "select count(*), count(error) from pg_hba_file_rules"   # 26|0 (view membaca file di disk)
docker exec postgres psql -U postgres -X -c 'SELECT pg_reload_conf()'
docker logs --since 2m postgres 2>&1 | grep -iE 'pg_hba|reload' ; echo "(harap: tidak ada 'could not load pg_hba.conf')"
git -C $I add postgres/conf/pg_hba.conf
git -C $I commit -m "chore(postgres): apply plan 06 transition pg_hba in place (S2)" -m "Written with cat > (inode kept), pg_reload_conf(), pg_hba_file_rules 26 rows / 0 errors." \
  -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KaSbTBqzDbq3DFSCQkLrAL"
```
Rollback S2: `cat /root/pg_hba.conf.pre-plan06 > $I/postgres/conf/pg_hba.conf` → `pg_reload_conf()` → `git -C $I revert --no-edit HEAD`
(revert menulis inode baru di host, isi container sudah benar; catat, dan samakan lagi di S10 recreate).

### Merge branch (Lead)
```bash
git -C $I merge --no-ff feat/infra-network-segmentation -m "merge: plan 06 network segmentation (N1)"
[[ $(stat -c %i $I/postgres/conf/pg_hba.conf) == "$ino" ]] && echo "inode tetap setelah merge"   # blob identik → file tidak ditulis ulang
```

## S1 — Network baru (0 downtime) — segera setelah merge

```bash
$I/postgres/scripts/bootstrap.sh     # db: ok (sudah ada); db-keycloak … db-drms-stg: dibuat; .env: … sudah ada (tidak diubah)
$I/traefik/scripts/bootstrap.sh      # proxy/odoo-edge/…: ok; odoo-edge-stg, kc-edge: dibuat; acme/logs/secrets/logrotate: ok
for n in kc-edge odoo-edge-stg db-keycloak db-odoo-pool-a db-odoo-staging db-cp db-cp-stg db-drms-stg; do
  docker network inspect -f '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} gw={{.Gateway}}{{end}} internal={{.Internal}} n={{len .Containers}}' $n; done
# harap: kc-edge 10.100.12.0/24 internal=false · odoo-edge-stg 10.100.13.0/24 internal=false ·
#        db-keycloak .20 / db-odoo-pool-a .21 / db-odoo-staging .22 / db-cp .23 / db-cp-stg .24 / db-drms-stg .26 internal=true · n=0
dryrun | tee $I/docs/qa/$(date +%F)-plan06-dryrun-after-S1.txt
# harap (AC-06-15 awal): Recreate untuk postgres, traefik, keycloak, odoo-pool-a, odoo-staging, control-plane{,-worker},
# control-plane-staging{,-worker}, drms-pk-stg{,-worker} — setiap stack berpindah ke Running setelah langkahnya.
```
Rollback S1: `docker network rm <baru>` (belum ada anggota).

## S3 — Attach Postgres & Traefik live (0 downtime)

```bash
for n in db-keycloak db-odoo-pool-a db-odoo-staging db-cp db-cp-stg db-drms-stg; do docker network connect $n postgres; done
docker network connect odoo-edge-stg traefik
docker network connect kc-edge traefik
docker inspect postgres -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}} {{end}}'
docker inspect traefik  -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}}/gwp={{$v.GwPriority}} {{end}}'
docker exec traefik cat /proc/net/route | awk '$2=="00000000"{print "default gw hex",$3}'   # 0100640A = 10.100.0.1
docker exec traefik getent hosts keycloak      # masih 10.100.0.x (proxy) sampai S8
# dari host (SSH tunnel admin): request :8443 → access log ClientHost tetap 10.100.0.1
```
Rollback S3: `docker network disconnect <net> postgres|traefik`.

## S4 — Staging Odoo (±11 s staging) + N2 staging

```bash
# (a) bump submodule staging ke commit N2 (sh_dbfilter_header 19.0.1.1.0) — SEGERA sebelum recreate
git -C $I/staging/odoo/addons/shared fetch origin && git -C $I/staging/odoo/addons/shared checkout <ADDONS_SHA>
grep -n "'version'" $I/staging/odoo/addons/shared/sh_dbfilter_header/__manifest__.py     # 19.0.1.1.0
# (b) recreate: network [db-odoo-staging, odoo-edge-stg] + SH_DBFILTER_TRUSTED_PROXIES=10.100.13.0/24 dalam SATU recreate
cd $I/staging/odoo && docker compose --dry-run up -d && docker compose up -d
docker compose ps                                   # healthy
docker inspect odoo-staging -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'   # db-odoo-staging odoo-edge-stg
docker exec traefik getent hosts odoo-staging       # 10.100.13.x
docker logs odoo-staging 2>&1 | grep -E 'sh_dbfilter_header active|accepted only from'   # "X-Sh-Odoo-Db accepted only from 10.100.13.0/24"
H=demo.staging.bimacreative.tech
curl -sS -o /dev/null -w '%{http_code}\n' --resolve $H:443:127.0.0.1 https://$H/web/login                       # 200
WSKEY=dGhlIHNhbXBsZSBub25jZQ==   # gitleaks:allow — nonce contoh publik RFC 6455 §1.3 ("the sample nonce"), bukan secret
curl -sS -o /dev/null -w '%{http_code}\n' --max-time 5 --http1.1 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H "Sec-WebSocket-Key: $WSKEY" -H "Origin: https://$H" \
  --resolve $H:443:127.0.0.1 https://$H/websocket     # 101 (curl exit 28 setelah 5 s = normal, koneksi WS tetap terbuka)
link=$(curl -sS --resolve $H:443:127.0.0.1 https://$H/web/login | grep -o '/sh_auth_oidc/authorize?[^"]*' | head -1 | sed 's/&amp;/\&/g')
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' --resolve $H:443:127.0.0.1 "https://$H$link"          # 303 → auth…/platform-staging
# login SSO manual demo.staging + ssotest.staging (Lead/user); cetak 1 PDF (report.url TETAP tidak diset)
grep '"RouterName":"auth-oidc-backchannel@file"' $I/traefik/logs/access.log | tail -3                          # ClientHost 10.100.0.1
docker logs --since 5m postgres 2>&1 | grep -iE 'no pg_hba|rejects' ; echo "(harap kosong)"
docker exec postgres psql -U postgres -X -c "select usename, client_addr, count(*) from pg_stat_activity where usename='odoo_staging' group by 1,2"   # 10.100.22.x
# AC-06-14 (D-i-D): container uji di db-odoo-staging (peer di luar daftar) dengan header palsu → 303/404 + WARNING
docker run --rm --network db-odoo-staging --user 100:101 --read-only --cap-drop ALL --security-opt no-new-privileges:true \
  --entrypoint curl odoo:19.0-20260908@sha256:144175ec0039d52daff1d79f7e51c9281ca3c98b96c830feb49d09764a9f5d7c \
  -sS -o /dev/null -w '%{http_code}\n' -H 'X-Sh-Odoo-Db: demo_staging' -H "X-Forwarded-Host: $H" http://odoo-staging:8069/web/login
docker logs --since 2m odoo-staging 2>&1 | grep -i 'WARNING.*sh_dbfilter'
git -C $I add staging/odoo/addons/shared && git -C $I commit -m "chore(odoo): staging addons <ADDONS_SHA> (sh_dbfilter_header 19.0.1.1.0, plan 06 S4)" -m "<trailers>"
```
Rollback S4: `git -C $I checkout $PRE -- staging/odoo/docker-compose.yml` (+ submodule `checkout 352e679` bila modul
bermasalah) → `docker compose up -d` (`db` + `odoo-edge` + pg_hba lama masih ada). Kembalikan file: `git -C $I checkout HEAD -- staging/odoo/docker-compose.yml`
setelah insiden dianalisis. Env saja bermasalah (303 → `/web/database/selector` di semua tenant) → hapus
`SH_DBFILTER_TRUSTED_PROXIES` + `up -d`.

## S5 — Staging control plane (±5–10 s)

```bash
cd $I/staging/control-plane && docker compose --dry-run up -d && docker compose up -d
docker compose ps -a                                # migrate Exited (0); web, worker healthy
docker inspect control-plane-staging control-plane-staging-worker -f '{{.Name}}: {{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'
# harap: web = db-cp-stg proxy · worker = db-cp-stg
docker exec control-plane-staging node -e "fetch('http://127.0.0.1:3000/api/health').then(r=>console.log(r.status))"   # 200
# login SSO cp.staging (manual) + job dry_run dari UI → results (docs/03-operations/infra-jobs.md)
docker logs --since 5m postgres 2>&1 | grep -iE 'no pg_hba|rejects' ; echo "(harap kosong)"
```
Rollback S5: `git -C $I checkout $PRE -- staging/control-plane/docker-compose.yml && docker compose up -d`.

## S6 — Staging DRMS ProyekKas (≤ 40 s, ESTIMASI)

```bash
cd $I/staging/drms-proyekkas && docker compose --dry-run up -d && docker compose up -d   # atau: infra-deploy staging/drms-proyekkas
docker compose ps -a                                # migrate Exited (0); drms-pk-stg, -worker healthy
docker inspect drms-pk-stg drms-pk-stg-worker -f '{{.Name}}: {{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'
# harap: db-drms-stg drms-kas-edge drms-kc-admin-stg
docker exec drms-pk-stg node -e "fetch('http://127.0.0.1:3000/api/v1/health').then(r=>console.log(r.status))"   # 200
grep '"RouterName":"drms-kc-admin-stg@file"' $I/traefik/logs/access.log | tail -3   # 200 dari 10.100.9.x (setelah aksi admin)
# login web DRMS + satu mail uji worker (log mailserver)
```
Catatan: compose ini juga ada di repo app ProyekKas — beri tahu tim app (network `db` → `db-drms-stg`).
Rollback S6: `git -C $I checkout $PRE -- staging/drms-proyekkas/docker-compose.yml && docker compose up -d`.

### Gerbang QA staging (N4)
```bash
NET_MATRIX_SOURCES="odoo-staging control-plane-staging control-plane-staging-worker drms-pk-stg drms-pk-stg-worker" \
  $I/scripts/net-matrix.sh --check
```
Selisih yang **masih diharapkan** sebelum S7–S9: `control-plane-staging → keycloak:8080/9000` (Keycloak masih di
`proxy` sampai S8). Selisih lain = STOP. Uji silang pg_hba (plan §8.3) memakai container `postgres:16.15-bookworm` di
`db-*` sementara (QA).

## Jendela prod (22:00–23:00 WIB) — S7 → S8 → S9, masing-masing dengan AC-nya

### S7 — Prod control plane (±4 s)
```bash
cd $I/web/control-plane && docker compose --dry-run up -d && docker compose up -d
docker compose ps -a; docker inspect control-plane control-plane-worker -f '{{.Name}}: {{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'
docker exec control-plane node -e "fetch('http://127.0.0.1:3000/api/health').then(r=>console.log(r.status))"   # 200
# login SSO cp.bimacreative.tech; worker heartbeat: docker inspect -f '{{.State.Health.Status}}' control-plane-worker → healthy
```
Rollback S7: `git -C $I checkout $PRE -- web/control-plane/docker-compose.yml && docker compose up -d`.

### S8 — Keycloak (±30–60 s, login baru gagal selama jendela)
```bash
cd $I/identity/keycloak && docker compose --dry-run up -d     # harap: Recreate keycloak (TANPA Build: image lokal sudah ada)
docker compose up -d
until [ "$(docker inspect -f '{{.State.Health.Status}}' keycloak)" = healthy ]; do sleep 5; done; date
docker inspect keycloak -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}}/gwp={{$v.GwPriority}} {{end}}'
# harap: kc-edge=10.100.12.x/gwp=1 db-keycloak=10.100.20.x metrics=10.100.5.x (tanpa proxy, db)
docker exec keycloak cat /proc/net/route | awk '$2=="00000000"{print "default gw hex",$3}'     # 010C640A = 10.100.12.1
docker exec keycloak bash -c 'printenv KC_PROXY_TRUSTED_ADDRESSES'                         # 10.100.12.0/24
docker exec traefik getent hosts keycloak                                                     # 10.100.12.x
for r in platform platform-staging drms drms-staging; do curl -sS -o /dev/null -w "$r %{http_code}\n" \
  --resolve auth.bimacreative.tech:443:127.0.0.1 https://auth.bimacreative.tech/realms/$r/.well-known/openid-configuration; done   # 200 ×4
curl -sS -o /dev/null -w '%{http_code}\n' --resolve auth.bimacreative.tech:443:127.0.0.1 https://auth.bimacreative.tech/realms/master/   # 403
curl -sk -o /dev/null -w '%{http_code}\n' --resolve auth.bimacreative.tech:8443:127.0.0.1 https://auth.bimacreative.tech:8443/admin/   # 302/200
docker exec keycloak bash -c 'exec 3<>/dev/tcp/mail.bimacreative.tech/587 && timeout 10 head -n1 <&3'; echo "rc=$?"   # "220 mail.bimacreative.tech ESMTP" rc 0 (baseline 2026-09-25 via proxy)
docker exec prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=up{job="keycloak"}'                 # value "1" (tunggu ≤ 1 interval)
# token `automation` via :8443 (docs/03-operations/keycloak.md), login SSO cp + demo.staging
```
Rollback S8: `git -C $I checkout $PRE -- identity/keycloak/docker-compose.yml && docker compose up -d` (`proxy` + `db` masih ada).
Hanya `KC_PROXY_TRUSTED_ADDRESSES` bermasalah → hapus baris itu + `up -d`.

### S9 — Prod Odoo pool-a (±8 s) + N2 prod
```bash
git -C $I/odoo/pool-a/addons/shared fetch origin && git -C $I/odoo/pool-a/addons/shared checkout <ADDONS_SHA>
cd $I/odoo/pool-a && docker compose --dry-run up -d && docker compose up -d     # network + SH_DBFILTER_TRUSTED_PROXIES=10.100.3.0/24 bersama
docker compose ps; docker inspect odoo-pool-a -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'   # db-odoo-pool-a odoo-edge
docker network inspect odoo-edge -f '{{range .Containers}}{{.Name}} {{end}}'                               # traefik odoo-pool-a SAJA
docker logs odoo-pool-a 2>&1 | grep 'accepted only from'                                                    # … 10.100.3.0/24
H=demo.erp.bimacreative.tech   # ulangi blok verifikasi S4 (login 200, /websocket 101, authorize 303, back-channel 10.100.0.1)
# AC-06-14 prod: container uji di db-odoo-pool-a + header palsu demo_demo → 303/404 + WARNING (perintah S4, ganti network/host/DB)
git -C $I add odoo/pool-a/addons/shared && git -C $I commit -m "chore(odoo): pool-a addons <ADDONS_SHA> (sh_dbfilter_header 19.0.1.1.0, plan 06 S9)" -m "<trailers>"
```
Rollback S9: seperti S4 untuk `odoo/pool-a`.

Setelah S9: `$I/scripts/net-matrix.sh --check` → harap `RESULT: OK` (semua konsumen sudah pindah; `db` hanya berisi
postgres). `docker network inspect db -f '{{range .Containers}}{{.Name}} {{end}}'` → `postgres` saja.

## S10 — Cleanup (setelah 24 jam soak + QA hijau)

Perubahan repo (task N6, branch sendiri):
- `postgres/conf/pg_hba.conf` ← isi `postgres/conf/pg_hba.conf.s10-final` tanpa baris `#S10#`; hapus file `.s10-final`.
- `postgres/docker-compose.yml`: hapus `- db` dari service dan blok `db:` di `networks:`.
- `postgres/scripts/bootstrap.sh`: hapus baris `ensure_internal_network db …` (komentar "pensiun, jangan dipakai ulang" tetap).
- `qa/container-inspect.sh`: hapus `db` dari daftar.

Eksekusi — **rekomendasi: recreate Postgres (±6,4 s, `postgres.md`) + Traefik (±3,5–5 s)** sekali di jendela ini, karena
keduanya sudah drift (fakta 2) dan AC-06-15 mensyaratkan `--dry-run` tanpa Recreate. Recreate juga mengikat ulang
bind-mount pg_hba ke file hasil merge, jadi trik "tulis di tempat" tidak diperlukan:
```bash
sed '/^#S10#/d' $I/postgres/conf/pg_hba.conf.s10-final > /tmp/pg_hba.final   # sebelum merge S10, dari branch N6
$I/scripts/pg-hba-validate.sh /tmp/pg_hba.final final | tail -3               # RESULT: OK
docker network inspect db -f '{{range .Containers}}{{.Name}} {{end}}'         # hanya "postgres"
git -C $I merge --no-ff <branch-S10>
cd $I/postgres && docker compose --dry-run up -d && docker compose up -d      # Recreate: tanpa `db`, pg_hba final
docker exec postgres psql -U postgres -X -At -c "select count(*), count(error), count(*) filter (where address='10.100.1.0') from pg_hba_file_rules"   # 16|0|0
docker network rm db
cd $I/traefik && docker compose --dry-run up -d && docker compose up -d       # ±5 s; H7: TIDAK pernah `docker kill`
dryrun | tee $I/docs/qa/$(date +%F)-plan06-dryrun-final.txt                   # AC-06-15: tidak ada Recreate/Create (migrate one-shot = Started, normal)
$I/scripts/net-matrix.sh --check | tee $I/docs/qa/$(date +%F)-plan06-matrix-after.txt   # RESULT: OK
```
Alternatif tanpa recreate Postgres (0 downtime DB): tulis final di tempat (`sed '/^#S10#/d' … > $I/postgres/conf/pg_hba.conf`
SEBELUM merge S10) → `pg_reload_conf()` → commit di `main` → merge (pola S2) → `docker network disconnect db postgres` →
`docker network rm db`. Konsekuensi: drift compose Postgres tetap ada (AC-06-15 gagal untuk postgres) sampai recreate berikutnya.

Rollback setelah S10: ADR 0010 §Rollback — `git checkout <rev> -- postgres/ traefik/scripts/bootstrap.sh`,
`postgres/scripts/bootstrap.sh` (buat ulang `db` 10.100.1.0/24), `docker network connect db postgres`, pg_hba transisi
di tempat + `pg_reload_conf()`, recreate stack konsumen dari revisi lama.

## Jalur yang diperiksa dan TIDAK berubah

| Komponen | Temuan (grep repo 2026-09-25) |
|---|---|
| `traefik/dynamic/**` | Service memakai nama container (`keycloak:8080`, `odoo-*:8069/8072`) → tidak ada perubahan fungsional; hanya komentar (`auth.yml`, `odoo-pools.yml`, `clients/drms-proyekkas-kc-admin.yml`). Subdirektori tidak di-watch → tidak ada reload. Router `auth-oidc-backchannel` (`ClientIP 10.100.0.1/32`) tetap cocok: hairpin dari network non-internal tiba sebagai gateway `proxy`. |
| `observability/prometheus/prometheus.yml` | `keycloak:9000` via `metrics` — tidak berubah. Uptime Kuma memonitor URL publik. |
| `scripts/backup.sh`, `restore*.sh`, `lib/restic-common.sh` | `docker exec postgres pg_dump` (socket) — tanpa nama network. |
| `scripts/infra-healthcheck.sh` | nama container dari `docker compose config` — tanpa nama network. |
| `scripts/infra-job/`, `provision-*`, `odoo-sso-user.sh`, `lib/*.sh` | `docker exec` saja; `--network none` untuk container utilitas. |
| `templates/web-client/` | `web-edge` — di luar scope. |
| `observability/scripts/uptime-kuma-provision.sh` | container sementara `--network proxy` → `uptime-kuma:3001` — tidak berubah. |
| `qa/container-inspect.sh` | daftar network diperluas (branch ini). |
