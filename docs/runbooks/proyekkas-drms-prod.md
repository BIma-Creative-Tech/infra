# Runbook — Go-live infra ProyekKas DRMS PRODUCTION (E10)

- **Kapan dipakai:** menaikkan ProyekKas (Payload CMS + APK) client DRMS di `https://drms-kas.bimacreative.tech`
  (Epik **E10** plan app `/opt/src/proyekkas/docs/proyekkas/plans/fase1-golive.md` §E10, §6; keputusan GATE 1
  G1-3 login APK password grant, G1-6 backup offsite wajib). Dijalankan **infra Lead** (+ aksi user §9).
- **Disiapkan:** infra-engineer, branch `feat/infra-drms-prod` (2026-09-26). Branch ini **tidak** mengubah apa pun yang
  live: tidak membuat network, tidak reload pg_hba, tidak mengubah Keycloak, tidak menjalankan container.
- **Terkait:** runbook staging/onboarding `proyekkas-drms-onboarding.md` (nama objek, H5 Admin REST, pola deploy),
  `docs/03-operations/{traefik,postgres,keycloak,backup,network-segmentation-runbook}.md`, ADR 0002 (TLS/DNS),
  0004 (kapasitas T19), 0006 (backup), 0010 (segmentasi network), plan 06 §3.2–§3.3, CLAUDE.md §3.5–§3.7.

## 0. Ringkasan objek prod

| Objek | Nilai | Status 2026-09-26 |
|---|---|---|
| Hostname | `drms-kas.bimacreative.tech` | record A **sudah ada** di NS otoritatif `apollo.dns-parking.com` = `31.97.50.221`, TTL 3600, tanpa AAAA, tanpa wildcard — pre-check diulang di §5 |
| Stack dir | `/opt/infra/web/clients/drms-proyekkas/` (project `drms-proyekkas-prod`) | compose + `.env.example` + `.gitignore` di branch ini |
| Container | `drms-pk-migrate` (one-shot, role owner), `drms-pk-web` (:3000), `drms-pk-worker`, `drms-pk-seed` (profile `seed`) | belum ada |
| Limit | web **384m**/0.75 CPU, worker **192m**/0.25, migrate & seed 384m/0.5 (sementara) | = reservasi T19 (ADR 0004 §3: sisa ≈ 1 160 → **≈ 584 MiB**) |
| Volume media | `drms_pk_media_prod` → `/data/media` | sudah di `MEDIA_VOLUMES` (`scripts/lib/restic-common.sh`) |
| DB / role | `pk_drms` / `pk_drms_{owner,app,ro}` (limit koneksi 2/25/3) | ada (DB kosong, 7,5 MB) |
| Network DB | `db-drms` 10.100.25.0/24 gw .1 `--internal` | **belum dibuat**; `postgres/scripts/bootstrap.sh` + compose postgres di branch ini |
| Network edge | `drms-kas-edge-prod` 10.100.14.0/24 gw .1 (bukan internal: egress) | **belum dibuat**; `traefik/scripts/bootstrap.sh` + compose traefik di branch ini |
| Network Admin REST | `drms-kc-admin` 10.100.8.0/24 `--internal` | **ada** (H5); router `drms-kc-admin-prod` ada |
| pg_hba | `host pk_drms pk_drms_owner,pk_drms_app,pk_drms_ro 10.100.25.0/24 scram-sha-256` | **sudah aktif** (pg_hba final plan 06 S10; `pg_hba_file_rules` baris 33, error kosong, 2026-09-26) — branch ini TIDAK menyentuh `pg_hba.conf` (hindari inode baru, network-segmentation-runbook §0.1) |
| Router Traefik | `drms-pk-{auth,api-v1,api-rest,web}` → `drms-pk-web:3000` | template `web/clients/drms-proyekkas/traefik/drms-proyekkas-prod.yml` (di luar `traefik/dynamic/` → belum dimuat) |
| Token/Admin REST | `auth-drms-token` (Path token realm `drms`, 60/menit/IP burst 30), `drms-kc-admin-prod` | **ada, sudah mencakup prod** |
| CrowdSec AppSec | pengecualian 920420 (Server Action) & 911100 (PATCH/DELETE `/api/`) host `drms-kas.bimacreative.tech`; 911100 Admin REST 10.100.8.0/24 × `/admin/realms/drms/` | **ada, sudah mencakup host prod** (`appsec-configs/drms-payload-crs-exclusions.yaml`, `appsec-rules/drms-payload-server-action.yaml` regex `^drms-kas(?:\.staging)?\.bimacreative\.tech$`, `keycloak-admin-exclusions.yaml`) — tidak perlu diubah |
| Realm Keycloak | `drms`, client `proyekkas-web` / `proyekkas-mobile` / `proyekkas-admin-api` | ada; DAG `proyekkas-mobile` **ON** di live (G1-3, diverifikasi 2026-09-28 via Admin REST: directAccessGrantsEnabled=true; token probe → invalid_grant) |
| Secret client | `identity/keycloak/secrets/drms-proyekkas-{web,admin-api}.secret` | ada |

## 1. Prasyarat (STOP bila salah satu belum)

1. Aksi user §9 butir 1–4 selesai (GHCR token, offsite backup, keputusan mailbox SMTP, fingerprint APK prod).
2. Image prod ada di GHCR dengan tag semver + digest, Trivy tanpa CRITICAL (§6).
3. **Backup offsite (G1-6) aktif dan diuji** (§7) — syarat go-live keputusan user, bukan opsional.
4. Jendela: Postgres & Traefik **tidak** di-restart di langkah network (`docker network connect`); Traefik **restart
   singkat** (±detik) hanya di §5.4 (pindah sertifikat staging → production).
