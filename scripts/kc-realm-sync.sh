#!/usr/bin/env bash
# Realm sebagai kode (job `kc_realm_sync`, kontrak saas-phase-1-contract.md §1/§1.1, ADR 0017 D7). IDEMPOTEN.
#
#   scripts/kc-realm-sync.sh platform <prod|demo|staging> [--approve] [--dry-run]
#
# Realm dari env (prod|demo → platform, staging → platform-staging). Desired-state:
#   identity/keycloak/realm/platform.json + identity/keycloak/realm/<realm>.overrides.json (opsional)
# Alur: GET kondisi live (Admin REST, client `kc-realm-sync`) → direktori state sementara (0700, field secret dibuang
# oleh `kc_realm_sync.py sanitize` sebelum ditulis) → `kc_realm_sync.py plan` → daftar op. --dry-run: cetak rencana
# (mode=plan). Apply: jalankan op, GET ulang, rencanakan lagi sampai kosong (maks. 4 putaran; op "tertunda" bergantung
# pada objek baru) — apply kedua = changed=0.
#   - slug WAJIB `platform` (job realm, bukan tenant);
#   - env prod|demo + apply WAJIB --approve (exit 3 tanpa itu); staging tidak;
#   - ada blocker → dry-run: blockers=N; apply: die (tidak ada op yang dijalankan).
# Tidak pernah menyentuh user (kecuali role realm-management user service account cp-admin), secret client, atau
# client di luar desired-state (kc-realm-sync, automation, bawaan Keycloak).
# Kredensial: identity/keycloak/secrets/kc-realm-sync-<realm>.secret (bootstrap manual sekali per realm, keycloak.md).
# Output baris terakhir: RESULT realm=<r> changed=<n> mode=<plan|apply> [blockers=<n>]
# JANGAN jalankan dengan `bash -x`.
set -euo pipefail
LIB="$(dirname "${BASH_SOURCE[0]}")/lib"
# shellcheck source=lib/odoo-pools.sh
source "$LIB/odoo-pools.sh"
KC_ADMIN_CLIENT=kc-realm-sync
# shellcheck source=lib/keycloak-admin.sh
source "$LIB/keycloak-admin.sh"
# shellcheck source=lib/kc-tenant.sh
source "$LIB/kc-tenant.sh"
PY="$LIB/kc_realm_sync.py"
MAX_ROUNDS=4

usage() { echo "pemakaian: $0 platform <prod|demo|staging> [--approve] [--dry-run]" >&2; exit 2; }
[[ $EUID -eq 0 ]] || die "harus root"
[[ $# -ge 2 ]] || usage
[[ "$1" == "$PLATFORM_SLUG" ]] || refuse "kc-realm-sync hanya untuk slug ${PLATFORM_SLUG}"
validate_slug_env "$1" "$2"; shift 2
APPROVE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --approve) APPROVE=1; shift ;;
    --dry-run) DRY=1; shift ;;
    *) usage ;;
  esac
done
REALM="$(kc_realm_for_env "$TENANT_ENV")"
LOG_PREFIX="kc-realm-sync ${REALM}"
if [[ $DRY -eq 0 && "$TENANT_ENV" != staging && $APPROVE -ne 1 ]]; then
  refuse "apply ke realm ${REALM} (env ${TENANT_ENV}) butuh --approve (persetujuan eksplisit job)"
fi
DESIRED="$INFRA_DIR/identity/keycloak/realm/platform.json"
OVERRIDES="$INFRA_DIR/identity/keycloak/realm/${REALM}.overrides.json"
[[ -r "$DESIRED" ]] || die "desired-state tidak ada: $DESIRED"
PYARGS=(--desired "$DESIRED" --state)
[[ -f "$OVERRIDES" ]] && PYARGS=(--desired "$DESIRED" --overrides "$OVERRIDES" --state)

take_lock "kc-realm-sync-${REALM}"
kc_init "$REALM"

STATE="$(mktemp -d)"
trap 'rm -rf -- "$STATE"' EXIT
chmod 0700 "$STATE"

# save <file> <path> — GET path → JSON tanpa secret ke $STATE/<file> (status ≠ 200 → die dengan pesan jelas)
save() {
  mkdir -p "$(dirname "$STATE/$1")"
  kc_request GET "$2"
  [[ "$KC_STATUS" == 200 ]] || die "GET ${2:-<realm>}: HTTP ${KC_STATUS} — hak client kc-realm-sync kurang? (keycloak.md §Realm sebagai kode)"
  printf '%s' "$KC_BODY" | python3 "$PY" sanitize > "$STATE/$1"
  KC_BODY=""
}

