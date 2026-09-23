#!/usr/bin/env bash
# Bootstrap idempoten pool Odoo (T10). Jalankan sebagai root sebelum `docker compose up -d`.
#   scripts/odoo-pool-bootstrap.sh <pool-a|staging>
#  1. <pool>/.env (600 root): PGHOST/PGPORT/PGUSER/PGPASSWORD (password disalin dari
#     postgres/.env, disinkronkan bila dirotasi) + ODOO_ADMIN_PASSWD (hash pbkdf2_sha512 master
#     password, dihitung dengan crypt_context Odoo di image).
#  2. <pool>/secrets/master-password (600 root): plaintext master password (48 char acak) —
#     hanya dibuat bila belum ada. secrets/tenants/ (700) untuk password admin tenant.
#  3. addons/clients/ ada (glob addons_path).
# Tidak mencetak secret; tidak menimpa nilai yang sudah ada (kecuali sinkron PGPASSWORD).
set -euo pipefail
# shellcheck source=lib/odoo-pools.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/odoo-pools.sh"

[[ $EUID -eq 0 ]] || die "harus root"
[[ $# -eq 1 ]] || die "pemakaian: $0 <pool-a|staging>"
pool_by_name "$1"
[[ -f "$PG_ENV_FILE" ]] || die "tidak ada $PG_ENV_FILE (jalankan postgres/scripts/bootstrap.sh)"
IMAGE="$(sed -n 's/^ *image: *//p' "$POOL_DIR/docker-compose.yml" | head -n1)"
[[ -n "$IMAGE" ]] || die "image tidak ditemukan di $POOL_DIR/docker-compose.yml"

umask 077
ENV_FILE="$POOL_DIR/.env"
SECRETS="$POOL_DIR/secrets"
install -d -o root -g root -m 0700 "$SECRETS" "$SECRETS/tenants"
install -d -o root -g root -m 0755 "$POOL_DIR/addons/clients"
touch "$ENV_FILE"; chown root:root "$ENV_FILE"; chmod 600 "$ENV_FILE"

set_var() { # <VAR> <value> — tambah bila belum ada, ganti bila berbeda
  local cur
  if grep -q "^$1=" "$ENV_FILE"; then
    cur="$(grep "^$1=" "$ENV_FILE" | head -n1 | cut -d= -f2-)"
    [[ "$cur" == "$2" ]] && { echo "$1: ok"; return; }
    local tmp; tmp="$(mktemp "$POOL_DIR/.env.XXXXXX")"
    awk -v k="$1" -v v="$2" 'BEGIN{FS=OFS="="} $1==k{print k "=" v; next} {print}' "$ENV_FILE" > "$tmp"
    chmod 600 "$tmp"; mv "$tmp" "$ENV_FILE"; echo "$1: diperbarui"
  else
    printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"; echo "$1: ditambahkan"
  fi
}

pg_pw="$(grep "^${POOL_PG_VAR}=" "$PG_ENV_FILE" | head -n1 | cut -d= -f2-)"
[[ ${#pg_pw} -ge 32 ]] || die "$POOL_PG_VAR kosong/terlalu pendek di $PG_ENV_FILE"
set_var PGHOST postgres
set_var PGPORT 5432
set_var PGUSER "$POOL_PGUSER"
set_var PGPASSWORD "$pg_pw"
unset pg_pw

MASTER="$SECRETS/master-password"
if [[ ! -s "$MASTER" ]]; then
  pw="$(openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c 48)"
  [[ ${#pw} -ge 32 ]] || die "gagal membangkitkan master password"
  printf '%s' "$pw" > "$MASTER"; unset pw
  echo "master-password: dibangkitkan (48 char) → $MASTER"
fi
chmod 600 "$MASTER"; chown root:root "$MASTER"

# Hash hanya dihitung ulang bila belum ada atau tidak cocok dengan plaintext (verifikasi di image).
cur_hash="$( { grep '^ODOO_ADMIN_PASSWD=' "$ENV_FILE" || true; } | head -n1 | cut -d= -f2- | sed "s/^'//; s/'\$//")"
verify='import sys
from odoo.tools.config import crypt_context
pw, h = sys.stdin.read().split("\n", 1)
print("ok" if h and crypt_context.verify(pw, h.strip()) else "no")'
ok="no"
if [[ -n "$cur_hash" ]]; then
  ok="$( { cat "$MASTER"; printf '\n%s' "$cur_hash"; } \
        | docker run --rm -i --network none --entrypoint python3 "$IMAGE" -c "$verify")"
fi
if [[ "$ok" != "ok" ]]; then
  hash="$(docker run --rm -i --network none --entrypoint python3 "$IMAGE" \
          -c 'import sys; from odoo.tools.config import crypt_context; print(crypt_context.hash(sys.stdin.read()))' < "$MASTER")"
  [[ "$hash" == '$pbkdf2-sha512$'* ]] || die "hash master password gagal"
  # single-quote: compose tidak menginterpolasi '$' di dalam nilai ber-kutip tunggal.
  set_var ODOO_ADMIN_PASSWD "'${hash}'"
else
  echo "ODOO_ADMIN_PASSWD: ok (cocok dengan secrets/master-password)"
fi
echo ".env: $(stat -c %a "$ENV_FILE") · secrets/: $(stat -c %a "$SECRETS")"
