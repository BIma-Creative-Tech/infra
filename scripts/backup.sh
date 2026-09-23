#!/usr/bin/env bash
# Backup restic — T13 (ADR 0006). Harus root. Dipanggil systemd (restic-backup / restic-prune).
#
#   backup.sh run     (default) 1) pg_dumpall --globals-only  2) pg_dump -Fc per DB (daftar dinamis
#                     dari pg_database, kecuali template & *_restoretest)  3) file: /opt/infra (config,
#                     .env, secrets/, traefik/acme/, crowdsec data, git) + filestore Odoo per pool
#                     4) restic copy ke remote bila dikonfigurasi, selain itu "REMOTE NOT CONFIGURED".
#   backup.sh prune   forget --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --prune, lalu check.
#   backup.sh check   restic check (metadata saja).
#
# Dump DB tidak pernah menyentuh disk: `restic backup --stdin-from-command -- docker exec postgres
# pg_dump …` (restic 0.19.1 doc/040_backup.rst: exit code ≠ 0 dari perintah → backup dibatalkan,
# tidak ada snapshot). Tidak ada password di argv: pg_dump memakai peer auth di socket lokal
# container (user postgres), password repo lewat RESTIC_PASSWORD_FILE.
# Output baris terakhir: RESULT key=value … (exit ≠ 0 bila ada langkah gagal).
set -euo pipefail
LOG_TAG=infra-backup
# shellcheck source=lib/restic-common.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/restic-common.sh"

# Path yang TIDAK di-backup dari /opt/infra: repo restic itu sendiri, log akses (rotasi), collection
# Ansible (diunduh ulang dari requirements.yml).
FILE_EXCLUDES=(
  "$INFRA_DIR/backups"
  "$INFRA_DIR/traefik/logs"
  "$INFRA_DIR/ansible/collections"
)

cmd_run() {
  local failed=0 ok_dbs=0 db dbs mp paths=() snap_out
  restic cat config >/dev/null || die "repo $RESTIC_REPOSITORY tidak bisa dibuka"

  # 1) globals (role, password hash role, membership) — dibutuhkan saat rebuild cluster.
  if restic backup --quiet --host "$RESTIC_HOST_TAG" --tag pg --tag pg-globals \
       --stdin-filename "pg/globals.sql" \
       --stdin-from-command -- docker exec "$PG_CONTAINER" pg_dumpall -U postgres --globals-only; then
    log "pg globals: ok"
  else
    warn "pg globals: GAGAL"; failed=1
  fi

  # 2) DB per DB (dinamis). -Z 0: tanpa kompresi pg_dump → dedup restic antar hari efektif
  #    (restic mengompresi sendiri, repo v2).
  dbs="$(pg_psql -d postgres -c "SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn ORDER BY 1")" \
    || die "tidak bisa membaca daftar DB dari container $PG_CONTAINER"
  for db in $dbs; do
    if ! valid_db "$db"; then warn "DB '$db' nama di luar $DB_RE — dilewati (periksa manual)"; failed=1; continue; fi
    if [[ "$db" == *_restoretest ]]; then log "DB $db: dilewati (DB uji restore)"; continue; fi
    if restic backup --quiet --host "$RESTIC_HOST_TAG" --tag pg --tag "db:$db" \
         --stdin-filename "pg/$db.dump" \
         --stdin-from-command -- docker exec "$PG_CONTAINER" pg_dump -U postgres -Fc -Z 0 -d "$db"; then
      log "pg $db: ok"; ok_dbs=$((ok_dbs + 1))
    else
      warn "pg $db: GAGAL"; failed=1
    fi
  done

  # 3) File — SETELAH dump DB (konsistensi DB ↔ filestore, ADR 0006). Volume dibaca langsung dari
  #    host (restic hanya membaca; container tidak disentuh).
  paths=("$INFRA_DIR")
  for v in "${FILESTORE_VOLUMES[@]}"; do
    mp="$(volume_mountpoint "$v")"
    if [[ -n "$mp" && -d "$mp/filestore" ]]; then paths+=("$mp/filestore")
    else warn "volume $v / filestore tidak ditemukan — dilewati"; fi
  done
  local excl=()
  for e in "${FILE_EXCLUDES[@]}"; do excl+=(--exclude "$e"); done
  if snap_out="$(restic backup --quiet --json --host "$RESTIC_HOST_TAG" --tag files "${excl[@]}" "${paths[@]}" | tail -1)"; then
    log "files: ok ($(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print("snapshot", d.get("snapshot_id","?")[:8], "files", d.get("total_files_processed"), "bytes", d.get("total_bytes_processed"))' "$snap_out" 2>/dev/null || echo '?'))"
  else
    warn "files: GAGAL"; failed=1
  fi

  # 4) Offsite (L4) — hanya bila remote.env terisi.
  local remote=not-configured
  if remote_configured; then
    if copy_to_remote; then remote=ok; else warn "restic copy ke remote GAGAL"; remote=failed; failed=1; fi
  else
    warn "REMOTE NOT CONFIGURED — backup HANYA di disk lokal yang sama ($RESTIC_REPOSITORY): tidak melindungi dari kehilangan disk/host. Isi $RESTIC_REMOTE_ENV (docs/03-operations/backup.md)."
  fi

  local status=ok; [[ $failed -eq 0 ]] || status=failed
  log "RESULT status=$status dbs_ok=$ok_dbs remote=$remote repo=$RESTIC_REPOSITORY"
  return $failed
}

# remote_configured — true bila RESTIC_REPOSITORY_REMOTE terisi dan bukan placeholder <...>.
remote_configured() {
  [[ -r "$RESTIC_REMOTE_ENV" ]] || return 1
  local v
  v="$(sed -n 's/^RESTIC_REPOSITORY_REMOTE=//p' "$RESTIC_REMOTE_ENV" | tail -1)"
  [[ -n "$v" && "$v" != *"<"* ]]
}

# copy_to_remote — BELUM PERNAH DIUJI (remote belum ada). Aktivasi: backup.md §Remote S3.
# restic 0.19.1 doc/045_working_with_repos.rst: repo tujuan = RESTIC_REPOSITORY, repo sumber =
# RESTIC_FROM_REPOSITORY + RESTIC_FROM_PASSWORD_FILE.
copy_to_remote() (
  set -a
  # shellcheck disable=SC1090
  . "$RESTIC_REMOTE_ENV"
  set +a
  export RESTIC_FROM_REPOSITORY="$RESTIC_REPOSITORY" RESTIC_FROM_PASSWORD_FILE="$RESTIC_PASSWORD_FILE"
  export RESTIC_REPOSITORY="$RESTIC_REPOSITORY_REMOTE" RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE_REMOTE"
  restic copy --quiet
)

cmd_prune() {
  restic forget --host "$RESTIC_HOST_TAG" --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --prune
  restic check
  log "RESULT status=ok action=prune+check"
}

cmd_check() {
  restic check
  log "RESULT status=ok action=check"
}

main() {
  require_root
  load_local_env
  acquire_lock
  case "${1:-run}" in
    run)   cmd_run ;;
    prune) cmd_prune ;;
    check) cmd_check ;;
    *) die "penggunaan: $0 [run|prune|check]" ;;
  esac
}

main "$@"
