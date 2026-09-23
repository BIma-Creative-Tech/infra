#!/usr/bin/env bash
# Bootstrap idempoten stack Traefik (T03). Jalankan sebagai root.
#  1. network docker `proxy` (bridge, subnet tetap) — dipakai bersama semua service HTTP
#     + network `odoo-edge` (H1): HANYA traefik + pool Odoo, agar container lain di `proxy`
#     tidak bisa menghubungi Odoo :8069/:8072 langsung (melewati CrowdSec/ratelimit/header DB)
#     + network `drms-kas-edge` (ProyekKas client DRMS): HANYA traefik + container web ProyekKas
#     + network `drms-kc-admin{,-stg}` (H5, --internal): traefik + app ProyekKas → Admin REST realm drms*
#  2. direktori acme/ (700) + acme-staging.json & acme.json (600) milik uid Traefik
#  3. direktori logs/ (750, grup adm) milik uid Traefik + secrets/ (700)
#  4. pasang konfigurasi logrotate host untuk access log (salin, bukan symlink: logrotate
#     menolak file konfigurasi yang bisa ditulis selain root)
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRAEFIK_UID=65532
TRAEFIK_GID=65532

[[ $EUID -eq 0 ]] || { echo "harus root" >&2; exit 1; }

# ensure_network <nama> <subnet> <gateway> [internal] — buat bila belum ada; bila ada, subnet (dan flag
# --internal) wajib sama. Argumen ke-4 `internal` → `docker network create --internal` (tanpa egress/gateway).
ensure_network() {
  local name="$1" net_subnet="$2" net_gateway="$3" want_internal=false subnet internal
  local -a extra=()
  if [[ "${4:-}" == "internal" ]]; then want_internal=true; extra=(--internal); fi
  if docker network inspect "$name" >/dev/null 2>&1; then
    subnet="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$name")"
    internal="$(docker network inspect -f '{{.Internal}}' "$name")"
    [[ "$subnet" == "$net_subnet" && "$internal" == "$want_internal" ]] \
      || { echo "network $name subnet=$subnet internal=$internal (harus $net_subnet, $want_internal) — periksa manual" >&2; exit 1; }
    echo "network $name: ok (sudah ada)"
  else
    docker network create --driver bridge "${extra[@]}" \
      --subnet "$net_subnet" --gateway "$net_gateway" \
      --label infra.stack=traefik "$name" >/dev/null
    echo "network $name: dibuat"
  fi
}

# proxy: semua service HTTP. Gateway 10.100.0.1 = IP sumber koneksi dari host (ipallowlist-admin).
ensure_network proxy 10.100.0.0/24 10.100.0.1
# odoo-edge: traefik + odoo-pool-a + odoo-staging saja. Bukan --internal: Odoo tetap butuh egress
# (sebelumnya lewat `proxy`, mis. OIDC ke auth.bimacreative.tech / SMTP keluar).
ensure_network odoo-edge 10.100.3.0/24 10.100.3.1
# drms-kas-edge: traefik + container web ProyekKas DRMS (drms-pk-web, drms-pk-stg) saja (pola odoo-edge).
# Bukan --internal: app butuh egress (FCM, issuer publik Keycloak via hairpin). Runbook
# docs/runbooks/proyekkas-drms-onboarding.md §Langkah 0.
ensure_network drms-kas-edge 10.100.7.0/24 10.100.7.1
# H5 — drms-kc-admin (prod) / drms-kc-admin-stg (staging): --internal, anggota traefik (alias
# auth.bimacreative.tech) + app ProyekKas (web/worker). Admin REST Keycloak HANYA realm drms / drms-staging
# lewat router dynamic/clients/drms-proyekkas-kc-admin.yml (ClientIP subnet ini). Keycloak tidak join.
# (10.100.6.0/24 = bekas obs-dockerapi, dihapus H3 — tidak dipakai ulang.)
ensure_network drms-kc-admin     10.100.8.0/24 10.100.8.1 internal
ensure_network drms-kc-admin-stg 10.100.9.0/24 10.100.9.1 internal

install -d -o "$TRAEFIK_UID" -g "$TRAEFIK_GID" -m 0700 "$STACK_DIR/acme"
for f in acme-staging.json acme.json; do
  [[ -e "$STACK_DIR/acme/$f" ]] || { install -o "$TRAEFIK_UID" -g "$TRAEFIK_GID" -m 0600 /dev/null "$STACK_DIR/acme/$f"; echo "acme/$f: dibuat"; }
  chown "$TRAEFIK_UID:$TRAEFIK_GID" "$STACK_DIR/acme/$f"
  chmod 0600 "$STACK_DIR/acme/$f"
done
# logs/: grup adm (gid 4) agar CrowdSec (T05, root tanpa capability + gid 4) bisa membaca access log.
install -d -o "$TRAEFIK_UID" -g 4 -m 0750 "$STACK_DIR/logs"
# secrets/: file API key bouncer CrowdSec (T05) — dibaca plugin Traefik, tidak di-commit.
install -d -o "$TRAEFIK_UID" -g "$TRAEFIK_GID" -m 0700 "$STACK_DIR/secrets"
echo "acme/, logs/, secrets/: ok"

install -o root -g root -m 0644 "$STACK_DIR/logrotate/traefik" /etc/logrotate.d/traefik
logrotate --debug /etc/logrotate.d/traefik >/dev/null 2>&1 && echo "logrotate: ok" || { echo "logrotate: konfigurasi invalid" >&2; exit 1; }
