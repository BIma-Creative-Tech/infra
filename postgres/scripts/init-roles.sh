#!/usr/bin/env bash
# Membuat/menyelaraskan role + DB aplikasi di cluster Postgres shared (T04). Idempoten:
# aman dijalankan berulang, juga untuk ROTASI password (ubah nilai di .env lalu jalankan ulang).
# Password dikirim lewat stdin ke psql di dalam container (tidak muncul di argv/`ps` host,
# tidak disimpan di environment container).
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${STACK_DIR}/.env"
CONTAINER="${PG_CONTAINER:-postgres}"

[[ $EUID -eq 0 ]] || { echo "harus root" >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo "$ENV_FILE tidak ada — jalankan scripts/bootstrap.sh" >&2; exit 1; }

# db:role:VAR_PASSWORD:connection_limit
APPS=(
  "keycloak:keycloak:PG_KEYCLOAK_PASSWORD:30"
  "control_plane:control_plane:PG_CONTROL_PLANE_PASSWORD:20"
  "datamart:datamart:PG_DATAMART_PASSWORD:10"
  # T16b — control plane STAGING (cp.staging, realm platform-staging). Limit kecil (ESTIMASI).
  "control_plane_staging:control_plane_staging:PG_CONTROL_PLANE_STAGING_PASSWORD:10"
  # Plan 11 / ADR 0013 — Umami web analytics. Role `umami` = OWNER DB (Umami menjalankan `prisma migrate deploy` sendiri
  # saat start: DDL + `CREATE EXTENSION pgcrypto` — trusted extension sejak PG13, boleh dibuat owner DB). Limit 10 → total 196.
  "umami:umami:PG_UMAMI_PASSWORD:10"
)

get_var() { grep -E "^$1=" "$ENV_FILE" | head -n1 | cut -d= -f2-; }

