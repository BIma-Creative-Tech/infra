#!/usr/bin/env bash
# Bootstrap idempoten stack webmail (ADR 0012, plan 08). Jalankan sebagai root SEBELUM `docker compose up -d`.
#  1. data/db (700, uid 33 = www-data image Roundcube nonroot) — SQLite; di /opt/infra → ikut backup restic `files`.
#  2. secrets/ (755 root; isi 0400 uid 33): des_key (32 char, AES-256-CBC, TANPA newline) dibuat sekali — MENGGANTI des_key
#     membuat sesi & password tersimpan terenkripsi tidak terbaca (user cukup login ulang).
#  3. secrets/pwhelper_token harus sudah ada — dibuat mail/scripts/pwhelper-secrets.sh (sumber: mail/secrets/pwhelper.token).
set -euo pipefail
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WM_UID=33
[[ $EUID -eq 0 ]] || { echo "harus root" >&2; exit 1; }

install -d -o root -g root -m 0755 "$STACK_DIR/data"
install -d -o "$WM_UID" -g "$WM_UID" -m 0700 "$STACK_DIR/data/db"
echo "data/db: ok"

install -d -o root -g root -m 0755 "$STACK_DIR/secrets"
if [[ ! -s "$STACK_DIR/secrets/des_key" ]]; then
  ( umask 077; openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | head -c 32 > "$STACK_DIR/secrets/des_key.new" )
  [[ $(wc -c < "$STACK_DIR/secrets/des_key.new") -eq 32 ]] || { rm -f "$STACK_DIR/secrets/des_key.new"; echo "gagal des_key" >&2; exit 1; }
  mv -f "$STACK_DIR/secrets/des_key.new" "$STACK_DIR/secrets/des_key"
  echo "secrets/des_key: dibuat"
fi
chown "$WM_UID:$WM_UID" "$STACK_DIR/secrets/des_key"; chmod 0400 "$STACK_DIR/secrets/des_key"
[[ -s "$STACK_DIR/secrets/pwhelper_token" ]] \
  || { echo "secrets/pwhelper_token belum ada — jalankan dulu: mail/scripts/pwhelper-secrets.sh" >&2; exit 1; }
echo "secrets/: ok"

for n in webmail-edge webmail-mail; do
  [[ "$(docker network inspect -f '{{.Internal}}' "$n" 2>/dev/null)" == "true" ]] \
    || { echo "network $n tidak ada / bukan --internal (traefik/scripts/bootstrap.sh, stack mail)" >&2; exit 1; }
done
echo "network webmail-edge, webmail-mail: ok (internal)"
