#!/bin/bash
# Snapshot SQLite 9router yang konsisten sebelum restic (ExecStartPre restic-backup.service, drop-in
# /etc/systemd/system/restic-backup.service.d/9router-sqlite.conf). Restic mem-backup data/snapshot/data.sqlite;
# file live data/db/data.sqlite{,-wal,-shm} di-exclude (restic_extra_excludes).
#
# Container jalan  → online backup API SQLite (better-sqlite3 db.backup(), aman saat app menulis, mode WAL) sebagai
#                    user node, tulis ke .tmp lalu integrity_check, lalu rename atomik.
# Container mati   → file sudah konsisten (tidak ada penulis): salin db + -wal lalu checkpoint tidak diperlukan.
# Restore: hentikan 9router → salin snapshot/data.sqlite ke db/data.sqlite, hapus db/data.sqlite-wal/-shm → start.
set -euo pipefail
DATA=/opt/9router/data
OUT_DIR="$DATA/snapshot"

log() { logger -t 9router-snapshot -- "$*"; echo "$*"; }

if [[ "$(docker inspect -f '{{.State.Running}}' 9router 2>/dev/null)" == "true" ]]; then
  docker exec -u node -w /app 9router node -e '
    const Database = require("better-sqlite3");
    const fs = require("fs");
    const dir = "/app/data/snapshot", tmp = dir + "/data.sqlite.tmp", out = dir + "/data.sqlite";
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    for (const f of [tmp, tmp + "-wal", tmp + "-shm"]) fs.rmSync(f, { force: true });
    const src = new Database("/app/data/db/data.sqlite", { readonly: true, fileMustExist: true });
    src.backup(tmp).then(() => {
      src.close();
      // Snapshot = satu file mandiri (tanpa -wal/-shm): ubah journal ke DELETE sebelum dicek.
      const chk = new Database(tmp);
      chk.pragma("journal_mode = DELETE");
      const r = chk.pragma("integrity_check", { simple: true });
      chk.close();
      if (r !== "ok") { console.error("integrity_check: " + r); process.exit(1); }
      fs.renameSync(tmp, out);
      console.log("ok " + fs.statSync(out).size + " bytes");
    }).catch(e => { console.error(e.message); process.exit(1); });
  ' | while read -r l; do log "online backup: $l"; done
  [[ "${PIPESTATUS[0]}" -eq 0 ]] || { log "GAGAL online backup"; exit 1; }
else
  install -d -m 700 -o "$(stat -c %u "$DATA")" -g "$(stat -c %g "$DATA")" "$OUT_DIR"
  rm -f "$OUT_DIR"/data.sqlite-wal
  cp -p "$DATA/db/data.sqlite" "$OUT_DIR/data.sqlite.tmp"
  [[ -s "$DATA/db/data.sqlite-wal" ]] && cp -p "$DATA/db/data.sqlite-wal" "$OUT_DIR/data.sqlite-wal"
  mv "$OUT_DIR/data.sqlite.tmp" "$OUT_DIR/data.sqlite"
  log "container mati — salinan file langsung ($(stat -c %s "$OUT_DIR/data.sqlite") bytes)"
fi
