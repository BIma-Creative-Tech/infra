#!/usr/bin/env bash
# Restore dari repo restic — T13 (ADR 0006). Harus root.
#
# DB (dump pg_dump -Fc di snapshot /pg/<db>.dump):
#   restore.sh <db> <target_db> [--snapshot ID] [--owner ROLE] [--overwrite [--confirm <target_db>]]
#     - target BELUM ada  → CREATE DATABASE <target> (template0, owner ROLE|postgres), REVOKE PUBLIC,
#                            pg_restore --no-owner --no-acl [--role=ROLE] --exit-on-error.
#     - target SUDAH ada  → DITOLAK, kecuali --overwrite DAN konfirmasi (ketik nama target di TTY, atau
#                            --confirm <target_db> yang sama persis). Restore dilakukan dulu ke DB
#                            sementara <target>__rst; hanya bila sukses DB lama di-DROP (FORCE) lalu
#                            DB sementara di-RENAME → kegagalan restore tidak pernah merusak target.
#   Setelah restore DB tenant Odoo sungguhan: REVOKE sudah; render router / filestore → backup.md.
#
# Filestore (snapshot tag `files`):
#   restore.sh --filestore <volume> <db> <target_dir> [--snapshot ID] [--path <relpath di dalam filestore/<db>>]
#     Memulihkan ke direktori BARU <target_dir> (harus belum ada / kosong; tidak boleh di bawah
#     /var/lib/docker). Tidak pernah menulis langsung ke volume container.
#
# Output baris terakhir: RESULT key=value … (exit ≠ 0 bila gagal).
set -euo pipefail
LOG_TAG=infra-restore
# shellcheck source=lib/restic-common.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/restic-common.sh"

usage() { sed -n '4,17p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

restore_db() {
  local db="$1" target="$2" snap="" owner=postgres overwrite=0 confirm=""
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --snapshot)  snap="${2:?}"; shift 2 ;;
      --owner)     owner="${2:?}"; shift 2 ;;
      --overwrite) overwrite=1; shift ;;
      --confirm)   confirm="${2:?}"; shift 2 ;;
      *) usage ;;
    esac
  done
  valid_db "$db" || die "nama DB sumber tidak valid: $db"
  valid_db "$target" || die "nama DB target tidak valid: $target"
  valid_db "$owner" || die "nama role owner tidak valid: $owner"
  [[ ${#target} -le 58 ]] || die "nama target terlalu panjang (≤ 58, butuh ruang untuk suffix __rst)"
  [[ "$target" != postgres && "$target" != template* ]] || die "target $target dilarang"
  [[ "$(pg_psql -d postgres -c "SELECT 1 FROM pg_roles WHERE rolname = '$owner'")" == 1 ]] \
    || die "role $owner tidak ada"

  if [[ -z "$snap" ]]; then snap="$(latest_db_snapshot "$db")"; fi
  [[ -n "$snap" ]] || die "tidak ada snapshot untuk $PG_SNAPSHOT_DIR/$db.dump"
  [[ "$snap" =~ ^[0-9a-f]{8,64}$ ]] || die "ID snapshot tidak valid: $snap"

  local work="$target"
  if db_exists "$target"; then
    [[ $overwrite -eq 1 ]] || die "DB $target SUDAH ADA — tidak ditimpa. Pakai target baru, atau --overwrite + konfirmasi (DESTRUKTIF)."
    if [[ -z "$confirm" ]]; then
      [[ -t 0 ]] || die "--overwrite tanpa TTY membutuhkan --confirm $target"
      read -r -p "DESTRUKTIF: DB '$target' akan DIGANTI isi snapshot $snap. Ketik nama DB untuk lanjut: " confirm
    fi
    [[ "$confirm" == "$target" ]] || die "konfirmasi tidak cocok — dibatalkan"
    work="${target}__rst"
    db_exists "$work" && die "DB sementara $work sudah ada (sisa restore gagal?) — periksa & hapus manual"
    log "overwrite dikonfirmasi: restore ke $work dulu, lalu ganti $target"
  fi

  local t0=$SECONDS
  log "restore $db (snapshot $snap) → $work (owner $owner)"
  pg_psql -d postgres -c "CREATE DATABASE \"$work\" OWNER \"$owner\" TEMPLATE template0" >/dev/null
  pg_psql -d postgres -c "REVOKE ALL ON DATABASE \"$work\" FROM PUBLIC" >/dev/null
  local role_opt=()
  [[ "$owner" == postgres ]] || role_opt=(--role="$owner")
  if ! restic dump "$snap" "$PG_SNAPSHOT_DIR/$db.dump" \
       | docker exec -i "$PG_CONTAINER" pg_restore -U postgres -d "$work" --no-owner --no-acl "${role_opt[@]}" --exit-on-error; then
    warn "pg_restore GAGAL — DB $work dibiarkan untuk diagnosa (hapus manual: DROP DATABASE \"$work\")"
    log "RESULT status=failed db=$db target=$work snapshot=$snap"
    return 1
  fi

  if [[ "$work" != "$target" ]]; then
    pg_psql -d postgres -c "DROP DATABASE \"$target\" WITH (FORCE)" >/dev/null
    pg_psql -d postgres -c "ALTER DATABASE \"$work\" RENAME TO \"$target\"" >/dev/null
    log "DB lama $target di-drop, $work di-rename → $target"
  fi
  log "RESULT status=ok db=$db target=$target snapshot=$snap seconds=$((SECONDS - t0))"
}

restore_filestore() {
  local vol="${1:?}" db="${2:?}" target_dir="${3:?}" snap="" rel=""
  shift 3
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --snapshot) snap="${2:?}"; shift 2 ;;
      --path)     rel="${2:?}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ "$vol" =~ ^[a-z0-9_]+$ ]] || die "nama volume tidak valid: $vol"
  valid_db "$db" || die "nama DB tidak valid: $db"
  [[ -z "$rel" || ( "$rel" =~ ^[A-Za-z0-9._/-]+$ && "$rel" != *..* ) ]] || die "--path tidak valid: $rel"
  target_dir="$(readlink -m "$target_dir")"
  [[ "$target_dir" != /var/lib/docker* ]] || die "target di bawah /var/lib/docker dilarang (tidak menulis ke volume)"
  if [[ -e "$target_dir" && -n "$(ls -A "$target_dir" 2>/dev/null)" ]]; then die "$target_dir sudah ada & tidak kosong"; fi

  local mp include
  mp="$(volume_mountpoint "$vol")"
  [[ -n "$mp" ]] || mp="/var/lib/docker/volumes/$vol/_data"   # volume sudah hilang: path standar
  include="$mp/filestore/$db${rel:+/$rel}"
  [[ -n "$snap" ]] || snap=latest
  install -d -m 700 "$target_dir"
  restic restore "$snap" --tag files --target "$target_dir" --include "$include"
  [[ -e "$target_dir$include" ]] || die "tidak ada yang dipulihkan untuk $include (snapshot $snap)"
  log "RESULT status=ok volume=$vol db=$db restored=$target_dir$include snapshot=$snap"
}

main() {
  require_root
  load_local_env
  [[ $# -ge 1 ]] || usage
  if [[ "$1" == --filestore ]]; then
    shift; [[ $# -ge 3 ]] || usage
    restore_filestore "$@"
  else
    [[ $# -ge 2 && "$1" != -* && "$2" != -* ]] || usage
    acquire_lock
    restore_db "$@"
  fi
}

main "$@"
