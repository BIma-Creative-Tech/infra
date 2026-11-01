#!/usr/bin/env bash
# Pasang paket dbt (requirements.txt ber-hash) ke datamart/pylib memakai image Python resmi yang SAMA dengan runner.
# Tanpa build image (ADR 0004 §9, ADR 0016 #2). pylib di luar git; di-mount ro ke container dbt.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
image=$(sed -n 's/^DBT_PYTHON_IMAGE=//p' "$here/datamart.env.example")
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; chmod 755 "$tmp"
docker run --rm -v "$here/requirements.txt:/req.txt:ro" -v "$tmp:/out" "$image" sh -c \
  'pip install --quiet --root-user-action=ignore --no-deps --no-compile --require-hashes --target /out/pylib -r /req.txt && chmod -R a+rX /out/pylib'
rm -rf "$here/pylib" && mv "$tmp/pylib" "$here/pylib"
echo "RESULT pylib=$here/pylib packages=$(find "$here/pylib" -maxdepth 1 -name '*.dist-info' | wc -l)"
