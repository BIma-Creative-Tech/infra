#!/usr/bin/env bash
# Restore test — T13 (ADR 0006 §Jadwal: bulanan, laporan ke journal). Harus root.
#
#   restore-test.sh [<db>]
#     1) DB: restore snapshot terbaru <db> (default: acak dari *_prod, bila tidak ada *_demo) ke DB
#        BARU <db>_restoretest (owner postgres, CONNECT PUBLIC dicabut) via scripts/restore.sh,
#        bandingkan jumlah tabel + count baris tabel kunci (res_users, res_partner, ir_module_module
#        bila ada) ISI DUMP di snapshot yang sama (TOC `pg_restore -l` + baris COPY per tabel kunci) vs
#        hasil restore, lalu DROP <db>_restoretest (hanya nama berakhiran _restoretest). DB live hanya
#        dicatat sebagai info: ia berubah setelah backup (2026-10-02: 5 modul baru → db_compare palsu).
#     2) Filestore: pulihkan satu file acak (lebih tua dari snapshot `files` terbaru) ke direktori
#        sementara, bandingkan sha256 dengan file live, hapus direktori sementara.
#     3) restic check --read-data-subset=<n>/5 (n = bulan mod 5 + 1 → seluruh data terbaca tiap 5 bulan).
#   Catatan: smoke `odoo --stop-after-init` dari ADR 0006 TIDAK dijalankan — pg_hba/dbfilter pool
#   hanya mengizinkan DB *_prod/*_demo/*_staging, DB *_restoretest tidak bisa dibuka role pool.
# Output baris terakhir: RESULT key=value … (exit ≠ 0 bila ada perbedaan/gagal).
set -euo pipefail
LOG_TAG=infra-restore-test
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=lib/restic-common.sh
. "$SCRIPT_DIR/lib/restic-common.sh"

KEY_TABLES=(res_users res_partner ir_module_module)

pick_db() {
  local list
  list="$(pg_psql -d postgres -c "SELECT datname FROM pg_database WHERE datname ~ '^[a-z0-9_]+_prod\$' ORDER BY 1")"
  [[ -n "$list" ]] || list="$(pg_psql -d postgres -c "SELECT datname FROM pg_database WHERE datname ~ '^[a-z0-9_]+_demo\$' ORDER BY 1")"
  [[ -n "$list" ]] || return 1
  shuf -n1 <<<"$list"
}

# db_stats <db> → baris "tables=<n>" lalu "<tabel>=<count>" per tabel kunci yang ada
db_stats() {
  local db="$1" t
  echo "tables=$(pg_psql -d "$db" -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'")"
  for t in "${KEY_TABLES[@]}"; do
    if [[ "$(pg_psql -d "$db" -c "SELECT to_regclass('public.$t') IS NOT NULL")" == t ]]; then
      echo "$t=$(pg_psql -d "$db" -c "SELECT count(*) FROM public.$t")"
    fi
  done
}

# dump_stats <db> <snapshot> → format sama dengan db_stats, dihitung dari ISI dump di snapshot (bukan DB live):
# jumlah entri TOC "TABLE public", lalu jumlah baris blok COPY per tabel kunci (format teks COPY: 1 baris = 1 row).
dump_stats() {
  local db="$1" snap="$2" toc t
  # pg_restore berhenti membaca begitu bagian yang dibutuhkan selesai → sisa stream dikuras (`cat >/dev/null`) agar
  # restic tidak mati kena SIGPIPE dan meninggalkan lock basi (yang menggagalkan `restic check` sesudahnya).
  toc="$(restic dump "$snap" "$PG_SNAPSHOT_DIR/$db.dump" \
    | { docker exec -i "$PG_CONTAINER" pg_restore -l; rc=$?; cat >/dev/null; exit $rc; })" || return 1
  echo "tables=$(grep -cE '^[0-9]+; [0-9]+ [0-9]+ TABLE public ' <<<"$toc")"
  for t in "${KEY_TABLES[@]}"; do
    if grep -qE "^[0-9]+; [0-9]+ [0-9]+ TABLE DATA public $t " <<<"$toc"; then
      echo "$t=$(restic dump "$snap" "$PG_SNAPSHOT_DIR/$db.dump" \
        | { docker exec -i "$PG_CONTAINER" pg_restore -f - --data-only -n public -t "$t"; cat >/dev/null; } \
        | awk '/^COPY /{c=1; next} c && /^\\\.$/{c=0; next} c{n++} END{print n+0}')"
    fi
  done
}

