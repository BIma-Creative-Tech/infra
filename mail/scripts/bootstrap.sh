#!/usr/bin/env bash
# Bootstrap idempoten stack mail (T11). Jalankan sebagai root SEBELUM `docker compose up -d` dan setiap kali
# file di mail/config/ berubah (sumber kebenaran = git; data/config = volume config DMS).
#  1. data/{mail,state,config} (700 root; DMS meng-chown isinya sendiri) — di /opt/infra → ikut backup restic.
#  2. /var/log/mailserver (root:adm 750) + subdir dms/ (di-mount ke /var/log/mail; DMS set 755 + file root 644)
#     — parent 750 menutup akses user host lain; CrowdSec (uid 0 di container) membaca sebagai owner.
#  3. secrets/ (700 root) — password mailbox (dibuat scripts/mailbox-add.sh).
#  4. Sinkron config git → data/config: postfix-main.cf, rspamd/override.d/*.conf.
#     postfix-main.cf hanya dibaca saat START container (butuh recreate); rspamd/** dipantau change detection DMS.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR=/var/log/mailserver

[[ $EUID -eq 0 ]] || { echo "harus root" >&2; exit 1; }

install -d -o root -g root -m 0700 "$STACK_DIR/data"
for d in mail state config; do
  [[ -d "$STACK_DIR/data/$d" ]] || install -d -o root -g root -m 0755 "$STACK_DIR/data/$d"
done
echo "data/: ok"

install -d -o root -g adm -m 0750 "$LOG_DIR"
# Subdir yang di-mount ke container: DMS mengubah owner/mode-nya sendiri saat start → hanya dibuat bila belum ada.
[[ -d "$LOG_DIR/dms" ]] || install -d -o root -g root -m 0755 "$LOG_DIR/dms"
echo "$LOG_DIR: ok"

install -d -o root -g root -m 0700 "$STACK_DIR/secrets"
echo "secrets/: ok"

changed=0
sync_file() { # sync_file <src> <dst> — salin hanya bila isi berbeda
  local src="$1" dst="$2"
  if ! cmp -s "$src" "$dst" 2>/dev/null; then
    install -D -o root -g root -m 0644 "$src" "$dst"
    echo "config: $dst diperbarui"
    changed=1
  fi
}
sync_file "$STACK_DIR/config/postfix-main.cf" "$STACK_DIR/data/config/postfix-main.cf"
for f in "$STACK_DIR"/config/rspamd/override.d/*.conf; do
  sync_file "$f" "$STACK_DIR/data/config/rspamd/override.d/$(basename "$f")"
done
[[ $changed -eq 1 ]] || echo "config: tidak ada perubahan"
if [[ $changed -eq 1 ]]; then
  echo "CATATAN: perubahan postfix-main.cf butuh 'docker compose up -d --force-recreate mailserver';" \
       "perubahan rspamd/override.d diterapkan otomatis oleh change detection DMS (±2 s + reload Rspamd)."
fi