for app in "${APPS[@]}"; do
  IFS=: read -r db role var limit <<<"$app"
  pw="$(get_var "$var")"
  [[ ${#pw} -ge 32 ]] || { echo "$var kosong/terlalu pendek di .env" >&2; exit 1; }
  # Nama db/role berasal dari daftar statis di atas (bukan input user).
  docker exec -i "$CONTAINER" psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres <<SQL
\\set pw '${pw}'
SELECT 'CREATE ROLE ${role}' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${role}')
\\gexec
ALTER ROLE ${role} WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  CONNECTION LIMIT ${limit} PASSWORD :'pw';
SELECT 'CREATE DATABASE ${db} OWNER ${role} ENCODING ''UTF8'' TEMPLATE template0'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${db}')
\\gexec
ALTER DATABASE ${db} OWNER TO ${role};
REVOKE ALL ON DATABASE ${db} FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE ${db} TO ${role};
SQL
  echo "ok: db=${db} role=${role} (password dari ${var}, connection limit ${limit})"
done
unset pw

# T10 — role pool Odoo (tanpa DB sendiri). Odoo membuat DB tenant sendiri (`CREATE DATABASE …
# TEMPLATE template0`, odoo/service/db.py `_create_empty_database`) → CREATEDB, tanpa superuser.
# Odoo terhubung ke DB `postgres` untuk daftar/buat DB (list_dbs, wait-for-psql.py) → GRANT CONNECT.
# DB tenant dibatasi pg_hba (regex nama DB per pool) + kepemilikan (list_dbs hanya DB milik role).
# role:VAR_PASSWORD:connection_limit  — limit = ESTIMASI (db_maxconn × proses pool), revisi T07/T19.
ODOO_ROLES=(
  "odoo_pool_a:PG_ODOO_POOL_A_PASSWORD:48"
  "odoo_staging:PG_ODOO_STAGING_PASSWORD:24"
)
for r in "${ODOO_ROLES[@]}"; do
  IFS=: read -r role var limit <<<"$r"
  pw="$(get_var "$var")"
  [[ ${#pw} -ge 32 ]] || { echo "$var kosong/terlalu pendek di .env" >&2; exit 1; }
  docker exec -i "$CONTAINER" psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres <<SQL
\\set pw '${pw}'
SELECT 'CREATE ROLE ${role}' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${role}')
\\gexec
ALTER ROLE ${role} WITH LOGIN NOSUPERUSER CREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  CONNECTION LIMIT ${limit} PASSWORD :'pw';
GRANT CONNECT ON DATABASE postgres TO ${role};
SQL
  echo "ok: role=${role} CREATEDB (password dari ${var}, connection limit ${limit}, CONNECT postgres)"
done
unset pw

# ProyekKas client DRMS (Payload CMS; ProyekKas ADR 0006 §1, /opt/src/proyekkas/docs/proyekkas/adr/).
# Nama DB sengaja TIDAK berakhiran _prod/_demo/_staging (di luar regex pg_hba pool Odoo di atas).
# Per DB tiga role: <db>_owner (pemilik DB + schema public via pg_database_owner; DDL, hanya container
# migrate), <db>_app (web/worker; CONNECT saja di level DB), <db>_ro (read-only; opsional).
# Hanya hak level DB/schema yang diatur di sini. GRANT per tabel, ALTER DEFAULT PRIVILEGES, REVOKE
# UPDATE/DELETE/TRUNCATE dan trigger append-only dijalankan MIGRASI aplikasi sebagai <db>_owner.
# Password: PG_<DB>_{OWNER,APP,RO}_PASSWORD di .env (dibangkitkan scripts/bootstrap.sh).
# db:limit_owner:limit_app:limit_ro — limit = ESTIMASI (prod: ADR 0006; staging lebih kecil).
PK_DBS=(
  "pk_drms:2:25:3"
  "pk_drms_stg:2:10:2"
)
for entry in "${PK_DBS[@]}"; do
  IFS=: read -r db lim_owner lim_app lim_ro <<<"$entry"
  up="${db^^}"
  pw_owner="$(get_var "PG_${up}_OWNER_PASSWORD")"
  pw_app="$(get_var "PG_${up}_APP_PASSWORD")"
  pw_ro="$(get_var "PG_${up}_RO_PASSWORD")"
  [[ ${#pw_owner} -ge 32 && ${#pw_app} -ge 32 && ${#pw_ro} -ge 32 ]] \
    || { echo "PG_${up}_{OWNER,APP,RO}_PASSWORD kosong/terlalu pendek di .env" >&2; exit 1; }
  # Nama db/role dari daftar statis di atas (bukan input user).
  docker exec -i "$CONTAINER" psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres <<SQL
\\set pw_owner '${pw_owner}'
\\set pw_app '${pw_app}'
\\set pw_ro '${pw_ro}'
SELECT 'CREATE ROLE ${db}_owner' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${db}_owner')
\\gexec
SELECT 'CREATE ROLE ${db}_app' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${db}_app')
\\gexec
SELECT 'CREATE ROLE ${db}_ro' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${db}_ro')
\\gexec
ALTER ROLE ${db}_owner WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  CONNECTION LIMIT ${lim_owner} PASSWORD :'pw_owner';
ALTER ROLE ${db}_app WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  CONNECTION LIMIT ${lim_app} PASSWORD :'pw_app';
ALTER ROLE ${db}_ro WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  CONNECTION LIMIT ${lim_ro} PASSWORD :'pw_ro';
SELECT 'CREATE DATABASE ${db} OWNER ${db}_owner ENCODING ''UTF8'' TEMPLATE template0'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${db}')
\\gexec
ALTER DATABASE ${db} OWNER TO ${db}_owner;
REVOKE ALL ON DATABASE ${db} FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE ${db} TO ${db}_owner;
GRANT CONNECT ON DATABASE ${db} TO ${db}_app, ${db}_ro;
SQL
  # Schema public (PG16: dimiliki pg_database_owner → ${db}_owner, docs predefined-roles).
  # PUBLIC dicabut seluruhnya; app/ro hanya USAGE (tanpa CREATE). Idempoten.
  docker exec -i "$CONTAINER" psql -X -q -v ON_ERROR_STOP=1 -U postgres -d "$db" <<SQL
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO ${db}_app, ${db}_ro;
SQL
  echo "ok: db=${db} owner=${db}_owner app=${db}_app ro=${db}_ro (limit ${lim_owner}/${lim_app}/${lim_ro}; CONNECT PUBLIC dicabut)"
done
unset pw_owner pw_app pw_ro

# Default PUBLIC di DB `postgres`/template1 juga ditutup agar role aplikasi hanya bisa ke DB-nya.
docker exec -i "$CONTAINER" psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres <<'SQL'
REVOKE ALL ON DATABASE postgres FROM PUBLIC;
REVOKE ALL ON DATABASE template1 FROM PUBLIC;
SQL
echo "ok: CONNECT PUBLIC dicabut dari postgres, template1"
