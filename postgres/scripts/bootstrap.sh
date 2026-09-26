#!/usr/bin/env bash
# Bootstrap idempoten stack Postgres (T04). Jalankan sebagai root dari mana saja.
#  1. network docker `db-<konsumen>` (internal, subnet tetap) — satu per konsumen Postgres (ADR 0010, plan 06 §3.2):
#     anggota HANYA `postgres` + konsumen itu. Network lama `db` (10.100.1.0/24, dipakai bersama) tetap dibuat sampai
#     plan 06 S10 (pensiun; subnet tidak dipakai ulang).
#  2. .env (mode 600 root) berisi password acak `openssl rand` — hanya dibuat bila belum ada;
#     variabel yang hilang ditambahkan, nilai yang sudah ada TIDAK diubah. Password tidak dicetak.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${STACK_DIR}/.env"
VARS=(POSTGRES_PASSWORD PG_KEYCLOAK_PASSWORD PG_CONTROL_PLANE_PASSWORD PG_DATAMART_PASSWORD
      PG_ODOO_POOL_A_PASSWORD PG_ODOO_STAGING_PASSWORD    # T10: role pool Odoo prod/staging
      PG_CONTROL_PLANE_STAGING_PASSWORD                   # T16b: control plane staging
      # ProyekKas client DRMS (ProyekKas ADR 0006 §1): role owner/app/ro per DB pk_drms, pk_drms_stg
      PG_PK_DRMS_OWNER_PASSWORD PG_PK_DRMS_APP_PASSWORD PG_PK_DRMS_RO_PASSWORD
      PG_PK_DRMS_STG_OWNER_PASSWORD PG_PK_DRMS_STG_APP_PASSWORD PG_PK_DRMS_STG_RO_PASSWORD)

[[ $EUID -eq 0 ]] || { echo "harus root" >&2; exit 1; }

# ensure_internal_network <nama> <subnet> <gateway> — buat (bridge, --internal) bila belum ada; bila ada, subnet dan
# flag --internal wajib sama (pola traefik/scripts/bootstrap.sh ensure_network).
ensure_internal_network() {
  local name="$1" net_subnet="$2" net_gateway="$3" subnet internal
  if docker network inspect "$name" >/dev/null 2>&1; then
    subnet="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$name")"
    internal="$(docker network inspect -f '{{.Internal}}' "$name")"
    [[ "$subnet" == "$net_subnet" && "$internal" == "true" ]] \
      || { echo "network $name subnet=$subnet internal=$internal (harus $net_subnet, true) — periksa manual" >&2; exit 1; }
    echo "network $name: ok (sudah ada)"
  else
    docker network create --driver bridge --internal \
      --subnet "$net_subnet" --gateway "$net_gateway" \
      --label infra.stack=postgres "$name" >/dev/null
    echo "network $name: dibuat"
  fi
}

# 1. network
# `db` — LAMA, dipakai bersama semua konsumen (QA-T17B-01). Dipertahankan selama transisi plan 06 (S1–S9); dihapus di S10
# (baris ini dihapus, `docker network rm db`). Subnet 10.100.1.0/24 TIDAK dipakai ulang.
# (S10 2026-09-26: `db` DIHAPUS — subnet 10.100.1.0/24 pensiun, jangan dipakai ulang.)
# ADR 0010 / plan 06 §3.2 — satu network --internal per konsumen (app + env; worker/migrate/seed app yang sama boleh
# berbagi). Blok 10.100.20.0/24–10.100.39.0/24 dicadangkan untuk db-*. Baris pg_hba (conf/pg_hba.conf) memakai subnet ini.
ensure_internal_network db-keycloak     10.100.20.0/24 10.100.20.1   # keycloak
ensure_internal_network db-odoo-pool-a  10.100.21.0/24 10.100.21.1   # odoo-pool-a (prod)
ensure_internal_network db-odoo-staging 10.100.22.0/24 10.100.22.1   # odoo-staging
ensure_internal_network db-cp           10.100.23.0/24 10.100.23.1   # control-plane (+worker, migrate)
ensure_internal_network db-cp-stg       10.100.24.0/24 10.100.24.1   # control-plane-staging (+worker, migrate)
ensure_internal_network db-drms-stg     10.100.26.0/24 10.100.26.1   # drms-pk-stg (+worker, migrate, seed)
# CADANGAN — belum dibuat (tidak ada konsumen; baris pg_hba-nya sudah ada, subnet tanpa anggota):
#   db-drms      10.100.25.0/24  drms-pk-web(-worker, migrate, seed) — saat onboarding ProyekKas DRMS prod
#   db-datamart  10.100.27.0/24  dbt cron datamart — saat stack datamart dibuat
#   10.100.28.0/24–10.100.39.0/24  db-* berikutnya (pool/dedicated Odoo, klien baru)
# Untuk mengaktifkan: tambahkan baris ensure_internal_network di atas + `docker network connect <net> postgres` + compose.

# 2. .env
umask 077
[[ -f "$ENV_FILE" ]] || { : > "$ENV_FILE"; echo ".env: dibuat"; }
chown root:root "$ENV_FILE"
chmod 600 "$ENV_FILE"
for v in "${VARS[@]}"; do
  if grep -q "^${v}=" "$ENV_FILE"; then
    echo ".env: $v sudah ada (tidak diubah)"
  else
    # 48 byte acak → base64 64 char; hanya [A-Za-z0-9] agar aman di URL/DSN (tetap > 32 char)
    pw="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 48)"
    [[ ${#pw} -ge 32 ]] || { echo "gagal membangkitkan password" >&2; exit 1; }
    printf '%s=%s\n' "$v" "$pw" >> "$ENV_FILE"
    echo ".env: $v dibangkitkan (${#pw} char)"
  fi
done
unset pw
