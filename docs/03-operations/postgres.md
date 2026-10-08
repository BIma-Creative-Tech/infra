# Operasional — Postgres shared (T04)

- **Stack:** `/opt/infra/postgres/` · image `postgres:16.15-bookworm` (pin tag + digest, ADR 0001)
- **Terkait:** ADR 0004 (sizing/tuning), ADR 0010 (network DB per konsumen), plan 02 §3, plan 06, CLAUDE.md §3.5

## Struktur

| Path | Isi | Git |
|---|---|---|
| `docker-compose.yml` | service `postgres`, volume `postgres_pgdata`, 6 network external `db-*` (ADR 0010; `db` lama dihapus plan 06 S10) | ya |
| `conf/pg_hba.conf` | aturan autentikasi (dimount ro, `-c hba_file=`) | ya |
| `.env` | `POSTGRES_PASSWORD`, `PG_KEYCLOAK_PASSWORD`, `PG_CONTROL_PLANE_PASSWORD`, `PG_CONTROL_PLANE_STAGING_PASSWORD` (T16b), `PG_DATAMART_PASSWORD`, `PG_ODOO_POOL_A_PASSWORD`, `PG_ODOO_STAGING_PASSWORD` (T10), `PG_PK_DRMS{,_STG}_{OWNER,APP,RO}_PASSWORD` (ProyekKas DRMS) — mode 600 root | **tidak** |
| `.env.example` | placeholder | ya |
| `scripts/bootstrap.sh` | idempoten: network `db-*` (`--internal`, subnet tetap) + `.env` dengan password acak (`openssl rand`, 48 char alnum); tidak mencetak password, tidak menimpa nilai yang ada | ya |
| `scripts/init-roles.sh` | idempoten: role + DB `keycloak`, `control_plane`, `control_plane_staging`, `datamart`; set password dari `.env` (via stdin psql); `REVOKE ALL ON DATABASE … FROM PUBLIC` | ya |

## Konfigurasi

- `user: 999:999` (uid `postgres` di image), `cap_drop: [ALL]` **tanpa `cap_add`** — diuji: init
  cluster + start berjalan tanpa capability karena volume sudah dimiliki 999 (entrypoint tidak perlu
  `chown`/`gosu`). `read_only: true` + tmpfs `/var/run/postgresql`, `/tmp` (uid 999). `shm_size: 256mb`.
- initdb: `--auth-host=scram-sha-256 --auth-local=peer --data-checksums`.
- Tuning (ADR 0004, ESTIMASI): `shared_buffers=512MB`, `work_mem=6MB`, `max_connections=200` (150 → 200 pada 2026-09-23, onboarding ProyekKas DRMS — ADR 0004 riwayat revisi),
  `password_encryption=scram-sha-256`. `mem_limit 2048m`, `cpus 1.5`. Revisi di T07.
  **OBS-N4-01 (Low, terbuka):** nilai tuning diberikan lewat argumen `command` compose (`source=command line`), sedangkan
  `postgresql.conf` di volume masih default (100/128MB) → setiap `pg_reload_conf()`/SIGHUP mencatat `… cannot be changed
  without restarting` dan `postgresql.conf contains errors`. Tidak berdampak (nilai efektif = command line); diselaraskan
  kelak agar log reload bersih (QA `docs/qa/2026-09-25-plan06-staging.md` §8).
- `pg_hba.conf`: socket lokal hanya `postgres` via `peer`; superuser **ditolak** lewat TCP;
  satu baris `host <db> <role> <subnet db-konsumen> scram-sha-256` per aplikasi (ADR 0010, tabel §Network per konsumen);
  sisanya `reject`. Keadaan final plan 06 S10 (2026-09-26): `pg_hba_file_rules` **16 aturan**, kolom `error` kosong,
  tanpa `10.100.1.0/24` (QA `docs/qa/2026-09-26-plan06-prod.md` AC-06-04).
