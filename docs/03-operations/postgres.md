# Operasional — Postgres shared (T04)

- **Stack:** `/opt/infra/postgres/` · image `postgres:16.15-bookworm` (pin tag + digest, ADR 0001)
- **Terkait:** ADR 0004 (sizing/tuning), plan 02 §3, CLAUDE.md §3.5

## Struktur

| Path | Isi | Git |
|---|---|---|
| `docker-compose.yml` | service `postgres`, volume `postgres_pgdata`, network external `db` | ya |
| `conf/pg_hba.conf` | aturan autentikasi (dimount ro, `-c hba_file=`) | ya |
| `.env` | `POSTGRES_PASSWORD`, `PG_KEYCLOAK_PASSWORD`, `PG_CONTROL_PLANE_PASSWORD`, `PG_DATAMART_PASSWORD`, `PG_ODOO_POOL_A_PASSWORD`, `PG_ODOO_STAGING_PASSWORD` (T10) — mode 600 root | **tidak** |
| `.env.example` | placeholder | ya |
| `scripts/bootstrap.sh` | idempoten: network `db` + `.env` dengan password acak (`openssl rand`, 48 char alnum); tidak mencetak password, tidak menimpa nilai yang ada | ya |
| `scripts/init-roles.sh` | idempoten: role + DB `keycloak`, `control_plane`, `datamart`; set password dari `.env` (via stdin psql); `REVOKE ALL ON DATABASE … FROM PUBLIC` | ya |

## Konfigurasi

- `user: 999:999` (uid `postgres` di image), `cap_drop: [ALL]` **tanpa `cap_add`** — diuji: init
  cluster + start berjalan tanpa capability karena volume sudah dimiliki 999 (entrypoint tidak perlu
  `chown`/`gosu`). `read_only: true` + tmpfs `/var/run/postgresql`, `/tmp` (uid 999). `shm_size: 256mb`.
- initdb: `--auth-host=scram-sha-256 --auth-local=peer --data-checksums`.
- Tuning (ADR 0004, ESTIMASI): `shared_buffers=512MB`, `work_mem=6MB`, `max_connections=150`,
  `password_encryption=scram-sha-256`. `mem_limit 2048m`, `cpus 1.5`. Revisi di T07.
- `pg_hba.conf`: socket lokal hanya `postgres` via `peer`; superuser **ditolak** lewat TCP;
  satu baris `host <db> <role> 10.100.1.0/24 scram-sha-256` per aplikasi; sisanya `reject`.
- Connection limit role: keycloak 30, control_plane 20, datamart 10, odoo_pool_a 48, odoo_staging 24 (ESTIMASI).
- **Role pool Odoo (T10)**: `odoo_pool_a`, `odoo_staging` — `LOGIN CREATEDB NOSUPERUSER NOCREATEROLE`, tanpa DB
  sendiri, `GRANT CONNECT ON DATABASE postgres`. `pg_hba` memakai **regex nama DB (PG16)**:
  `/^[a-z0-9_]+_(prod|demo)$` hanya untuk `odoo_pool_a`, `/^[a-z0-9_]+_staging$` hanya untuk `odoo_staging`.
  DB tenant dibuat Odoo (owner = role pool); `scripts/provision-odoo-db.sh` mencabut CONNECT PUBLIC per DB.
  Verifikasi: `SELECT database, user_name, error FROM pg_hba_file_rules;`.
- Data: named volume `postgres_pgdata` (`/var/lib/docker/volumes/postgres_pgdata/_data`, mode 700 oleh Postgres).

## Network `db` — cara service lain terhubung

- Bridge **`--internal`** (tanpa egress internet), **subnet tetap `10.100.1.0/24`**, dibuat oleh
  `scripts/bootstrap.sh`. Tidak ada port di-publish ke host.
- Service yang butuh DB (Keycloak T06, control-plane T12, Odoo T10, dbt) join network external `db`:
  ```yaml
  services:
    keycloak:
      networks: [db, proxy]
  networks:
    db:
      external: true
      name: db
    proxy:
      external: true
      name: proxy
  ```
- Host: `postgres`, port `5432`, DB = role = `keycloak` | `control_plane` | `datamart`,
  password dari `/opt/infra/postgres/.env` (salin ke `.env` stack konsumen, mode 600).
  Contoh DSN: `postgresql://keycloak:<PG_KEYCLOAK_PASSWORD>@postgres:5432/keycloak`.
- DB/role baru (mis. Odoo pool T10): tambah entri di `APPS` `init-roles.sh` + variabel di `.env`
  (bootstrap menambahkan password bila variabel ditambahkan ke `VARS`) + baris `host` di `pg_hba.conf`,
  lalu reload. Catatan T10: Odoo menghubungi DB `postgres` untuk daftar/buat DB — `CONNECT` PUBLIC
  di DB `postgres` sudah dicabut, jadi role pool perlu `GRANT CONNECT ON DATABASE postgres` + baris hba.

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

## Rotasi password

- Role aplikasi: hapus baris `PG_<APP>_PASSWORD=` di `.env` → `./scripts/bootstrap.sh` (membangkitkan
  nilai baru) → `./scripts/init-roles.sh` (ALTER ROLE … PASSWORD) → perbarui `.env` stack konsumen →
  restart konsumen. Koneksi lama tetap hidup sampai diputus.
- Superuser `postgres`: `POSTGRES_PASSWORD` hanya dipakai saat initdb; login superuser lewat jaringan
  ditolak `pg_hba`, akses hanya `docker exec` (peer). Rotasi opsional:
  `docker exec -it postgres psql -U postgres -c '\password postgres'` lalu samakan `.env`.

## Rollback

- Konfigurasi: `git checkout <rev> -- postgres/` → `docker compose up -d` (recreate, data tetap).
- Image: kembalikan tag/digest sebelumnya (minor 16.x kompatibel on-disk).
- `docker volume rm postgres_pgdata` / `DROP DATABASE` = **destruktif, butuh konfirmasi eksplisit**;
  backup `pg_dump` per DB diatur T13 (ADR 0006).