5. Titik rollback: `PRE=$(git -C /opt/infra rev-parse main)`; `sudo /opt/infra/scripts/backup.sh run` (dump terbaru).

## 2. Merge & network (tanpa recreate)

Merge `feat/infra-drms-prod` ke `main` di `/opt/infra`. Branch **tidak** mengubah `pg_hba.conf`, jadi tidak ada masalah inode.
Compose `postgres` & `traefik` kini menyebut network eksternal baru → **jalankan 2.1 segera setelah merge**; jangan
`docker compose up`/`infra-deploy` di kedua stack itu sebelum network ada (`network … declared as external, but could not be found`).

```bash
cd /opt/infra
./postgres/scripts/bootstrap.sh   # "network db-drms: dibuat"; network lain "ok"; .env: semua "sudah ada (tidak diubah)"
./traefik/scripts/bootstrap.sh    # "network drms-kas-edge-prod: dibuat"; acme/logs/secrets ok; logrotate ok
docker network connect db-drms postgres
docker network connect drms-kas-edge-prod traefik
```
**Verifikasi:**
```bash
docker network inspect -f '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{.Gateway}}{{end}} internal={{.Internal}}' db-drms drms-kas-edge-prod
#   db-drms 10.100.25.0/24 10.100.25.1 internal=true · drms-kas-edge-prod 10.100.14.0/24 10.100.14.1 internal=false
docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' postgres traefik   # memuat db-drms / drms-kas-edge-prod
tail -n 20 /opt/infra/traefik/logs/access.log | grep -o '"ClientHost":"10\.100\.0\.1"' | head -1   # gateway Traefik tetap proxy (akses via tunnel)
(cd postgres && docker compose up --dry-run -d 2>&1 | tail -3); (cd traefik && docker compose up --dry-run -d 2>&1 | tail -3)
#   "Recreate" = drift config-hash yang DIHARAPKAN (network-segmentation-runbook §0.2) → recreate terjadwal, bukan sekarang
```
Uji login DB dari subnet baru (container sementara, password dari `postgres/.env`, tidak ditampilkan):
```bash
IMG=postgres:16.15-bookworm@sha256:efedf3595f1d6f415c08568ba171029bf54052e754cc9f030e3f2412b21f3d67
pw() { printf 'PGPASSWORD=%s\n' "$(grep "^$1=" /opt/infra/postgres/.env | cut -d= -f2-)"; }
docker run --rm --network db-drms --env-file <(pw PG_PK_DRMS_APP_PASSWORD)     $IMG psql -h postgres -U pk_drms_app -d pk_drms -AtX -c 'select current_user'   # pk_drms_app
docker run --rm --network db-drms --env-file <(pw PG_PK_DRMS_STG_APP_PASSWORD) $IMG psql -h postgres -U pk_drms_stg_app -d pk_drms_stg -AtX -c 'select 1' # FATAL pg_hba (stg dari subnet prod)
docker run --rm --network db-drms-stg --env-file <(pw PG_PK_DRMS_APP_PASSWORD) $IMG psql -h postgres -U pk_drms_app -d pk_drms -AtX -c 'select 1'         # FATAL pg_hba (prod dari subnet stg)
```
**Rollback:** `docker network disconnect drms-kas-edge-prod traefik; docker network disconnect db-drms postgres;
docker network rm drms-kas-edge-prod db-drms` + `git revert` commit network (setelah disconnect, dry-run kembali tanpa drift baru).

## 3. Stack dir, `.env`, secret (tanpa menjalankan container)

```bash
D=/opt/infra/web/clients/drms-proyekkas          # dir dari git (compose, .env.example, .gitignore, traefik/)
chmod 750 "$D"; chown root:root "$D"
install -m 600 -o root -g root "$D/.env.example" "$D/.env"    # lalu edit: image GHCR@digest, SMTP_*, ANDROID_APP_CERT_SHA256
install -d -m 750 -o root -g root "$D/secrets"
umask 077
PGENV=/opt/infra/postgres/.env; get() { grep "^$1=" "$PGENV" | cut -d= -f2-; }
# password bootstrap.sh hanya [A-Za-z0-9] → aman di URL tanpa encode (cek dulu: grep -c '[^A-Za-z0-9]' = 0)
printf 'postgres://pk_drms_owner:%s@postgres:5432/pk_drms' "$(get PG_PK_DRMS_OWNER_PASSWORD)" > "$D/secrets/database_url_owner.secret"
printf 'postgres://pk_drms_app:%s@postgres:5432/pk_drms'   "$(get PG_PK_DRMS_APP_PASSWORD)"   > "$D/secrets/database_url_app.secret"
printf '%s' "$(openssl rand -hex 32)" > "$D/secrets/payload_secret.secret"      # BARU — jangan salin dari staging
cp /opt/infra/identity/keycloak/secrets/drms-proyekkas-web.secret       "$D/secrets/oidc_web_client_secret.secret"
cp /opt/infra/identity/keycloak/secrets/drms-proyekkas-admin-api.secret "$D/secrets/kc_admin_client_secret.secret"
printf '%s' '<password mailbox SMTP prod>' > "$D/secrets/smtp_password.secret"  # ketik via editor/read -s, bukan di history
chown 1001:1001 "$D"/secrets/*.secret; chmod 0400 "$D"/secrets/*.secret
```
**Verifikasi:** `ls -l $D/secrets` (6 file, `-r-------- 1001 1001`), `for f in $D/secrets/*; do tail -c1 "$f" | xxd -p; done`
(tidak ada `0a`), `cd $D && docker compose config -q` (rc 0), `git -C /opt/infra status --short` (tidak ada `.env`/`secrets`).
Catatan: `payload_secret` prod = kunci baru; kehilangan nilai ini = sesi/token Payload tidak valid → ikut backup `/opt/infra` (restic).

