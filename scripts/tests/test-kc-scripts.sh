#!/usr/bin/env bash
# Jalankan uji skrip job SaaS Fase 1 (scripts/tests/test_kc_scripts.py) di container SEKALI PAKAI:
#   - tanpa jaringan (--network none) → mustahil memanggil Keycloak/Traefik sungguhan;
#   - tanpa socket Docker → `docker` di dalam uji hanya shim (test_kc_scripts.py menolak berjalan bila socket ada);
#   - repo di-mount read-only; semua tulisan di /tmp container (dibuang bersama container).
# Image: odoo:19.0-20260908 (sudah ada di host; berisi bash 5.2, python3 + PyYAML, curl, flock) dijalankan sebagai root
# (skrip memeriksa EUID). Tidak butuh root di host selain akses docker.
#
#   scripts/tests/test-kc-scripts.sh            # semua kelas uji
#   scripts/tests/test-kc-scripts.sh T03User    # satu kelas (argumen diteruskan ke unittest)
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="${TEST_IMAGE:-odoo:19.0-20260908}"
name="p1test-a2-kc-$$"
filter=()
for t in "$@"; do filter+=("test_kc_scripts.${t}"); done
[[ ${#filter[@]} -gt 0 ]] || filter=(test_kc_scripts)
exec docker run --rm --name "$name" --network none --user 0 --read-only --tmpfs /tmp:rw,exec --tmpfs /run:rw \
  --memory 512m --cpus 1 -v "$REPO:/src:ro" -w /src/scripts/tests -e PYTHONDONTWRITEBYTECODE=1 \
  --entrypoint python3 "$IMAGE" -m unittest -v "${filter[@]}"
