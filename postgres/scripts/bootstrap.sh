#!/usr/bin/env bash
# Bootstrap idempoten stack Postgres (T04). Jalankan sebagai root dari mana saja.
#  1. network docker `db` (internal, subnet tetap) — dipakai bersama oleh Keycloak/control-plane/Odoo
#  2. .env (mode 600 root) berisi password acak `openssl rand` — hanya dibuat bila belum ada;
#     variabel yang hilang ditambahkan, nilai yang sudah ada TIDAK diubah. Password tidak dicetak.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${STACK_DIR}/.env"
NET_NAME="db"
NET_SUBNET="10.100.1.0/24"
NET_GATEWAY="10.100.1.1"
VARS=(POSTGRES_PASSWORD PG_KEYCLOAK_PASSWORD PG_CONTROL_PLANE_PASSWORD PG_DATAMART_PASSWORD
      PG_ODOO_POOL_A_PASSWORD PG_ODOO_STAGING_PASSWORD    # T10: role pool Odoo prod/staging
      PG_CONTROL_PLANE_STAGING_PASSWORD                   # T16b: control plane staging
      # ProyekKas client DRMS (ProyekKas ADR 0006 §1): role owner/app/ro per DB pk_drms, pk_drms_stg
      PG_PK_DRMS_OWNER_PASSWORD PG_PK_DRMS_APP_PASSWORD PG_PK_DRMS_RO_PASSWORD
      PG_PK_DRMS_STG_OWNER_PASSWORD PG_PK_DRMS_STG_APP_PASSWORD PG_PK_DRMS_STG_RO_PASSWORD)

[[ $EUID -eq 0 ]] || { echo "harus root" >&2; exit 1; }

# 1. network
if docker network inspect "$NET_NAME" >/dev/null 2>&1; then
  internal="$(docker network inspect -f '{{.Internal}}' "$NET_NAME")"
  subnet="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$NET_NAME")"
  if [[ "$internal" != "true" || "$subnet" != "$NET_SUBNET" ]]; then
    echo "network $NET_NAME ada tetapi internal=$internal subnet=$subnet (harus true/$NET_SUBNET) — periksa manual" >&2
    exit 1
  fi
  echo "network $NET_NAME: ok (sudah ada)"
else
  docker network create --driver bridge --internal \
    --subnet "$NET_SUBNET" --gateway "$NET_GATEWAY" \
    --label infra.stack=postgres "$NET_NAME" >/dev/null
  echo "network $NET_NAME: dibuat"
fi

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
