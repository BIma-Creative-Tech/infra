#!/usr/bin/env bash
# Bootstrap idempoten stack Traefik (T03). Jalankan sebagai root.
#  1. network docker `proxy` (bridge, subnet tetap) — dipakai bersama semua service HTTP
#  2. direktori acme/ (700) + acme-staging.json & acme.json (600) milik uid Traefik
#  3. direktori logs/ (750) milik uid Traefik
#  4. pasang konfigurasi logrotate host untuk access log (salin, bukan symlink: logrotate
#     menolak file konfigurasi yang bisa ditulis selain root)
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NET_NAME="proxy"
NET_SUBNET="10.100.0.0/24"
NET_GATEWAY="10.100.0.1"
TRAEFIK_UID=65532
TRAEFIK_GID=65532

[[ $EUID -eq 0 ]] || { echo "harus root" >&2; exit 1; }

if docker network inspect "$NET_NAME" >/dev/null 2>&1; then
  subnet="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$NET_NAME")"
  [[ "$subnet" == "$NET_SUBNET" ]] || { echo "network $NET_NAME subnet=$subnet (harus $NET_SUBNET) — periksa manual" >&2; exit 1; }
  echo "network $NET_NAME: ok (sudah ada)"
else
  docker network create --driver bridge \
    --subnet "$NET_SUBNET" --gateway "$NET_GATEWAY" \
    --label infra.stack=traefik "$NET_NAME" >/dev/null
  echo "network $NET_NAME: dibuat"
fi

install -d -o "$TRAEFIK_UID" -g "$TRAEFIK_GID" -m 0700 "$STACK_DIR/acme"
for f in acme-staging.json acme.json; do
  [[ -e "$STACK_DIR/acme/$f" ]] || { install -o "$TRAEFIK_UID" -g "$TRAEFIK_GID" -m 0600 /dev/null "$STACK_DIR/acme/$f"; echo "acme/$f: dibuat"; }
  chown "$TRAEFIK_UID:$TRAEFIK_GID" "$STACK_DIR/acme/$f"
  chmod 0600 "$STACK_DIR/acme/$f"
done
install -d -o "$TRAEFIK_UID" -g "$TRAEFIK_GID" -m 0750 "$STACK_DIR/logs"
echo "acme/ & logs/: ok"

install -o root -g root -m 0644 "$STACK_DIR/logrotate/traefik" /etc/logrotate.d/traefik
logrotate --debug /etc/logrotate.d/traefik >/dev/null 2>&1 && echo "logrotate: ok" || { echo "logrotate: konfigurasi invalid" >&2; exit 1; }