- Connection limit role: keycloak 30, control_plane 20, control_plane_staging 10 (T16b), datamart 10, odoo_pool_a 48,
  odoo_staging 24, `pk_drms_{owner,app,ro}` 2/25/3, `pk_drms_stg_{owner,app,ro}` 2/10/2, umami 10 (plan 11) (ESTIMASI) — total
  **196** ≤ `max_connections` 200 (2026-10-07: + `erajaya_loyalty_stg` 10 → **206**, overcommit plafon — lihat entri erajaya di bawah) (`SELECT sum(rolconnlimit) FROM pg_roles WHERE rolconnlimit > 0`; sisa 4 − 3 slot superuser
  reserved = **1 slot** — konsumen DB berikutnya butuh `max_connections` naik, recreate ±6 s; plan 11 R4).
- **Control plane staging (T16b, 2026-09-23):** DB/role `control_plane_staging` (pola `control_plane`, limit 10), baris hba
  eksplisit. Diterapkan tanpa recreate: `bootstrap.sh` → `init-roles.sh` → `cat pg_hba.new > conf/pg_hba.conf` (inode tetap) →
  `pg_reload_conf()` → `pg_hba_file_rules` baris 19. Isolasi diuji (container `--network db`, network lama — sejak plan 06
  diganti uji silang per `db-*`, lihat §Network per konsumen): `control_plane_staging` →
  `control_plane_staging` OK; → `control_plane`/`postgres` dan `control_plane` → `control_plane_staging` = `pg_hba.conf rejects connection`.
- **ProyekKas DRMS (2026-09-23):** DB `pk_drms`, `pk_drms_stg` (owner `*_owner`, CONNECT hanya role DB itu, PUBLIC
  dicabut); baris hba eksplisit per DB. Runbook `docs/runbooks/proyekkas-drms-onboarding.md` §Langkah 1.
- **Umami (plan 11, 2026-09-27):** DB/role `umami` (owner, pola `keycloak`; Umami menjalankan `prisma migrate deploy` sendiri
  → butuh DDL + `CREATE EXTENSION pgcrypto`), network `db-umami` 10.100.28.0/24. Diterapkan tanpa recreate: `bootstrap.sh` →
  `docker network connect db-umami postgres` → pg_hba ditulis di tempat (inode 855055 tetap) + `pg_reload_conf()` →
  `pg_hba_file_rules` 17 baris / 0 error → `init-roles.sh`. Uji silang lulus (`analytics.md`). Compose sudah memuat `db-umami`
  → `--dry-run` = Recreate (drift) sampai recreate terjadwal berikutnya.
- **erajaya-loyalty staging (2026-10-07):** DB/role `erajaya_loyalty_stg` (OWNER, pola `umami`: Payload menjalankan
  `prodMigrations` di container app saat start → butuh DDL), limit 10, network `db-erajaya-stg` 10.100.29.0/24. Diterapkan
  tanpa restart: network + `docker network connect` → pg_hba di tempat (inode 855055 tetap) + `pg_reload_conf()` →
  `pg_hba_file_rules` 20 baris / 0 error → pernyataan `APPS` untuk entri ini. `pg-hba-validate.sh final` 336 sel / 0 selisih;
  uji silang live lulus. **Σ `CONNECTION LIMIT` kini 206 > 197** (plafon; NYATA 28 koneksi) → naikkan `max_connections` pada
  recreate terjadwal berikutnya. Runbook `docs/runbooks/erajaya-loyalty-staging.md`.
- **Role pool Odoo (T10)**: `odoo_pool_a`, `odoo_staging` — `LOGIN CREATEDB NOSUPERUSER NOCREATEROLE`, tanpa DB
  sendiri, `GRANT CONNECT ON DATABASE postgres`. `pg_hba` memakai **regex nama DB (PG16)**:
  `/^[a-z0-9_]+_(prod|demo)$` hanya untuk `odoo_pool_a`, `/^[a-z0-9_]+_staging$` hanya untuk `odoo_staging`.
  DB tenant dibuat Odoo (owner = role pool); `scripts/provision-odoo-db.sh` mencabut CONNECT PUBLIC per DB.
  Verifikasi: `SELECT database, user_name, error FROM pg_hba_file_rules;`.
