#!/usr/bin/env bash
# Ingest raw data mart (ADR 0016 #1): DB Odoo <slug>_<env> → schema raw_<slug>_<env> di DB `datamart`.
#   datamart/ingest.sh <slug> <env>        (root; dipanggil datamart-refresh.sh)
# Setiap tabel = datamart/ingest/<slug>/<tabel>.sql (SELECT eksplisit) + DDL di _ddl.sql.
# COPY TO STDOUT dari DB sumber (psql superuser via peer di container postgres, seperti backup.sh), lalu
# SATU transaksi di datamart: CREATE SCHEMA/TABLE IF NOT EXISTS → TRUNCATE → COPY … FROM STDIN (data inline).
# Gagal di tengah = rollback, raw lama tetap. Baris terakhir: RESULT …
set -euo pipefail
umask 077
slug=${1:?pemakaian: ingest.sh <slug> <env>}
env=${2:?pemakaian: ingest.sh <slug> <env>}
[[ "$slug" =~ ^[a-z0-9_]{3,30}$ && "$env" =~ ^(prod|demo|staging)$ ]] || { echo "slug/env tidak valid" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
dir="$here/ingest/$slug"
src_db="${slug}_${env}"
schema="raw_${slug}_${env}"
[[ -f "$dir/_ddl.sql" ]] || { echo "tidak ada $dir/_ddl.sql" >&2; exit 2; }

psql_src() { docker exec -i postgres psql -U postgres -d "$src_db" -v ON_ERROR_STOP=1 -X -q "$@"; }
exists=$(docker exec postgres psql -U postgres -XtAc "SELECT 1 FROM pg_database WHERE datname = '$src_db'")
if [[ "$exists" != 1 ]]; then
  echo "RESULT slug=$slug env=$env status=skip reason=no_source_db"
  exit 0
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
{
  echo "\\set ON_ERROR_STOP 1"
  echo "SET client_min_messages = warning;"
  echo "BEGIN;"
  echo "CREATE SCHEMA IF NOT EXISTS $schema;"
  sed "s/{{schema}}/$schema/g" "$dir/_ddl.sql"
  for f in "$dir"/[a-z]*.sql; do
    table=$(basename "$f" .sql)
    query=$(grep -v '^[[:space:]]*--' "$f" | tr '\n' ' ')
    echo "TRUNCATE $schema.$table;"
    # plan 18: `-- optional-table: <tabel>` = tabel milik modul opsional; tidak ada di DB sumber → raw dibiarkan kosong.
    opt=$(sed -n 's/^--[[:space:]]*optional-table:[[:space:]]*\([a-z0-9_]*\).*/\1/p' "$f" | head -1)
    if [[ -n "$opt" && $(psql_src -tAc "SELECT to_regclass('public.$opt') IS NOT NULL") != t ]]; then
      continue
    fi
    echo "COPY $schema.$table FROM STDIN;"
    psql_src -c "COPY ($query) TO STDOUT"
    echo '\.'
  done
  # pemilik raw = superuser (COPY); runner dbt (role datamart) hanya perlu baca
  echo "GRANT USAGE ON SCHEMA $schema TO datamart; GRANT SELECT ON ALL TABLES IN SCHEMA $schema TO datamart;"
  echo "COMMENT ON SCHEMA $schema IS 'ingest $(date -u +%Y-%m-%dT%H:%M:%SZ) dari $src_db';"
  echo "COMMIT;"
} > "$tmp"

docker exec -i postgres psql -U postgres -d datamart -X -q -v ON_ERROR_STOP=1 < "$tmp" >/dev/null
rows=$(docker exec postgres psql -U postgres -d datamart -XtAc \
  "SELECT string_agg(relname || '=' || n_live_tup, ' ' ORDER BY relname) FROM pg_stat_user_tables WHERE schemaname = '$schema'")
echo "RESULT slug=$slug env=$env status=ok schema=$schema bytes=$(stat -c %s "$tmp") $rows"
