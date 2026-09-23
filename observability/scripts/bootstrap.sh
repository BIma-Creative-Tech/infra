#!/usr/bin/env bash
# Bootstrap idempoten stack observability (T14a). Jalankan sebagai root SEBELUM `docker compose up -d`.
#  1. network docker (bridge, subnet tetap, --internal = tanpa egress):
#     - observability 10.100.4.0/24 : prometheus, node-exporter, loki, alloy, grafana
#     - metrics       10.100.5.0/24 : prometheus + target scrape di stack lain (traefik :8082,
#                                      crowdsec :6060, keycloak :9000). Dibuat di sini (bukan oleh
#                                      compose) karena dipakai bersama beberapa stack.
#     (obs-dockerapi 10.100.6.0/24 DIHAPUS di H3 — Alloy tidak lagi memakai Docker API; subnet jangan dipakai ulang
#      tanpa catatan di docs/03-operations/observability.md.)
#  2. data/grafana (uid 472) & data/uptime-kuma (uid 10101) mode 700 — di bawah /opt/infra → ikut
#     backup restic harian (ADR 0006 "Uptime Kuma data, Grafana data"). TSDB Prometheus/Loki = named
#     volume (tidak di-backup, ADR 0006 #5).
#  3. secrets/grafana-admin-password (acak 40 char, 600 uid 472) — dibuat sekali, tidak ditimpa.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRAFANA_UID=472
KUMA_UID=10101

[[ $EUID -eq 0 ]] || { echo "harus root" >&2; exit 1; }

# ensure_internal_network <nama> <subnet> <gateway>
ensure_internal_network() {
  local name="$1" net_subnet="$2" net_gateway="$3" subnet internal
  if docker network inspect "$name" >/dev/null 2>&1; then
    subnet="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$name")"
    internal="$(docker network inspect -f '{{.Internal}}' "$name")"
    [[ "$subnet" == "$net_subnet" && "$internal" == "true" ]] \
      || { echo "network $name subnet=$subnet internal=$internal (harus $net_subnet, true) — periksa manual" >&2; exit 1; }
    echo "network $name: ok (sudah ada)"
  else
    docker network create --driver bridge --internal \
      --subnet "$net_subnet" --gateway "$net_gateway" \
      --label infra.stack=observability "$name" >/dev/null
    echo "network $name: dibuat"
  fi
}

ensure_internal_network observability 10.100.4.0/24 10.100.4.1
ensure_internal_network metrics       10.100.5.0/24 10.100.5.1

install -d -o root -g root -m 0755 "$STACK_DIR/data"
install -d -o "$GRAFANA_UID" -g "$GRAFANA_UID" -m 0700 "$STACK_DIR/data/grafana"
install -d -o "$KUMA_UID" -g "$KUMA_UID" -m 0700 "$STACK_DIR/data/uptime-kuma"
echo "data/: ok"

install -d -o root -g root -m 0700 "$STACK_DIR/secrets"
PW="$STACK_DIR/secrets/grafana-admin-password"
# Password awal HANYA untuk instalasi baru (DB Grafana belum ada); setelah user mengganti password, file dihapus.
if [[ ! -e "$STACK_DIR/data/grafana/grafana.db" && ! -s "$PW" ]]; then
  ( umask 077; openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 40 > "$PW" )
  echo "secrets/grafana-admin-password: dibuat (instalasi baru — tambahkan env __FILE + mount sementara)"
fi
[[ -e "$PW" ]] && { chown "$GRAFANA_UID:$GRAFANA_UID" "$PW"; chmod 0600 "$PW"; }
echo "secrets/: ok"