- Data: named volume `postgres_pgdata` (`/var/lib/docker/volumes/postgres_pgdata/_data`, mode 700 oleh Postgres).

## Network per konsumen (`db-*`, ADR 0010) — cara service lain terhubung

Sejak plan 06 (selesai 2026-09-26) **tidak ada network DB bersama**. Network lama `db` (`10.100.1.0/24`) dihapus di S10
(`docker network rm db`); subnet itu **pensiun, jangan dipakai ulang**. Setiap konsumen (satu app + env; worker/migrate/seed
app yang sama boleh berbagi) punya bridge **`--internal`** sendiri, anggota hanya `postgres` + konsumen itu, dibuat oleh
`scripts/bootstrap.sh`. Tidak ada port di-publish ke host. Nama host DB di DSN tetap `postgres` (DNS Docker per network).

| Network | Subnet | Anggota (selain `postgres`) | Baris `pg_hba` (role → DB) |
|---|---|---|---|
| `db-keycloak` | 10.100.20.0/24 | keycloak | `keycloak` → `keycloak` |
| `db-odoo-pool-a` | 10.100.21.0/24 | odoo-pool-a | `odoo_pool_a` → `postgres`, `/^[a-z0-9_]+_(prod\|demo)$` |
| `db-odoo-staging` | 10.100.22.0/24 | odoo-staging | `odoo_staging` → `postgres`, `/^[a-z0-9_]+_staging$` |
| `db-cp` | 10.100.23.0/24 | control-plane, control-plane-worker, migrate | `control_plane` → `control_plane` |
| `db-cp-stg` | 10.100.24.0/24 | control-plane-staging(-worker), migrate | `control_plane_staging` → `control_plane_staging` |
| `db-drms` | 10.100.25.0/24 | **cadangan** (DRMS prod, belum dibuat) | `pk_drms_{owner,app,ro}` → `pk_drms` |
| `db-drms-stg` | 10.100.26.0/24 | drms-pk-stg(-worker), migrate, seed | `pk_drms_stg_{owner,app,ro}` → `pk_drms_stg` |
| `db-datamart` | 10.100.27.0/24 | **cadangan** (dbt cron, belum dibuat) | `datamart` → `datamart` |
| `db-umami` | 10.100.28.0/24 | umami (plan 11, 2026-09-27) | `umami` → `umami` |
| `db-erajaya-stg` | 10.100.29.0/24 | erajaya-staging-web (+ seed) — erajaya-loyalty staging, 2026-10-07 | `erajaya_loyalty_stg` → `erajaya_loyalty_stg` |
| — | 10.100.30–39.0/24 | cadangan `db-*` berikutnya | — |

Sumber: `postgres/scripts/bootstrap.sh`, `postgres/docker-compose.yml`, `postgres/conf/pg_hba.conf`. Uji silang QA N7
(container sekali pakai per `db-*`, password salah): hanya pasangan role konsumen sendiri lolos pg_hba, sisanya
`pg_hba.conf rejects connection`.

Contoh compose konsumen:
```yaml
services:
  keycloak:
    networks:
      db-keycloak: {}
networks:
  db-keycloak:
    external: true
    name: db-keycloak
```
- Password dari `/opt/infra/postgres/.env` (salin ke `.env` stack konsumen, mode 600).
  Contoh DSN: `postgresql://keycloak:<PG_KEYCLOAK_PASSWORD>@postgres:5432/keycloak`.
