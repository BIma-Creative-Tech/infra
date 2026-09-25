#!/usr/bin/env bash
# Render router Traefik tenant Odoo dari templates/traefik-client.yml (T10). IDEMPOTEN.
#
#   scripts/render-client-route.sh <slug> <prod|demo|staging> [--host <fqdn>]   # tulis + HUP
#   scripts/render-client-route.sh <slug> <env> --remove                        # hapus + HUP (suspend)
#
# Menulis traefik/dynamic/clients/<slug>-<env>.yml lalu `docker exec traefik kill -HUP 1`
# (file di subdirektori tidak di-watch file provider). Isi identik → tidak ditulis, tidak HUP.
# H7: JANGAN `docker kill --signal=HUP` — men-set HasBeenManuallyStopped=true + membatalkan restart
# manager (moby daemon/kill.go) → container tidak start setelah reboot (docs/03-operations/traefik.md).
# Syarat sebelum menulis (ADR 0002 #5, CLAUDE.md §3.5.1):
#   - DB tenant sudah ada & dimiliki role pool (jalankan provision-odoo-db.sh dulu);
#   - DNS pre-check: A <fqdn> = IP VPS di 1.1.1.1 dan 8.8.8.8 (minimal satu menjawab, tidak ada
#     jawaban lain), tanpa AAAA — mencegah kegagalan ACME berulang (rate limit LE);
#   - hostname belum dipakai router client lain.
# Output baris terakhir: RESULT route=<file> host=<fqdn> db=<db> changed=<yes|no|removed>
set -euo pipefail
# shellcheck source=lib/odoo-pools.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/odoo-pools.sh"
# shellcheck source=lib/traefik-route.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/traefik-route.sh"   # VPS_IP, dns_precheck, traefik_hup
TEMPLATE="$INFRA_DIR/templates/traefik-client.yml"

usage() { echo "pemakaian: $0 <slug> <prod|demo|staging> [--host <fqdn>] | --remove" >&2; exit 2; }
[[ $EUID -eq 0 ]] || die "harus root"
[[ $# -ge 2 ]] || usage
validate_slug_env "$1" "$2"; shift 2
HOST=""; REMOVE=no
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) [[ $# -ge 2 ]] || usage; HOST="$2"; shift 2 ;;
    --remove) REMOVE=yes; shift ;;
    *) usage ;;
  esac
done
OUT="$TRAEFIK_CLIENTS_DIR/${SLUG}-${TENANT_ENV}.yml"
# Nama file bisa bentrok dengan router website (provision-web-client.sh: web-<slug>-<env>.yml) bila slug
# Odoo diawali `web-` → jangan pernah menimpa/menghapus file milik skrip lain.
if [[ -f "$OUT" ]] && ! grep -q '^# DIRENDER OTOMATIS oleh scripts/render-client-route.sh' "$OUT"; then
  die "$OUT ada tetapi bukan hasil render-client-route.sh — tidak disentuh"
fi

hup() { traefik_hup "$ROUTE_NAME"; }

exec 9>"/run/lock/odoo-route-${SLUG}-${TENANT_ENV}.lock"
flock -n 9 || die "render ${SLUG}-${TENANT_ENV} sedang berjalan (lock)"

if [[ "$REMOVE" == yes ]]; then
  if [[ -e "$OUT" ]]; then
    rm -f -- "$OUT"; hup
    echo "RESULT route=${OUT} host=- db=${DB_NAME} changed=removed"
  else
    echo "RESULT route=${OUT} host=- db=${DB_NAME} changed=no"
  fi
  exit 0
fi

[[ -n "$HOST" ]] || HOST="$(default_host)"
validate_host "$HOST"
[[ -f "$TEMPLATE" ]] || die "template tidak ada: $TEMPLATE"

# 1. DB ada & milik role pool
owner="$(docker exec -i "$PG_CONTAINER" psql -X -q -tA -U postgres -d postgres \
  -c "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '${DB_NAME}'")"
[[ "$owner" == "$POOL_PGUSER" ]] || die "DB ${DB_NAME} belum ada / owner '${owner}' ≠ ${POOL_PGUSER} — jalankan provision-odoo-db.sh dulu"

# 2. DNS pre-check (lib/traefik-route.sh)
dns_precheck "$HOST"

# 3. hostname unik di antara router client
if grep -l -F "Host(\`${HOST}\`)" "$TRAEFIK_CLIENTS_DIR"/*.yml 2>/dev/null | grep -v -x -F "$OUT"; then
  die "hostname ${HOST} sudah dipakai file router di atas"
fi

# 4. render (semua nilai sudah lolos regex: tidak mengandung '|', '&', '\' atau baris baru)
install -d -o root -g root -m 0755 "$TRAEFIK_CLIENTS_DIR"
tmp="$(mktemp "$TRAEFIK_CLIENTS_DIR/.render.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
{
  echo "# DIRENDER OTOMATIS oleh scripts/render-client-route.sh dari templates/traefik-client.yml — jangan edit manual."
  sed -e '1,/^# Tenant:/{/^# Tenant:/!d}' "$TEMPLATE"
} | sed -e "s|__ROUTE__|${ROUTE_NAME}|g" -e "s|__HOST__|${HOST}|g" -e "s|__DB__|${DB_NAME}|g" \
        -e "s|__POOL__|${POOL_CONTAINER}|g" -e "s|__SLUG__|${SLUG}|g" -e "s|__ENV__|${TENANT_ENV}|g" \
        -e "s|__GENERATED__|oleh render-client-route.sh|g" > "$tmp"
grep -q '__[A-Z]*__' "$tmp" && die "placeholder tersisa di hasil render"
python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$tmp" || die "hasil render bukan YAML valid"
chmod 0644 "$tmp"

if [[ -f "$OUT" ]] && cmp -s "$tmp" "$OUT"; then
  echo "RESULT route=${OUT} host=${HOST} db=${DB_NAME} changed=no"
  exit 0
fi
mv -f -- "$tmp" "$OUT"
hup
echo "RESULT route=${OUT} host=${HOST} db=${DB_NAME} changed=yes"
