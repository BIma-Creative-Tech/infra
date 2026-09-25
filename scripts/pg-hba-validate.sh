#!/usr/bin/env bash
# Validasi pg_hba.conf di Postgres SEMENTARA (plan 06 §6 S2/S10, ADR 0010). READ-ONLY terhadap platform:
# tidak menyentuh container/network/volume live — hanya 2 container sementara `--rm` tanpa network eksternal
# (`--network none`; alamat uji ditambahkan ke `lo` DI DALAM netns container sementara itu).
#
#   pg-hba-validate.sh <pg_hba-file> [transition|final]
#
#  1. Postgres image platform (pin sama dengan postgres/docker-compose.yml) start dengan -c hba_file=<file>
#     → `pg_hba_file_rules` wajib tanpa kolom `error`.
#  2. Matriks sumber × (DB, role): psql dari alamat subnet tiap network (10.100.<n>.5) dengan password SALAH.
#     "password authentication failed" = baris hba MENGIZINKAN (sampai tahap auth) → ALLOW;
#     "pg_hba.conf rejects connection" / "no pg_hba.conf entry" = REJECT. Role/DB tidak perlu ada.
#     Harapan: DB/role hanya dari subnet db-<konsumen> miliknya; mode `transition` juga dari 10.100.1.0/24 (`db` lama).
# Exit 0 = semua sesuai harapan, 1 = ada error/selisih, 2 = pemakaian.
set -euo pipefail

PG_IMAGE="postgres:16.15-bookworm@sha256:efedf3595f1d6f415c08568ba171029bf54052e754cc9f030e3f2412b21f3d67"
# Hanya dipakai sebagai pemegang netns (busybox `ip`, `sleep`); pin sama dengan traefik/docker-compose.yml.
NS_IMAGE="traefik:v3.7.13@sha256:24841fe2de7304c149343d877d2923b4c8800a38ba015dea9174c23b20e344a0"

