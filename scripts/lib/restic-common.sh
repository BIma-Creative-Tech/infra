# shellcheck shell=bash
# Fungsi bersama backup restic (T13, ADR 0006) — di-source oleh scripts/backup.sh,
# scripts/restore.sh, scripts/restore-test.sh. Tidak ada secret di file ini:
#   /etc/restic/local.env   (600 root; RESTIC_REPOSITORY, RESTIC_PASSWORD_FILE, RESTIC_CACHE_DIR)
#   /etc/restic/password    (600 root; password repo — JANGAN PERNAH hilang, lihat backup.md)
#   /etc/restic/remote.env  (600 root; placeholder S3 — scripts/restic-remote.env.example)

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
INFRA_DIR="${INFRA_DIR:-/opt/infra}"
PG_CONTAINER="${PG_CONTAINER:-postgres}"
RESTIC_LOCAL_ENV="${RESTIC_LOCAL_ENV:-/etc/restic/local.env}"
RESTIC_REMOTE_ENV="${RESTIC_REMOTE_ENV:-/etc/restic/remote.env}"
# Nama host tetap di snapshot (retensi `forget` dikelompokkan per host+paths).
RESTIC_HOST_TAG="${RESTIC_HOST_TAG:-$(hostname -s)}"
# Volume filestore Odoo per pool (isi `filestore/` saja; sessions/ tidak di-backup).
# Pool/dedicated baru: tambahkan nama volumenya di sini.
# shellcheck disable=SC2034  # dipakai backup.sh / restore-test.sh
FILESTORE_VOLUMES=(odoo_pool_a_data odoo_staging_data)
# Volume media aplikasi non-Odoo: di-backup SELURUH root volume (tanpa subdir `filestore/`).
# ProyekKas client DRMS (ADR ProyekKas 0004 §6): upload Payload di /data/media (prod + staging).
# Dibaca backup.sh (snapshot `files`, setelah dump DB); volume yang belum ada dilewati (log info).
# restore-test.sh belum menguji file media (hanya filestore Odoo).
# erajaya-loyalty staging (Payload media, MEDIA_DIR=/data/media): erajaya_loyalty_media_stg.
# shellcheck disable=SC2034  # dipakai backup.sh
MEDIA_VOLUMES=(drms_pk_media_prod drms_pk_media_stg erajaya_loyalty_media_stg)
# Nama DB Postgres yang valid untuk skrip ini (sama dengan konvensi header X-Sh-Odoo-Db).
DB_RE='^[a-z0-9_]{1,63}$'
# Path di dalam snapshot untuk dump DB: `--stdin-filename pg/<db>.dump` → /pg/<db>.dump
PG_SNAPSHOT_DIR=/pg

LOG_TAG="${LOG_TAG:-infra-backup}"

# log/warn/die → journal via logger (tag LOG_TAG, prioritas info/warning/err — bisa difilter
# `journalctl -t infra-backup -p warning`) + terminal bila dijalankan manual. Di bawah systemd
# (INVOCATION_ID ada) stdout sudah masuk journal unit → hanya logger agar tidak dobel.
_emit() {
  local prio="$1"; shift
  logger -t "$LOG_TAG" -p "user.$prio" -- "$*" 2>/dev/null || true
  [[ -n "${INVOCATION_ID:-}" ]] || { if [[ $prio == info ]]; then echo "$*"; else echo "$*" >&2; fi; }
}
log()  { _emit info "$*"; }
warn() { _emit warning "WARNING: $*"; }
die()  { _emit err "ERROR: $*"; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die "harus root"; }

# load_local_env — export variabel repo lokal; gagal bila file/password/binary tidak ada.
load_local_env() {
  [[ -r "$RESTIC_LOCAL_ENV" ]] || die "$RESTIC_LOCAL_ENV tidak ada (jalankan role Ansible backup)"
  set -a
  # shellcheck disable=SC1090
  . "$RESTIC_LOCAL_ENV"
  set +a
  [[ -n "${RESTIC_REPOSITORY:-}" && -s "${RESTIC_PASSWORD_FILE:-}" ]] \
    || die "RESTIC_REPOSITORY/RESTIC_PASSWORD_FILE tidak valid di $RESTIC_LOCAL_ENV"
  command -v restic >/dev/null || die "binary restic tidak ada"
}

# acquire_lock — satu job restic/infra-backup pada satu waktu (backup, prune, restore-test).
# Proses anak (restore-test.sh → restore.sh) mewarisi fd 9 yang sudah terkunci → tidak mengunci ulang.
acquire_lock() {
  [[ "${INFRA_BACKUP_LOCK_HELD:-}" == 1 ]] && return 0
  exec 9>/run/infra-backup.lock
  flock -w 3600 9 || die "lock /run/infra-backup.lock tidak didapat dalam 1 jam"
  export INFRA_BACKUP_LOCK_HELD=1
}

pg_psql() { docker exec -i "$PG_CONTAINER" psql -U postgres -AtX -v ON_ERROR_STOP=1 "$@"; }

db_exists() { [[ "$(pg_psql -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '$1'")" == 1 ]]; }

valid_db() { [[ "$1" =~ $DB_RE ]]; }

# latest_db_snapshot <db> → ID snapshot terbaru yang memuat /pg/<db>.dump (kosong bila tidak ada)
latest_db_snapshot() {
  restic snapshots --json --latest 1 --path "$PG_SNAPSHOT_DIR/$1.dump" \
    | python3 -c 'import json,sys; s=json.load(sys.stdin); print(s[-1]["id"] if s else "")'
}

# volume_mountpoint <volume> → path host (kosong bila volume tidak ada)
volume_mountpoint() { docker volume inspect -f '{{.Mountpoint}}' "$1" 2>/dev/null || true; }
