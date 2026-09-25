#!/usr/bin/env bash
# pwhelper-secrets.sh — siapkan secret helper ganti password webmail (ADR 0012, plan 08). Idempoten, root.
#  1. Token Bearer bersama webmail ↔ pwhelper: secrets/pwhelper.token (600 root, 48 char, TANPA newline) — dibuat sekali.
#     Disalin ke data/config/pwhelper/token (600 root; dibaca helper di mailserver) dan webmail/secrets/pwhelper_token
#     (0400 uid 33 = www-data image Roundcube nonroot).
#  2. Deny list data/config/pwhelper/deny.pbkdf2: hash PBKDF2-SHA256 (salt acak per baris, 200k iterasi) dari password
#     AWAL/default setiap alamat di allowlist (secrets/<alamat>.password) → user tidak bisa "mengganti" ke password default.
#     Password tidak pernah dicetak; dibaca dari file, diproses di python3 host via STDIN.
#  --rotate-token  buat token baru (lalu recreate webmail agar membaca file baru — lihat docs/03-operations/webmail.md).
set -euo pipefail
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$(cd "$STACK_DIR/.." && pwd)"
[[ $EUID -eq 0 ]] || { echo "harus root" >&2; exit 1; }

TOKEN="$STACK_DIR/secrets/pwhelper.token"
CONF="$STACK_DIR/data/config/pwhelper"
WM_SECRET_DIR="$INFRA_DIR/webmail/secrets"
WM_UID=33

install -d -o root -g root -m 0700 "$STACK_DIR/secrets" "$CONF"
if [[ "${1:-}" == "--rotate-token" || ! -s "$TOKEN" ]]; then
  ( umask 077; openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | head -c 48 > "$TOKEN.new" )
  [[ $(wc -c < "$TOKEN.new") -eq 48 ]] || { rm -f "$TOKEN.new"; echo "gagal membuat token" >&2; exit 1; }
  mv -f "$TOKEN.new" "$TOKEN"; chmod 600 "$TOKEN"
  echo "token: dibuat/dirotasi"
fi
install -o root -g root -m 0600 "$TOKEN" "$CONF/token"
install -d -o root -g root -m 0755 "$WM_SECRET_DIR"
install -o "$WM_UID" -g "$WM_UID" -m 0400 "$TOKEN" "$WM_SECRET_DIR/pwhelper_token"
echo "token: disalin ke data/config/pwhelper/token + webmail/secrets/pwhelper_token"

# Deny list dari password awal alamat-alamat di allowlist.
mapfile -t ADDRS < <(grep -Ev '^\s*(#|$)' "$STACK_DIR/config/pwhelper/allowlist.txt")
python3 -I -c '
import hashlib, os, sys
out = []
for path in sys.stdin.read().split("\0"):
    if not path:
        continue
    try:
        pw = open(path, "rb").read().rstrip(b"\n")
    except FileNotFoundError:
        continue
    salt = os.urandom(16)
    h = hashlib.pbkdf2_hmac("sha256", pw, salt, 200000)
    out.append(f"pbkdf2_sha256$200000${salt.hex()}${h.hex()}")
dst = sys.argv[1]
fd = os.open(dst + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write("\n".join(out) + "\n")
os.replace(dst + ".tmp", dst)
print(f"deny list: {len(out)} entri")
' "$CONF/deny.pbkdf2" < <(for a in "${ADDRS[@]}"; do printf '%s\0' "$STACK_DIR/secrets/$a.password"; done)
chmod 600 "$CONF/deny.pbkdf2"
