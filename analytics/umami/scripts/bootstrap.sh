#!/usr/bin/env bash
# Bootstrap idempoten stack Umami (plan 11 U3, ADR 0013). Jalankan sebagai root.
#  1. .env (600 root): APP_SECRET + TWO_FACTOR_ENCRYPTION_KEY dibangkitkan SEKALI (`openssl rand -hex 32`), nilai yang ada
#     TIDAK diubah; DATABASE_URL diselaraskan dengan PG_UMAMI_PASSWORD di postgres/.env (rotasi password: postgres.md).
#  2. secrets/ (700 root) — tempat password admin Umami (secrets/admin-password, 600) untuk owner.
# Tidak ada secret yang dicetak.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$(cd "$STACK_DIR/../.." && pwd)"
ENV_FILE="$STACK_DIR/.env"
PG_ENV="${PG_ENV_FILE:-$INFRA_DIR/postgres/.env}"

[[ $EUID -eq 0 ]] || { echo "harus root" >&2; exit 1; }
[[ -f "$PG_ENV" ]] || { echo "$PG_ENV tidak ada — jalankan postgres/scripts/bootstrap.sh" >&2; exit 1; }

umask 077
pgpw="$(grep -E '^PG_UMAMI_PASSWORD=' "$PG_ENV" | head -n1 | cut -d= -f2-)"
[[ ${#pgpw} -ge 32 && "$pgpw" =~ ^[A-Za-z0-9]+$ ]] \
  || { echo "PG_UMAMI_PASSWORD kosong/tidak valid di $PG_ENV — jalankan postgres/scripts/bootstrap.sh" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] || { : > "$ENV_FILE"; echo ".env: dibuat"; }
chown root:root "$ENV_FILE"
chmod 600 "$ENV_FILE"

for v in APP_SECRET TWO_FACTOR_ENCRYPTION_KEY; do
  if grep -q "^${v}=" "$ENV_FILE"; then
    echo ".env: $v sudah ada (tidak diubah)"
  else
    val="$(openssl rand -hex 32)"
    [[ "$val" =~ ^[0-9a-f]{64}$ ]] || { echo "gagal membangkitkan $v" >&2; exit 1; }
    printf '%s=%s\n' "$v" "$val" >> "$ENV_FILE"
    echo ".env: $v dibangkitkan (64 hex)"
  fi
done
unset val

url="postgresql://umami:${pgpw}@postgres:5432/umami"
if grep -qxF "DATABASE_URL=${url}" "$ENV_FILE"; then
  echo ".env: DATABASE_URL sesuai postgres/.env (tidak diubah)"
else
  tmp="$(mktemp "$STACK_DIR/.env.XXXXXX")"
  { grep -v '^DATABASE_URL=' "$ENV_FILE" || true; printf 'DATABASE_URL=%s\n' "$url"; } > "$tmp"
  chmod 600 "$tmp"; mv -f -- "$tmp" "$ENV_FILE"
  echo ".env: DATABASE_URL ditulis (restart umami agar dipakai)"
fi
unset pgpw url

install -d -o root -g root -m 0700 "$STACK_DIR/secrets"
echo "secrets/: ok"
