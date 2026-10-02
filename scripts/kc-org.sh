#!/usr/bin/env bash
# Pastikan Organization Keycloak untuk satu tenant (job `kc_org_ensure`, kontrak saas-phase-1-contract.md §1/§1.1,
# ADR 0017 D2). IDEMPOTEN.
#
#   scripts/kc-org.sh <slug> <prod|demo|staging> --tenant-id <uuid> [--dry-run]
#
# Realm dari env (prod|demo → platform, staging → platform-staging). Org: name = <slug>, alias = <tenant_id>
# (= clients.id CP), atribut `slug=[<slug>]`, enabled. Slug `platform` (tenant internal) diizinkan.
#   - org <slug> tidak ada → dibuat;
#   - ada dengan alias sama → hanya atribut/enabled diselaraskan;
#   - ada dengan alias BEDA → exit 3 "org slug sudah terikat tenant lain" (§0.2);
#   - alias <tenant_id> sudah dipakai org slug LAIN → exit 3 (satu tenant_id = satu org).
# Kredensial: client `cp-admin` (identity/keycloak/secrets/cp-admin-<realm>.secret) — lib/keycloak-admin.sh.
# Output baris terakhir: RESULT realm=<r> org=<id|-> tenant=<uuid> created=<0|1> changed=<n>
#                        [blockers=<n> pada --dry-run]  (org=- bila dry-run dan org belum ada)
# JANGAN jalankan dengan `bash -x`.
set -euo pipefail
LIB="$(dirname "${BASH_SOURCE[0]}")/lib"
# shellcheck source=lib/odoo-pools.sh
source "$LIB/odoo-pools.sh"
KC_ADMIN_CLIENT=cp-admin
# shellcheck source=lib/keycloak-admin.sh
source "$LIB/keycloak-admin.sh"
# shellcheck source=lib/kc-tenant.sh
source "$LIB/kc-tenant.sh"

usage() { echo "pemakaian: $0 <slug> <prod|demo|staging> --tenant-id <uuid> [--dry-run]" >&2; exit 2; }
[[ $EUID -eq 0 ]] || die "harus root"
[[ $# -ge 2 ]] || usage
validate_slug_env "$1" "$2"; shift 2
TENANT_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant-id) [[ $# -ge 2 ]] || usage; TENANT_ID="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) usage ;;
  esac
done
[[ "$TENANT_ID" =~ $UUID_RE ]] || die "--tenant-id harus UUID huruf kecil"
REALM="$(kc_realm_for_env "$TENANT_ENV")"
LOG_PREFIX="kc-org ${REALM}/${SLUG}"
take_lock "kc-org-${REALM}-${SLUG}"

kc_init "$REALM"
kc_org_by_slug "$SLUG" "$TENANT_ID"
[[ -z "$ORG_ALIAS_OWNER" ]] || refuse "tenant_id ini sudah menjadi alias org lain (${ORG_ALIAS_OWNER}) — satu tenant satu org"
CREATED=0
if [[ -z "$ORG_ID" ]]; then
  body="$(python3 -c '
import json, sys
slug, tid = sys.argv[1:]
print(json.dumps({"name": slug, "alias": tid, "enabled": True,
                  "description": "Tenant " + slug + " (dikelola control-plane, jangan edit manual)",
                  "attributes": {"slug": [slug]}}))' "$SLUG" "$TENANT_ID")"
  if change "organization ${SLUG} dibuat (alias=${TENANT_ID})"; then
    # KC 26: POST /organizations → 201 + Location …/organizations/<id>. Tanpa domain diterima (diverifikasi
    # Keycloak 26.7.4 sekali pakai, 2026-10-03).
    kc_send POST /organizations "$body" 201
    ORG_ID="${KC_LOCATION##*/}"
    [[ "$ORG_ID" =~ $UUID_RE ]] || die "id organization baru tidak dikenali dari Location"
    CREATED=1
  fi
elif [[ "$ORG_ALIAS" != "$TENANT_ID" ]]; then
  refuse "org slug sudah terikat tenant lain (alias org ≠ --tenant-id)"
else
  # alias sama → selaraskan atribut slug + enabled (alias tidak bisa diubah setelah dibuat di KC 26)
  diff="$(kc_json '", ".join(x for x, bad in (("attributes.slug", (d.get("attributes") or {}).get("slug") != ["'"$SLUG"'"]), ("enabled", d.get("enabled") is not True)) if bad)' "$ORG_JSON")"
  if [[ -z "$diff" ]]; then
    log "organization ${SLUG} ada (id ${ORG_ID}, alias cocok) — tidak ada perubahan"
  elif change "organization ${SLUG}: ${diff}"; then
    body="$(kc_json '{**d, "enabled": True, "attributes": {**(d.get("attributes") or {}), "slug": ["'"$SLUG"'"]}}' "$ORG_JSON")"
    # PUT /organizations/{id} — representasi penuh → 204 (diverifikasi KC 26.7.4; alias tidak boleh berubah).
    kc_send PUT "/organizations/${ORG_ID}" "$body" 204
  fi
fi

echo "RESULT realm=${REALM} org=${ORG_ID:--} tenant=${TENANT_ID} created=${CREATED} changed=${CHANGED}$(result_tail)"
