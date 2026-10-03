#!/usr/bin/env bash
# Suspend/resume tenant Odoo di edge (job tenant_suspend / tenant_resume, kontrak saas-phase-1-contract.md §1/§1.1,
# ADR 0018 #6). IDEMPOTEN.
#
#   scripts/tenant-state.sh <slug> <prod|demo|staging> --suspend|--resume [--dry-run]
#
# Render ulang route traefik/dynamic/clients/<slug>-<env>.yml lewat scripts/render-client-route.sh:
#   --suspend → `--suspended` (router main/login/oidc/websocket → middleware tenant-suspended@file, redirect 302 ke
#               halaman control plane /suspended/<slug>); --resume → render dengan `--resume` (tanpa flag, status suspended dipertahankan).
# Host dibaca dari route yang ada (harus hasil render-client-route.sh, tepat satu host). DB, filestore, user Keycloak,
# mail, dan web profile TIDAK disentuh (ADR 0018 #6). Slug `platform` ditolak (exit 3).
# Route alias manual (mis. expomedia-staging-alias.yml) TIDAK ikut disuspend — lihat traefik.md §Tenant suspended.
# --dry-run: hanya membaca file route; tidak memanggil render (tidak ada docker exec / DNS / HUP).
# Output baris terakhir: RESULT route=<slug>-<env>.yml host=<fqdn> state=<suspended|active> changed=<0|1> [blockers=<n>]
set -euo pipefail
LIB="$(dirname "${BASH_SOURCE[0]}")/lib"
# shellcheck source=lib/odoo-pools.sh
source "$LIB/odoo-pools.sh"
PLATFORM_SLUG=platform
DRY=0; CHANGED=0; BLOCKERS=0
log() { echo "[tenant-state ${SLUG}-${TENANT_ENV}] $*"; }
refuse() { echo "ERROR: DITOLAK: $*" >&2; exit 3; }

usage() { echo "pemakaian: $0 <slug> <prod|demo|staging> --suspend|--resume [--dry-run]" >&2; exit 2; }
[[ $EUID -eq 0 ]] || die "harus root"
[[ $# -ge 3 ]] || usage
validate_slug_env "$1" "$2"; shift 2
[[ "$SLUG" != "$PLATFORM_SLUG" ]] || refuse "slug ${PLATFORM_SLUG} tidak bisa disuspend"
WANT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --suspend) [[ -z "$WANT" ]] || usage; WANT=suspended; shift ;;
    --resume) [[ -z "$WANT" ]] || usage; WANT=active; shift ;;
    --dry-run) DRY=1; shift ;;
    *) usage ;;
  esac
done
[[ -n "$WANT" ]] || usage

ROUTE="$TRAEFIK_CLIENTS_DIR/${SLUG}-${TENANT_ENV}.yml"
[[ -f "$ROUTE" && ! -L "$ROUTE" ]] || die "route ${ROUTE} tidak ada — tenant belum punya route (job odoo_route)"
grep -q '^# DIRENDER OTOMATIS oleh scripts/render-client-route.sh' "$ROUTE" \
  || die "${ROUTE} bukan hasil render-client-route.sh — tidak disentuh"
mapfile -t hosts < <(grep -o 'Host(`[a-z0-9.-]*`)' "$ROUTE" | sed 's/^Host(`//; s/`)$//' | sort -u)
[[ ${#hosts[@]} -eq 1 ]] || die "route ${ROUTE} memuat ${#hosts[@]} host (diharapkan tepat 1)"
HOST="${hosts[0]}"
validate_host "$HOST"
n_susp="$(grep -c 'tenant-suspended@file' "$ROUTE" || true)"
case "$n_susp" in
  0) CUR=active ;;
  4) CUR=suspended ;;
  *) die "route ${ROUTE} setengah suspended (${n_susp} router) — render manual dulu" ;;
esac
log "host=${HOST} state=${CUR} → ${WANT} mode=$([[ $DRY -eq 1 ]] && echo dry-run || echo apply)"

if [[ "$CUR" == "$WANT" ]]; then
  log "sudah ${WANT} — tidak ada perubahan"
elif [[ $DRY -eq 1 ]]; then
  CHANGED=1
  log "PLAN: render-client-route.sh ${SLUG} ${TENANT_ENV} --host ${HOST}$([[ "$WANT" == suspended ]] && echo ' --suspended' || echo ' --resume')"
else
  args=("$SLUG" "$TENANT_ENV" --host "$HOST")
  if [[ "$WANT" == suspended ]]; then args+=(--suspended); else args+=(--resume); fi
  out="$("$(dirname "${BASH_SOURCE[0]}")/render-client-route.sh" "${args[@]}")" || { echo "$out"; die "render-client-route.sh gagal"; }
  echo "$out" | grep -v '^RESULT ' || true
  rres="$(grep '^RESULT ' <<<"$out" | tail -n1 || true)"
  case "$rres" in
    *" changed=yes"*) CHANGED=1; log "UBAH: route dirender ${WANT}" ;;
    *" changed=no"*) log "render: isi identik (tidak ada perubahan)" ;;
    *) die "RESULT render-client-route.sh tidak dikenali" ;;
  esac
fi

extra=""; [[ $DRY -eq 1 ]] && extra=" blockers=${BLOCKERS}"
echo "RESULT route=$(basename "$ROUTE") host=${HOST} state=${WANT} changed=${CHANGED}${extra}"
