#!/usr/bin/env bash
# Konfigurasi tenant BCTOne self-serve (job `bctone_tenant_config`, ADR 0019 #3/#4). IDEMPOTEN.
#
#   scripts/bctone-tenant-config.sh <slug> <prod|demo|staging> --plan <bctone-free|bctone-umkm|bctone-bisnis>
#       [--pack <fnb|retail|jasa|bengkel|distribusi|manufaktur|kecantikan|lainnya>] [--limit <metric>=<int> ...] [--disable] [--dry-run]
#
# Prasyarat: DB <slug>_<env> sudah ada (job odoo_db_provision) dan submodule addons/shared pool memuat
# sh_bct_tenant_agent >= 19.0.1.1.0. Slug `platform` ditolak (exit 3).
# Langkah:
#  1. install sh_bct_tenant_agent (one-off --stop-after-init) bila belum (menarik `account`); --disable tidak meng-install.
#     --pack: modul paket industri ikut di-install (daftar per pack di `case "$PACK"` di bawah; semua + l10n_id,
#     hanya modul Odoo CE yang ada di image pool). Modul yang sudah ter-install tidak disentuh (tanpa -u).
#  2. kunci HMAC per tenant = HMAC-SHA256(master, "bctone-usage:<slug>") (sama dengan control-plane
#     src/lib/usage-ingest.ts tenantUsageKey). Master: /etc/infra-jobs/bctone-usage-<instance>.secret (600 root, di luar
#     git; nilai sama dengan USAGE_INGEST_SECRET CP instance itu). Ditulis ke <pool>/secrets/oidc/bct-usage.<db>
#     (0440 root:$ODOO_GID, hex tanpa newline) — dir yang sudah di-mount ro sebagai $SH_OIDC_SECRET_DIR. --disable
#     menghapus file kunci.
#  3. ICP lewat odoo shell: sh_bct_tenant_agent.enabled (1|0), tenant_slug, endpoint, plan, limit.<metric> (metrik tanpa
#     --limit = dikosongkan = tanpa batas) + signal_changes().
# Kunci TIDAK pernah dicetak. Output baris terakhir:
#   RESULT db=<db> mode=<enabled|disabled> changed=<n> [blockers=<n>]
set -euo pipefail
LIB="$(dirname "${BASH_SOURCE[0]}")/lib"
# shellcheck source=lib/odoo-pools.sh
source "$LIB/odoo-pools.sh"
# shellcheck source=lib/odoo-exec.sh
source "$LIB/odoo-exec.sh"
PLATFORM_SLUG=platform
MODULE=sh_bct_tenant_agent
MIN_MODULE=19.0.1.1.0
METRICS=(users devices outlets trx_per_month omzet_per_month ai_prompts_per_day)
refuse() { echo "ERROR: DITOLAK: $*" >&2; exit 3; }

usage() {
  echo "pemakaian: $0 <slug> <prod|demo|staging> --plan <bctone-free|bctone-umkm|bctone-bisnis> [--limit m=n ...] [--disable] [--dry-run]" >&2
  exit 2
}
[[ $EUID -eq 0 ]] || die "harus root"
[[ $# -ge 2 ]] || usage
validate_slug_env "$1" "$2"; shift 2
[[ "$SLUG" != "$PLATFORM_SLUG" ]] || refuse "slug ${PLATFORM_SLUG} bukan tenant BCTOne"
PLAN=""; ENABLE=1; PACK=""
declare -A LIMIT=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan) [[ $# -ge 2 ]] || usage; PLAN="$2"; shift 2 ;;
    --pack) [[ $# -ge 2 ]] || usage; PACK="$2"; shift 2 ;;
    --limit)
      [[ $# -ge 2 ]] || usage
      [[ "$2" =~ ^([a-z_]{1,32})=(0|[1-9][0-9]{0,11})$ ]] || die "--limit harus <metric>=<int>"
      m="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
      [[ " ${METRICS[*]} " == *" $m "* ]] || die "metrik tidak dikenal: $m"
      [[ -z "${LIMIT[$m]:-}" ]] || die "--limit $m duplikat"
      LIMIT[$m]="$v"; shift 2 ;;
    --disable) ENABLE=0; shift ;;
    --dry-run) DRY=1; shift ;;
    *) usage ;;
  esac
done
case "$PLAN" in bctone-free|bctone-umkm|bctone-bisnis) ;; *) die "--plan harus bctone-free|bctone-umkm|bctone-bisnis" ;; esac
case "$PACK" in
  "") PACK_MODULES=() ;;
  fnb) PACK_MODULES=(l10n_id point_of_sale pos_restaurant stock) ;;
  retail) PACK_MODULES=(l10n_id point_of_sale stock sale_management purchase) ;;
  jasa) PACK_MODULES=(l10n_id sale_management project hr_timesheet sale_timesheet crm) ;;
  bengkel) PACK_MODULES=(l10n_id point_of_sale stock repair sale_management purchase) ;;
  distribusi) PACK_MODULES=(l10n_id stock sale_management purchase crm) ;;
  manufaktur) PACK_MODULES=(l10n_id mrp stock sale_management purchase) ;;
  kecantikan) PACK_MODULES=(l10n_id point_of_sale stock) ;;
  lainnya) PACK_MODULES=(l10n_id sale_management project) ;;
  *) die "--pack harus fnb|retail|jasa|bengkel|distribusi|manufaktur|kecantikan|lainnya" ;;
