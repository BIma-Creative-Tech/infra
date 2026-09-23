#!/usr/bin/env bash
# Tambah mailbox DMS dengan password acak + kuota (T11, ADR 0005 #10, #15). Idempoten.
#   mailbox-add.sh <alamat> [kuota]          kuota default 2G (setup quota set; satuan B/k/M/G/T)
#   mailbox-add.sh --rotate <alamat>         ganti password (setup email update) → file secret ditimpa
# Password: 32 char [A-Za-z0-9] → secrets/<alamat>.password (600 root, TANPA newline). Tidak pernah dicetak.
# Password dikirim ke `setup email add|update` lewat STDIN (prompt "Enter/Confirm Password",
# helpers/database/manage/postfix-accounts.sh `_password_request_if_missing`) — tidak di argv host.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
C=mailserver
[[ $EUID -eq 0 ]] || { echo "harus root" >&2; exit 1; }

ROTATE=0
if [[ "${1:-}" == "--rotate" ]]; then ROTATE=1; shift; fi
ADDR="${1:?alamat wajib}"
QUOTA="${2:-2G}"
[[ "$ADDR" =~ ^[a-z0-9._-]+@[a-z0-9.-]+\.[a-z]{2,}$ ]] || { echo "alamat tidak valid (huruf kecil saja): $ADDR" >&2; exit 1; }
[[ "$QUOTA" =~ ^[0-9]+[BkMGT]?$ ]] || { echo "kuota tidak valid: $QUOTA" >&2; exit 1; }

SECRET="$STACK_DIR/secrets/$ADDR.password"
install -d -o root -g root -m 0700 "$STACK_DIR/secrets"

# `setup email list` bisa exit ≠ 0 walau daftar tercetak (mis. Dovecot belum siap) → tangkap output dulu
# (dengan pipefail, `cmd | grep -q` salah membaca akun yang ada sebagai tidak ada).
exists() {
  local out
  out="$(docker exec "$C" setup email list 2>/dev/null || true)"
  grep -qE "^\* ${ADDR//./\\.} " <<<"$out"
}

gen_password() {
  ( umask 077; openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c 32 > "$SECRET.new" )
  [[ $(wc -c < "$SECRET.new") -eq 32 ]] || { rm -f "$SECRET.new"; echo "gagal membuat password" >&2; exit 1; }
}

send_password() { # send_password add|update
  local p; p="$(cat "$SECRET.new")"
  printf '%s\n%s\n' "$p" "$p" | docker exec -i "$C" setup email "$1" "$ADDR" >/dev/null
  unset p
  mv -f "$SECRET.new" "$SECRET"; chmod 600 "$SECRET"
}

if exists; then
  if [[ $ROTATE -eq 1 ]]; then
    trap 'rm -f "$SECRET.new"' EXIT
    gen_password; send_password update
    echo "$ADDR: password dirotasi → $SECRET"
  else
    echo "$ADDR: sudah ada (tidak diubah)"
  fi
else
  [[ $ROTATE -eq 0 ]] || { echo "$ADDR belum ada — tidak bisa rotasi" >&2; exit 1; }
  trap 'rm -f "$SECRET.new"' EXIT
  gen_password; send_password add
  echo "$ADDR: dibuat → $SECRET"
fi

# setquota gagal (sedfile "No difference") bila nilai sudah sama → cek dovecot-quotas.cf dulu.
if docker exec "$C" grep -qxF "$ADDR:$QUOTA" /tmp/docker-mailserver/dovecot-quotas.cf 2>/dev/null; then
  echo "$ADDR: kuota $QUOTA (sudah)"
else
  docker exec "$C" setup quota set "$ADDR" "$QUOTA" >/dev/null
  echo "$ADDR: kuota $QUOTA"
fi