[[ $# -ge 1 && $# -le 2 ]] || { sed -n '5,13p' "$0" >&2; exit 2; }
HBA="$(realpath "$1")"; MODE="${2:-transition}"
[[ -f "$HBA" ]] || { echo "file tidak ada: $1" >&2; exit 2; }
[[ "$MODE" == transition || "$MODE" == final ]] || { echo "mode harus transition|final" >&2; exit 2; }

NS="pghba-validate-ns-$$"; PG="pghba-validate-pg-$$"
# shellcheck disable=SC2329  # dipanggil lewat trap EXIT
cleanup() { docker rm -f "$PG" "$NS" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Sumber uji: label=alamat. db = network lama (transisi), sisanya plan 06 §3.2 (+ network non-DB sebagai kontrol negatif).
declare -A SRC=(
  [db]=10.100.1.5 [proxy]=10.100.0.5 [odoo-edge]=10.100.3.5 [kc-edge]=10.100.12.5 [odoo-edge-stg]=10.100.13.5
  [db-keycloak]=10.100.20.5 [db-odoo-pool-a]=10.100.21.5 [db-odoo-staging]=10.100.22.5 [db-cp]=10.100.23.5
  [db-cp-stg]=10.100.24.5 [db-drms]=10.100.25.5 [db-drms-stg]=10.100.26.5 [db-datamart]=10.100.27.5
)
# Pasangan uji: "db role network-pemilik" (network-pemilik = satu-satunya db-* yang boleh; `-` = tidak boleh dari mana pun).
PAIRS=(
  "keycloak keycloak db-keycloak"
  "control_plane control_plane db-cp"
  "control_plane_staging control_plane_staging db-cp-stg"
  "datamart datamart db-datamart"
  "postgres odoo_pool_a db-odoo-pool-a"
  "acme_prod odoo_pool_a db-odoo-pool-a"
  "acme_demo odoo_pool_a db-odoo-pool-a"
  "acme_staging odoo_pool_a -"
  "postgres odoo_staging db-odoo-staging"
  "acme_staging odoo_staging db-odoo-staging"
  "acme_prod odoo_staging -"
  # DIKETAHUI (plan 06 §2.4, tidak diubah plan ini): regex `_staging$` juga cocok dengan DB control_plane_staging →
  # hba ALLOW; ditutup di lapisan privilege (CONNECT odoo_staging → control_plane_staging dicabut).
  "control_plane_staging odoo_staging db-odoo-staging"
  "pk_drms pk_drms_app db-drms"
  "pk_drms pk_drms_owner db-drms"
  "pk_drms_stg pk_drms_stg_app db-drms-stg"
  "pk_drms_stg pk_drms_stg_ro db-drms-stg"
  "pk_drms_stg pk_drms_app -"
  "keycloak control_plane -"
  "postgres postgres -"
  "keycloak postgres -"
)
# Pasangan yang TIDAK diizinkan dari `db` lama walau mode transition (tidak ada baris lama untuknya).
legacy_allowed() { [[ "$3" != "-" ]]; }

docker run -d --rm --name "$NS" --network none --cap-drop ALL --cap-add NET_ADMIN \
  --entrypoint sleep "$NS_IMAGE" 600 >/dev/null
for label in "${!SRC[@]}"; do docker exec "$NS" ip addr add "${SRC[$label]}/32" dev lo; done

docker run -d --rm --name "$PG" --network "container:$NS" --user 999:999 --read-only \
  --tmpfs /var/lib/postgresql/data:uid=999,gid=999,mode=0700 --tmpfs /var/run/postgresql:uid=999,gid=999,mode=0775 \
  --tmpfs /tmp:uid=999,gid=999,mode=1777 \
  -e POSTGRES_PASSWORD="$(openssl rand -hex 24)" \
  -e POSTGRES_INITDB_ARGS="--auth-host=scram-sha-256 --auth-local=peer" \
  -v "$HBA:/etc/postgresql/pg_hba.conf:ro" \
  "$PG_IMAGE" postgres -c hba_file=/etc/postgresql/pg_hba.conf -c listen_addresses='*' >/dev/null

for _ in $(seq 1 60); do
  # entrypoint menjalankan server sementara (listen_addresses='') saat init → tunggu listener TCP final
  docker exec "$PG" pg_isready -q -h 10.100.1.5 2>/dev/null && break
  sleep 1
done
docker exec "$PG" pg_isready -h 10.100.1.5 >/dev/null || { docker logs "$PG" | tail -20 >&2; echo "postgres sementara tidak siap" >&2; exit 1; }

rc=0
echo "## pg_hba_file_rules ($HBA)"
docker exec "$PG" psql -U postgres -X -A -F ' | ' -c \
  "SELECT line_number, type, database, user_name, address, netmask, auth_method, coalesce(error,'') AS error FROM pg_hba_file_rules ORDER BY line_number"
errs="$(docker exec "$PG" psql -U postgres -X -At -c "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL")"
echo "error rows: $errs"; [[ "$errs" == 0 ]] || rc=1

echo "## matriks sumber × (db, role) — mode $MODE"
checked=0; mism=0
for label in $(printf '%s\n' "${!SRC[@]}" | sort); do
  ip="${SRC[$label]}"
  for p in "${PAIRS[@]}"; do
    read -r db role owner <<<"$p"
    want=REJECT
    [[ "$label" == "$owner" ]] && want=ALLOW
    [[ "$MODE" == transition && "$label" == db ]] && legacy_allowed "$db" "$role" "$owner" && want=ALLOW
    # db-drms/db-datamart = cadangan: baris hba ada → ALLOW (network belum dibuat, tidak ada anggota).
    out="$(docker exec -e PGPASSWORD=invalid-probe -e PGCONNECT_TIMEOUT=3 "$PG" \
            psql -X -w "host=$ip port=5432 dbname=$db user=$role sslmode=disable" -c 'select 1' 2>&1 || true)"
    case "$out" in
      *"password authentication failed"*) got=ALLOW ;;
      *"rejects connection"*|*"no pg_hba.conf entry"*) got=REJECT ;;
      *) got="?($(tr '\n' ' ' <<<"$out" | cut -c1-80))" ;;
    esac
    checked=$((checked + 1))
    if [[ "$got" != "$want" ]]; then mism=$((mism + 1)); rc=1; echo "MISMATCH $label($ip) db=$db role=$role want=$want got=$got"; fi
  done
done
echo "cells checked: $checked, mismatches: $mism"
[[ $rc -eq 0 ]] && echo "RESULT: OK" || echo "RESULT: FAIL"
exit "$rc"
