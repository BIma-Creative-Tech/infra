#!/usr/bin/env bash
# Jalankan SEKALI setelah start pertama (idempoten). Entrypoint image membuat symlink
# /var/lib/crowdsec/data/<file> → /staging/... (layer image). Dengan read_only: true,
# `cscli hub upgrade` gagal menulis lewat symlink itu ("chtimes ...: read-only file system").
# Skrip ini mengganti symlink dengan salinan nyata di volume data/db sehingga hub upgrade bisa
# memperbarui datafile. Entrypoint tidak membuat ulang symlink bila file sudah ada.
set -euo pipefail
docker exec crowdsec sh -c '
  for f in /var/lib/crowdsec/data/*; do
    if [ -L "$f" ]; then
      t="$(readlink -f "$f")"; rm "$f"; cp -Rp "$t" "$f"; echo "materialized: $f"
    fi
  done'
docker exec crowdsec cscli hub upgrade