- **Konsumen DB baru** (ADR 0010 Consequences): (1) tambah `ensure_internal_network db-<x> <subnet 10.100.28–39> <gw>` di
  `scripts/bootstrap.sh` lalu jalankan; (2) `docker network connect db-<x> postgres` (live) **dan** tambahkan `db-<x>` ke
  `docker-compose.yml` postgres (tanpa itu `--dry-run` menandai Recreate = drift); (3) role/DB di `APPS` `init-roles.sh` +
  variabel `.env`; (4) baris `host <db> <role> <subnet db-x> scram-sha-256` di `pg_hba.conf`, tulis **di tempat** + reload
  (§Start / stop); (5) compose konsumen hanya `db-<x>` (+ edge-nya sendiri); (6) uji silang pg_hba + `scripts/net-matrix.sh`
  (QA checklist B15, plan 06 §14). Catatan T10: Odoo menghubungi DB `postgres` untuk daftar/buat DB — `CONNECT` PUBLIC di DB
  `postgres` sudah dicabut, jadi role pool perlu `GRANT CONNECT ON DATABASE postgres` + baris hba.

## Start / stop

```bash
cd /opt/infra/postgres
./scripts/bootstrap.sh          # sekali / idempoten
docker compose up -d
docker compose ps               # (healthy) — healthcheck pg_isready via socket
./scripts/init-roles.sh         # idempoten
docker compose down             # stop; volume postgres_pgdata TETAP
```
Reload `pg_hba.conf` tanpa restart: `docker exec postgres psql -U postgres -c 'SELECT pg_reload_conf()'`.
**Perhatian:** `pg_hba.conf` di-bind-mount sebagai *file tunggal*. Editor yang menulis file baru (inode baru —
mis. `sed -i`, Edit tool) membuat container tetap melihat versi lama → reload tidak berefek; perlu
`docker compose restart postgres` (terjadi di T10). Untuk reload tanpa restart, tulis di tempat:
`cat pg_hba.new > conf/pg_hba.conf` lalu `pg_reload_conf()`.
Cek: `docker exec postgres psql -U postgres -c '\l'` dan `-c '\du'`.
Perubahan `command` (mis. `max_connections`) → `docker compose up -d` (recreate), bukan `restart`. Durasi terukur
2026-09-23: healthy ±6,4 s setelah recreate; Odoo/Keycloak/cp-worker mencatat error koneksi selama jendela itu lalu
pulih sendiri (tidak perlu restart konsumen). Plan 06 S10 (2026-09-26 16:08 WIB, recreate untuk melepas `db` + pg_hba
final): odoo-pool-a/odoo-staging masing-masing 1 `OperationalError … shutting down`, control-plane-worker 2 `pg-boss error`
tepat saat recreate, pulih sendiri (QA N7 AC-06-16).

## Rotasi password

- Role aplikasi: hapus baris `PG_<APP>_PASSWORD=` di `.env` → `./scripts/bootstrap.sh` (membangkitkan
  nilai baru) → `./scripts/init-roles.sh` (ALTER ROLE … PASSWORD) → perbarui `.env` stack konsumen →
  restart konsumen. Koneksi lama tetap hidup sampai diputus.
- Superuser `postgres`: `POSTGRES_PASSWORD` hanya dipakai saat initdb; login superuser lewat jaringan
  ditolak `pg_hba`, akses hanya `docker exec` (peer). Rotasi opsional:
  `docker exec -it postgres psql -U postgres -c '\password postgres'` lalu samakan `.env`.

## Rollback

- Konfigurasi: `git checkout <rev> -- postgres/` → `docker compose up -d` (recreate, data tetap).
- Segmentasi network (kembali ke `db` bersama): ADR 0010 §Rollback / plan 06 §7 — butuh `bootstrap.sh` lama (buat ulang `db`
  10.100.1.0/24), pg_hba transisi di tempat, dan recreate konsumen dari revisi lama.
- Image: kembalikan tag/digest sebelumnya (minor 16.x kompatibel on-disk).
- `docker volume rm postgres_pgdata` / `DROP DATABASE` = **destruktif, butuh konfirmasi eksplisit**;
  backup `pg_dump` per DB diatur T13 (ADR 0006).