## 4. Keycloak realm `drms` — perubahan G1-3 (TIDAK dijalankan oleh branch ini)

Keputusan user G1-3: login APK prod = password grant (Direct Access Grant) seperti staging, dengan mitigasi. Client
`proyekkas-admin-api` hanya punya `view-users`/`manage-users` (tidak bisa mengubah client) dan realm `drms` tidak punya
client `automation` → perubahan lewat **admin console** (akun `platform-admin` + TOTP, tunnel `keycloak.md` §Akses admin
console via SSH tunnel) — sama dengan perubahan staging (user via console, `keycloak.md` L92–95).

**Sebelum** (bukti state lama, dari VPS, tanpa kredensial):
```bash
curl -s https://auth.bimacreative.tech/realms/drms/protocol/openid-connect/token \
  -d grant_type=password -d client_id=proyekkas-mobile -d username=probe-nonexistent -d password=x
#   → {"error":"unauthorized_client",…"Client not allowed for direct access grants"}
```
**Langkah console** (`https://auth.bimacreative.tech:8443/admin/` → pilih realm **drms**):
1. *Clients* → `proyekkas-mobile` → tab *Settings* → *Capability config* → centang **Direct access grants** (Standard
   flow tetap ON, Implicit OFF, Client authentication OFF) → *Save*. **Hanya** client ini (`proyekkas-web` &
   `proyekkas-admin-api` tetap OFF).
2. *Realm settings* → tab *Security defenses* → *Brute force detection*: pastikan aktif dengan nilai export
   (`bruteForceStrategy` MULTIPLE / "Lockout temporarily", failure factor **5**, wait increment 60 s, max wait 900 s,
   quick login check 1000 ms, minimum quick login wait 60 s, max delta 43 200 s, permanent lockout OFF). Jangan ubah.
3. *Authentication* → *Policies* → *Password policy*: `length(12)` … `passwordHistory(5)` (lebih ketat dari syarat G1-3
   minimal 10 karakter). Jangan ubah.
4. *Realm settings* → *Events* → *User events settings*: *Save events* ON (sudah, 7 hari) — sumber audit `LOGIN_ERROR`.
5. *Realm settings* → *Sessions*: offline idle 14 hari, offline max 30 hari ON (sudah) — tidak berubah oleh G1-3.
6. *Clients* → `proyekkas-web` → *Credentials*: **jangan** *Regenerate* (secret sudah dipakai §3).

Admin REST ekuivalen butir 1 (bila kelak ada client `automation` di realm `drms`, `scripts/lib/keycloak-admin.sh`):
`GET /admin/realms/drms/clients?clientId=proyekkas-mobile` → ambil `id` → `PUT /admin/realms/drms/clients/{id}` dengan
representasi penuh yang sama + `"directAccessGrantsEnabled": true` → 204.

**Sesudah** — verifikasi:
```bash
curl -s https://auth.bimacreative.tech/realms/drms/protocol/openid-connect/token \
  -d grant_type=password -d client_id=proyekkas-mobile -d username=probe-nonexistent -d password=x
#   → {"error":"invalid_grant","error_description":"Invalid user credentials"}   (DAG aktif)
curl -s … -d client_id=proyekkas-web …   # → unauthorized_client / invalid_client (DAG tetap OFF di client lain)
tail -n 50 /opt/infra/traefik/logs/access.log | grep -o '"RouterName":"auth-drms-token@file"' | head -1   # lewat router token drms
```
Uji brute force (user uji sementara, dihapus setelahnya): buat user `pk-bf-probe` (password sesuai policy, tanpa role),
kirim 6× password grant dengan password salah lalu 1× password benar → tetap `invalid_grant`; console *Users* →
`pk-bf-probe` menunjukkan terkunci sementara; event `LOGIN_ERROR` `user_temporarily_disabled` tercatat. Hapus user.
**Rollback:** hapus centang *Direct access grants* → token endpoint kembali `unauthorized_client`; APK prod password-mode
tidak bisa login (butuh build `browser`).
Export git: `identity/keycloak/realm-export/drms.json` di branch ini sudah `"directAccessGrantsEnabled": true` untuk
`proyekkas-mobile` (satu baris) — merge hanya bersama/ setelah perubahan console.

Mitigasi G1-3 dan statusnya:

| Mitigasi | Status |
|---|---|
| DAG hanya `proyekkas-mobile` | langkah 1; client lain OFF (export & verifikasi) |
| `bruteForceProtected` realm `drms` | ON di export (5 gagal → kunci sementara 60 s…15 m); verifikasi live langkah 2 + uji probe |
| Rate limit token endpoint prod | router `auth-drms-token` **sudah ada** & mencakup `/realms/drms/…/token`: 60/menit/IP burst 30 (uji offline 2026-09-26: 31×502 lalu 429) — catatan: batas ini juga berlaku untuk tebakan password dari satu IP (lebih longgar dari `ratelimit-login` 10/menit) karena Traefik tidak bisa membedakan `grant_type` di body |
| Password min 10 | policy realm `length(12)` + kompleksitas + history 5 |
| Pencabutan perangkat | sisi app (ADR app 0003 §5: revoke device + logout sesi offline via Admin REST `drms-kc-admin-prod`) — diuji QA E9/E12, bukan infra |
| Pemantauan | event `LOGIN_ERROR` (7 hari, console *Events*); listener `jboss-logging` → log container Keycloak → Loki — alert laju `LOGIN_ERROR` **belum ada** (usulan tindak lanjut) |

## 5. Traefik router prod + sertifikat