esac
[[ -z "$PACK" || $ENABLE -eq 1 ]] || die "--pack tidak berlaku dengan --disable"
case "$TENANT_ENV" in
  staging) INSTANCE=staging; ENDPOINT="https://cp.staging.${PLATFORM_DOMAIN}/api/bctone/usage" ;;
  *) INSTANCE=prod; ENDPOINT="https://cp.${PLATFORM_DOMAIN}/api/bctone/usage" ;;
esac
MASTER_FILE="/etc/infra-jobs/bctone-usage-${INSTANCE}.secret"
KEY_FILE="$(oidc_secret_dir)/bct-usage.${DB_NAME}"
log "plan=${PLAN} enable=${ENABLE} mode=$([[ $DRY -eq 1 ]] && echo dry-run || echo apply)"

container_running "$PG_CONTAINER" || die "container $PG_CONTAINER tidak berjalan"
container_running "$POOL_CONTAINER" || die "container $POOL_CONTAINER tidak berjalan"
if [[ $DRY -eq 0 ]]; then
  exec 8>"/run/lock/odoo-provision-${DB_NAME}.lock"
  flock -w 60 8 || die "provisioning ${DB_NAME} sedang berjalan (lock)"
fi
DB_EXISTS=1
if [[ $DRY -eq 1 && -z "$(pgq "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}'")" ]]; then
  DB_EXISTS=0; block "DB ${DB_NAME} belum ada (job odoo_db_provision)"
else
  require_tenant_db
fi

# ---- 1. modul
module_version() {
  [[ $DB_EXISTS -eq 1 ]] || return 0
  pgq "SELECT coalesce(latest_version, '') FROM ir_module_module WHERE name = '${MODULE}' AND state = 'installed'" "$DB_NAME"
}
avail="$(docker exec "$POOL_CONTAINER" sh -c "test -f /mnt/extra-addons/shared/${MODULE}/__manifest__.py && echo yes" || true)"
ver="$(module_version)"
if [[ $ENABLE -eq 1 ]]; then
  if [[ -z "$ver" ]]; then
    if [[ "$avail" != yes ]]; then
      block "${MODULE} tidak ada di addons/shared ${POOL} — naikkan submodule dulu (docs/03-operations/odoo.md)"
    elif change "install ${MODULE} (one-off --stop-after-init)"; then
      odoo_cli -i "$MODULE" --stop-after-init --log-level=warn
      ver="$(module_version)"
      [[ -n "$ver" ]] || die "${MODULE} gagal di-install"
    fi
  fi
  # paket industri: hanya modul yang belum ter-install (tidak pernah -u otomatis)
  if [[ ${#PACK_MODULES[@]} -gt 0 ]]; then
    missing=()
    for m in "${PACK_MODULES[@]}"; do
      st="$([[ $DB_EXISTS -eq 1 ]] && pgq "SELECT state FROM ir_module_module WHERE name = '${m}'" "$DB_NAME" || true)"
      [[ "$st" == installed ]] || missing+=("$m")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
      csv="$(IFS=,; echo "${missing[*]}")"
      if change "install pack ${PACK}: ${csv} (one-off --stop-after-init)"; then
        odoo_cli -i "$csv" --stop-after-init --log-level=warn
        for m in "${missing[@]}"; do
          [[ "$(pgq "SELECT state FROM ir_module_module WHERE name = '${m}'" "$DB_NAME")" == installed ]] || die "modul ${m} gagal di-install"
        done
      fi
    else
      log "pack ${PACK}: semua modul sudah ter-install"
    fi
  fi
  if [[ -n "$ver" ]] && ! version_ge "$ver" "$MIN_MODULE"; then
    block "${MODULE} ${ver} < ${MIN_MODULE}: backup DB lalu -u ${MODULE} (skrip tidak meng-upgrade otomatis)"
  fi
fi

# ---- 2. kunci per tenant
file_meta() { stat -c '%a %u:%g' "$1" 2>/dev/null || true; }
if [[ $ENABLE -eq 1 ]]; then
  if [[ ! -f "$MASTER_FILE" || -L "$MASTER_FILE" || "$(file_meta "$MASTER_FILE")" != "600 0:0" ]]; then
    block "master ${MASTER_FILE} tidak ada / bukan 600 root:root (lihat docs/03-operations/bctone.md)"
  else
    KEY_HEX="$(python3 - "$MASTER_FILE" "$SLUG" <<'PY'
import hashlib, hmac, sys
raw = open(sys.argv[1], 'rb').read(4097).rstrip(b'\n')
if not 32 <= len(raw) <= 4096 or any(c < 0x21 or c > 0x7e for c in raw):
    sys.exit('master tidak valid')
print(hmac.new(raw, b'bctone-usage:' + sys.argv[2].encode(), hashlib.sha256).hexdigest())
PY
)" || die "master ${MASTER_FILE} tidak valid (32..4096 karakter ASCII cetak)"
    [[ "$KEY_HEX" =~ ^[0-9a-f]{64}$ ]] || die "kunci turunan tidak valid"
    [[ -d "$(oidc_secret_dir)" ]] || die "$(oidc_secret_dir) tidak ada — jalankan odoo-pool-bootstrap.sh ${POOL}"
    if [[ -f "$KEY_FILE" && ! -L "$KEY_FILE" ]] && cmp -s <(printf '%s' "$KEY_HEX") "$KEY_FILE"; then
      log "file kunci: isi sesuai"
      if [[ "$(file_meta "$KEY_FILE")" != "440 0:${ODOO_GID}" ]]; then
        change "file kunci: mode/owner → 0440 root:${ODOO_GID}" && { chown "root:${ODOO_GID}" "$KEY_FILE"; chmod 0440 "$KEY_FILE"; }
      fi
    elif change "file kunci $(basename "$KEY_FILE"): ditulis (0440 root:${ODOO_GID})"; then
      tmp="$(mktemp "$(oidc_secret_dir)/.bct-usage.XXXXXX")"
      printf '%s' "$KEY_HEX" > "$tmp"; chown "root:${ODOO_GID}" "$tmp"; chmod 0440 "$tmp"; mv -f "$tmp" "$KEY_FILE"
    fi
    unset KEY_HEX
  fi
elif [[ -e "$KEY_FILE" || -L "$KEY_FILE" ]]; then
  change "file kunci $(basename "$KEY_FILE"): dihapus (--disable)" && rm -f "$KEY_FILE"
fi

# ---- 3. ICP (hanya bila modul ter-install; --disable tanpa modul = tidak ada yang dimatikan)
if [[ $BLOCKERS -gt 0 ]]; then
  log "odoo shell TIDAK dijalankan (ada blocker)"
elif [[ -z "$ver" ]]; then
  [[ $ENABLE -eq 0 ]] && log "${MODULE} tidak ter-install — tidak ada yang dinonaktifkan"
  [[ $ENABLE -eq 1 && $DRY -eq 1 ]] && log "PLAN: ICP sh_bct_tenant_agent.* ditulis setelah install"
else
  want="'enabled': '${ENABLE}', 'tenant_slug': '${SLUG}', 'endpoint': '${ENDPOINT}', 'plan': '${PLAN}'"
  for m in "${METRICS[@]}"; do want+=", 'limit.${m}': '${LIMIT[$m]:-}'"; done
  # Semua nilai lolos regex (slug, enum plan, angka, FQDN platform) → aman sebagai literal Python.
  out="$(odoo_cli shell --log-level=warn 2>&1 <<PY
ICP = env['ir.config_parameter'].sudo()
want = {${want}}
dry = ${DRY} == 1
n = 0
for key, value in want.items():
    key = 'sh_bct_tenant_agent.' + key
    cur = ICP.get_param(key) or ''
    if cur != value:
        n += 1
        print('CFG_CHANGE %s: %s -> %s' % (key, cur or '-', value or '-'))
        if not dry:
            ICP.set_param(key, value)
if dry or not n:
    env.cr.rollback()
else:
    env.cr.commit()
    env.registry.signal_changes()
print('CFG_RESULT changed=%d' % n)
PY
)" || { echo "$out" | tail -n 30 >&2; die "odoo shell gagal"; }
  { grep '^CFG_CHANGE ' <<<"$out" || true; } | sed 's/^CFG_CHANGE /ICP /' | while IFS= read -r line; do
    if [[ $DRY -eq 1 ]]; then log "PLAN: ${line}"; else log "UBAH: ${line}"; fi
  done
  n="$(sed -n 's/^CFG_RESULT changed=\([0-9]*\)$/\1/p' <<<"$out" | tail -n1)"
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "$out" | tail -n 30 >&2; die "output odoo shell tidak dikenali"; }
  CHANGED=$((CHANGED + n))
fi

extra=""; [[ $DRY -eq 1 ]] && extra=" blockers=${BLOCKERS}"
echo "RESULT db=${DB_NAME} mode=$([[ $ENABLE -eq 1 ]] && echo enabled || echo disabled) changed=${CHANGED}${extra}"
