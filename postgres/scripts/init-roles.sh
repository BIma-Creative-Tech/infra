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

# Default PUBLIC di DB `postgres`/template1 juga ditutup agar role aplikasi hanya bisa ke DB-nya.
docker exec -i "$CONTAINER" psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres <<'SQL'
REVOKE ALL ON DATABASE postgres FROM PUBLIC;
REVOKE ALL ON DATABASE template1 FROM PUBLIC;
SQL
echo "ok: CONNECT PUBLIC dicabut dari postgres, template1"