1. **DNS pre-check ulang** (ADR 0002 #5) tepat sebelum HUP:
   ```bash
   for r in 1.1.1.1 8.8.8.8 apollo.dns-parking.com; do echo "$r A=$(dig +short A drms-kas.bimacreative.tech @$r) AAAA=$(dig +short AAAA drms-kas.bimacreative.tech @$r)"; done
   #   A = 31.97.50.221 di ketiganya, AAAA kosong. CAA bimacreative.tech = 0 issue "letsencrypt.org" (sudah)
   ```
2. Aktifkan router (resolver **staging** dulu, §3.5.1):
   ```bash
   cd /opt/infra
   git mv web/clients/drms-proyekkas/traefik/drms-proyekkas-prod.yml traefik/dynamic/clients/drms-proyekkas-prod.yml
   git commit -m "feat(traefik): router ProyekKas DRMS prod (le-http-staging)"
   docker exec traefik kill -HUP 1
   ```
3. Verifikasi:
   ```bash
   docker logs --since 2m traefik 2>&1 | grep -E '"level":"(error|fatal)"'     # kosong (selain ACME tidak relevan)
   H=drms-kas.bimacreative.tech
   echo | openssl s_client -connect 31.97.50.221:443 -servername $H 2>/dev/null | openssl x509 -noout -issuer   # "(STAGING)"
   curl -sk -o /dev/null -w '%{http_code}\n' https://$H/api/v1/health       # 502 sebelum app (§6), 200 sesudahnya
   tail -n 20 traefik/logs/access.log | grep -o '"RouterName":"drms-pk-[a-z0-9-]*@file"' | sort | uniq -c
   ```
4. Pindah ke `le-http` (prosedur `traefik.md` §Pindah staging → production): backup `acme-staging.json`, ganti keempat
   `certResolver` → `le-http`, hapus entri sertifikat staging hostname ini dari `acme-staging.json`,
   `docker compose restart traefik` (**jeda edge ±detik**, semua host), verifikasi `Verify return code: 0` + issuer LE
   production. Opsi (keputusan Lead): langsung `le-http` tanpa tahap staging — DNS sudah lolos, hemat satu restart
   Traefik; menyimpang dari §3.5.1, catat bila dipilih.
5. **Rollback:** `git revert` commit router → `kill -HUP 1` → host prod 404; cert tetap di `acme.json` (tidak berbahaya).

Uji offline (sudah dijalankan di branch ini, 2026-09-26): Traefik v3.7.13 sementara, **salinan** `traefik/dynamic` +
file prod, `--network none`, middleware `crowdsec` diganti stub headers, backend `traefik/whoami:v1.12.0` di netns yang
sama; hasil di §10.

## 6. Image (GHCR) & deploy pertama

Pull auth (sekali, root — `infra-deploy` menjalankan `docker compose pull` sebagai root lewat sudo):
```bash
read -rs CR_PAT && printf '%s' "$CR_PAT" | docker login ghcr.io -u <github-user-mesin> --password-stdin; unset CR_PAT
ls -l /root/.docker/config.json        # 600 root; isi = base64 (BUKAN enkripsi) → token hanya read:packages
```
GHCR hanya menerima **PAT classic** (docs GitHub "Working with the Container registry": "GitHub Packages only supports
authentication using a personal access token (classic)"), scope **`read:packages`** saja; buat dari akun mesin/bot bila
ada, dengan tanggal kedaluwarsa + pengingat rotasi.

Deploy pertama (manual Lead; `.env` sudah berisi `PK_{WEB,MIGRATE}_IMAGE=ghcr.io/bctech-adm/proyekkas-{web,migrate}:X.Y.Z@sha256:…`):
```bash
cd /opt/infra/web/clients/drms-proyekkas
docker compose config -q && docker compose pull && docker compose up -d
docker compose ps -a                       # drms-pk-migrate Exited (0); drms-pk-web & drms-pk-worker (healthy)
docker logs drms-pk-migrate | tail         # Migrated: … / Done.
docker inspect -f '{{.Name}} mem={{.HostConfig.Memory}} cpu={{.HostConfig.NanoCpus}}' drms-pk-web drms-pk-worker
#   web 402653184 (384m) 750000000 · worker 201326592 (192m) 250000000
docker stats --no-stream drms-pk-web drms-pk-worker     # staging acuan: web 87 MiB / worker 54 MiB (2026-09-26)
H=https://drms-kas.bimacreative.tech
curl -s -o /dev/null -w '%{http_code}\n' $H/api/v1/health         # 200
curl -s -D - -o /dev/null $H/auth/login | grep -i ^location        # 302 → auth.bimacreative.tech/realms/drms/…client_id=proyekkas-web…S256
curl -s $H/.well-known/assetlinks.json                              # fingerprint kunci rilis PROD
docker exec postgres psql -U postgres -AtX -c "select usename,count(*) from pg_stat_activity where datname='pk_drms' group by 1"   # hanya pk_drms_app (≤ 15)
docker exec drms-pk-web node -e "fetch('http://drms-pk-stg:3000').then(()=>console.log('BOCOR')).catch(e=>console.log('ok terisolasi',e.cause?.code))"   # ENOTFOUND
```
Bootstrap admin (sekali, opsional): isi `SEED_ADMIN_EMAIL`/`SEED_ADMIN_KEYCLOAK_SUB` (user realm `drms` yang sudah ada) →
`docker compose --profile seed run --rm drms-pk-seed` → kosongkan lagi. Data master go-live = skrip impor E11 (bukan seed).
**Rollback deploy pertama:** `docker compose down` (JANGAN `-v`; volume & DB tetap) → router 502.

## 7. Backup — lokal + offsite (G1-6, WAJIB sebelum go-live)

Lokal (sudah otomatis): `backup.sh` men-dump semua DB (daftar dinamis → `pk_drms` ikut) dan seluruh root volume
`MEDIA_VOLUMES` (`drms_pk_media_prod` ikut begitu volume ada). Setelah §6:
```bash
sudo systemctl start restic-backup.service; journalctl -u restic-backup -n 30 --no-pager | grep -E 'pg pk_drms:|files:|RESULT'
sudo -i; set -a; . /etc/restic/local.env; set +a; restic ls latest --tag files | grep -m3 drms_pk_media_prod
```

### 7.1 Pilihan offsite (harga dibaca dari halaman resmi 2026-09-26; ESTIMASI volume)

Volume: repo restic lokal sekarang **71 MB** (seluruh platform, dedup+kompresi); DRMS menambah ≈ 0,8 GB/bulan media
(plan §6) → ≈ 10 GB/tahun + dump DB kecil. Order of magnitude: **< 20 GB di tahun pertama**.

| Opsi | Harga (sumber resmi) | Perkiraan biaya/bulan | Kelebihan | Kekurangan |
|---|---|---|---|---|
| **Backblaze B2** (S3-compatible, restic `s3:`) | $6.95/TB/bulan, **10 GB pertama gratis**, tanpa minimum durasi/ukuran, egress gratis s.d. 3× data tersimpan, lalu $0.01/GB | **$0 → ≈ $0.07–0.15** (10–20 GB) | per-byte, tanpa minimum, restore per DB/file, key bisa dibatasi satu bucket | region US/EU (lihat UU PDP §9); Object Lock + restic prune perlu desain (belum diverifikasi sesi ini) |
| Cloudflare R2 | $0.015/GB-bulan, 10 GB-bulan gratis, egress gratis, Class A $4.50/juta (1 juta gratis) | ≈ $0–0.15 | egress gratis | operasi berbayar di atas kuota; Object Lock tidak tercantum di halaman harga |
| Wasabi | mulai $7.99/TB/bulan, **minimum 1 TB** ditagih, **minimum durasi 90 hari**, tanpa egress/API fee, immutability didukung | **≈ $7.99** (minimum) | immutability, tanpa egress fee | bayar 1 TB untuk < 20 GB; objek di-prune < 90 hari tetap ditagih |
| Hetzner Storage Box BX11 (SFTP, restic `sftp:`) | 1 TB, 10 snapshot, lokasi DE/FI; harga tidak terbaca di halaman (UNVERIFIED) | UNVERIFIED | snapshot sisi server | bukan S3 (butuh kunci SSH, `backup.sh` saat ini hanya pola S3 env) |
| **Hostinger daily backup add-on** | harga tidak dicantumkan di artikel support ("payment options in the next steps") | lihat panel Hostinger | tanpa konfigurasi; seluruh VPS; disimpan terpisah dari server | 2 harian + 2 mingguan saja; restore **menimpa seluruh VPS**; tidak bisa unduh/restore per file/DB; masih di akun/provider yang sama |

**Rekomendasi:** **Backblaze B2** sebagai L4 (memenuhi G1-6: offsite, harian, per-DB/per-file restore, biaya ≈ $0 di
tahun pertama). Hostinger daily add-on = **pelengkap** opsional (RPO kehilangan VPS 1 hari untuk seluruh host, restore
cepat), bukan pengganti: restore all-or-nothing dan satu provider/akun dengan VPS. Wasabi hanya bila immutability
wajib sekarang (biaya minimum ≈ $8/bulan).

### 7.2 Aktivasi B2 (Lead, setelah user memberi kredensial §9)
Ikuti `backup.md` §Menambah remote S3 (L4) persis; nilai B2: `RESTIC_REPOSITORY_REMOTE=s3:https://s3.<region>.backblazeb2.com/<bucket>`
(endpoint S3 ditampilkan di halaman bucket B2 — salin apa adanya), `AWS_ACCESS_KEY_ID=<keyID>`,
`AWS_SECRET_ACCESS_KEY=<applicationKey>`, `AWS_DEFAULT_REGION=<region>`. Lalu `restic init --from-repo … --copy-chunker-params`,
`systemctl start restic-backup.service` → `RESULT … remote=ok`. `copy_to_remote` **belum pernah dijalankan** → ini uji pertamanya.
Celah yang tersisa (tindak lanjut infra, bukan penghalang): retensi `forget --prune` di repo remote belum ada
(`backup.md` L169) → biaya tumbuh pelan; alert untuk `remote=failed` belum ada.

### 7.3 Restore drill (wajib sekali sebelum go-live, dari REMOTE, lalu bulanan)
```bash
sudo -i
umask 077; set -a; . /etc/restic/remote.env; set +a
cat > /root/restic-remote-as-local.env <<EOF
RESTIC_REPOSITORY=$RESTIC_REPOSITORY_REMOTE
RESTIC_PASSWORD_FILE=$RESTIC_PASSWORD_FILE_REMOTE
AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION
EOF
# 1) DB: ke DB BARU (restore.sh menolak menimpa DB yang ada) — ukur waktu (RTO)
time RESTIC_LOCAL_ENV=/root/restic-remote-as-local.env /opt/infra/scripts/restore.sh pk_drms pk_drms_restoretest --owner pk_drms_owner
docker exec postgres psql -U postgres -d pk_drms_restoretest -AtX -c "select count(*) from payload_migrations"   # = jumlah di pk_drms
# 2) Media: ke direktori BARU (bukan volume live)
RESTIC_REPOSITORY=$RESTIC_REPOSITORY_REMOTE RESTIC_PASSWORD_FILE=$RESTIC_PASSWORD_FILE_REMOTE \
  restic restore latest --tag files --include /var/lib/docker/volumes/drms_pk_media_prod/_data --target /root/drill-media
diff -rq /root/drill-media/var/lib/docker/volumes/drms_pk_media_prod/_data /var/lib/docker/volumes/drms_pk_media_prod/_data | head   # hanya file baru setelah snapshot
# 3) Bersihkan (destruktif atas DB UJI saja — konfirmasi nama sebelum menjalankan)
docker exec postgres psql -U postgres -c 'DROP DATABASE pk_drms_restoretest'; rm -rf /root/drill-media /root/restic-remote-as-local.env
```
Catat hasil (durasi, jumlah baris, jumlah file) di §Status. `restore.sh --filestore` khusus layout filestore Odoo — untuk
media ProyekKas pakai `restic restore --include` seperti di atas. Nama tabel `payload_migrations` = tabel migrasi Payload
(cek dengan `\dt` bila berbeda).

## 8. Monitoring

- **Uptime Kuma** (`status.bimacreative.tech:8443/dashboard`, tunnel): monitor baru *HTTP(s) – Keyword*
  `ProyekKas DRMS prod (drms-kas)` → `https://drms-kas.bimacreative.tech/api/v1/health`, method GET (HEAD → 404, endpoint
  GET saja), keyword `ok`, interval 60 s, retry 2, notifikasi sertifikat kedaluwarsa ON, notifikasi email/Telegram yang sama
  dengan monitor platform. **Tidak** ditampilkan di status page publik (sama dengan staging).
- `docker stats`/kolektor T19: pantau web ≤ 80 % limit (≈ 307 MiB) — di atas itu naikkan ke 512m **dengan persetujuan user**
  (plan §6).
- AC E10 "alert uji terkirim" untuk health/disk/container restart: aturan alert Prometheus/Grafana **belum ada di repo**
  (`observability/prometheus/` hanya `prometheus.yml`) → task observability terpisah; sementara Kuma (health + cert) menjadi
  alert minimum. Uji: stop sementara `drms-pk-web` di luar jam kerja **atau** monitor uji ke path 404 → notifikasi masuk.

## 9. Aksi USER (tidak bisa dilakukan Lead/agent)

1. **DNS A** `drms-kas.bimacreative.tech` → `31.97.50.221`: **terlihat sudah dibuat** (NS otoritatif, 2026-09-26). Konfirmasi
   memang disengaja; jangan tambah AAAA.
2. **GHCR:** (a) PAT **classic** scope `read:packages` saja (akun mesin bila ada), berkedaluwarsa, serahkan ke Lead lewat
   kanal aman untuk `docker login` §6; (b) di repo `bctech-adm/drms`: environment `infra-deploy` dengan *required reviewers*
   + secret `DEPLOY_SSH_KEY`/`DEPLOY_KNOWN_HOSTS` (setelah wrapper §6 CI siap); (c) izinkan Actions menulis packages.
3. **Backup offsite (G1-6):** buat akun **Backblaze B2** (kartu pembayaran), bucket **private** (nama mis.
   `bct-vps-restic`, pilih region), *Application Key* dibatasi ke bucket itu → berikan `keyID`, `applicationKey`, endpoint S3
   bucket ke Lead. Simpan **password repo remote** (dibangkitkan Lead) di password manager. Opsional: beli add-on daily
   backup Hostinger di panel VPS.
   Pertimbangan kepatuhan: data berisi PII karyawan (selfie, lokasi, rekening) → penyimpanan di luar Indonesia (UU PDP
   27/2022, transfer lintas negara) — data terenkripsi sisi klien oleh restic (kunci hanya di VPS + password manager);
   keputusan region/penerimaan risiko ada di user/klien.
4. **Keycloak console** (bila Lead tidak memegang akses `platform-admin` + TOTP): langkah §4 butir 1–2.
5. **SMTP prod:** pakai `no-reply@bimacreative.tech` (kuota 30/jam **dibagi** dengan staging) atau mailbox prod terpisah.
6. **Fingerprint SHA-256 kunci rilis APK prod** (E3-c) untuk `ANDROID_APP_CERT_SHA256`.

## 10. Status penerapan & bukti persiapan

| Langkah | Status | Tanggal | Bukti |
|---|---|---|---|
| Persiapan branch `feat/infra-drms-prod` | DONE | 2026-09-26 | `docker compose config --quiet` (placeholder env) rc 0; shellcheck v0.11.0 bootstrap postgres/traefik: tidak ada temuan baru (SC2015 info L90 traefik sudah ada di `main`); Traefik v3.7.13 sementara: 0 error non-ACME, router `drms-pk-{auth,api-v1,api-rest,web}` enabled; routing `/auth/*`,`/api/v1/auth/*`→auth, `/api/v1/*`→api-v1, `/api/<slug>`→api-rest, `/admin`,`/`,`/.well-known/assetlinks.json`→web; Authorization sampai backend hanya di auth & api-v1; body 11 MiB → 413 di api-v1; host lain 404; token realm `drms` → `auth-drms-token` 31×502 lalu 429 |
| §2 network | BELUM | | |
| §3 secret | BELUM | | |
| §4 Keycloak DAG | BELUM | | |
| §5 router + cert | BELUM | | |
| §6 GHCR + deploy | BELUM | | |
| §7 offsite + drill | BELUM | | |
| §8 Kuma | BELUM | | |

### 10.1 Riwayat deploy prod

| Waktu (WIB) | Versi | Digest web / migrate | Backup pra-deploy | Rollback |
|---|---|---|---|---|
| 2026-09-27 14:30 | 0.3.0 (go-live) | `093e35e3…` / `187dfdd2…` | — (DB baru) | — |
| 2026-09-27 17:01 | 0.4.0 (navigasi admin gaya Odoo, ADR PK 0014; tanpa migrasi skema) | `dcffa2af…` / `33e1b94c…` | `backups/proyekkas/pk_drms-20260927-165938-pre-0.4.0.dump` | `.env.pre-0.4.0` → `docker compose up -d` |
| 2026-09-27 22:32 | 0.4.1 (breadcrumb + 390px overflow; tanpa migrasi) + `ANDROID_APP_CERT_SHA256` prod `E3:09:…:02:53` (App Links, APK mobile-v0.2.0) — dijalankan OWNER (Lead diblokir classifier) | `42682f7f…` / `139ab67a…` | `backups/proyekkas/pk_drms-20260927-222959-pre-0.4.1.dump` | `.env.pre-0.4.1` → `docker compose up -d` |
| 2026-10-05 09:20 | 0.6.0 (multi-PT MC1–MC4, 2FA opsional; 8 migrasi, tidak kompatibel mundur; 0.5.x dilewati). Sebelumnya: realm `drms` pk-user di scope mapping (fe01694) + role pk-user ke 2 user (client `automation`). Pasca-deploy: `group_admin`=true untuk kedua user | `5b7ab68f…` / `564353fa…` | `backups/proyekkas/pk_drms-20261005-091909-pre-0.6.0.dump` | `.env.pre-0.6.0` → `docker compose up -d` **+ restore dump** (migrasi MC tidak bisa dibalik) |
| 2026-10-06 07:22 | 0.6.1 (pemberitahuan privasi karyawan + ack; retensi selfie 12→6 bulan untuk PT 1,2,3 yang belum mengubah, diaudit). 2 migrasi (36 ms + 19 ms). Smoke: health/privasi/admin/unduh 200, `/api/v1/privacy-notice` version=1, login 302 realm drms. `.env` di-backup & diedit OWNER (hook melarang Lead menyalin `.env`) | `913d02d0…` / `767d7a4b…` | `backups/proyekkas/pk_drms-20261006-071630-pre-0.6.1.dump` | `.env.pre-0.6.1` → `docker compose up -d` **+ restore dump** (kolom privacy_ack & data retensi) |
| 2026-10-09 06:28 | 0.6.2 (perbaikan laporan QA 2026-10-08 + bump keamanan next 16.3.8/sharp 0.35.5). 5 migrasi QA (total ±120 ms); `qa_flow_lpj_source` createdForCompanyIds=[3]; `qa_settlements_guard_merge` → Done. Smoke: health/privasi/admin/unduh 200, privacy-notice version=1, login 302 realm drms, 0 log error. Persetujuan owner langsung (sesi Lead). `.env`: hanya `PK_WEB_IMAGE`/`PK_MIGRATE_IMAGE` diubah Lead (hook melarang salinan `.env.pre-0.6.2`; nilai lama = baris 0.6.1) | `7707e0a4…` / `18e9ddaf…` | `backups/proyekkas/pk_drms-20261009-062714-pre-0.6.2.dump` | `PK_*_IMAGE` → ref 0.6.1@digest → `docker compose up -d` **+ restore dump** |
| 2026-10-09 13:18 | 0.6.3 (admin CMS: kolom "Aksi" di semua list, sel Rupiah, "—" untuk sel kosong; web saja, APK tetap). 1 migrasi data `20261009_120000_list_row_actions_column` (24 ms, payload_preferences) → Done. Smoke: health/admin login/privasi/unduh 200, list tanpa sesi 302 ke login realm drms, 0 log error. Persetujuan owner langsung di sesi Lead. Hanya `PK_*_IMAGE` diubah (nilai lama = baris 0.6.2) | `20121376…` / `e9bfea2d…` | `backups/proyekkas/pk_drms-20261009-131146-pre-0.6.3.dump` | `PK_*_IMAGE` → 0.6.2@digest → `docker compose up -d` (baris pref tidak berbahaya) atau restore dump |
| 2026-10-10 08:51 | 0.6.4 (nama tampilan app "RR Teams", tautan teks admin → tombol; tanpa migrasi DB — migrate one-shot langsung Done). Langsung prod tanpa staging build yang sama (persetujuan owner di sesi Lead; staging nanti menerima build develop 0.7.0). Smoke: health/admin login/unduh/privasi 200, `/admin/login` memuat "RR Teams", 0 log error. Display name realm Keycloak `drms` masih "DRMS ProyekKas" (diubah owner via console, terpisah) | `baa15c3f…` / `a3ec7fb1…` | `backups/proyekkas/pk_drms-20261010-084959-pre-0.6.4.dump` | `PK_*_IMAGE` → 0.6.3@digest → `docker compose up -d` |
| 2026-10-12 14:02 | Impor go-live E11 (data, bukan rilis): master Karyawan + Rekening RR Teams, file sha256 `b04f099c…` (/srv/drms-import, deploy 0400). Dry-run run `be3153aa…` LULUS 0 error; commit run `4c80f216-eb35-4b86-9e74-c71bae3496da` TERSIMPAN: Bank 1 baru, Karyawan 8 baru + 1 ubah, Rekening 8 baru, Perusahaan/Pengaturan sama, cut-over NO-OP. employees 4 → 12. Operator `infra-lead (permintaan owner)`, persetujuan owner di sesi Lead. Laporan JSON (data pribadi) hanya di /srv/drms-import/out | — (image 0.6.4 tetap) | `backups/proyekkas/pk_drms-20261012-135428-pre-import-e11.dump` | restore dump (destruktif, konfirmasi owner) |
| 2026-10-13 00:36 | 0.9.1 (dari 0.6.4; 0.7.0–0.9.0 dilewati; DRMS 10/10 Phases D–G + fix "Lampiran umum"). **Image pindah namespace** `ghcr.io/bima-creative-tech/proyekkas-{web,migrate}` (pull dengan login root yang ada OK). 32 migrasi → Done, termasuk **p2s_urgency_level DESTRUKTIF: DROP `period_from/period_to`, 4 dari 5 baris berisi nilai** (keputusan owner tanpa riwayat; nilai disimpan di `backups/proyekkas/pk_drms-20261013-003337-expense_period-pre-0.9.1.csv`). Log: project_pm dilewati (1 project tanpa PM — memang belum di-assign, owner), aturan "Pengajuan Direktur" dibuat untuk DRMS/LAS/TBK (customisedKept kosong), 1 project ber-RAB tanpa RAP (`TBK/TBK "TBK TEST"`), lampiran ditautkan media#7→PB#16, #8→#19, #9→#20. Staging diuji dulu (sama build, 00:30). Smoke: health/admin login/privasi/unduh 200, list tanpa sesi 302, `/auth/login` → realm drms, 0 log error. Persetujuan owner di sesi Lead. Deploy dijalankan dengan override env shell (hook melarang Lead edit `.env`); **`.env` diedit owner via `!`** | `a4ac2848…` / `9ceb6277…` | `backups/proyekkas/pk_drms-20261013-003337-pre-0.9.1.dump` | **hanya restore dump** (skema 0.7.0+ tidak kompatibel dengan 0.6.4) lalu `PK_*_IMAGE` → 0.6.4@digest (`baa15c3f…`/`a3ec7fb1…`) |

## 11. CI/CD — desain GHCR + deploy prod

**Kondisi sekarang:** `.github/workflows/ci.yml` repo app (`bctech-adm/drms`) membangun `proyekkas-web:ci` /
`proyekkas-migrate:ci` + Trivy image, **tidak push** (komentar L151–152). `/usr/local/sbin/infra-deploy <stack>` (template
`ansible/roles/users/templates/infra-deploy.sh.j2`) = versi minimal T01: validasi nama stack + kepemilikan compose, lalu
`docker compose pull` + `up -d --remove-orphans`. **Tidak** bisa menerima tag image, tidak menunggu healthy, tidak rollback,
dan `deploy` tidak bisa menulis `.env` (dir 750 root) — sengaja.

**Desain (tindak lanjut; butuh plan kecil + review Lead, bukan bagian branch ini):**
1. *Build & push* (repo app, job `publish`, `needs: build`): `permissions: packages: write, contents: read`; login
   `ghcr.io` dengan `GITHUB_TOKEN`; tag `ghcr.io/bctech-adm/proyekkas-{web,migrate}:<semver>` (tag git `vX.Y.Z` = prod;
   `X.Y.Z-stg-<sha7>` dari `develop` = staging); Trivy CRITICAL sebelum push (sudah ada); keluarkan **digest** ke summary job.
   Tag tidak pernah ditimpa (tag lama = jalur rollback).
2. *Deploy prod* (job `deploy-prod`, `environment: infra-deploy` + required reviewers, hanya dari tag di `main`):
   `ssh -p 2221 deploy@31.97.50.221 sudo /usr/local/sbin/infra-deploy web/clients/drms-proyekkas --set PK_WEB_IMAGE=<ref@digest> --set PK_MIGRATE_IMAGE=<ref@digest>`.
3. *infra-deploy v2* (Ansible template, root-owned): `--set KEY=VAL` hanya bila KEY ada di allowlist per stack
   `/etc/infra-deploy/allow/<stack-dengan-_>.conf` (root 644) beserta regex nilai, mis.
   `PK_WEB_IMAGE ^ghcr\.io/bctech-adm/proyekkas-web:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$`; simpan `.env` lama ke
   `.env.prev` (600), tulis `.env` baru atomik; hook pra-deploy per stack (`pg_dump pk_drms` ke `backups/proyekkas/` —
   migrasi tidak reversibel); `pull` → `up -d` → tunggu semua service `healthy` (timeout 180 s) + smoke
   `curl https://drms-kas.bimacreative.tech/api/v1/health` = 200 → sukses; gagal → pulihkan `.env.prev`, `up -d`, exit ≠ 0.
   `infra-deploy --rollback <stack>` = tukar `.env`↔`.env.prev` + `up -d`. SSH key CI di `authorized_keys` user `deploy`
   dengan `restrict,command="…"` (opsional, dianjurkan).
4. *Sampai v2 ada:* deploy prod **manual oleh Lead** seperti staging (edit `.env` → `docker compose up -d`, atau
   `sudo infra-deploy web/clients/drms-proyekkas` setelah `.env` diedit root). CI cukup push ke GHCR.

**Rollback app (berlaku manual maupun v2):**
- Image saja (migrasi kompatibel mundur): `.env` → ref@digest lama → `docker compose up -d` (migrate lama = no-op).
- Skema tidak kompatibel: restore dump pra-deploy ke DB baru (`restore.sh pk_drms pk_drms_rb --owner pk_drms_owner`) lalu
  tukar — **destruktif, konfirmasi user**; atau migrasi *down* dari tim app.
- Matikan: `docker compose down` (tanpa `-v`).

## 12. Catatan & risiko

- Compose ini = versi infra; E10 sisi app (`deploy/prod/docker-compose.yml`) belum ada. Bila repo app menerbitkannya, diff
  terhadap file ini harus kosong kecuali komentar (nama container/network/volume/limit mengikat router, pg_hba, backup, T19).
- Setelah §2, `postgres` & `traefik` punya drift config-hash (Recreate saat `up -d` berikutnya) — jadwalkan recreate
  terkendali (network-segmentation-runbook §0.2); jangan `infra-deploy postgres|traefik` tanpa jendela.
- Batas `auth-drms-token` 60/menit/IP juga berlaku untuk tebakan password; perlindungan per-akun = brute force Keycloak.
- `drms-kas-edge-prod` bukan `--internal`: web/worker punya egress internet (dibutuhkan issuer publik, SMTP hairpin, FCM).
- Backup lokal tetap di disk yang sama sampai §7.2 aktif — **go-live tanpa L4 melanggar G1-6**.
