#!/usr/bin/env bash
# Cek tenant lapis kedua sh_auth_oidc per DB (job `odoo_tenant_config`, kontrak saas-phase-1-contract.md §1/§1.1,
# ADR 0017 D4). IDEMPOTEN.
#
#   scripts/odoo-tenant-config.sh <slug> <prod|demo|staging> --tenant-check <off|compat|strict> [--dry-run]
#
# ICP di DB <slug>_<env>:
#   sh_auth_oidc.expected_tenant_id = alias Organization Keycloak slug (= tenant_id; dibaca dengan cp-admin, GET saja)
#   sh_auth_oidc.tenant_check       = off | compat (log WARNING, login tetap) | strict (klaim tenant_id ≠ → login ditolak)
# Ditulis lewat `odoo shell` (ICP.set_param membersihkan ormcache) + commit + env.registry.signal_changes() agar worker
# pool memuat ulang cache (pelajaran: ubah via odoo shell wajib signal_changes). Slug `platform` ditolak (exit 3).
# strict butuh sh_auth_oidc ≥ 19.0.1.3.0 ter-install (BLOKIR bila lebih lama — modul lama mengabaikan ICP ini, strict
# palsu); compat dengan modul lama hanya PERINGATAN (pra-staging nilai).
# Alias org kosong/bukan UUID + mode compat|strict → dry-run BLOKIR / apply exit 3 (QA F4); mode off → expected
# dikosongkan.
# Output baris terakhir: RESULT db=<db> mode=<off|compat|strict> tenant=<uuid|-> changed=<n> [blockers=<n>]
# (dry-run: `mode` tetap = mode yang diminta; penanda dry-run hanya `blockers=`.)
set -euo pipefail
LIB="$(dirname "${BASH_SOURCE[0]}")/lib"
# shellcheck source=lib/odoo-pools.sh
source "$LIB/odoo-pools.sh"
KC_ADMIN_CLIENT=cp-admin
# shellcheck source=lib/keycloak-admin.sh
source "$LIB/keycloak-admin.sh"
# shellcheck source=lib/odoo-exec.sh
source "$LIB/odoo-exec.sh"
# shellcheck source=lib/kc-tenant.sh
source "$LIB/kc-tenant.sh"
MIN_MODULE=19.0.1.3.0

usage() { echo "pemakaian: $0 <slug> <prod|demo|staging> --tenant-check <off|compat|strict> [--dry-run]" >&2; exit 2; }
[[ $EUID -eq 0 ]] || die "harus root"
[[ $# -ge 2 ]] || usage
validate_slug_env "$1" "$2"; shift 2
[[ "$SLUG" != "$PLATFORM_SLUG" ]] || refuse "slug ${PLATFORM_SLUG} tidak punya DB Odoo"
MODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant-check) [[ $# -ge 2 ]] || usage; MODE="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) usage ;;
  esac
done
case "$MODE" in off|compat|strict) ;; *) die "--tenant-check harus off|compat|strict" ;; esac
REALM="$(kc_realm_for_env "$TENANT_ENV")"
LOG_PREFIX="odoo-tenant-config ${DB_NAME}"
log "tenant_check=${MODE} mode=$([[ $DRY -eq 1 ]] && echo dry-run || echo apply)"

container_running "$PG_CONTAINER" || die "container $PG_CONTAINER tidak berjalan"
container_running "$POOL_CONTAINER" || die "container $POOL_CONTAINER tidak berjalan"
if [[ $DRY -eq 0 ]]; then
  exec 8>"/run/lock/odoo-provision-${DB_NAME}.lock"
  flock -w 60 8 || die "provisioning ${DB_NAME} sedang berjalan (lock)"
fi
DB_EXISTS=1
if [[ $DRY -eq 1 && -z "$(pgq "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}'")" ]]; then
  DB_EXISTS=0; block "DB ${DB_NAME} belum ada"
else
  require_tenant_db
fi

# ---- versi modul sh_auth_oidc
if [[ $DB_EXISTS -eq 1 ]]; then
  ver="$(pgq "SELECT coalesce(latest_version, '') FROM ir_module_module WHERE name = 'sh_auth_oidc' AND state = 'installed'" "$DB_NAME")"
  if [[ -z "$ver" ]]; then
    [[ "$MODE" == off ]] || block "sh_auth_oidc tidak ter-install di ${DB_NAME} (jalankan provision-odoo-sso.sh)"
  elif ! version_ge "$ver" "$MIN_MODULE"; then
    case "$MODE" in
      strict) block "sh_auth_oidc ${ver} < ${MIN_MODULE}: mode strict tidak ditegakkan modul lama" ;;
      compat) log "PERINGATAN: sh_auth_oidc ${ver} < ${MIN_MODULE} — nilai disimpan, belum dibaca modul" ;;
    esac
  fi
fi

# ---- tenant_id dari Organization (GET saja)
kc_init "$REALM"
kc_org_by_slug "$SLUG"
[[ -n "$ORG_ID" ]] || block "organization ${SLUG} belum ada (job kc_org_ensure)"
TENANT_ID="$ORG_ALIAS"
# QA F4: tenant_id kosong/bukan UUID TIDAK PERNAH ditulis bersama mode compat/strict (strict dengan expected kosong =
# cek palsu). Dry-run → BLOKIR; apply → exit 3. Mode off: expected_tenant_id dikosongkan (nilai alias tidak dipakai).
if [[ -n "$ORG_ID" && ! "$TENANT_ID" =~ $UUID_RE ]]; then
  TENANT_ID=""
  if [[ "$MODE" == off ]]; then
    log "PERINGATAN: alias organization ${SLUG} kosong/bukan UUID — expected_tenant_id dikosongkan (mode off)"
  elif [[ $DRY -eq 1 ]]; then
    block "alias organization ${SLUG} kosong/bukan UUID — tenant_check ${MODE} butuh tenant_id valid (kc_org_ensure)"
  else
    refuse "alias organization ${SLUG} kosong/bukan UUID — tenant_check ${MODE} tidak ditulis tanpa tenant_id valid"
  fi
fi

if [[ $BLOCKERS -gt 0 ]]; then
  log "odoo shell TIDAK dijalankan (ada blocker)"
else
  # Nilai sudah tervalidasi regex (UUID / off|compat|strict) → aman sebagai literal Python.
  out="$(odoo_cli shell --log-level=warn 2>&1 <<PY
ICP = env['ir.config_parameter'].sudo()
want = {'sh_auth_oidc.expected_tenant_id': '${TENANT_ID}', 'sh_auth_oidc.tenant_check': '${MODE}'}
dry = ${DRY} == 1
n = 0
for key, value in want.items():
    cur = ICP.get_param(key) or ''
    if cur != value:
        n += 1
        print('CFG_CHANGE %s: %s -> %s' % (key, cur or '-', value))
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
echo "RESULT db=${DB_NAME} mode=${MODE} tenant=${TENANT_ID:--} changed=${CHANGED}${extra}"