test_db() {
  local db="$1" target="${1}_restoretest" snap src dst live rc=0
  valid_db "$db" || die "nama DB tidak valid: $db"
  db_exists "$db" || die "DB $db tidak ada"
  db_exists "$target" && die "$target sudah ada (sisa uji sebelumnya?) — periksa lalu DROP manual"
  snap="$(latest_db_snapshot "$db")"
  [[ -n "$snap" ]] || { warn "tidak ada snapshot untuk $db"; return 1; }
  "$SCRIPT_DIR/restore.sh" "$db" "$target" --snapshot "$snap" || { warn "restore $db gagal"; return 1; }
  src="$(dump_stats "$db" "$snap")" || { warn "membaca isi dump $db (snapshot ${snap:0:8}) gagal"; src=""; }
  dst="$(db_stats "$target")"; live="$(db_stats "$db")"
  log "dump     $db@${snap:0:8}: $(tr '\n' ' ' <<<"$src")"
  log "restore  $target: $(tr '\n' ' ' <<<"$dst")"
  log "live     $db (info, bukan pembanding): $(tr '\n' ' ' <<<"$live")"
  if [[ -n "$src" && "$src" == "$dst" ]]; then log "DB $db: SAMA dump vs restore (jumlah tabel & count tabel kunci)"
  else warn "DB $db: BERBEDA dump vs restore"; rc=1; fi
  [[ "$target" == *_restoretest ]] || die "guard: menolak DROP $target"
  pg_psql -d postgres -c "DROP DATABASE \"$target\" WITH (FORCE)" >/dev/null
  if db_exists "$target"; then warn "DROP $target gagal"; rc=1; else log "DB $target dihapus"; fi
  return $rc
}

test_filestore_file() {
  local snap_json snap_time snap_id vol mp db file rel tmp h_live h_rest
  snap_json="$(restic snapshots --json --latest 1 --tag files)"
  snap_id="$(python3 -c 'import json,sys; s=json.load(sys.stdin); print(s[-1]["short_id"] if s else "")' <<<"$snap_json")"
  snap_time="$(python3 -c 'import json,sys; s=json.load(sys.stdin); print(s[-1]["time"] if s else "")' <<<"$snap_json")"
  [[ -n "$snap_id" ]] || { warn "tidak ada snapshot files"; return 1; }
  for vol in $(shuf -e "${FILESTORE_VOLUMES[@]}"); do
    mp="$(volume_mountpoint "$vol")"; [[ -n "$mp" && -d "$mp/filestore" ]] || continue
    file="$(find "$mp/filestore" -type f ! -newermt "$snap_time" 2>/dev/null | shuf -n1 || true)"
    [[ -n "$file" ]] && break
  done
  [[ -n "${file:-}" ]] || { warn "tidak ada file filestore yang lebih tua dari snapshot $snap_id"; return 1; }
  rel="${file#"$mp/filestore/"}"; db="${rel%%/*}"; rel="${rel#*/}"
  tmp="$INFRA_DIR/backups/.restoretest-$$"
  "$SCRIPT_DIR/restore.sh" --filestore "$vol" "$db" "$tmp" --snapshot "$snap_id" --path "$rel" \
    || { rm -rf -- "$tmp"; warn "restore file filestore gagal"; return 1; }
  h_live="$(sha256sum < "$file" | cut -d' ' -f1)"
  h_rest="$(sha256sum < "$tmp$file" | cut -d' ' -f1)"
  rm -rf -- "$tmp"
  if [[ "$h_live" == "$h_rest" ]]; then log "filestore $vol/$db/$rel: sha256 SAMA ($h_live)"; return 0; fi
  warn "filestore $vol/$db/$rel: sha256 BERBEDA (live $h_live, restore $h_rest)"; return 1
}

main() {
  require_root
  load_local_env
  acquire_lock
  local db="${1:-}" t0=$SECONDS db_rc=0 fs_rc=0 chk_rc=0 subset
  if [[ -z "$db" ]]; then db="$(pick_db)" || die "tidak ada DB *_prod/*_demo untuk diuji"; fi
  test_db "$db" || db_rc=1
  test_filestore_file || fs_rc=1
  subset="$(( 10#$(date +%m) % 5 + 1 ))/5"
  restic check --read-data-subset="$subset" || chk_rc=1
  local status=ok; (( db_rc + fs_rc + chk_rc == 0 )) || status=failed
  log "RESULT status=$status db=$db db_compare=$([[ $db_rc -eq 0 ]] && echo ok || echo failed) filestore=$([[ $fs_rc -eq 0 ]] && echo ok || echo failed) check_subset=$subset:$([[ $chk_rc -eq 0 ]] && echo ok || echo failed) rto_seconds=$((SECONDS - t0))"
  [[ $status == ok ]]
}

main "$@"