gather() {
  rm -rf -- "${STATE:?}"/*
  save realm.json ""
  save profile.json /users/profile
  save client-scopes.json /client-scopes
  save clients.json "/clients?first=0&max=1000"
  [[ "$(kc_json 'str(len(d))' "$(cat "$STATE/clients.json")")" -lt 1000 ]] || die "≥ 1000 client — paging belum diimplementasikan"
  local kind id rest
  while read -r kind id rest; do
    case "$kind" in
      client)
        [[ "$id" =~ $UUID_RE ]] || die "uuid client tidak valid"
        save "clients/${id}/default.json" "/clients/${id}/default-client-scopes"
        save "clients/${id}/optional.json" "/clients/${id}/optional-client-scopes"
        save "clients/${id}/roles.json" "/clients/${id}/roles" ;;
      sa)
        [[ "$id" =~ $UUID_RE ]] || die "uuid client tidak valid"
        kc_request GET "/clients/${id}/service-account-user"
        if [[ "$KC_STATUS" == 200 ]]; then
          mkdir -p "$STATE/sa"
          printf '%s' "$KC_BODY" | python3 "$PY" sanitize > "$STATE/sa/${id}-user.json"
          sa_uid="$(kc_json 'd["id"]' "$(cat "$STATE/sa/${id}-user.json")")"
          [[ "$sa_uid" =~ $UUID_RE ]] || die "id user service account ${rest} tidak valid"
          RM_ID="$(python3 -c 'import json,sys; print(next(c["id"] for c in json.load(open(sys.argv[1])) if c.get("clientId") == "realm-management"))' "$STATE/clients.json")"
          save "sa/${id}-rm.json" "/users/${sa_uid}/role-mappings/clients/${RM_ID}"
        fi ;;
      rm)
        [[ "$id" =~ $UUID_RE ]] || die "uuid realm-management tidak valid"
        save rm-roles.json "/clients/${id}/roles" ;;
      flow)
        [[ "$id" =~ ^[A-Za-z0-9%._-]{1,128}$ ]] || die "alias flow tidak valid"
        save flow-executions.json "/authentication/flows/${id}/executions" ;;
      *) die "need: jenis tidak dikenal ${kind}" ;;
    esac
  done < <(python3 "$PY" need "${PYARGS[@]}" "$STATE")
}

# plan → $STATE/plan.json; cetak blocker/catatan; set NOPS, NBLOCK
plan() {
  python3 "$PY" plan "${PYARGS[@]}" "$STATE" > "$STATE/plan.json" || die "planner gagal"
  NOPS="$(kc_json 'str(len(d["ops"]))' "$(cat "$STATE/plan.json")")"
  NBLOCK="$(kc_json 'str(len(d["blockers"]))' "$(cat "$STATE/plan.json")")"
  kc_json '"\n".join(["CATATAN: " + n for n in d["notes"]] + ["BLOKIR: " + b for b in d["blockers"]])' \
    "$(cat "$STATE/plan.json")" | sed '/^$/d' | while IFS= read -r line; do log "$line"; done
}

TOTAL=0
round=1
while :; do
  gather
  plan
  if [[ $DRY -eq 1 ]]; then
    BLOCKERS=$NBLOCK
    kc_json '"\n".join(o["d"] for o in d["ops"])' "$(cat "$STATE/plan.json")" | sed '/^$/d' \
      | while IFS= read -r line; do log "PLAN: $line"; done
    TOTAL=$NOPS
    break
  fi
  [[ "$NBLOCK" -eq 0 ]] || die "${NBLOCK} blocker — tidak ada yang diterapkan (jalankan --dry-run untuk detail)"
  [[ "$NOPS" -gt 0 ]] || break
  [[ $round -le $MAX_ROUNDS ]] || die "tidak konvergen setelah ${MAX_ROUNDS} putaran (${NOPS} op tersisa)"
  executed=0
  for ((i = 0; i < NOPS; i++)); do
    op="$(kc_json "d['ops'][$i]" "$(cat "$STATE/plan.json")")"
    method="$(kc_json 'd["m"] or ""' "$op")"
    desc="$(kc_json 'd["d"]' "$op")"
    if [[ -z "$method" ]]; then
      log "TERTUNDA: ${desc}"
      continue
    fi
    path="$(kc_json 'd["p"]' "$op")"
    body="$(kc_json '"" if d["b"] is None else json.dumps(d["b"])' "$op")"
    read -r -a expect <<<"$(kc_json '" ".join(str(c) for c in d["e"])' "$op")"
    log "UBAH: ${desc}"
    kc_send "$method" "$path" "$body" "${expect[@]}"
    executed=$((executed+1))
  done
  TOTAL=$((TOTAL+executed))
  round=$((round+1))
done

extra=""; [[ $DRY -eq 1 ]] && extra=" blockers=${BLOCKERS}"
echo "RESULT realm=${REALM} changed=${TOTAL} mode=$([[ $DRY -eq 1 ]] && echo plan || echo apply)${extra}"
