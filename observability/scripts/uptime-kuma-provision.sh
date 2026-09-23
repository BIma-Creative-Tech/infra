#!/usr/bin/env bash
# Provisioning awal Uptime Kuma (T14a) — idempoten: admin `platform-admin` (sekali, password acak di
# secrets/uptime-kuma-admin-password 600 root), 4 monitor HTTP publik, status page `platform` yang
# dipetakan ke status.bimacreative.tech. Jalankan sebagai root setelah `docker compose up -d`.
# Koneksi langsung ke http://uptime-kuma:3001 lewat network `proxy` (tidak lewat Traefik/Internet).
set -euo pipefail
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $EUID -eq 0 ]] || { echo "harus root" >&2; exit 1; }

PW="$STACK_DIR/secrets/uptime-kuma-admin-password"
if [[ ! -s "$PW" ]]; then
  ( umask 077; openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 40 > "$PW" )
  echo "secrets/uptime-kuma-admin-password: dibuat"
fi
chmod 0600 "$PW"

IMAGE="$(docker inspect -f '{{.Config.Image}}' uptime-kuma)"
# Container sementara: uid Kuma, read-only, tanpa capability; file password dibaca root lalu
# dikirim lewat stdin → tidak perlu membuat file 600 root terbaca uid lain.
docker run --rm -i --network proxy --user 10101:10101 --read-only --cap-drop ALL \
  --security-opt no-new-privileges:true --entrypoint sh \
  -v "$STACK_DIR/scripts/uptime-kuma-provision.js:/provision.js:ro" \
  --tmpfs /run/secrets:uid=10101,gid=10101,mode=0700 \
  "$IMAGE" -c 'cat > /run/secrets/uptime-kuma-admin-password && exec node /provision.js' < "$PW"
