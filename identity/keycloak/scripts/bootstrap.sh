#!/usr/bin/env bash
# Bootstrap idempoten stack Keycloak (T06). Jalankan sebagai root sebelum `docker compose up -d`.
# Membuat .env (600) berisi KC_DB_PASSWORD (disalin dari postgres/.env) dan admin bootstrap
# sementara (password acak 48 char). Tidak mencetak secret; tidak menimpa nilai yang ada.
set -euo pipefail
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PG_ENV="$STACK_DIR/../../postgres/.env"
ENV_FILE="$STACK_DIR/.env"
[[ $EUID -eq 0 ]] || { echo "harus root" >&2; exit 1; }
[[ -f "$PG_ENV" ]] || { echo "tidak ada $PG_ENV (jalankan postgres/scripts/bootstrap.sh)" >&2; exit 1; }

umask 077
touch "$ENV_FILE"; chmod 600 "$ENV_FILE"; chown root:root "$ENV_FILE"

set_if_missing() { # <VAR> <value>
  grep -q "^$1=" "$ENV_FILE" || { printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"; echo "$1: ditambahkan"; }
}
pg_pw="$(grep '^PG_KEYCLOAK_PASSWORD=' "$PG_ENV" | cut -d= -f2-)"
[[ -n "$pg_pw" ]] || { echo "PG_KEYCLOAK_PASSWORD kosong di $PG_ENV" >&2; exit 1; }
set_if_missing KC_DB_PASSWORD "$pg_pw"
# Admin sementara hanya relevan sebelum realm master ada; setelah dihapus dari .env jangan dibuat ulang.
if [[ ! -f "$STACK_DIR/.bootstrap-done" ]]; then
  set_if_missing KC_BOOTSTRAP_ADMIN_USERNAME "temp-admin"
  set_if_missing KC_BOOTSTRAP_ADMIN_PASSWORD "$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 48)"
fi
# Sinkron bila password DB dirotasi di postgres/.env
cur="$(grep '^KC_DB_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)"
if [[ "$cur" != "$pg_pw" ]]; then
  sed -i "s|^KC_DB_PASSWORD=.*|KC_DB_PASSWORD=${pg_pw}|" "$ENV_FILE"; echo "KC_DB_PASSWORD: disinkronkan"
fi
echo ".env: ok ($(stat -c %a "$ENV_FILE"))"
