# shellcheck shell=bash
# shellcheck disable=SC2034  # library: variabel di file ini dipakai oleh skrip pemanggil (source), bukan di sini
# Pemetaan pool Odoo (T10) — di-source oleh scripts/odoo-pool-bootstrap.sh,
# scripts/provision-odoo-db.sh, scripts/render-client-route.sh. Satu sumber kebenaran.
#
#   env tenant  → pool      container      role Postgres   domain default
#   prod, demo  → pool-a    odoo-pool-a    odoo_pool_a     <slug>.erp.bimacreative.tech (prod)
#                                                          demo: --host wajib (tanpa default)
#   staging     → staging   odoo-staging   odoo_staging    <slug>.staging.bimacreative.tech
#
# Tidak ada secret di file ini.

INFRA_DIR="${INFRA_DIR:-/opt/infra}"
PG_CONTAINER="${PG_CONTAINER:-postgres}"
PG_ENV_FILE="$INFRA_DIR/postgres/.env"
TRAEFIK_CONTAINER="${TRAEFIK_CONTAINER:-traefik}"
TRAEFIK_CLIENTS_DIR="$INFRA_DIR/traefik/dynamic/clients"
PLATFORM_DOMAIN="bimacreative.tech"
ODOO_CONF_IN_CONTAINER="/etc/odoo/odoo.conf"

SLUG_RE='^[a-z0-9-]{3,30}$'
ENV_RE='^(prod|demo|staging)$'
# FQDN: label huruf kecil/angka/'-' (tidak diawali/diakhiri '-'), minimal 2 label, total ≤ 253.
FQDN_RE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'

die() { echo "ERROR: $*" >&2; exit 1; }

# pool_for_env <env> → set POOL, POOL_DIR, POOL_CONTAINER, POOL_PGUSER, POOL_PG_VAR, POOL_DOMAIN
pool_for_env() {
  case "$1" in
    prod|demo)
      POOL=pool-a; POOL_DIR="$INFRA_DIR/odoo/pool-a"; POOL_CONTAINER=odoo-pool-a
      POOL_PGUSER=odoo_pool_a; POOL_PG_VAR=PG_ODOO_POOL_A_PASSWORD
      POOL_DOMAIN="erp.$PLATFORM_DOMAIN" ;;
    staging)
      POOL=staging; POOL_DIR="$INFRA_DIR/staging/odoo"; POOL_CONTAINER=odoo-staging
      POOL_PGUSER=odoo_staging; POOL_PG_VAR=PG_ODOO_STAGING_PASSWORD
      POOL_DOMAIN="staging.$PLATFORM_DOMAIN" ;;
    *) die "env tidak dikenal: $1" ;;
  esac
}

# pool_by_name <pool-a|staging> → sama dengan pool_for_env
pool_by_name() {
  case "$1" in
    pool-a) pool_for_env prod ;;
    staging) pool_for_env staging ;;
    *) die "pool tidak dikenal: $1 (pool-a|staging)" ;;
  esac
}

# validate_slug_env <slug> <env> → set SLUG, TENANT_ENV, DB_NAME, ROUTE_NAME
validate_slug_env() {
  [[ "$1" =~ $SLUG_RE ]] || die "slug tidak valid: harus cocok $SLUG_RE"
  [[ "$2" =~ $ENV_RE ]] || die "env tidak valid: harus prod|demo|staging"
  SLUG="$1"; TENANT_ENV="$2"
  # '-' → '_' (injektif: slug tidak boleh memuat '_'; env selalu komponen terakhir).
  DB_NAME="${SLUG//-/_}_${TENANT_ENV}"
  [[ "$DB_NAME" =~ ^[a-z0-9_]{1,63}$ ]] || die "nama DB hasil tidak valid"
  ROUTE_NAME="odoo-${SLUG}-${TENANT_ENV}"
  pool_for_env "$TENANT_ENV"
}

# default_host → hostname default tenant (dipakai bila --host tidak diberikan).
# env demo TIDAK punya default: pola `<slug>-demo.erp…` bisa bentrok dengan slug lain
# (`acme` demo vs `acme-demo` prod) → control plane wajib memberi --host eksplisit.
default_host() {
  case "$TENANT_ENV" in
    prod|staging) echo "${SLUG}.${POOL_DOMAIN}" ;;
    demo) die "env demo butuh --host <fqdn> eksplisit" ;;
  esac
}

validate_host() {
  [[ ${#1} -le 253 && "$1" =~ $FQDN_RE ]] || die "hostname tidak valid: $1"
}

# Nama file secret password admin tenant (600 root, di luar git).
tenant_secret_file() { echo "$POOL_DIR/secrets/tenants/${DB_NAME}.admin-password"; }

container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]
}
