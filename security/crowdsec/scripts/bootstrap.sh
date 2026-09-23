#!/usr/bin/env bash
# Bootstrap idempoten stack CrowdSec (T05). Jalankan sebagai root, SEBELUM `docker compose up -d`.
#  1. network docker `crowdsec` (bridge, subnet tetap 10.100.2.0/24): hanya crowdsec + traefik.
#     Tidak --internal karena CrowdSec butuh egress (hub update, CAPI/blocklist komunitas).
#     LAPI (8080) & AppSec (7422) tidak dicapai container lain di network `proxy`.
#  2. data/config (/etc/crowdsec) & data/db (/var/lib/crowdsec/data) mode 700 root.
#  3. traefik/secrets/ (700, uid Traefik) untuk file API key bouncer Traefik.
#  4. traefik/logs/ group `adm` (gid 4) mode 750 → CrowdSec (root tanpa capability, anggota
#     gid 4 di image) bisa membaca access log tanpa CAP_DAC_OVERRIDE.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$(cd "$STACK_DIR/../.." && pwd)"
NET_NAME="crowdsec"
NET_SUBNET="10.100.2.0/24"
NET_GATEWAY="10.100.2.1"
TRAEFIK_UID=65532
ADM_GID=4

[[ $EUID -eq 0 ]] || { echo "harus root" >&2; exit 1; }

if docker network inspect "$NET_NAME" >/dev/null 2>&1; then
  subnet="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$NET_NAME")"
  [[ "$subnet" == "$NET_SUBNET" ]] || { echo "network $NET_NAME subnet=$subnet (harus $NET_SUBNET) — periksa manual" >&2; exit 1; }
  echo "network $NET_NAME: ok (sudah ada)"
else
  docker network create --driver bridge \
    --subnet "$NET_SUBNET" --gateway "$NET_GATEWAY" \
    --label infra.stack=crowdsec "$NET_NAME" >/dev/null
  echo "network $NET_NAME: dibuat"
fi

install -d -o root -g root -m 0700 "$STACK_DIR/data" "$STACK_DIR/data/config" "$STACK_DIR/data/db"
echo "data/: ok"

install -d -o "$TRAEFIK_UID" -g "$TRAEFIK_UID" -m 0700 "$INFRA_DIR/traefik/secrets"
echo "traefik/secrets/: ok"

chgrp "$ADM_GID" "$INFRA_DIR/traefik/logs"
chmod 0750 "$INFRA_DIR/traefik/logs"
echo "traefik/logs/: group adm, 750"
